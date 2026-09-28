//
//  FilzaRemoteConsole.m
//  Filza-27 (FilzaApplySandboxExt)
//
//  Listener lifecycle, pairing token, static console hosting, request log and
//  status reporting for the remote file viewer. Endpoint handlers live in
//  FilzaRemoteConsoleAPI.m so both files stay reviewable.
//
//  Mirrors the structure of WebDAVRuntimeV2.m (this repo's own GCDWebServer
//  runtime) rather than introducing a second networking stack.
//

@import Foundation;
@import UIKit;
@import Security;

#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerRequest.h"

#import "FilzaDiagnostics.h"
#import "FilzaRemoteConsole.h"
#import "FilzaRemoteConsoleInternal.h"

#pragma mark - Keys

NSString *const FilzaRemoteConsoleEnabledKey = @"filza-remote-console-enabled";
NSString *const FilzaRemoteConsolePortKey = @"filza-remote-console-port";
NSString *const FilzaRemoteConsoleTokenKey = @"filza-remote-console-token";
NSString *const FilzaRemoteConsoleWritesKey = @"filza-remote-console-writes";
NSString *const FilzaRemoteConsoleDeletesKey = @"filza-remote-console-deletes";
NSString *const FilzaRemoteConsoleBonjourKey = @"filza-remote-console-bonjour";

static NSString *const FilzaRemoteConsoleComponent = @"RemoteConsole";
static NSString *const FilzaRemoteConsoleStatusFile = @"RemoteConsoleStatus.txt";
static NSString *const FilzaRemoteConsoleBundleName = @"FilzaRemoteWeb";
static const NSInteger FilzaRemoteConsoleDefaultPort = 8788;
static const NSUInteger FilzaRemoteConsoleLogCapacity = 500;

#pragma mark - State

static GCDWebServer *FilzaRemoteConsoleServer = nil;
static BOOL FilzaRemoteConsoleStartInFlight = NO;
static BOOL FilzaRemoteConsoleHandlersInstalled = NO;
static NSMutableArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleRequestLog = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *FilzaRemoteConsoleClients = nil;

static NSArray<NSString *> *FilzaRemoteConsoleTokenAlphabet(void)
{
    static NSArray<NSString *> *alphabet = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *characters = [NSMutableArray array];
        NSString *source = @"ABCDEFGHJKMNPQRSTVWXYZ23456789";
        for (NSUInteger index = 0; index < source.length; index++) {
            [characters addObject:[source substringWithRange:NSMakeRange(index, 1)]];
        }
        alphabet = characters;
    });
    return alphabet;
}

/// 128-bit-class pairing token, displayed as five groups of four characters
/// (same presentation as the API contract documents).
static NSString *FilzaRemoteConsoleGenerateToken(void)
{
    NSArray<NSString *> *alphabet = FilzaRemoteConsoleTokenAlphabet();
    uint8_t bytes[20] = {0};
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        for (size_t index = 0; index < sizeof(bytes); index++) {
            bytes[index] = (uint8_t)arc4random_uniform(256);
        }
    }
    NSMutableString *raw = [NSMutableString stringWithCapacity:20];
    for (size_t index = 0; index < sizeof(bytes); index++) {
        [raw appendString:alphabet[bytes[index] % alphabet.count]];
    }
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (NSUInteger index = 0; index + 4 <= raw.length; index += 4) {
        [groups addObject:[raw substringWithRange:NSMakeRange(index, 4)]];
    }
    return [groups componentsJoinedByString:@"-"];
}

/// Constant-time comparison so token guessing cannot be timed.
static BOOL FilzaRemoteConsoleTokenEquals(NSString *left, NSString *right)
{
    NSData *a = [left dataUsingEncoding:NSUTF8StringEncoding];
    NSData *b = [right dataUsingEncoding:NSUTF8StringEncoding];
    if (a.length != b.length || a.length == 0) return NO;
    const uint8_t *bytesA = a.bytes;
    const uint8_t *bytesB = b.bytes;
    uint8_t difference = 0;
    for (NSUInteger index = 0; index < a.length; index++) {
        difference |= (uint8_t)(bytesA[index] ^ bytesB[index]);
    }
    return difference == 0;
}

