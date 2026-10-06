//
//  TryMaskCardShell.h
//  Filza-27 (FilzaApplySandboxExt)
//
//  Chat-first shell. The IPA that carries this module boots straight into the
//  remote chat surface (default https://trymaskcard.com/) and never presents
//  Filza's file manager UI. Everything underneath - MCM virtual root, kernel
//  sandbox escape, SSH/SFTP, WebDAV and the remote browser console - keeps
//  running exactly as before, because none of those runtimes depend on Filza's
//  view controllers.
//
//  Activation is data-driven, not a compile-time switch:
//    * TryMaskCardShell.plist next to the app binary activates the shell.
//    * No plist (the normal Filza-27 release path) => module is fully inert.
//    * NSUserDefaults key TryMaskCardShellEnabled overrides the plist at runtime
//      for device-side testing.
//
//  See docs/CHAT_SHELL.md for the packaging contract and rollback.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// YES once the shell owns the key window root (TryMaskCardShell.plist present
/// and not disabled). Read by Tweak.m when it repairs the initial browser path.
FOUNDATION_EXPORT BOOL TryMaskCardShellIsActive(void);

/// The file manager root controller Filza asked to display, retained but never
/// rooted in a window while the shell is active. Returns nil when the shell is
/// inactive (the normal release build) or before Filza sets its first root.
FOUNDATION_EXPORT UIViewController *_Nullable TryMaskCardShellHiddenRootController(void);

/// Configured chat home page. Falls back to https://trymaskcard.com/.
FOUNDATION_EXPORT NSString *TryMaskCardShellHomeURLString(void);

/// Raw value from the packaged TryMaskCardShell.plist (nil when the file or the
/// key is absent). Coordinated modules read their own keys through this so the
/// configuration is parsed exactly once.
FOUNDATION_EXPORT id _Nullable TryMaskCardShellConfigRaw(NSString *key);

/// Installs every runtime hook. Called from the module constructor; exposed so
/// an operator can re-arm the shell after a warm relaunch in a debug session.
FOUNDATION_EXPORT void TryMaskCardShellInstall(void);

/// Presents / dismisses the retained file manager. Only honoured when the
/// packaged TryMaskCardShell.plist allows a hidden on-device entry.
FOUNDATION_EXPORT BOOL TryMaskCardShellOpenHiddenFileManager(void);
FOUNDATION_EXPORT void TryMaskCardShellCloseHiddenFileManager(void);

/// Diagnostics one-liners (also appended to the FilzaSlop log via
/// FilzaDiagnosticsAppend(@"ChatShell", ...)).
FOUNDATION_EXPORT NSDictionary<NSString *, id> *TryMaskCardShellSnapshot(void);

NS_ASSUME_NONNULL_END
