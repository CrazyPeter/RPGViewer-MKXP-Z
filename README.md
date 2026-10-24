# RPGViewer-MKXP-Z

> RPGViewer 在 iOS / iPadOS 上跑 RPG Maker XP / VX / VX Ace 用的 mkxp-z 引擎。
>
> 本仓库只有引擎。宿主 App 与界面都不在这里，引擎对外的全部能力收敛在 `src/app_bridge.h`。


---

## 目录

- [整体架构](#整体架构)
- [唯一的接口：app_bridge.h](#唯一的接口app_bridgeh)
- [三个关键设计](#三个关键设计)
- [视口：从「左下角 1/3」到稳定铺满](#视口从左下角-13-到稳定铺满)
- [构建链](#构建链)
- [踩坑清单](#踩坑清单)
- [目录结构](#目录结构)
- [从零构建](#从零构建)
- [许可](#许可)
- [致谢](#致谢)

---

## 整体架构

```
┌──────────────────────────────────────────────────────────────┐
│  mkxp-z core  (this repo, C++ / ObjC++)                      │
│                                                              │
│   main.cpp (EngineHost)   display/graphics   audio           │
│   eventthread             filesystem         patcher         │
│                                                              │
│   ANGLE  ──  OpenGL ES over Metal  ──▶  CAMetalLayer         │
│   Ruby 1.8 / 1.9 / 3.1   ── 三套 merged .o，运行时择一        │
└──────────────────────────────────────────────────────────────┘
```

图里只有引擎这一侧。它上面还有一个宿主 App，本仓库不含它，只约定接口。

宿主与引擎之间只有两条硬规矩，违反任何一条都会在真机上以极难定位的方式爆掉：

1. **宿主侧不 import 任何引擎头**（`SDL.h`、`sharedstate.h`、`config.h` 都不行）。宿主只认识 `app_bridge.h` 里的函数和 C 枚举。
2. **引擎侧不 import 任何宿主头**（`UIKit`、`Foundation` 只出现在平台 `.mm` 里，且不向上层暴露）。

两条合起来：引擎可以编成静态库扔给任何宿主，宿主也可以整体换掉而不动引擎一行。

---

## 唯一的接口：app_bridge.h

`src/app_bridge.h` 是全部的契约。按用途分组：

| 分组 | 代表函数 | 说明 |
|---|---|---|
| 会话握手 | `mkxp_setGamePath` / `mkxp_waitForGamePath` / `mkxp_abandonSession` / `mkxp_waitForNativeGamePath` | 宿主把游戏目录交给引擎；空路径表示「这局不是你的」 |
| 会话配置 | `mkxp_applySessionConfig` / `mkxp_setActiveRubyVersion` / `mkxp_setSyntaxTransformMode` | 每次启动前一次性配好 Ruby 与语法变换 |
| 目录重定向 | `mkxp_setManagedConfigDir` / `mkxp_setUserDataDirectory` / `mkxp_setSharedFontsDirectory` | 配置与存档落到宿主管理的位置，游戏目录保持导入时的原样 |
| 输入注入 | `mkxp_injectKeyEvent` / `mkxp_pushTextInput` | 键位按 **SDL scancode** 传，软键盘文本按 UTF-8 分片推入 |
| 视口 | `mkxp_setHostViewportRegion` / `mkxp_setSafeAreaInsets` / `mkxp_setGameRect` | 宿主可以把画面限制在子矩形里，引擎侧只做布局 |
| 错误与提示 | `mkxp_presentErrorAndWait` / `mkxp_presentInfoAndWait` | 阻塞式。iOS 上 `SDL_ShowSimpleMessageBox` 是空实现，只能走这条路 |
| 生命周期 | `mkxp_requestTerminate` / `mkxp_requestPause` / `mkxp_requestResume` | 请求，不是命令；引擎自己决定何时收尾 |
| 性能与诊断 | `mkxp_getAverageFPS` / `mkxp_getTargetFPS` / `mkxp_getANGLEVersion` | 面板数字全部来自引擎实测，不猜 |

### 非移动端自动退化为 no-op

这个头文件最省事的一点：`MKXPZ_MOBILE == 0` 时，整份 API 变成 `static inline` 空实现（见文件末尾）。

于是引擎代码里可以无条件写 `mkxp_debugLog(...)`、`mkxp_getScreenScale()`，不需要在调用点套 `#ifdef`；链接桌面版也不需要 `app_bridge.cpp`，编译器会把它们全部删掉。桌面构建保持与上游 mkxp-z 完全一致的行为。

代价是每个默认值都要想清楚。stub 里有两处刻意与移动端默认值相反，注释写明了原因：

- `mkxp_getNetworkEnabled()` 返回 `true` —— 桌面没有联网开关，不能凭空假装飞行模式。
- `mkxp_getVerticalAlignment()` 返回 `CENTER` —— 桌面窗口居中，移动端才用 `TOP` 把画面顶上去给手柄留位置。

---

## 三个关键设计

### 1. 引擎常驻，一个进程只 boot 一次

iOS 上 `main()` 就是宿主 App 的 `main()`。引擎是静态库不是子进程，所以它**没有权利退出**：一旦返回，UIKit 跟着一起走，整个进程直接结束。

因此引擎的生命周期是「一次启动，全程常驻」：

```
进程启动
  └─ EngineHost::init()   等一个游戏路径（同时 pump run loop，否则 UIKit 冻死）
       └─ 拿到路径 → SDL_Init → 创建窗口 → 跑 Ruby → 游戏结束
            └─ 清理会话状态，回到等待，等下一个游戏
```

SDL、ANGLE 的 EGL 上下文、OpenAL 设备、Ruby VM 全部跨游戏复用。换游戏只是换一个路径，不是重启引擎。

这条约束直接决定了两件事：会话状态必须在每次启动前重置（否则上一个游戏的快进倍率、作弊开关会漏到下一个）；以及，引擎要能分辨「这一局该我跑」和「这一局不该我跑」。

### 2. 空路径握手

```c
/* 宿主：这一局不是给你的，但别死，standby */
void mkxp_abandonSession(void) { mkxp_setGamePath(""); }

/* 引擎：空值不算唤醒，等到真的路径再启动 */
const char *mkxp_waitForNativeGamePath(void);
```

`main()` 里对应的一段：

```c
const char *selectedPath = mkxp_waitForGamePath();
if (selectedPath && selectedPath[0])
    snprintf(dataDir_, sizeof(dataDir_), "%s", selectedPath);

if (dataDir_[0] == '\0') {
    Debug() << "Web game selected; engine standing by.";
    const char *native = mkxp_waitForNativeGamePath();
    snprintf(dataDir_, sizeof(dataDir_), "%s", native);
}
```

### 3. 三套 Ruby 并行

一个 Ruby 跑不了所有 RPG Maker 游戏。新一点的 PE 分支要 3.1，早期 XP 游戏是按 1.8 的解析器写的。所以三套都编，运行时选：

```
libruby18-static.a  + binding18 ─┐
libruby.3.1-static.a + binding31 ├─▶ 各自 ld -r 合并成 mkxpNN-merged.o（符号隐藏）
libruby19-static.a  + binding19 ─┘
                                     └─▶ libtool -static -o libmkxp-ruby.a
```

三个 merged object 必须全部链接进来，一个都不能少：`binding.h` 声明了所有入口点并在运行时 dispatch，少一个就是链接错误，哪怕这个游戏只用一种 Ruby。

宿主每次启动前调 `mkxp_setActiveRubyVersion(MKXP_RUBY_18 / 19 / 31)`。选 3.1 时通常同时打开 `MKXP_SYNTAX_TRANSFORM_LEGACY`，让引擎在载入阶段把 1.8 风格的写法就地改写成 3.1 能解析的形式。

---

## 视口：从「左下角 1/3」到稳定铺满

这是本项目花时间最多的 bug，也是唯一改到渲染核心逻辑的修复，值得写清楚。

**现象**：进游戏后画面只占屏幕左下角约 1/3；转一次屏或切一次后台回来自动恢复。

**最初的怀疑对象全错了**：宿主 relayout、safe area、旋转回调、`VALIGN` 设置，逐个排查都不是。

**真因**在 `graphics.cpp` 的 `checkResize` 里，一行被丢弃的返回值：

```c
Vec2i drawableSize(winSize);                    // 种子值是 winSize，单位是「点」
threadData->drawableSizeMsg.poll(drawableSize); // 返回值被丢掉了
```

`UnidirMessage::poll` 在队列为空时 `return false`，并且**完全不碰传入的 out 参数**。于是 `drawableSize` 保留了点单位的种子值：

```
bsf = drawableSize.x / winSize.x = 402 / 402 = 1.0
```

3x 屏幕上 `backingScaleFactor` 从 3.0 塌成 1.0，`scSize` 缩成三分之一，画面被画进真实 framebuffer 的一角。**而且全程零报错**——402/402=1 完全自洽，日志里每个数字看起来都合理。

**修法**：`poll` 返回 false 时用屏幕 scale 把点换算成像素。

```c
if (!threadData->drawableSizeMsg.poll(drawableSize)) {
    float uiScale = mkxp_getScreenScale();
    if (uiScale > 0.0f) {
        drawableSize = Vec2i((int)(winSize.x * uiScale + 0.5f),
                             (int)(winSize.y * uiScale + 0.5f));
    }
}
```

同时补了三处稳健性（不是这个 bug 的主因，但都是真实隐患）：

- **scale 来源分级**：先 `windowScene.screen`，再 `window.screen`，最后 `UIScreen.mainScreen`。原代码只用 `uiWindow.screen`，而窗口还没挂到 scene 时它是 `nil`，`nil.nativeScale` 是 0，所有派生尺寸当场塌成点数。
- **bounds 优先用窗口自身**，而不是 `rootViewController.view.layer`。旋转后一到两帧内 layer 还是旧尺寸。
- **`mkxpGL_GetDrawableSize` 优先采用 layer tree 的尺寸**。`eglQuerySurface` 只返回 ANGLE 上次 `obtainNextDrawable` 时缓存的值，resize 之后给的是**上一个**尺寸——而它正是把 bsf 带偏的源头。

修复后 `bsf` 全程稳定在 3.000，`gameRect` 恢复铺满宽度。

> 这类 bug 的共同点：不 crash、不报错、每个中间量单独看都合理。能定位它靠的是把 `backingScaleFactor` 打出来——所以引擎里保留了 `mkxp_debugLog`，`RPGVIEWER_ENGINELOG` 一开就有一条 per-resize 记录。

---

## 构建链

```
tools/fetch-deps-ios.sh     拉预编译依赖（SDL2 / pixman / OpenAL / physfs /
                             freetype / openssl / uchardet / theora + ANGLE）
        │
        ▼
tools/build-core-ios.sh     src/ 全部源码 → libmkxpz-core.a
        │                   （renderer / audio / event loop / fs / bridge）
        ▼
tools/build-binding-ios.sh × 3   binding/ + hmode7/ → mkxp18/19/31-merged.o
        │
        ▼
libtool -static             → libmkxp-ruby.a
        │
        ▼
build/<sdk>-arm64/lib/      宿主 Xcode 工程链接这两个 .a
```

两个产物刻意分开：core 是纯 C++，不依赖任何 Ruby；Ruby 那一半按版本各编各的，再合并成一个归档。宿主用 `-lmkxpz-core -lmkxp-ruby` 两条链接名就够，不需要知道绝对路径。

### 为什么宿主工程要两个 target

`iphoneos` 与 `iphonesimulator` 的产物不能共用。而在 Xcode 里**没法**在构建时选路径：build settings 在任何 scheme pre-action 或 build phase 之前就已解析完，且 Xcode 在构建 task graph 时就要校验显式链接输入是否存在——用环境变量、symlink 还是 `SRCROOT` 拼路径，到那时候都已经晚了。

所以宿主的 `project.yml` 里是两个 target，路径写死：

| Scheme | 产物目录 |
|---|---|
| `RPGViewer` | `build/iphoneos-arm64/lib` |
| `RPGViewerSimulator` | `build/iphonesimulator-arm64/lib` |

源码、Info.plist 完全一样，只有二进制路径不同。两个目录在构建开始前都已存在，没有解析、没有校验问题。

---

## 踩坑清单

按踩到的顺序记，都是「看起来不可能出错」的那类：

1. **`UnidirMessage::poll` 失败时不动 out 参数。** 种子值单位是点，除出来恰好等于 1，于是所有数字自洽。见上文。
2. **`eglQuerySurface` 是缓存值，不是实时值。** resize 之后仍返回上一次 `obtainNextDrawable` 的尺寸，拿它算 bsf 必偏。
3. **`uiWindow.screen` 可能是 `nil`。** 窗口尚未挂到 scene 时取不到，`nil.nativeScale` 为 0，整条尺寸链塌成点数。必须分级回退到 `UIScreen.mainScreen`。
4. **编译参数变了不会触发重编。** 时间戳没变，`.o` 全部判定为最新，链接器也不报错——故障只在真机上出现。现在参数变化写进 `.build-flags`，并全量重编。
5. **Xcode build phase 里 `set -euo pipefail` + `awk` 会静默失败。** `xcrun otool` 在赋值里失败会被 `pipefail` 直接中止；`awk` 提前 `exit` 会让上游 `printf` 收到 `Broken pipe`。两个问题在 phase 里的表现都是「失败且无任何输出」。改用先落临时文件再读。
6. **`deps/` 里 30 个预编译库仍是 26.0 且无源码。** 链接期告警还在，只能等依赖重新出包。
7. **宿主 `gameRect` 不能在主线程同步 dispatch 到主队列。** 会死锁，表现为 App 直接回桌面。引擎在布局回调里就把它拷到主队列，读取侧直接读。

---

## 目录结构

```
src/
  app_bridge.h / .cpp      引擎 ↔ 宿主的唯一 C 接口（移动端实现 / 桌面端 no-op）
  main.cpp                 EngineHost：等待游戏路径、SDL 初始化、GL drawable 尺寸
  angle_native_layer.mm    ANGLE 的 CAMetalLayer 尺寸与 scale 同步
  ios_fatal_report.mm      ObjC 异常 / C++ 异常统一转成引擎错误路径
  display/graphics.cpp     渲染主循环、视口与 checkResize
  eventthread.cpp          SDL 事件泵、按键与文本输入
  audio/ filesystem/ net/ crypto/ binding.h

binding/                   Ruby 绑定（1.8 / 1.9 / 3.1 共用一套源码）
hmode7/                    游戏内作弊菜单等扩展（原为子模块，已内联到本仓库）
multiruby/                 多 Ruby 符号隐藏与合并
syntax-transform/          1.8 → 3.x 的语法变换补丁
deps/                      依赖交叉编译体系（makefile + 各库补丁，不含源码包）
tools/                     fetch-deps / build-core / build-binding / 测试脚本
tests/                     C++ 单测、引擎内 Ruby 测试、iOS 测试宿主
assets/                    字体（Liberation Sans + 文泉驿微米黑）、CA 证书、手柄映射
```

---

## 从零构建

前置：macOS + Xcode 命令行工具、可用的 iOS SDK。

```bash
# 1. 拉预编译依赖（按 deps/.version 固定版本，校验 sha256 后才解包）
tools/fetch-deps-ios.sh --sdk iphoneos
#    → deps/build-iphoneos-arm64/{lib,include,ruby-stdlib}
#    → deps/ANGLE/iphoneos/{lib,include}

# 2. 编引擎核心（--min-os 必须与宿主部署目标一致）
DEPS=deps/build-iphoneos-arm64
tools/build-core-ios.sh --sdk iphoneos --min-os 15.0 \
    --out "$DEPS/lib" --obj "$DEPS/core-obj" \
    --include "$DEPS/include" \
    --include "$DEPS/include/SDL2" \
    --include "$DEPS/include/freetype2" \
    --include "$DEPS/include/pixman-1" \
    --include "$DEPS/include/ogg" \
    --include "$DEPS/include/openssl" \
    --include "$DEPS/include/uchardet" \
    --include "$DEPS/include/theora" \
    --include "$DEPS/include/vorbis" \
    --include "$DEPS/include/libpng16" \
    --include "$DEPS/include/AL" \
    --include "deps/ANGLE/iphoneos/include"

# 3. 三个 Ruby 各编一次，然后合并成一个归档
tools/build-binding-ios.sh --ruby 18 --sdk iphoneos --min-os 15.0 ...
tools/build-binding-ios.sh --ruby 19 --sdk iphoneos --min-os 15.0 ...
tools/build-binding-ios.sh --ruby 31 --sdk iphoneos --min-os 15.0 ...
( cd "$DEPS/lib" && libtool -static -o libmkxp-ruby.a \
    mkxp18-merged.o mkxp19-merged.o mkxp31-merged.o )
```

宿主编译时链接 `libmkxpz-core.a` + `libmkxp-ruby.a`，并把 `src/` 加入头文件搜索路径（宿主只需要 `app_bridge.h`）。完整参数见 `tools/build-core-ios.sh` 与 `tools/build-binding-ios.sh` 的头部注释。

> 本仓库不附带预编译产物。`deps/ANGLE/`、`deps/sources/`、`deps/build-*/` 均在 `.gitignore` 内，请按 `deps/.version` 记录的版本自行拉取。

---

## 许可

引擎是 **GPLv2+**，全文见 `COPYING`。

- 可以自由使用、修改、再分发，包括商用。
- 一旦**分发**出去（App Store、TestFlight、直接发 IPA 都算），必须同时提供对应源码。
- 静态链接 GPL 库的宿主程序，整体会被视为衍生作品——这是使用 GPL 引擎必须接受的代价，不会因为宿主代码私有而消失。

若开启 `enable-https`（默认开启），还需遵守 OpenSSL 的 Apache v2 条款，实际效果是产物按 GPLv3 分发，详见 `assets/LICENSE.mkxp-z-with-https.txt`。

本仓库不含任何游戏资源。

---

## 致谢

- **Ancurio** —— 写了 mkxp
- **mkxp-z 维护者** —— 把 mkxp 推进到能跑现代 RGSS 项目
- **genexix05** —— `mkxp-z-apple-mobile`：iOS 平台层、`app_bridge.h`、ANGLE 与三 Ruby 并行的整体设计都来自这里
- **mateo-m** —— `empo-deps`（预编译依赖）、`hmode7`、Empo 的 iOS 实践
- **JoiPlay** —— Ruby 1.8 / 1.9 的 iOS 补丁基础
- 以及所有在 issue 和补丁里留下痕迹的人