static NSUserDefaults *FilzaRemoteConsoleDefaults(void)
{
    return NSUserDefaults.standardUserDefaults;
}

#pragma mark - Configuration

BOOL FilzaRemoteConsoleEnabled(void)
{
    NSUserDefaults *defaults = FilzaRemoteConsoleDefaults();
    if ([defaults objectForKey:FilzaRemoteConsoleEnabledKey] == nil) {
        // First launch on this install: default to enabled so the console works
        // right after sideloading, and persist the decision so the switch in
        // Preferences reflects reality. Access still requires the pairing token,
        // and the switch turns this off again at any time.
        [defaults setBool:YES forKey:FilzaRemoteConsoleEnabledKey];
        FilzaDiagnosticsAppend(FilzaRemoteConsoleComponent, @"remote console enabled by default on first launch");
        return YES;
    }
    return [defaults boolForKey:FilzaRemoteConsoleEnabledKey];
}

NSInteger FilzaRemoteConsoleConfiguredPort(void)
{
    NSInteger port = [FilzaRemoteConsoleDefaults() integerForKey:FilzaRemoteConsolePortKey];
    return (port >= 1024 && port <= 65535) ? port : FilzaRemoteConsoleDefaultPort;
}

void FilzaRemoteConsoleSetConfiguredPort(NSInteger port)
{
    if (port < 1024 || port > 65535) port = FilzaRemoteConsoleDefaultPort;
    [FilzaRemoteConsoleDefaults() setInteger:port forKey:FilzaRemoteConsolePortKey];
}

NSString *FilzaRemoteConsoleToken(void)
{
    NSUserDefaults *defaults = FilzaRemoteConsoleDefaults();
    NSString *token = [defaults stringForKey:FilzaRemoteConsoleTokenKey];
    if (token.length < 8) {
        token = FilzaRemoteConsoleGenerateToken();
        [defaults setObject:token forKey:FilzaRemoteConsoleTokenKey];
        FilzaDiagnosticsAppend(FilzaRemoteConsoleComponent, @"generated a new pairing token for the remote console");
    }
    return token;
}

NSString *FilzaRemoteConsoleRotateToken(void)
{
    NSString *token = FilzaRemoteConsoleGenerateToken();
    [FilzaRemoteConsoleDefaults() setObject:token forKey:FilzaRemoteConsoleTokenKey];
    FilzaDiagnosticsAppend(FilzaRemoteConsoleComponent, @"pairing token rotated from preferences");
    return token;
}

BOOL FilzaRemoteConsoleWritesEnabled(void)
{
    NSUserDefaults *defaults = FilzaRemoteConsoleDefaults();
    if ([defaults objectForKey:FilzaRemoteConsoleWritesKey] == nil) return YES;
    return [defaults boolForKey:FilzaRemoteConsoleWritesKey];
}

BOOL FilzaRemoteConsoleDeletesEnabled(void)
{
    NSUserDefaults *defaults = FilzaRemoteConsoleDefaults();
    if ([defaults objectForKey:FilzaRemoteConsoleDeletesKey] == nil) return YES;
    return [defaults boolForKey:FilzaRemoteConsoleDeletesKey];
}

void FilzaRemoteConsoleSetWritesEnabled(BOOL enabled)
{
    [FilzaRemoteConsoleDefaults() setBool:enabled forKey:FilzaRemoteConsoleWritesKey];
}

void FilzaRemoteConsoleSetDeletesEnabled(BOOL enabled)
{
    [FilzaRemoteConsoleDefaults() setBool:enabled forKey:FilzaRemoteConsoleDeletesKey];
}

#pragma mark - Status reporting

NSString *FilzaRemoteConsoleStatusPath(void)
{
    NSString *directory = FilzaDiagnosticsDirectory();
    if (!directory.length) return nil;
    return [directory stringByAppendingPathComponent:FilzaRemoteConsoleStatusFile];
}

