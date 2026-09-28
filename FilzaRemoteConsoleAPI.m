//
//  FilzaRemoteConsoleAPI.m
//  Filza-27 (FilzaApplySandboxExt)
//
//  API v1 read surface for the remote file viewer (docs/API.md), implemented as
//  GCDWebServer handlers so it reuses the HTTP stack this repo already vendors
//  for WebDAV. Filza's own process permissions decide what is actually visible;
//  the console reports capability instead of pretending access exists.
//
//  Endpoints here:  ping · info · list · stat · search · download · thumb ·
//                   text · hex · clients · settings · token/rotate
//  Uploads, mutations, ZIP and SSE live in FilzaRemoteConsoleFileOps.m.
//

@import Foundation;
@import UIKit;
@import ImageIO;

#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerStreamedResponse.h"
#import "GCDWebServerRequest.h"

#import "FilzaDiagnostics.h"
#import "FilzaRemoteConsole.h"
#import "FilzaRemoteConsoleInternal.h"

NSString *const FilzaRemoteConsolePartialSuffix = @".filzapart";

static NSString *const FilzaRemoteConsoleVersion = @"2.0.0";

#pragma mark - Roots

/// Roots exposed to the console. Every entry is checked for readability at first
/// use, so a build where a container class is unavailable reports fewer roots
/// instead of listing paths the process cannot touch.
static NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleRootTable(void)
{
    static NSArray<NSDictionary<NSString *, id> *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSDictionary<NSString *, id> *> *roots = [NSMutableArray array];
        NSFileManager *fileManager = NSFileManager.defaultManager;

        NSString *home = NSHomeDirectory();
        if (home.length) {
            [roots addObject:@{
                @"name": @"App",
                @"label": @"Filza 容器",
                @"path": home,
                @"writable": @YES,
            }];
        }

        NSArray<NSDictionary<NSString *, id> *> *candidates = @[
            @{@"name": @"Media", @"label": @"媒体与 DCIM", @"path": @"/private/var/mobile/Media", @"writable": @YES},
            @{@"name": @"Containers", @"label": @"应用数据容器", @"path": @"/private/var/mobile/Containers/Data/Application", @"writable": @YES},
            @{@"name": @"Shared", @"label": @"App Group 容器", @"path": @"/private/var/mobile/Containers/Shared/AppGroup", @"writable": @YES},
            @{@"name": @"System", @"label": @"系统（只读）", @"path": @"/private/var", @"writable": @NO},
        ];
        for (NSDictionary<NSString *, id> *candidate in candidates) {
            NSString *path = candidate[@"path"];
            if (![fileManager isReadableFileAtPath:path]) continue;
            NSMutableDictionary<NSString *, id> *entry = [candidate mutableCopy];
            entry[@"path"] = path.stringByResolvingSymlinksInPath ?: path;
            [roots addObject:entry];
        }
        table = roots;
    });
    return table;
}

NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleRoots(void)
{
    NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *root in FilzaRemoteConsoleRootTable()) {
        BOOL writable = [root[@"writable"] boolValue] && FilzaRemoteConsoleWritesEnabled();
        [result addObject:@{
            @"name": root[@"name"],
            @"path": [@"/" stringByAppendingString:root[@"name"]],
            @"label": root[@"label"],
            @"readable": @YES,
            @"writable": @(writable),
        }];
    }
    return result;
}

NSDictionary<NSString *, id> *FilzaRemoteConsoleResolveRoot(NSString *rootName)
{
    for (NSDictionary<NSString *, id> *root in FilzaRemoteConsoleRootTable()) {
        if ([root[@"name"] isEqualToString:rootName]) return root;
    }
    return nil;
}

