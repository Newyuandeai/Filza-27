//
//  FilzaRemoteConsole.h
//  Filza-27 (FilzaApplySandboxExt)
//
//  Browser-based remote file viewer for Filza-27, served from inside the
//  injected Filza process over the GCDWebServer copy that this repo already
//  vendors (the same dependency the WebDAV runtime uses).
//
//  Contract: docs/API.md (FilzaRemote API v1). The web console that drives it
//  ships as FilzaRemoteWeb.bundle next to Filza3105.bundle.
//
//  Design rules this file follows, copied from the repo's own network runtime:
//    * preferences live in NSUserDefaults with explicit keys (WebDAVRuntimeV2.m)
//    * GCDWebServer owns the listener; no bespoke socket server is introduced
//    * every state transition is appended to FilzaSlop Logs + a status file
//    * the listener binds all interfaces but requires a pairing token
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// NSUserDefaults keys (mirrors FilzaWebDAV* / FilzaSSH* key style).
FOUNDATION_EXPORT NSString *const FilzaRemoteConsoleEnabledKey;
FOUNDATION_EXPORT NSString *const FilzaRemoteConsolePortKey;
FOUNDATION_EXPORT NSString *const FilzaRemoteConsoleTokenKey;
FOUNDATION_EXPORT NSString *const FilzaRemoteConsoleWritesKey;
FOUNDATION_EXPORT NSString *const FilzaRemoteConsoleDeletesKey;
FOUNDATION_EXPORT NSString *const FilzaRemoteConsoleBonjourKey;

/// Lifecycle.
FOUNDATION_EXPORT BOOL FilzaRemoteConsoleIsRunning(void);
FOUNDATION_EXPORT BOOL FilzaRemoteConsoleStart(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT void FilzaRemoteConsoleStop(void);
FOUNDATION_EXPORT BOOL FilzaRemoteConsoleEnabled(void);

/// Configuration.
FOUNDATION_EXPORT NSInteger FilzaRemoteConsoleConfiguredPort(void);
FOUNDATION_EXPORT void FilzaRemoteConsoleSetConfiguredPort(NSInteger port);
FOUNDATION_EXPORT NSString *FilzaRemoteConsoleToken(void);
FOUNDATION_EXPORT NSString *FilzaRemoteConsoleRotateToken(void);
FOUNDATION_EXPORT BOOL FilzaRemoteConsoleWritesEnabled(void);
FOUNDATION_EXPORT BOOL FilzaRemoteConsoleDeletesEnabled(void);
FOUNDATION_EXPORT void FilzaRemoteConsoleSetWritesEnabled(BOOL enabled);
FOUNDATION_EXPORT void FilzaRemoteConsoleSetDeletesEnabled(BOOL enabled);

/// Reporting (used by the preferences section and the diagnostics console).
FOUNDATION_EXPORT NSString *_Nullable FilzaRemoteConsoleURLString(void);
FOUNDATION_EXPORT NSString *_Nullable FilzaRemoteConsolePairingURLString(void);
FOUNDATION_EXPORT void FilzaRemoteConsoleWriteStatus(NSString *message);
FOUNDATION_EXPORT NSString *_Nullable FilzaRemoteConsoleStatusPath(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *FilzaRemoteConsoleSnapshot(void);

/// Static web console bundle (FilzaRemoteWeb.bundle) and its URL, if installed.
FOUNDATION_EXPORT NSBundle *_Nullable FilzaRemoteConsoleResourceBundle(void);

#pragma mark - Shared plumbing used by FilzaRemoteConsole.m / FilzaRemoteConsoleAPI.m

/// Registered by FilzaRemoteConsoleAPI.m: installs every /api/v1 handler plus
/// the static console handler on the given server.
FOUNDATION_EXPORT void FilzaRemoteConsoleInstallHandlers(void *server);

/// True when the request carries the current pairing token (header, bearer or
/// `?token=`). Comparison is constant time.
FOUNDATION_EXPORT BOOL FilzaRemoteConsoleRequestAuthorized(void *request);

/// Records a request for GET /api/v1/clients.
FOUNDATION_EXPORT void FilzaRemoteConsoleRecordRequest(NSString *method,
                                                       NSString *path,
                                                       NSInteger status,
                                                       int64_t milliseconds,
                                                       NSString *_Nullable remote,
                                                       NSString *_Nullable userAgent);

/// JSON helpers shared by the handlers.
FOUNDATION_EXPORT id FilzaRemoteConsoleErrorBody(NSString *code, NSString *message);
FOUNDATION_EXPORT id FilzaRemoteConsoleErrorBodyWithExtra(NSString *code, NSString *message, NSDictionary *_Nullable extra);
FOUNDATION_EXPORT id FilzaRemoteConsoleOKBody(NSDictionary *_Nullable pairs);

/// Virtual-path handling for API v1 (see docs/API.md §3).
/// Roots are: /Filza (Filza container + its visible tree), /Media (photo/video
/// library export root), /System (read-only system paths Filza can read).
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleRoots(void);
FOUNDATION_EXPORT NSString *_Nullable FilzaRemoteConsoleResolveVirtualPath(NSString *virtualPath,
                                                                          NSString *_Nullable *_Nullable rootName,
                                                                          NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT NSString *_Nullable FilzaRemoteConsoleVirtualPathForAbsolutePath(NSString *absolutePath);

NS_ASSUME_NONNULL_END