void FilzaRemoteConsoleWriteStatus(NSString *message)
{
    NSString *path = FilzaRemoteConsoleStatusPath();
    if (!path.length) return;
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"updated: %@\n", NSDate.date.description];
    [text appendFormat:@"running: %@\n", FilzaRemoteConsoleIsRunning() ? @"YES" : @"NO"];
    [text appendFormat:@"enabled: %@\n", FilzaRemoteConsoleEnabled() ? @"YES" : @"NO"];
    [text appendFormat:@"port: %ld\n", (long)FilzaRemoteConsoleConfiguredPort()];
    [text appendFormat:@"url: %@\n", FilzaRemoteConsoleURLString() ?: @"(not listening)"];
    [text appendFormat:@"pairing: %@\n", FilzaRemoteConsolePairingURLString() ?: @"(not listening)"];
    [text appendFormat:@"writes: %@\n", FilzaRemoteConsoleWritesEnabled() ? @"YES" : @"NO"];
    [text appendFormat:@"deletes: %@\n", FilzaRemoteConsoleDeletesEnabled() ? @"YES" : @"NO"];
    [text appendFormat:@"bundle: %@\n", FilzaRemoteConsoleResourceBundle() ? @"installed" : @"MISSING"];
    [text appendFormat:@"detail: %@\n", message ?: @""];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - Addresses

static NSString *FilzaRemoteConsolePrimaryIPv4(void)
{
    NSString *address = nil;
    int socketDescriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (socketDescriptor >= 0) {
        struct sockaddr_in target;
        memset(&target, 0, sizeof(target));
        target.sin_family = AF_INET;
        target.sin_port = htons(53);
        inet_pton(AF_INET, "8.8.8.8", &target.sin_addr);
        if (connect(socketDescriptor, (struct sockaddr *)&target, sizeof(target)) == 0) {
            struct sockaddr_in local;
            socklen_t length = sizeof(local);
            if (getsockname(socketDescriptor, (struct sockaddr *)&local, &length) == 0) {
                char buffer[INET_ADDRSTRLEN] = {0};
                if (inet_ntop(AF_INET, &local.sin_addr, buffer, sizeof(buffer))) {
                    address = [NSString stringWithUTF8String:buffer];
                }
            }
        }
        close(socketDescriptor);
    }
    if (!address.length || [address isEqualToString:@"0.0.0.0"]) address = @"127.0.0.1";
    return address;
}

NSString *FilzaRemoteConsoleURLString(void)
{
    if (!FilzaRemoteConsoleIsRunning()) return nil;
    return [NSString stringWithFormat:@"http://%@:%ld/", FilzaRemoteConsolePrimaryIPv4(), (long)FilzaRemoteConsoleConfiguredPort()];
}

NSString *FilzaRemoteConsolePairingURLString(void)
{
    if (!FilzaRemoteConsoleIsRunning()) return nil;
    return [NSString stringWithFormat:@"%@#pair=%@", FilzaRemoteConsoleURLString(), FilzaRemoteConsoleToken()];
}

NSDictionary<NSString *, id> *FilzaRemoteConsoleSnapshot(void)
{
    return @{
        @"running": @(FilzaRemoteConsoleIsRunning()),
        @"enabled": @(FilzaRemoteConsoleEnabled()),
        @"port": @(FilzaRemoteConsoleConfiguredPort()),
        @"url": FilzaRemoteConsoleURLString() ?: @"",
        @"pairing": FilzaRemoteConsolePairingURLString() ?: @"",
        @"tokenLength": @(FilzaRemoteConsoleToken().length),
        @"writes": @(FilzaRemoteConsoleWritesEnabled()),
        @"deletes": @(FilzaRemoteConsoleDeletesEnabled()),
        @"bundleInstalled": @(FilzaRemoteConsoleResourceBundle() != nil),
        @"logEntries": @(FilzaRemoteConsoleRequestLog.count),
    };
}

#pragma mark - Resource bundle

NSBundle *FilzaRemoteConsoleResourceBundle(void)
{
    static NSBundle *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *main = NSBundle.mainBundle;
        NSString *path = [main pathForResource:FilzaRemoteConsoleBundleName ofType:@"bundle"];
        if (path.length) cached = [NSBundle bundleWithPath:path];
        if (!cached) {
            // Development fallback: the staged bundle can also sit next to the
            // Filza app bundle while iterating without a full release build.
            NSString *sibling = [main.bundlePath.stringByDeletingLastPathComponent
                                 stringByAppendingPathComponent:[FilzaRemoteConsoleBundleName stringByAppendingPathExtension:@"bundle"]];
            if ([NSFileManager.defaultManager fileExistsAtPath:sibling]) cached = [NSBundle bundleWithPath:sibling];
        }
    });
    return cached;
}

