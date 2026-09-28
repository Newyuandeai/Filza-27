//
//  FilzaRemoteConsoleInternal.h
//  Filza-27 (FilzaApplySandboxExt)
//
//  Declarations shared between FilzaRemoteConsole.m (lifecycle) and
//  FilzaRemoteConsoleAPI.m (API v1 handlers). Not part of the public surface.
//

#import <Foundation/Foundation.h>
#import "GCDWebServer.h"

NS_ASSUME_NONNULL_BEGIN

/// Installs one API handler wrapped with CORS, token authorisation, timing and
/// request logging (see FilzaRemoteConsole.m).
void FilzaRemoteConsoleAddHandler(GCDWebServer *server,
                                  NSString *method,
                                  NSString *path,
                                  GCDWebServerProcessBlock block);

/// Same, but with an explicit request class — uploads need the body on disk
/// (GCDWebServerFileRequest) or multipart parsing (GCDWebServerMultiPartFormRequest)
/// instead of the default in-memory GCDWebServerDataRequest.
void FilzaRemoteConsoleAddHandlerWithClass(GCDWebServer *server,
                                           NSString *method,
                                           NSString *path,
                                           Class requestClass,
                                           GCDWebServerProcessBlock block);

/// Same wrapper, but without the token requirement (GET /api/v1/ping and the
/// CORS preflight, exactly as docs/API.md §4.1 specifies).
void FilzaRemoteConsoleAddOpenHandler(GCDWebServer *server,
                                      NSString *method,
                                      NSString *pathRegex,
                                      GCDWebServerProcessBlock block);

/// Implemented by FilzaRemoteConsoleFileOps.m: uploads, mutations, ZIP and SSE.
void FilzaRemoteConsoleInstallFileOpsHandlers(GCDWebServer *server);

/// Shared JSON body reader for POST endpoints (returns an empty dictionary when
/// the body is absent or not JSON).
NSDictionary<NSString *, id> *_Nullable FilzaRemoteConsoleJSONBody(GCDWebServerRequest *request);

/// Virtual path resolution, extended variant returning the root dictionary.
NSDictionary<NSString *, id> *_Nullable FilzaRemoteConsoleResolveRoot(NSString *rootName);

/// Request log snapshots backing GET /api/v1/clients.
NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleRequestLogEntries(void);
NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleClientEntries(void);

/// Upload staging suffix (never listed, never downloadable) — matches
/// docs/API.md §3.3.
FOUNDATION_EXPORT NSString *const FilzaRemoteConsolePartialSuffix;

/// MIME lookup used by /download and /thumb.
FOUNDATION_EXPORT NSString *FilzaRemoteConsoleMimeTypeForPath(NSString *path);

/// Kind classification used by /list entries.
FOUNDATION_EXPORT NSString *FilzaRemoteConsoleKindForPath(NSString *path, BOOL directory);

NS_ASSUME_NONNULL_END