/// Maps an untrusted virtual path to an absolute path, or fails with the exact
/// error code the contract documents (bad_request / forbidden / not_found).
NSString *FilzaRemoteConsoleResolveVirtualPath(NSString *virtualPath,
                                               NSString **rootNameOut,
                                               NSError **error)
{
    void (^fail)(NSInteger, NSString *, NSString *) = ^(NSInteger code, NSString *errorCode, NSString *message) {
        if (error) {
            *error = [NSError errorWithDomain:@"FilzaRemoteConsole"
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: message, @"filzaErrorCode": errorCode}];
        }
    };

    if (![virtualPath isKindOfClass:NSString.class] || ![virtualPath hasPrefix:@"/"]) {
        fail(400, @"bad_request", @"path must be an absolute virtual path like /App/Documents");
        return nil;
    }

    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSString *segment in [virtualPath componentsSeparatedByString:@"/"]) {
        if (!segment.length) continue;
        if ([segment isEqualToString:@".."] || [segment isEqualToString:@"."]) {
            fail(403, @"forbidden", @"path traversal rejected");
            return nil;
        }
        if ([segment containsString:@"\\"]) {
            fail(400, @"bad_request", @"backslash is not allowed in a virtual path");
            return nil;
        }
        for (NSUInteger index = 0; index < segment.length; index++) {
            unichar character = [segment characterAtIndex:index];
            if (character < 0x20 || character == 0x7F) {
                fail(400, @"bad_request", @"control characters are not allowed in a virtual path");
                return nil;
            }
        }
        [segments addObject:segment];
    }

    if (!segments.count) {
        fail(400, @"bad_request", @"path must name a root, for example /App");
        return nil;
    }

    NSString *rootName = segments.firstObject;
    NSDictionary<NSString *, id> *root = FilzaRemoteConsoleResolveRoot(rootName);
    if (!root) {
        fail(404, @"not_found", [NSString stringWithFormat:@"unknown root \"%@\"", rootName]);
        return nil;
    }
    if (rootNameOut) *rootNameOut = rootName;

    NSString *absolute = root[@"path"];
    for (NSUInteger index = 1; index < segments.count; index++) {
        absolute = [absolute stringByAppendingPathComponent:segments[index]];
    }

    NSString *canonical = absolute.stringByStandardizingPath.stringByResolvingSymlinksInPath ?: absolute;
    NSString *canonicalRoot = ((NSString *)root[@"path"]).stringByStandardizingPath;
    if (![canonical isEqualToString:canonicalRoot] &&
        ![canonical hasPrefix:[canonicalRoot stringByAppendingString:@"/"]]) {
        fail(403, @"forbidden", @"resolved path escapes its root");
        return nil;
    }
    return canonical;
}

NSString *FilzaRemoteConsoleVirtualPathForAbsolutePath(NSString *absolutePath)
{
    if (!absolutePath.length) return nil;
    NSString *canonical = absolutePath.stringByStandardizingPath;
    NSString *best = nil;
    for (NSDictionary<NSString *, id> *root in FilzaRemoteConsoleRootTable()) {
        NSString *rootPath = root[@"path"];
        if ([canonical isEqualToString:rootPath] || [canonical hasPrefix:[rootPath stringByAppendingString:@"/"]]) {
            if (!best || rootPath.length > best.length) best = rootPath;
        }
    }
    if (!best) return nil;
    for (NSDictionary<NSString *, id> *root in FilzaRemoteConsoleRootTable()) {
        if ([root[@"path"] isEqualToString:best]) {
            NSString *relative = canonical.length > best.length ? [canonical substringFromIndex:best.length] : @"";
            return [@"/" stringByAppendingString:[root[@"name"] stringByAppendingString:relative]];
        }
    }
    return nil;
}

#pragma mark - Entry classification

static NSArray<NSString *> *FilzaRemoteConsoleExtensionsForKind(NSString *kind)
{
    static NSDictionary<NSString *, NSArray<NSString *> *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"image": @[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"avif", @"bmp", @"heic", @"heif", @"ico", @"tif", @"tiff", @"svg"],
            @"video": @[@"mp4", @"mkv", @"mov", @"webm", @"avi", @"m4v", @"3gp", @"ts", @"flv"],
            @"audio": @[@"mp3", @"m4a", @"aac", @"wav", @"flac", @"ogg", @"opus", @"amr", @"wma", @"aiff"],
            @"archive": @[@"zip", @"rar", @"7z", @"tar", @"gz", @"bz2", @"xz", @"iso", @"jar", @"apks"],
            @"document": @[@"pdf", @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx", @"odt", @"ods", @"epub", @"rtf", @"pages", @"numbers", @"key"],
            @"code": @[@"js", @"mjs", @"cjs", @"ts", @"tsx", @"jsx", @"json", @"html", @"htm", @"css", @"scss", @"kt", @"kts", @"java", @"swift", @"py", @"c", @"h", @"cpp", @"hpp", @"cs", @"go", @"rs", @"rb", @"php", @"sh", @"zsh", @"bash", @"plist", @"xml", @"yml", @"yaml", @"toml", @"ini", @"conf", @"gradle", @"patch", @"diff"],
            @"text": @[@"txt", @"md", @"markdown", @"log", @"csv", @"tsv", @"nfo", @"srt", @"vtt", @"license", @"readme"],
            @"apk": @[@"apk", @"aab", @"xapk", @"ipa", @"deb"],
            @"disk": @[@"img", @"bin", @"dmg", @"vhd", @"vmdk"],
        };
    });
    return map[kind] ?: @[];
}