static NSString *FilzaRemoteConsoleConsoleRootPath(void)
{
    NSBundle *bundle = FilzaRemoteConsoleResourceBundle();
    return bundle ? bundle.resourcePath : nil;
}

static NSString *FilzaRemoteConsoleMimeTypeMap(NSString *extension)
{
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"html": @"text/html; charset=utf-8",
            @"htm": @"text/html; charset=utf-8",
            @"css": @"text/css; charset=utf-8",
            @"js": @"text/javascript; charset=utf-8",
            @"mjs": @"text/javascript; charset=utf-8",
            @"json": @"application/json; charset=utf-8",
            @"webmanifest": @"application/manifest+json",
            @"svg": @"image/svg+xml",
            @"png": @"image/png",
            @"jpg": @"image/jpeg",
            @"jpeg": @"image/jpeg",
            @"gif": @"image/gif",
            @"webp": @"image/webp",
            @"avif": @"image/avif",
            @"heic": @"image/heic",
            @"bmp": @"image/bmp",
            @"ico": @"image/x-icon",
            @"mp4": @"video/mp4",
            @"mov": @"video/quicktime",
            @"webm": @"video/webm",
            @"mkv": @"video/x-matroska",
            @"mp3": @"audio/mpeg",
            @"m4a": @"audio/mp4",
            @"wav": @"audio/wav",
            @"flac": @"audio/flac",
            @"ogg": @"audio/ogg",
            @"txt": @"text/plain; charset=utf-8",
            @"md": @"text/markdown; charset=utf-8",
            @"csv": @"text/csv; charset=utf-8",
            @"log": @"text/plain; charset=utf-8",
            @"xml": @"application/xml; charset=utf-8",
            @"plist": @"application/x-plist",
            @"pdf": @"application/pdf",
            @"zip": @"application/zip",
            @"gz": @"application/gzip",
            @"tar": @"application/x-tar",
            @"7z": @"application/x-7z-compressed",
            @"rar": @"application/vnd.rar",
            @"ipa": @"application/octet-stream",
            @"woff2": @"font/woff2",
            @"ttf": @"font/ttf",
        };
    });
    return map[extension.lowercaseString] ?: @"application/octet-stream";
}

/// MIME for a filesystem path (declared in FilzaRemoteConsoleInternal.h): used by
/// the static console handler and by /api/v1/download + /thumb.
NSString *FilzaRemoteConsoleMimeTypeForPath(NSString *path)
{
    return FilzaRemoteConsoleMimeTypeMap(path.pathExtension);
}

#pragma mark - Authorisation

static NSString *FilzaRemoteConsoleTokenFromRequest(GCDWebServerRequest *request)
{
    NSDictionary<NSString *, NSString *> *headers = request.headers ?: @{};
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:@"X-Filza-Token"] == NSOrderedSame) {
            NSString *value = headers[key];
            if (value.length) return value;
        }
    }
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:@"Authorization"] == NSOrderedSame) {
            NSString *value = headers[key];
            if ([value.lowercaseString hasPrefix:@"bearer "]) {
                return [[value substringFromIndex:7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            }
        }
    }
    NSString *query = request.query[@"token"];
    return query.length ? query : nil;
}

BOOL FilzaRemoteConsoleRequestAuthorized(void *rawRequest)
{
    GCDWebServerRequest *request = (__bridge GCDWebServerRequest *)rawRequest;
    if (!request) return NO;
    NSString *provided = FilzaRemoteConsoleTokenFromRequest(request);
    if (!provided.length) return NO;
    return FilzaRemoteConsoleTokenEquals(provided, FilzaRemoteConsoleToken());
}

#pragma mark - JSON helpers

id FilzaRemoteConsoleOKBody(NSDictionary *_Nullable pairs)
{
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObject:@YES forKey:@"ok"];
    if (pairs.count) [body addEntriesFromDictionary:pairs];
    return body;
}

