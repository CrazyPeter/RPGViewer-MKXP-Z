// Upstream ANGLE's Metal backend expects a CALayer* as the EGL native window,
// not a UIWindow*. This ObjC++ helper extracts the layer from SDL's UIWindow.

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#include <SDL_syswm.h>

extern "C" void *mkxp_getANGLENativeLayer(void *sdlWindow) {
    SDL_SysWMinfo wmInfo;
    SDL_VERSION(&wmInfo.version);
    if (!SDL_GetWindowWMInfo((SDL_Window *)sdlWindow, &wmInfo))
        return nullptr;
    UIWindow *uiWindow = wmInfo.info.uikit.window;
    CALayer *layer = uiWindow.rootViewController.view.layer;

    // ANGLE bypasses SDL's EAGL view, which normally sets
    // contentScaleFactor = nativeScale for Retina rendering.
    // Without this, the Metal drawable is created at 1x resolution.
    layer.contentsScale = uiWindow.screen.nativeScale;

    return (__bridge void *)layer;
}

// Sync the CAMetalLayer (and its parent CALayer's contentsScale) to
// the current UIKit bounds on rotation. eglQuerySurface returns
// ANGLE's cached `mCurrentKnownDrawableSize` which only refreshes
// inside obtainNextDrawable - i.e., when the RGSS thread actually
// renders a frame. During a rotation event, the engine needs the
// new drawable dims immediately to post them to the RGSS thread,
// so we push them ourselves here.
//
// Must run on the main thread (CA layer mutations). Callable from
// any thread: dispatches synchronously to main if needed.
//
// Returns the post-refresh pixel dimensions in *outW / *outH. Both
// pointers are optional.
extern "C" void mkxp_refreshANGLENativeLayerSize(void *sdlWindow,
                                                 int *outW, int *outH) {
    __block CGFloat pixelW = 0;
    __block CGFloat pixelH = 0;

    dispatch_block_t work = ^{
        SDL_SysWMinfo wmInfo;
        SDL_VERSION(&wmInfo.version);
        if (!SDL_GetWindowWMInfo((SDL_Window *)sdlWindow, &wmInfo))
            return;
        UIWindow *uiWindow = wmInfo.info.uikit.window;
        if (uiWindow == nil)
            return;
        CALayer *parentLayer = uiWindow.rootViewController.view.layer;

        /* Resolve the scale from the window's own scene first.
         *
         * `uiWindow.screen` is nil while the window is still being attached
         * to a scene, and `nativeScale` on a nil screen is 0 — so every
         * size derived from it collapsed to *points* instead of pixels. The
         * engine then saw a drawable equal to the point size, concluded the
         * window was already 1x (backingScaleFactor 3.0 -> 1.0), and drew a
         * picture one third the intended size into a corner of the real
         * framebuffer. That is the "game sits in the bottom-left corner"
         * symptom, and it survived every relayout because the wrong scale
         * was baked into winSize before the picture maths ever ran. */
        UIScreen *uiScreen = uiWindow.windowScene.screen;
        if (uiScreen == nil)
            uiScreen = uiWindow.screen;
        CGFloat scale = uiWindow.traitCollection.displayScale;
        if (uiScreen.nativeScale > scale)
            scale = uiScreen.nativeScale;
        if (scale <= 0.0)
            scale = UIScreen.mainScreen.nativeScale;
        if (scale <= 1.0) {
            /* Still 1 on a Retina device: the lookups above raced window
             * attachment. The parent layer's contentsScale is the last
             * value we set, and if that is Retina too then this window
             * genuinely is not yet on a Retina screen — but the drawable
             * has to be sized for the screen it is about to land on, so
             * fall back to the main screen rather than silently shipping a
             * 1x drawable that shrinks the picture to a corner. */
            CGFloat fallback = UIScreen.mainScreen.nativeScale;
            if (fallback > scale)
                scale = fallback;
        }
        if (scale <= 0.0)
            scale = 2.0;

        // contentsScale may have drifted if the window was moved to
        // another screen (iPad multitasking). Re-apply each time.
        parentLayer.contentsScale = scale;

        /* The window's own bounds are authoritative. The root view
         * controller's layer can still be sized against the pre-rotation
         * screen for a frame or two, and that stale rect is exactly how the
         * wrong size reached the engine. Prefer the window frame and fall
         * back to the layer only when the window has no size yet. */
        CGRect bounds = uiWindow.bounds;
        if (CGRectIsEmpty(bounds) ||
            bounds.size.width <= 0.0 ||
            bounds.size.height <= 0.0) {
            bounds = parentLayer.bounds;
        }

        pixelW = bounds.size.width * scale;
        pixelH = bounds.size.height * scale;

        // Find ANGLE's CAMetalLayer sublayer and sync it to the parent.
        // ANGLE inserts its CAMetalLayer as a sublayer since our parent
        // is a plain CALayer rather than CAMetalLayer. On rotation, we
        // must update:
        //   - frame:        parent-relative rect (handles bounds +
        //                   position together. The layer's anchorPoint
        //                   and stale position would otherwise leave it
        //                   visually off-center after rotation)
        //   - contentsScale
        //   - drawableSize: the Metal texture size ANGLE renders into
        for (CALayer *sub in parentLayer.sublayers) {
            if ([sub isKindOfClass:[CAMetalLayer class]]) {
                CAMetalLayer *metal = (CAMetalLayer *)sub;
                metal.frame = bounds;
                metal.contentsScale = scale;
                metal.drawableSize = CGSizeMake(pixelW, pixelH);
            }
        }

    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }

    /* Last-resort correction.
     *
     * Everything downstream trusts that this function returns pixels: the
     * engine divides it by the window's point size to get
     * backingScaleFactor, and that factor is what sizes the picture. A
     * drawable that comes back the same size as the window in points means
     * the scale was lost somewhere above, and the picture silently shrinks
     * to 1/scale of the screen with no error anywhere -- which is exactly
     * how this bug presented as "the game sits in the bottom-left corner".
     *
     * Re-derive the pixel size from the window's point size and a scale that
     * cannot be 1 on a Retina device. The trait collection is consulted
     * first because it belongs to the window itself and stays valid while
     * `screen` is momentarily nil mid-attach. */
    if (outW && outH && pixelW > 0.0 && pixelH > 0.0) {
        __block CGSize pointSize = CGSizeZero;
        __block CGFloat verifyScale = 0.0;

        dispatch_block_t verify = ^{
            SDL_SysWMinfo wmInfo;
            SDL_VERSION(&wmInfo.version);
            if (!SDL_GetWindowWMInfo((SDL_Window *)sdlWindow, &wmInfo))
                return;
            UIWindow *uiWindow = wmInfo.info.uikit.window;
            if (uiWindow == nil)
                return;

            pointSize = uiWindow.bounds.size;

            // Per-window, so it does not depend on the screen being
            // attached yet.
            verifyScale = uiWindow.traitCollection.displayScale;

            UIScreen *uiScreen = uiWindow.windowScene.screen;
            if (uiScreen == nil)
                uiScreen = uiWindow.screen;
            if (uiScreen.nativeScale > verifyScale)
                verifyScale = uiScreen.nativeScale;
        };

        if ([NSThread isMainThread]) {
            verify();
        } else {
            dispatch_sync(dispatch_get_main_queue(), verify);
        }

        /* A scale of exactly 1 is the failure mode being corrected, so any
         * device that reports 1 while its parent layer carries a real
         * Retina scale is treated as a bad sample rather than as truth. */
        if (verifyScale <= 1.0) {
            __block CGFloat fallbackScale = 0.0;
            dispatch_block_t fallback = ^{
                SDL_SysWMinfo wmInfo;
                SDL_VERSION(&wmInfo.version);
                if (!SDL_GetWindowWMInfo((SDL_Window *)sdlWindow, &wmInfo))
                    return;
                UIWindow *uiWindow = wmInfo.info.uikit.window;
                if (uiWindow == nil)
                    return;
                CALayer *parentLayer = uiWindow.rootViewController.view.layer;
                // contentsScale was just set from the same scale source;
                // if the parent layer already carries a Retina value, the
                // window's own trait lookup was the stale one.
                fallbackScale = parentLayer.contentsScale;
                if (fallbackScale <= 1.0)
                    fallbackScale = UIScreen.mainScreen.nativeScale;
            };
            if ([NSThread isMainThread]) {
                fallback();
            } else {
                dispatch_sync(dispatch_get_main_queue(), fallback);
            }
            if (fallbackScale > verifyScale)
                verifyScale = fallbackScale;
        }

        if (verifyScale > 1.0 && pointSize.width > 0.0 && pointSize.height > 0.0) {
            CGFloat expectW = pointSize.width * verifyScale;
            CGFloat expectH = pointSize.height * verifyScale;

            // One pixel of slack for rounding.
            if (fabs(pixelW - expectW) > 1.0 || fabs(pixelH - expectH) > 1.0) {
                pixelW = expectW;
                pixelH = expectH;

                // Push the corrected size into the Metal layer as well, so
                // the next eglQuerySurface agrees with what we report here.
                dispatch_block_t apply = ^{
                    SDL_SysWMinfo wmInfo;
                    SDL_VERSION(&wmInfo.version);
                    if (!SDL_GetWindowWMInfo((SDL_Window *)sdlWindow, &wmInfo))
                        return;
                    UIWindow *uiWindow = wmInfo.info.uikit.window;
                    if (uiWindow == nil)
                        return;
                    CALayer *parentLayer = uiWindow.rootViewController.view.layer;
                    CGFloat s = uiWindow.windowScene.screen.nativeScale;
                    if (s <= 0.0)
                        s = verifyScale;
                    parentLayer.contentsScale = s;
                    for (CALayer *sub in parentLayer.sublayers) {
                        if ([sub isKindOfClass:[CAMetalLayer class]]) {
                            CAMetalLayer *metal = (CAMetalLayer *)sub;
                            metal.contentsScale = s;
                            metal.drawableSize =
                                CGSizeMake(pointSize.width * s,
                                           pointSize.height * s);
                        }
                    }
                };
                if ([NSThread isMainThread]) {
                    apply();
                } else {
                    dispatch_sync(dispatch_get_main_queue(), apply);
                }
            }
        }
    }

    if (outW) *outW = (int)pixelW;
    if (outH) *outH = (int)pixelH;
}

// ANGLE's GL_MAX_TEXTURE_SIZE can exceed the actual Metal device limit
// (e.g. ANGLE reports 16384 on simulator where Metal only supports 8192).
// Query the real limit by checking Metal GPU family support.
extern "C" int mkxp_getMetalMaxTextureSize(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return 4096;

#if TARGET_OS_SIMULATOR
    // Simulator Metal devices have stricter limits than the host GPU.
    // The GPU family checks report the host Mac's capabilities, not
    // the simulated device's. Hardcode the known simulator limit.
    return 8192;
#else
    // Real devices: use GPU family to determine the documented limit.
    // Apple3+ (A9 and later): 16384
    // Apple2 (A8): 8192
    // Apple1 (A7): 4096
    if ([device supportsFamily:MTLGPUFamilyApple3])
        return 16384;
    if ([device supportsFamily:MTLGPUFamilyApple2])
        return 8192;
    return 4096;
#endif
}