NSString *FilzaRemoteConsoleKindForPath(NSString *path, BOOL directory)
{
    if (directory) return @"folder";
    static NSDictionary<NSString *, NSString *> *extensionToKind = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *mapping = [NSMutableDictionary dictionary];
        for (NSString *kind in @[@"image", @"video", @"audio", @"archive", @"document", @"code", @"text", @"apk", @"disk"]) {
            for (NSString *extension in FilzaRemoteConsoleExtensionsForKind(kind)) {
                mapping[extension] = kind;
            }
        }
        extensionToKind = mapping;
    });
    NSString *extension = path.pathExtension.lowercaseString;
    if (!extension.length) return path.lastPathComponent.length ? @"other" : @"other";
    return extensionToKind[extension] ?: @"other";
}

static NSDictionary<NSString *, id> *FilzaRemoteConsoleEntryForAbsolutePath(NSString *absolutePath,
                                                                           NSFileManager *fileManager)
{
    NSDictionary<NSAttributedStringKey, id> *attributes = [fileManager attributesOfItemAtPath:absolutePath error:NULL];
    if (!attributes) return nil;

    NSString *type = attributes[NSFileType] ?: NSFileTypeRegular;
    BOOL directory = [type isEqualToString:NSFileTypeDirectory];
    BOOL symlink = [type isEqualToString:NSFileTypeSymbolicLink];
    unsigned long long size = directory ? 0 : [attributes[NSFileSize] unsignedLongLongValue];
    NSDate *modified = attributes[NSFileModificationDate] ?: NSDate.date;
    NSString *name = absolutePath.lastPathComponent.length ? absolutePath.lastPathComponent : absolutePath;

    NSString *virtual = FilzaRemoteConsoleVirtualPathForAbsolutePath(absolutePath);
    if (!virtual.length) return nil;

    NSString *extension = directory ? @"" : name.pathExtension.lowercaseString;
    NSString *mime = directory ? @"inode/directory" : FilzaRemoteConsoleMimeTypeForPath(name);

    return @{
        @"name": name,
        @"path": virtual,
        @"dir": @(directory),
        @"size": directory ? @0 : @(size),
        @"mtime": @((int64_t)(modified.timeIntervalSince1970 * 1000.0)),
        @"ext": extension ?: @"",
        @"kind": FilzaRemoteConsoleKindForPath(name, directory),
        @"mime": mime,
        @"hidden": @(name.length && [name hasPrefix:@"."]),
        @"readable": @([fileManager isReadableFileAtPath:absolutePath]),
        @"writable": @([fileManager isWritableFileAtPath:absolutePath]),
        @"symlink": @(symlink),
    };
}

static NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleSortedEntries(NSArray<NSDictionary<NSString *, id> *> *entries)
{
    return [entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        BOOL leftDirectory = [left[@"dir"] boolValue];
        BOOL rightDirectory = [right[@"dir"] boolValue];
        if (leftDirectory != rightDirectory) return leftDirectory ? NSOrderedAscending : NSOrderedDescending;
        return [(NSString *)left[@"name"] caseInsensitiveCompare:right[@"name"]];
    }];
}

#pragma mark - Request helpers

static NSString *FilzaRemoteConsoleStringParam(GCDWebServerRequest *request, NSString *key)
{
    id value = request.query[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSInteger FilzaRemoteConsoleIntegerParam(GCDWebServerRequest *request, NSString *key, NSInteger fallback)
{
    NSString *raw = FilzaRemoteConsoleStringParam(request, key);
    if (!raw.length) return fallback;
    return (NSInteger)raw.longLongValue;
}

NSDictionary<NSString *, id> *FilzaRemoteConsoleJSONBody(GCDWebServerRequest *request)
{
    if (![request respondsToSelector:@selector(jsonObject)]) return @{};
    id object = [request performSelector:@selector(jsonObject)];
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

static NSArray<NSString *> *FilzaRemoteConsoleStringArray(id value)
{
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:NSString.class]) [result addObject:item];
    }
    return result;
}

static GCDWebServerDataResponse *FilzaRemoteConsoleJSON(NSDictionary *body, NSInteger status)
{
    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithJSONObject:body];
    response.statusCode = status;
    return response;
}

static GCDWebServerDataResponse *FilzaRemoteConsoleErrorResponse(NSError *error)
{
    NSString *code = error.userInfo[@"filzaErrorCode"] ?: @"internal";
    NSString *message = error.localizedDescription ?: code;
    NSInteger status = 500;
    if ([code isEqualToString:@"bad_request"]) status = 400;
    else if ([code isEqualToString:@"unauthorized"]) status = 401;
    else if ([code isEqualToString:@"forbidden"]) status = 403;
    else if ([code isEqualToString:@"not_found"]) status = 404;
    else if ([code isEqualToString:@"conflict"]) status = 409;
    else if ([code isEqualToString:@"range_not_satisfiable"]) status = 416;
    else if ([code isEqualToString:@"unsupported_media"]) status = 415;
    return FilzaRemoteConsoleJSON(FilzaRemoteConsoleErrorBody(code, message), status);
}