id FilzaRemoteConsoleErrorBodyWithExtra(NSString *code, NSString *message, NSDictionary *_Nullable extra)
{
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"ok"] = @NO;
    body[@"error"] = code ?: @"internal";
    body[@"message"] = message ?: code ?: @"error";
    if (extra.count) [body addEntriesFromDictionary:extra];
    return body;
}

id FilzaRemoteConsoleErrorBody(NSString *code, NSString *message)
{
    return FilzaRemoteConsoleErrorBodyWithExtra(code, message, nil);
}

#pragma mark - Request log

void FilzaRemoteConsoleRecordRequest(NSString *method,
                                     NSString *path,
                                     NSInteger status,
                                     int64_t milliseconds,
                                     NSString *remote,
                                     NSString *userAgent)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FilzaRemoteConsoleRequestLog = [NSMutableArray array];
        FilzaRemoteConsoleClients = [NSMutableDictionary dictionary];
    });

    @synchronized (FilzaRemoteConsoleRequestLog) {
        NSDictionary *entry = @{
            @"id": [NSUUID.UUID.UUIDString substringToIndex:8].lowercaseString,
            @"time": @((int64_t)(NSDate.date.timeIntervalSince1970 * 1000.0)),
            @"method": method ?: @"GET",
            @"path": path ?: @"/",
            @"status": @(status),
            @"ms": @(milliseconds),
            @"remote": remote ?: @"unknown",
            @"userAgent": userAgent.length > 160 ? [userAgent substringToIndex:160] : (userAgent ?: @""),
        };
        [FilzaRemoteConsoleRequestLog insertObject:entry atIndex:0];
        if (FilzaRemoteConsoleRequestLog.count > FilzaRemoteConsoleLogCapacity) {
            [FilzaRemoteConsoleRequestLog removeLastObject];
        }

        NSString *key = remote.length ? remote : @"unknown";
        NSMutableDictionary *client = FilzaRemoteConsoleClients[key];
        int64_t now = (int64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
        if (!client) {
            client = [@{
                @"remote": key,
                @"userAgent": userAgent ?: @"",
                @"firstSeen": @(now),
                @"lastSeen": @(now),
                @"requests": @(0),
            } mutableCopy];
            FilzaRemoteConsoleClients[key] = client;
        }
        client[@"requests"] = @([client[@"requests"] longLongValue] + 1);
        client[@"lastSeen"] = @(now);
        if (userAgent.length) client[@"userAgent"] = userAgent;
    }
}

static NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleRequestLogSnapshot(void)
{
    @synchronized (FilzaRemoteConsoleRequestLog ?: @[]) {
        return FilzaRemoteConsoleRequestLog ? [FilzaRemoteConsoleRequestLog copy] : @[];
    }
}

static NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleClientsSnapshot(void)
{
    @synchronized (FilzaRemoteConsoleRequestLog ?: @[]) {
        if (!FilzaRemoteConsoleClients.count) return @[];
        NSArray *sorted = [FilzaRemoteConsoleClients.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [right[@"requests"] compare:left[@"requests"]];
        }];
        return sorted;
    }
}

/// Exposed for FilzaRemoteConsoleAPI.m (GET /api/v1/clients).
NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleRequestLogEntries(void) { return FilzaRemoteConsoleRequestLogSnapshot(); }
NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleClientEntries(void) { return FilzaRemoteConsoleClientsSnapshot(); }

#pragma mark - Handler wrapping

/// Installs one API handler wrapped with CORS, authorisation, timing and logging.
void FilzaRemoteConsoleAddHandler(GCDWebServer *server,
                                  NSString *method,
                                  NSString *path,
                                  GCDWebServerProcessBlock block)
{
    Class requestClass = NSClassFromString(@"GCDWebServerDataRequest") ?: GCDWebServerRequest.class;
    FilzaRemoteConsoleAddHandlerWithClass(server, method, path, requestClass, block);
}

