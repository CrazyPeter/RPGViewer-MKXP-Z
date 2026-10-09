// RPGViewerLauncher.m - our Objective-C host for the mkxp-z engine.
//
// Phase 0 smoke launcher: boots one real RPG Maker XP game (turkey0.5)
// out of the app bundle, selects Ruby 1.8 for it (RGSS1 -> Ruby 1.8),
// and lets the engine run. Mirrors the engine's own test host (see
// engine/tests/host/host.m) with two changes that matter for us:
//
//   1. it picks a Ruby version via mkxp_setActiveRubyVersion(), which is
//      the same call our real library UI will make per game once we
//      detect the engine from the imported folder;
//   2. it names our own launcher identity ($rpgviewer), matching the
//      per-launcher detection contract in app_bridge.h.
//
// The engine's main() blocks in mkxp_waitForGamePath() until a host
// names a folder, so the work happens from a main-queue block pushed in
// the constructor. Doing it in the constructor proper would run before
// the C++ statics in app_bridge.cpp are constructed and the values
// would be wiped.
//
// Engine: mkxp-z (Apple mobile fork), GPLv2+.

#import <Foundation/Foundation.h>

#import "app_bridge.h"

// Copy the bundled game out of the read-only bundle. The engine writes a
// path cache next to the game, so it needs a writable folder.
static NSString *prepareGameFolder(NSString *source, NSString *documents) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *target = [documents stringByAppendingPathComponent:@"Game"];

    [fm removeItemAtPath:target error:nil];

    NSError *error = nil;
    if ([fm copyItemAtPath:source toPath:target error:&error])
        return target;

    NSLog(@"[launcher] could not copy the game folder: %@", error);
    return source;
}

static void rpgViewerLauncherStart(void) {
    @autoreleasepool {
        NSString *resources = NSBundle.mainBundle.resourcePath;
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

        NSString *game = prepareGameFolder(
            [resources stringByAppendingPathComponent:@"Game"], documents);

        // Our launcher identity: exposes $rpgviewer = true to game
        // scripts before any preload/game code runs.
        mkxp_setLauncherIdentity("rpgviewer");

        // turkey0.5 declares rgssVersion 1 (XP) but its scripts use
        // modern Ruby syntax (lambda literals, leading-dot chaining),
        // which the 1.8 parser rejects. Dispatch 1.9 so they parse.
        // Real library code will pick this per game by probing the
        // script set, not by trusting mkxp.json.
        mkxp_setActiveRubyVersion(MKXP_RUBY_19);
        mkxp_setSyntaxTransformMode(MKXP_SYNTAX_TRANSFORM_LEGACY);

        // Keep imported game folders pristine: engine-writable payload
        // (saves, path cache) goes to a per-game container instead.
        NSString *userData =
            [documents stringByAppendingPathComponent:@"UserData"];
        [NSFileManager.defaultManager createDirectoryAtPath:userData
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        mkxp_setUserDataDirectory(userData.fileSystemRepresentation);

        // Host-wide font pool, shared by every game, like the Windows
        // system font folder. Supplies the CJK fallback font too.
        mkxp_setSharedFontsDirectory(
            [resources stringByAppendingPathComponent:@"Assets.bundle/Fonts"]
                .fileSystemRepresentation);

        // Mozilla root store for Ruby's openssl ext and the native HTTP
        // client. Without it TLS fails closed.
        mkxp_setCABundlePath(
            [resources stringByAppendingPathComponent:@"Assets.bundle/cacert.pem"]
                .fileSystemRepresentation);

        // Read mkxp.json from the game folder rather than the cwd.
        mkxp_setManagedConfigDir(game.fileSystemRepresentation);

        // Default to a letterboxed, centered picture.
        mkxp_applyPerGameSettings(MKXP_VALIGN_CENTER, /*postloadEnabled*/ true);

        NSLog(@"[launcher] game folder: %@", game);
        NSLog(@"[launcher] ruby: %s", mkxp_getRubyVersion());

        mkxp_setGamePath(game.fileSystemRepresentation);
    }
}

__attribute__((constructor)) static void rpgViewerLauncherInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        rpgViewerLauncherStart();
    });
}