/// Resolves `?path=` and reports contract-shaped errors.
static NSString *FilzaRemoteConsoleRequiredPath(GCDWebServerRequest *request, NSError **error)
{
    NSString *virtualPath = FilzaRemoteConsoleStringParam(request, @"path");
    if (!virtualPath.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"FilzaRemoteConsole" code:400 userInfo:@{
                NSLocalizedDescriptionKey: @"path parameter is required",
                @"filzaErrorCode": @"bad_request",
            }];
        }
        return nil;
    }
    return FilzaRemoteConsoleResolveVirtualPath(virtualPath, NULL, error);
}

#pragma mark - GET handlers

static GCDWebServerResponse *FilzaRemoteConsoleHandleInfo(GCDWebServerRequest *request)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSDictionary<NSString *, id> *attributes = nil;
    NSString *appPath = NSHomeDirectory();
    if (appPath.length) attributes = [fileManager attributesOfFileSystemForPath:appPath error:NULL];

    unsigned long long total = [attributes[NSFileSystemSize] unsignedLongLongValue];
    unsigned long long free = [attributes[NSFileSystemFreeSize] unsignedLongLongValue];

    NSArray<NSDictionary<NSString *, id> *> *roots = FilzaRemoteConsoleRoots();
    NSString *bundleState = FilzaRemoteConsoleResourceBundle() ? @"installed" : @"missing";

    return FilzaRemoteConsoleJSON(FilzaRemoteConsoleOKBody(@{
        @"app": @"FilzaRemote",
        @"version": FilzaRemoteConsoleVersion,
        @"serverTime": @((int64_t)(NSDate.date.timeIntervalSince1970 * 1000.0)),
        @"uptimeMs": @((int64_t)(NSProcessInfo.processInfo.systemUptime * 1000.0)),
        @"device": @{
            @"model": [UIDevice.currentDevice name] ?: @"iOS device",
            @"manufacturer": @"Apple",
            @"android": [NSString stringWithFormat:@"%@ %@", UIDevice.currentDevice.systemName, UIDevice.currentDevice.systemVersion],
            @"sdkInt": @0,
        },
        @"host": FilzaRemoteConsoleURLString() ?: @"127.0.0.1",
        @"port": @(FilzaRemoteConsoleConfiguredPort()),
        @"tokenRequired": @YES,
        @"roots": roots,
        @"storage": @{
            @"totalBytes": @(total),
            @"freeBytes": @(free),
            @"usedBytes": @(total > free ? total - free : 0),
        },
        @"features": @[@"list", @"stat", @"mkdir", @"rename", @"delete", @"move", @"copy", @"search",
                       @"download", @"zip", @"upload", @"upload-chunked", @"thumb", @"text", @"hex",
                       @"events", @"clients", @"settings", @"token-rotate"],
        @"writesEnabled": @(FilzaRemoteConsoleWritesEnabled()),
        @"deletesEnabled": @(FilzaRemoteConsoleDeletesEnabled()),
        @"hostKind": @"ios-tweak",
        @"consoleBundle": bundleState,
    }), 200);
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleList(GCDWebServerRequest *request)
{
    NSError *error = nil;
    NSString *virtualPath = FilzaRemoteConsoleStringParam(request, @"path");
    if (!virtualPath.length) {
        NSArray<NSDictionary<NSString *, id> *> *roots = FilzaRemoteConsoleRoots();
        virtualPath = roots.count ? roots.firstObject[@"path"] : @"/App";
    }
    NSString *absolute = FilzaRemoteConsoleResolveVirtualPath(virtualPath, NULL, &error);
    if (!absolute) return FilzaRemoteConsoleErrorResponse(error);

    NSFileManager *fileManager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:absolute isDirectory:&isDirectory] || !isDirectory) {
        return FilzaRemoteConsoleErrorResponse([NSError errorWithDomain:@"FilzaRemoteConsole" code:404 userInfo:@{
            NSLocalizedDescriptionKey: @"not a directory", @"filzaErrorCode": @"not_found",
        }]);
    }

    BOOL includeHidden = FilzaRemoteConsoleIntegerParam(request, @"showHidden", 0) == 1;
    NSArray<NSString *> *names = [fileManager contentsOfDirectoryAtPath:absolute error:&error];
    if (!names) return FilzaRemoteConsoleErrorResponse(error);

    NSMutableArray<NSDictionary<NSString *, id> *> *entries = [NSMutableArray array];
    NSUInteger limit = 5000;
    for (NSString *name in names) {
        if ([name hasSuffix:FilzaRemoteConsolePartialSuffix]) continue;
        if (!includeHidden && [name hasPrefix:@"."]) continue;
        NSDictionary *entry = FilzaRemoteConsoleEntryForAbsolutePath([absolute stringByAppendingPathComponent:name], fileManager);
        if (entry) [entries addObject:entry];
        if (entries.count > limit) break;
    }

    NSArray *sorted = FilzaRemoteConsoleSortedEntries(entries);
    BOOL truncated = sorted.count > limit;
    if (truncated) sorted = [sorted subarrayWithRange:NSMakeRange(0, limit)];

    NSString *parent = nil;
    NSMutableArray<NSString *> *segments = [[virtualPath componentsSeparatedByString:@"/"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *segment, __unused NSDictionary *bindings) { return segment.length > 0; }]].mutableCopy;
    if (segments.count > 1) {
        [segments removeLastObject];
        parent = [@"/" stringByAppendingString:[segments componentsJoinedByString:@"/"]];
    }

    return FilzaRemoteConsoleJSON(FilzaRemoteConsoleOKBody(@{
        @"path": virtualPath,
        @"parent": parent ?: NSNull.null,
        @"root": segments.firstObject ?: @"",
        @"entries": sorted,
        @"count": @(sorted.count),
        @"truncated": @(truncated),
    }), 200);
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleStat(GCDWebServerRequest *request)
{
    NSError *error = nil;
    NSString *absolute = FilzaRemoteConsoleRequiredPath(request, &error);
    if (!absolute) return FilzaRemoteConsoleErrorResponse(error);
    NSDictionary *entry = FilzaRemoteConsoleEntryForAbsolutePath(absolute, NSFileManager.defaultManager);
    if (!entry) {
        return FilzaRemoteConsoleErrorResponse([NSError errorWithDomain:@"FilzaRemoteConsole" code:404 userInfo:@{
            NSLocalizedDescriptionKey: @"no such file or directory", @"filzaErrorCode": @"not_found",
        }]);
    }
    NSMutableDictionary *body = [FilzaRemoteConsoleOKBody(nil) mutableCopy];
    [body addEntriesFromDictionary:entry];
    return FilzaRemoteConsoleJSON(body, 200);
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleSearch(GCDWebServerRequest *request)
{
    NSError *error = nil;
    NSString *term = FilzaRemoteConsoleStringParam(request, @"q");
    if (!term.length) {
        return FilzaRemoteConsoleErrorResponse([NSError errorWithDomain:@"FilzaRemoteConsole" code:400 userInfo:@{
            NSLocalizedDescriptionKey: @"q parameter is required", @"filzaErrorCode": @"bad_request",
        }]);
    }
    NSString *start = FilzaRemoteConsoleResolveVirtualPath(FilzaRemoteConsoleStringParam(request, @"path") ?: @"/App", NULL, &error);
    if (!start) return FilzaRemoteConsoleErrorResponse(error);

    NSInteger limit = MAX(1, MIN(FilzaRemoteConsoleIntegerParam(request, @"limit", 500), 5000));
    BOOL caseSensitive = FilzaRemoteConsoleIntegerParam(request, @"caseSensitive", 0) == 1;
    NSString *needle = caseSensitive ? term : term.lowercaseString;
    NSDate *started = NSDate.date;

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    NSMutableArray<NSString *> *queue = [NSMutableArray arrayWithObject:start];
    NSUInteger scanned = 0;

    while (queue.count && results.count < (NSUInteger)limit) {
        NSString *directory = queue.firstObject;
        [queue removeObjectAtIndex:0];
        scanned += 1;

        for (NSString *name in [fileManager contentsOfDirectoryAtPath:directory error:NULL]) {
            if ([name hasPrefix:@"."] || [name hasSuffix:FilzaRemoteConsolePartialSuffix]) continue;
            NSString *child = [directory stringByAppendingPathComponent:name];
            NSString *haystack = caseSensitive ? name : name.lowercaseString;
            BOOL isDirectory = NO;
            [fileManager fileExistsAtPath:child isDirectory:&isDirectory];
            if ([haystack containsString:needle]) {
                NSDictionary *entry = FilzaRemoteConsoleEntryForAbsolutePath(child, fileManager);
                if (entry) [results addObject:entry];
                if (results.count >= (NSUInteger)limit) break;
            }
            if (isDirectory) [queue addObject:child];
        }
    }

    return FilzaRemoteConsoleJSON(FilzaRemoteConsoleOKBody(@{
        @"results": results,
        @"scanned": @(scanned),
        @"limitReached": @(results.count >= (NSUInteger)limit),
        @"tookMs": @((int64_t)([NSDate.date timeIntervalSinceDate:started] * 1000.0)),
    }), 200);
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleDownload(GCDWebServerRequest *request)
{
    NSError *error = nil;
    NSString *absolute = FilzaRemoteConsoleRequiredPath(request, &error);
    if (!absolute) return FilzaRemoteConsoleErrorResponse(error);

    NSFileManager *fileManager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:absolute isDirectory:&isDirectory] || isDirectory) {
        return FilzaRemoteConsoleErrorResponse([NSError errorWithDomain:@"FilzaRemoteConsole" code:404 userInfo:@{
            NSLocalizedDescriptionKey: @"not a readable file", @"filzaErrorCode": @"not_found",
        }]);
    }
    if ([absolute hasSuffix:FilzaRemoteConsolePartialSuffix]) {
        return FilzaRemoteConsoleErrorResponse([NSError errorWithDomain:@"FilzaRemoteConsole" code:403 userInfo:@{
            NSLocalizedDescriptionKey: @"partial upload files are not readable", @"filzaErrorCode": @"forbidden",
        }]);
    }

    NSDictionary *attributes = [fileManager attributesOfItemAtPath:absolute error:NULL];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    BOOL inline = FilzaRemoteConsoleIntegerParam(request, @"inline", 0) == 1;

    NSRange range = NSMakeRange(NSNotFound, 0);
    if (request.hasByteRange) {
        if (request.byteRange.location >= size || size == 0) {
            GCDWebServerDataResponse *response = FilzaRemoteConsoleJSON(
                FilzaRemoteConsoleErrorBody(@"range_not_satisfiable", @"range not satisfiable"), 416);
            [response setValue:[NSString stringWithFormat:@"bytes */%llu", size] forAdditionalHeader:@"Content-Range"];
            return response;
        }
        range = request.byteRange;
    }

    GCDWebServerFileResponse *response = [GCDWebServerFileResponse responseWithFile:absolute
                                                                         byteRange:range
                                                                      isAttachment:!inline];
    if (!response) {
        return FilzaRemoteConsoleErrorResponse([NSError errorWithDomain:@"FilzaRemoteConsole" code:404 userInfo:@{
            NSLocalizedDescriptionKey: @"file could not be opened", @"filzaErrorCode": @"not_found",
        }]);
    }
    response.contentType = FilzaRemoteConsoleMimeTypeForPath(absolute);
    [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
    return response;
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleThumb(GCDWebServerRequest *request)
{
    NSError *error = nil;
    NSString *absolute = FilzaRemoteConsoleRequiredPath(request, &error);
    if (!absolute) return FilzaRemoteConsoleErrorResponse(error);

    NSString *kind = FilzaRemoteConsoleKindForPath(absolute, NO);
    if (![kind isEqualToString:@"image"]) {
        return FilzaRemoteConsoleErrorResponse([NSError errorWithDomain:@"FilzaRemoteConsole" code:415 userInfo:@{
            NSLocalizedDescriptionKey: @"thumbnails are available for image files only",
            @"filzaErrorCode": @"unsupported_media",
        }]);
    }

    NSInteger width = MAX(16, MIN(FilzaRemoteConsoleIntegerParam(request, @"w", 256), 1024));
    NSData *thumbnail = nil;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:absolute], NULL);
    if (source) {
        NSDictionary *options = @{
            (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (id)kCGImageSourceThumbnailMaxPixelSize: @(width),
        };
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
        if (image) {
            NSMutableData *data = [NSMutableData data];
            CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
                                                                                CFSTR("public.jpeg"), 1, NULL);
            if (destination) {
                CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{
                    (id)kCGImageDestinationLossyCompressionQuality: @0.82,
                });
                CGImageDestinationFinalize(destination);
                CFRelease(destination);
                if (data.length) thumbnail = data;
            }
            CGImageRelease(image);
        }
    }

    if (!thumbnail) {
        // Fall back to the original bytes: the browser can scale it, and a
        // decode failure should not make the console useless for that file.
        GCDWebServerFileResponse *fallback = [GCDWebServerFileResponse responseWithFile:absolute];
        fallback.contentType = FilzaRemoteConsoleMimeTypeForPath(absolute);
        return fallback;
    }

    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithData:thumbnail contentType:@"image/jpeg"];
    [response setValue:@"public, max-age=300" forAdditionalHeader:@"Cache-Control"];
    return response;
}