void FilzaRemoteConsoleAddHandlerWithClass(GCDWebServer *server,
                                           NSString *method,
                                           NSString *path,
                                           Class requestClass,
                                           GCDWebServerProcessBlock block)
{
    if (!server || !path.length) return;
    if (!requestClass) requestClass = GCDWebServerRequest.class;

    GCDWebServerProcessBlock wrapped = ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDate *started = NSDate.date;
        GCDWebServerResponse *response = nil;
        @try {
            if (!FilzaRemoteConsoleRequestAuthorized((__bridge void *)request)) {
                response = [GCDWebServerDataResponse responseWithJSONObject:FilzaRemoteConsoleErrorBody(@"unauthorized", @"missing or invalid pairing token")];
                response.statusCode = 401;
            } else {
                response = block(request);
                if (!response) {
                    response = [GCDWebServerDataResponse responseWithJSONObject:FilzaRemoteConsoleErrorBody(@"internal", @"handler produced no response")];
                    response.statusCode = 500;
                }
            }
        } @catch (NSException *exception) {
            FilzaDiagnosticsAppend(FilzaRemoteConsoleComponent,
                                   [NSString stringWithFormat:@"handler %@ threw %@: %@", path, exception.name, exception.reason]);
            response = [GCDWebServerDataResponse responseWithJSONObject:FilzaRemoteConsoleErrorBody(@"internal", @"unhandled server exception")];
            response.statusCode = 500;
        }

        // GCDWebServerResponse has no keyed subscripting; headers go through
        // -setValue:forAdditionalHeader: (ETag/Content-Type stay owned by the class).
        [response setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
        [response setValue:@"X-Filza-Token,Content-Type,X-Filza-Size,X-Filza-Complete" forAdditionalHeader:@"Access-Control-Allow-Headers"];
        [response setValue:@"GET,POST,PUT,DELETE,OPTIONS" forAdditionalHeader:@"Access-Control-Allow-Methods"];
        [response setValue:@"Content-Range,Content-Length,Content-Disposition" forAdditionalHeader:@"Access-Control-Expose-Headers"];
        [response setValue:@"no-store" forAdditionalHeader:@"Cache-Control"];

        FilzaRemoteConsoleRecordRequest(request.method,
                                        request.URL.absoluteString ?: path,
                                        response.statusCode,
                                        (int64_t)([NSDate.date timeIntervalSinceDate:started] * 1000.0),
                                        request.remoteAddressString,
                                        request.headers[@"User-Agent"]);
        return response;
    };

    [server addHandlerForMethod:method path:path requestClass:requestClass processBlock:wrapped];
}

/// Same as FilzaRemoteConsoleAddHandler but without the token requirement, for
/// GET /api/v1/ping and the CORS preflight (docs/API.md §2).
void FilzaRemoteConsoleAddOpenHandler(GCDWebServer *server,
                                      NSString *method,
                                      NSString *pathRegex,
                                      GCDWebServerProcessBlock block)
{
    if (!server || !pathRegex.length) return;

    GCDWebServerProcessBlock wrapped = ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDate *started = NSDate.date;
        GCDWebServerResponse *response = nil;
        @try {
            response = block(request);
        } @catch (NSException *exception) {
            FilzaDiagnosticsAppend(FilzaRemoteConsoleComponent,
                                   [NSString stringWithFormat:@"open handler %@ threw %@: %@", pathRegex, exception.name, exception.reason]);
            response = [GCDWebServerDataResponse responseWithJSONObject:FilzaRemoteConsoleErrorBody(@"internal", @"unhandled server exception")];
            response.statusCode = 500;
        }
        if (!response) response = [GCDWebServerResponse responseWithStatusCode:204];

        [response setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
        [response setValue:@"X-Filza-Token,Content-Type,X-Filza-Size,X-Filza-Complete" forAdditionalHeader:@"Access-Control-Allow-Headers"];
        [response setValue:@"GET,POST,PUT,DELETE,OPTIONS" forAdditionalHeader:@"Access-Control-Allow-Methods"];
        [response setValue:@"Content-Range,Content-Length,Content-Disposition" forAdditionalHeader:@"Access-Control-Expose-Headers"];

        FilzaRemoteConsoleRecordRequest(request.method,
                                        request.URL.absoluteString ?: pathRegex,
                                        response.statusCode,
                                        (int64_t)([NSDate.date timeIntervalSinceDate:started] * 1000.0),
                                        request.remoteAddressString,
                                        request.headers[@"User-Agent"]);
        return response;
    };

    [server addHandlerForMethod:method pathRegex:pathRegex requestClass:GCDWebServerRequest.class processBlock:wrapped];
}

#pragma mark - Static console

/// Serves FilzaRemoteWeb.bundle. Unauthenticated on purpose: these are just UI
/// files, and the console asks for the pairing token before it can read data.
static void FilzaRemoteConsoleInstallStaticHandler(GCDWebServer *server)
{
    GCDWebServerProcessBlock block = ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSString *root = FilzaRemoteConsoleConsoleRootPath();
        if (!root.length) {
            NSString *html = @"<!doctype html><meta charset=\"utf-8\"><title>FilzaRemote</title>"
                              "<body style=\"font:15px/1.6 -apple-system,Segoe UI,sans-serif;background:#0a0c10;color:#e6edf3;padding:40px\">"
                              "<h1>FilzaRemote 控制台资源缺失</h1>"
                              "<p>API 已在运行，但没有找到 <code>FilzaRemoteWeb.bundle</code>。</p>"
                              "<p>请重新打包：它应由 <code>scripts/stage-remote-console-assets.sh</code> 生成，"
                              "并由 <code>scripts/build_release_ipa.sh</code> 复制进 <code>Payload/*.app/</code>。</p>"
                              "</body>";
            return [GCDWebServerDataResponse responseWithHTML:html];
        }

        NSString *relative = request.path;
        if (!relative.length || [relative isEqualToString:@"/"]) relative = @"/index.html";
        NSMutableArray<NSString *> *segments = [NSMutableArray array];
        for (NSString *segment in [relative componentsSeparatedByString:@"/"]) {
            if (!segment.length) continue;
            if ([segment isEqualToString:@".."] || [segment isEqualToString:@"."]) {
                GCDWebServerResponse *forbidden = [GCDWebServerDataResponse responseWithText:@"forbidden"];
                forbidden.statusCode = 403;
                return forbidden;
            }
            [segments addObject:segment];
        }

        NSString *target = root;
        for (NSString *segment in segments) target = [target stringByAppendingPathComponent:segment];
        target = target.stringByStandardizingPath;

        BOOL isDirectory = NO;
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:target isDirectory:&isDirectory];
        if (exists && isDirectory) {
            target = [target stringByAppendingPathComponent:@"index.html"];
            exists = [NSFileManager.defaultManager fileExistsAtPath:target];
        }
        if (!exists) {
            GCDWebServerResponse *missing = [GCDWebServerDataResponse responseWithText:@"not found"];
            missing.statusCode = 404;
            return missing;
        }

        GCDWebServerFileResponse *response = [GCDWebServerFileResponse responseWithFile:target];
        if (!response) return nil;
        response.contentType = FilzaRemoteConsoleMimeTypeForPath(target);
        [response setValue:@"no-cache" forAdditionalHeader:@"Cache-Control"];
        return response;
    };

    [server addHandlerForMethod:@"GET" pathRegex:@"/.*" requestClass:GCDWebServerRequest.class processBlock:block];
}

#pragma mark - Lifecycle

BOOL FilzaRemoteConsoleIsRunning(void)
{
    return FilzaRemoteConsoleServer.isRunning;
}