#pragma mark - text / hex

static NSData *FilzaRemoteConsoleReadSlice(NSString *absolutePath, unsigned long long offset, NSUInteger length, NSError **error)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:absolutePath];
    if (!handle) {
        if (error) {
            *error = [NSError errorWithDomain:@"FilzaRemoteConsole" code:403 userInfo:@{
                NSLocalizedDescriptionKey: @"cannot open file for reading", @"filzaErrorCode": @"forbidden",
            }];
        }
        return nil;
    }
    @try {
        if (offset > 0) [handle seekToFileOffset:offset];
        return [handle readDataOfLength:length] ?: NSData.data;
    } @finally {
        [handle closeFile];
    }
}

static BOOL FilzaRemoteConsoleLooksBinary(NSData *data)
{
    NSUInteger length = MIN(data.length, (NSUInteger)8192);
    if (!length) return NO;
    const uint8_t *bytes = data.bytes;
    NSUInteger control = 0;
    for (NSUInteger index = 0; index < length; index++) {
        uint8_t byte = bytes[index];
        if (byte == 0) return YES;
        if (byte < 0x09 || (byte > 0x0D && byte < 0x20)) control += 1;
    }
    if ((double)control / (double)length > 0.10) return YES;
    // The viewer renders UTF-8: bytes that are not valid UTF-8 are not text in
    // the encoding we display.
    NSString *decoded = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, length)]
                                              encoding:NSUTF8StringEncoding];
    return decoded == nil;
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleText(GCDWebServerRequest *request)
{
    NSError *error = nil;
    NSString *absolute = FilzaRemoteConsoleRequiredPath(request, &error);
    if (!absolute) return FilzaRemoteConsoleErrorResponse(error);

    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:absolute error:NULL];
    if (!attributes) return FilzaRemoteConsoleErrorResponse(error ?: [NSError errorWithDomain:@"FilzaRemoteConsole" code:404 userInfo:@{NSLocalizedDescriptionKey: @"no such file", @"filzaErrorCode": @"not_found"}]);
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];

    NSUInteger maxBytes = (NSUInteger)MAX(1, MIN(FilzaRemoteConsoleIntegerParam(request, @"max", 262144), 4 * 1024 * 1024));
    unsigned long long offset = (unsigned long long)MAX(0, FilzaRemoteConsoleIntegerParam(request, @"offset", 0));
    NSUInteger length = (NSUInteger)MIN((unsigned long long)maxBytes, offset < size ? size - offset : 0);

    NSData *data = FilzaRemoteConsoleReadSlice(absolute, offset, length, &error);
    if (!data) return FilzaRemoteConsoleErrorResponse(error);
    BOOL binary = FilzaRemoteConsoleLooksBinary(data);
    NSString *content = binary ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!binary && !content) {
        content = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }

    return FilzaRemoteConsoleJSON(FilzaRemoteConsoleOKBody(@{
        @"path": FilzaRemoteConsoleVirtualPathForAbsolutePath(absolute) ?: absolute,
        @"size": @(size),
        @"offset": @(offset),
        @"truncated": @(offset + data.length < size),
        @"encoding": @"utf-8",
        @"binary": @(binary),
        @"content": binary ? NSNull.null : (content ?: @""),
    }), 200);
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleHex(GCDWebServerRequest *request)
{
    NSError *error = nil;
    NSString *absolute = FilzaRemoteConsoleRequiredPath(request, &error);
    if (!absolute) return FilzaRemoteConsoleErrorResponse(error);

    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:absolute error:NULL];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    unsigned long long offset = (unsigned long long)MAX(0, FilzaRemoteConsoleIntegerParam(request, @"offset", 0));
    NSUInteger length = (NSUInteger)MAX(1, MIN(FilzaRemoteConsoleIntegerParam(request, @"length", 4096), 1024 * 1024));
    length = (NSUInteger)MIN((unsigned long long)length, offset < size ? size - offset : 0);

    NSData *data = FilzaRemoteConsoleReadSlice(absolute, offset, length, &error);
    if (!data) return FilzaRemoteConsoleErrorResponse(error);

    const uint8_t *bytes = data.bytes;
    NSMutableArray<NSDictionary<NSString *, id> *> *rows = [NSMutableArray array];
    for (NSUInteger index = 0; index < data.length; index += 16) {
        NSUInteger count = MIN((NSUInteger)16, data.length - index);
        NSMutableString *hex = [NSMutableString string];
        NSMutableString *ascii = [NSMutableString string];
        for (NSUInteger i = 0; i < count; i++) {
            if (i) [hex appendString:@" "];
            [hex appendFormat:@"%02x", bytes[index + i]];
        }
        for (NSUInteger i = 0; i < count; i++) {
            uint8_t byte = bytes[index + i];
            [ascii appendFormat:@"%c", (byte >= 32 && byte < 127) ? byte : '.'];
        }
        [rows addObject:@{
            @"offset": @(offset + index),
            @"hex": hex,
            @"ascii": ascii,
        }];
    }

    return FilzaRemoteConsoleJSON(FilzaRemoteConsoleOKBody(@{
        @"path": FilzaRemoteConsoleVirtualPathForAbsolutePath(absolute) ?: absolute,
        @"offset": @(offset),
        @"length": @(data.length),
        @"total": @(size),
        @"rows": rows,
    }), 200);
}

#pragma mark - management

static GCDWebServerResponse *FilzaRemoteConsoleHandleClients(GCDWebServerRequest *request)
{
    (void)request;
    return FilzaRemoteConsoleJSON(FilzaRemoteConsoleOKBody(@{
        @"clients": FilzaRemoteConsoleClientEntries(),
        @"log": FilzaRemoteConsoleRequestLogEntries(),
        @"connections": @0,
    }), 200);
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleSettings(GCDWebServerRequest *request)
{
    NSDictionary<NSString *, id> *body = FilzaRemoteConsoleJSONBody(request);
    if (body[@"writesEnabled"]) FilzaRemoteConsoleSetWritesEnabled([body[@"writesEnabled"] boolValue]);
    if (body[@"deletesEnabled"]) FilzaRemoteConsoleSetDeletesEnabled([body[@"deletesEnabled"] boolValue]);
    if (body[@"showHidden"]) {
        [NSUserDefaults.standardUserDefaults setBool:[body[@"showHidden"] boolValue] forKey:@"filza-remote-console-show-hidden"];
    }
    if (body[@"port"]) {
        NSInteger port = [body[@"port"] integerValue];
        if (port >= 1024 && port <= 65535 && port != FilzaRemoteConsoleConfiguredPort()) {
            FilzaRemoteConsoleSetConfiguredPort(port);
            FilzaRemoteConsoleStop();
            NSError *restartError = nil;
            if (!FilzaRemoteConsoleStart(&restartError)) {
                return FilzaRemoteConsoleErrorResponse(restartError);
            }
        }
    }
    FilzaRemoteConsoleWriteStatus(@"settings updated from the web console");
    return FilzaRemoteConsoleJSON(FilzaRemoteConsoleOKBody(@{
        @"settings": @{
            @"writesEnabled": @(FilzaRemoteConsoleWritesEnabled()),
            @"deletesEnabled": @(FilzaRemoteConsoleDeletesEnabled()),
            @"showHidden": @([NSUserDefaults.standardUserDefaults boolForKey:@"filza-remote-console-show-hidden"]),
            @"port": @(FilzaRemoteConsoleConfiguredPort()),
        },
    }), 200);
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleRotate(GCDWebServerRequest *request)
{
    (void)request;
    NSString *token = FilzaRemoteConsoleRotateToken();
    FilzaRemoteConsoleWriteStatus(@"pairing token rotated from the web console");
    return FilzaRemoteConsoleJSON(FilzaRemoteConsoleOKBody(@{@"token": token}), 200);
}

#pragma mark - Registration

void FilzaRemoteConsoleInstallHandlers(void *rawServer)
{
    GCDWebServer *server = (__bridge GCDWebServer *)rawServer;
    if (!server) return;

    // CORS preflight + ping are intentionally unauthenticated (docs/API.md §2).
    FilzaRemoteConsoleAddOpenHandler(server, @"OPTIONS", @"/.*", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        (void)request;
        GCDWebServerResponse *response = [GCDWebServerResponse responseWithStatusCode:204];
        return response;
    });
    FilzaRemoteConsoleAddOpenHandler(server, @"GET", @"/api/v1/ping", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        (void)request;
        return FilzaRemoteConsoleJSON(FilzaRemoteConsoleOKBody(@{
            @"serverTime": @((int64_t)(NSDate.date.timeIntervalSince1970 * 1000.0)),
            @"app": @"FilzaRemote",
        }), 200);
    });

    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/info", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleInfo(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/list", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleList(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/stat", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleStat(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/search", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleSearch(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/download", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleDownload(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/thumb", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleThumb(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/text", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleText(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/hex", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleHex(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/clients", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleClients(request);
    });

    FilzaRemoteConsoleAddHandler(server, @"POST", @"/api/v1/settings", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleSettings(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"POST", @"/api/v1/token/rotate", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleRotate(request);
    });

    // Uploads, mutations, ZIP and SSE.
    FilzaRemoteConsoleInstallFileOpsHandlers(server);
}