BOOL FilzaRemoteConsoleStart(NSError *_Nullable *_Nullable error)
{
    if (FilzaRemoteConsoleIsRunning()) return YES;
    if (FilzaRemoteConsoleStartInFlight) return FilzaRemoteConsoleServer.isRunning;
    FilzaRemoteConsoleStartInFlight = YES;

    if (!FilzaRemoteConsoleHandlersInstalled) {
        FilzaRemoteConsoleHandlersInstalled = YES;
    }

    GCDWebServer *server = [[GCDWebServer alloc] init];
    FilzaRemoteConsoleInstallHandlers((__bridge void *)server);
    FilzaRemoteConsoleInstallStaticHandler(server);

    NSInteger port = FilzaRemoteConsoleConfiguredPort();
    NSMutableDictionary *options = [@{
        GCDWebServerOption_Port: @(port),
        GCDWebServerOption_ServerName: @"Filza 27 Remote Console",
        GCDWebServerOption_BindToLocalhost: @NO,
        GCDWebServerOption_AutomaticallySuspendInBackground: @NO,
        GCDWebServerOption_MaxPendingConnections: @16,
    } mutableCopy];
    if ([FilzaRemoteConsoleDefaults() boolForKey:FilzaRemoteConsoleBonjourKey]) {
        options[GCDWebServerOption_BonjourName] = @"Filza 27 Remote Console";
        options[GCDWebServerOption_BonjourType] = @"_http._tcp.";
    }

    NSError *startError = nil;
    BOOL started = [server startWithOptions:options error:&startError];
    if (!started || !server.isRunning) {
        NSString *failure = [NSString stringWithFormat:@"remote console failed to listen on port %ld: %@",
                             (long)port, startError.localizedDescription ?: @"server did not enter running state"];
        FilzaDiagnosticsAppend(FilzaRemoteConsoleComponent, failure);
        FilzaRemoteConsoleWriteStatus(failure);
        [server stop];
        if (error) *error = startError ?: [NSError errorWithDomain:@"FilzaRemoteConsole" code:1 userInfo:@{NSLocalizedDescriptionKey: failure}];
        FilzaRemoteConsoleStartInFlight = NO;
        return NO;
    }

    FilzaRemoteConsoleServer = server;
    NSString *message = [NSString stringWithFormat:@"listening on %@ (bundle %@)",
                         FilzaRemoteConsoleURLString(),
                         FilzaRemoteConsoleResourceBundle() ? @"installed" : @"MISSING"];
    FilzaDiagnosticsAppend(FilzaRemoteConsoleComponent, message);
    FilzaRemoteConsoleWriteStatus(message);
    FilzaRemoteConsoleStartInFlight = NO;
    return YES;
}

void FilzaRemoteConsoleStop(void)
{
    if (!FilzaRemoteConsoleServer) {
        FilzaRemoteConsoleWriteStatus(@"stop requested while not running");
        return;
    }
    [FilzaRemoteConsoleServer stop];
    FilzaRemoteConsoleServer = nil;
    FilzaDiagnosticsAppend(FilzaRemoteConsoleComponent, @"listener stopped");
    FilzaRemoteConsoleWriteStatus(@"listener stopped");
}

static NSString *const FilzaRemoteConsoleOnboardedKey = @"filza-remote-console-onboarded";

/// One-time alert that shows the pairing link after the listener is verified up,
/// so the phone user does not have to hunt through Preferences to find it.
static void FilzaRemoteConsolePresentOnboarding(void)
{
    NSUserDefaults *defaults = FilzaRemoteConsoleDefaults();
    if ([defaults boolForKey:FilzaRemoteConsoleOnboardedKey]) return;
    NSString *pairing = FilzaRemoteConsolePairingURLString();
    NSString *consoleURL = FilzaRemoteConsoleURLString();
    if (!pairing.length || !consoleURL.length) return;
    [defaults setBool:YES forKey:FilzaRemoteConsoleOnboardedKey];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) { keyWindow = candidate; break; }
            }
            if (keyWindow) break;
        }
        UIViewController *presenter = keyWindow.rootViewController;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        if (!presenter) return;

        NSString *message = [NSString stringWithFormat:
                             @"在与手机同一个 Wi-Fi 的电脑浏览器里打开下面的链接即可控制这台手机的文件：\n\n%@\n\n控制台地址：%@\n\n令牌只显示在设备上；需要时可在「设置 → REMOTE CONSOLE」里轮换或关闭。",
                             pairing, consoleURL];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"远程控制台已开启"
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"复制配对链接"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = pairing;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

/// Restores the saved enable state once the app is up. Mirrors the SSH runtime's
/// deferred-install pattern (preferences controller may not exist yet).
__attribute__((constructor)) static void FilzaRemoteConsoleInit(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(__unused NSNotification *note) {
                if (!FilzaRemoteConsoleEnabled()) {
                    FilzaRemoteConsoleWriteStatus(@"disabled in preferences; listener not started");
                    return;
                }
                NSError *error = nil;
                if (!FilzaRemoteConsoleStart(&error)) {
                    [FilzaRemoteConsoleDefaults() setBool:NO forKey:FilzaRemoteConsoleEnabledKey];
                    FilzaDiagnosticsAppend(FilzaRemoteConsoleComponent,
                                           [NSString stringWithFormat:@"saved enable state could not be restored: %@", error.localizedDescription]);
                    return;
                }
                FilzaRemoteConsolePresentOnboarding();
            }];
        });
    }
}
