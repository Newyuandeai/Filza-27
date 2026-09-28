//
//  FilzaRemoteConsoleFileOps.m
//  Filza-27 (FilzaApplySandboxExt)
//
//  Write surface for the remote file viewer (docs/API.md):
//    PUT  /api/v1/upload      resumable chunked upload (.filzapart staging)
//    POST /api/v1/upload      multipart/form-data (curl -F parity)
//    POST /api/v1/mkdir | rename | delete | move | copy
//    GET  /api/v1/zip         streamed ZIP of a file/folder selection
//    GET  /api/v1/events      server-sent events for one directory
//
//  Uploads use GCDWebServerFileRequest / GCDWebServerMultiPartFormRequest so the
//  body lands on disk instead of in memory 鈥?the same reason the WebDAV runtime
//  uses GCDWebServer's upload directory rather than reading request bodies.
//

@import Foundation;
@import UIKit;

#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileRequest.h"
#import "GCDWebServerMultiPartFormRequest.h"
#import "GCDWebServerRequest.h"
#import "GCDWebServerStreamedResponse.h"

#import "FilzaDiagnostics.h"
#import "FilzaRemoteConsole.h"
#import "FilzaRemoteConsoleInternal.h"

static NSString *const FilzaRemoteConsoleFileOpsComponent = @"RemoteConsole";
static const NSUInteger FilzaRemoteConsoleZipFlushThreshold = 256 * 1024;
static const NSUInteger FilzaRemoteConsoleZipEntryLimit = 20000;

#pragma mark - Small shared helpers

static NSError *FilzaRemoteConsoleMakeError(NSInteger status, NSString *code, NSString *message)
{
    return [NSError errorWithDomain:@"FilzaRemoteConsole"
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey: message ?: code,
                                      @"filzaErrorCode": code ?: @"internal"}];
}

static NSInteger FilzaRemoteConsoleStatusForCode(NSString *code)
{
    if ([code isEqualToString:@"bad_request"]) return 400;
    if ([code isEqualToString:@"unauthorized"]) return 401;
    if ([code isEqualToString:@"forbidden"]) return 403;
    if ([code isEqualToString:@"not_found"]) return 404;
    if ([code isEqualToString:@"method_not_allowed"]) return 405;
    if ([code isEqualToString:@"conflict"]) return 409;
    if ([code isEqualToString:@"too_large"]) return 413;
    if ([code isEqualToString:@"unsupported_media"]) return 415;
    if ([code isEqualToString:@"range_not_satisfiable"]) return 416;
    if ([code isEqualToString:@"unavailable"]) return 503;
    return 500;
}

/// Named ...JSONReply to stay clear of FilzaRemoteConsoleJSONReply(request) from
/// FilzaRemoteConsoleAPI.m, which has a different signature and external linkage.
static GCDWebServerDataResponse *FilzaRemoteConsoleJSONReply(NSDictionary *body, NSInteger status)
{
    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithJSONObject:body];
    response.statusCode = status;
    return response;
}

static GCDWebServerDataResponse *FilzaRemoteConsoleFail(NSError *error)
{
    NSString *code = error.userInfo[@"filzaErrorCode"] ?: @"internal";
    NSInteger status = error.code > 0 ? error.code : FilzaRemoteConsoleStatusForCode(code);
    return FilzaRemoteConsoleJSONReply(FilzaRemoteConsoleErrorBody(code, error.localizedDescription), status);
}

static NSDictionary<NSString *, id> *FilzaRemoteConsoleOK(NSDictionary<NSString *, id> *pairs)
{
    return FilzaRemoteConsoleOKBody(pairs);
}

/// Repeated query parameters collapse in GCDWebServerRequest.query, but
/// `?paths=a&paths=b` is part of the contract 鈥?so parse the raw query string.
static NSArray<NSString *> *FilzaRemoteConsoleQueryValues(GCDWebServerRequest *request, NSString *key)
{
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    NSString *raw = request.URL.query;
    if (!raw.length) return values;
    for (NSString *pair in [raw componentsSeparatedByString:@"&"]) {
        NSRange separator = [pair rangeOfString:@"="];
        NSString *name = separator.location == NSNotFound ? pair : [pair substringToIndex:separator.location];
        NSString *value = separator.location == NSNotFound ? @"" : [pair substringFromIndex:separator.location + 1];
        NSString *decodedName = [name stringByRemovingPercentEncoding] ?: name;
        if (![decodedName isEqualToString:key]) continue;
        NSString *decodedValue = [value stringByRemovingPercentEncoding] ?: value;
        [values addObject:[decodedValue stringByReplacingOccurrencesOfString:@"+" withString:@" "]];
    }
    return values;
}

static NSDictionary<NSString *, id> *FilzaRemoteConsoleRequestJSON(GCDWebServerRequest *request)
{
    if (![request respondsToSelector:@selector(jsonObject)]) return @{};
    id object = [request performSelector:@selector(jsonObject)];
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

static unsigned long long FilzaRemoteConsoleFileSize(NSString *path)
{
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    return attributes ? [attributes[NSFileSize] unsignedLongLongValue] : 0;
}

static BOOL FilzaRemoteConsolePathIsDirectory(NSString *path)
{
    BOOL isDirectory = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory];
    return exists && isDirectory;
}

/// Rejects names that could escape the target directory. The console sends the
/// file name out-of-band (never inside the URL path), so this is the only gate.
static NSString *FilzaRemoteConsoleValidatedName(NSString *raw, NSError **error)
{
    NSString *name = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
        [name containsString:@"/"] || [name containsString:@"\\"]) {
        if (error) *error = FilzaRemoteConsoleMakeError(400, @"bad_request", @"invalid file name");
        return nil;
    }
    for (NSUInteger index = 0; index < name.length; index++) {
        unichar character = [name characterAtIndex:index];
        if (character < 0x20 || character == 0x7F) {
            if (error) *error = FilzaRemoteConsoleMakeError(400, @"bad_request", @"control characters are not allowed in a file name");
            return nil;
        }
    }
    return name.length > 200 ? [name substringToIndex:200] : name;
}

#pragma mark - Upload: resumable raw chunks

static GCDWebServerResponse *FilzaRemoteConsoleHandleUploadRaw(GCDWebServerRequest *request)
{
    if (!FilzaRemoteConsoleWritesEnabled()) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(403, @"forbidden", @"writes_disabled"));
    }

    NSError *error = nil;
    NSDictionary<NSString *, NSString *> *query = request.query ?: @{};
    NSString *virtualDirectory = query[@"path"];
    if (!virtualDirectory.length) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"path (target directory) is required"));
    }
    NSString *directory = FilzaRemoteConsoleResolveVirtualPath(virtualDirectory, NULL, &error);
    if (!directory) return FilzaRemoteConsoleFail(error);
    if (!FilzaRemoteConsolePathIsDirectory(directory)) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"path must be a directory"));
    }

    NSString *name = FilzaRemoteConsoleValidatedName(query[@"name"], &error);
    if (!name) return FilzaRemoteConsoleFail(error);

    NSString *targetPath = [directory stringByAppendingPathComponent:name];
    NSString *partPath = [targetPath stringByAppendingString:FilzaRemoteConsolePartialSuffix];

    long long offset = [query[@"offset"] longLongValue];
    long long existing = (long long)FilzaRemoteConsoleFileSize(partPath);
    if (offset != existing) {
        NSDictionary *body = FilzaRemoteConsoleErrorBodyWithExtra(@"conflict", @"offset_mismatch", @{@"expectedOffset": @(existing)});
        return FilzaRemoteConsoleJSONReply(body, 409);
    }

    NSString *temporaryPath = nil;
    if ([request isKindOfClass:GCDWebServerFileRequest.class]) {
        temporaryPath = ((GCDWebServerFileRequest *)request).temporaryPath;
    }
    if (!temporaryPath.length) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"upload body was not received"));
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager fileExistsAtPath:partPath]) {
        if (![NSData.data writeToFile:partPath atomically:NO]) {
            return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(500, @"internal", @"cannot create staging file"));
        }
    }

    NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:temporaryPath];
    NSFileHandle *writer = [NSFileHandle fileHandleForWritingAtPath:partPath];
    if (!reader || !writer) {
        [reader closeFile];
        [writer closeFile];
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(500, @"internal", @"cannot open staging or upload body"));
    }
    @try {
        if (offset > 0) [writer seekToFileOffset:(unsigned long long)offset];
        else [writer truncateFileAtOffset:0];
        for (;;) {
            @autoreleasepool {
                NSData *chunk = [reader readDataOfLength:256 * 1024];
                if (!chunk.length) break;
                [writer writeData:chunk];
            }
        }
    } @finally {
        [writer closeFile];
        [reader closeFile];
    }

    long long newSize = (long long)FilzaRemoteConsoleFileSize(partPath);
    NSString *declaredHeader = request.headers[@"X-Filza-Size"] ?: query[@"size"];
    long long declared = declaredHeader.longLongValue;
    BOOL complete = [query[@"complete"] isEqualToString:@"1"]
        || [request.headers[@"X-Filza-Complete"] isEqualToString:@"1"]
        || (declared > 0 && newSize >= declared);

    NSString *finalVirtual = FilzaRemoteConsoleVirtualPathForAbsolutePath(targetPath) ?: targetPath;
    if (complete) {
        BOOL overwrite = [query[@"overwrite"] isEqualToString:@"1"];
        if ([fileManager fileExistsAtPath:targetPath]) {
            if (!overwrite) {
                return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(409, @"conflict", @"exists"));
            }
            [fileManager removeItemAtPath:targetPath error:NULL];
        }
        if (![fileManager moveItemAtPath:partPath toPath:targetPath error:&error]) {
            return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(500, @"internal", error.localizedDescription ?: @"cannot publish upload"));
        }
        [fileManager setAttributes:@{NSFileModificationDate: NSDate.date} ofItemAtPath:targetPath error:NULL];
        FilzaDiagnosticsAppend(FilzaRemoteConsoleFileOpsComponent,
                               [NSString stringWithFormat:@"upload complete: %@ (%lld bytes)", finalVirtual, newSize]);
    }

    return FilzaRemoteConsoleJSONReply(FilzaRemoteConsoleOK(@{
        @"path": finalVirtual,
        @"size": @(newSize),
        @"complete": @(complete),
        @"offset": @(newSize),
    }), 200);
}

#pragma mark - Upload: multipart/form-data

static GCDWebServerResponse *FilzaRemoteConsoleHandleUploadMultipart(GCDWebServerRequest *request)
{
    GCDWebServerMultiPartFormRequest *multipart = (GCDWebServerMultiPartFormRequest *)request;
    GCDWebServerMultiPartFile *file = multipart.files.firstObject;
    if (!file) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"multipart body had no file part"));
    }

    NSError *error = nil;
    NSString *directory = FilzaRemoteConsoleResolveVirtualPath((request.query ?: @{})[@"path"], NULL, &error);
    if (!directory) return FilzaRemoteConsoleFail(error);
    if (!FilzaRemoteConsolePathIsDirectory(directory)) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"path must be a directory"));
    }

    NSString *name = FilzaRemoteConsoleValidatedName(file.fileName.lastPathComponent ?: file.fileName, &error);
    if (!name) return FilzaRemoteConsoleFail(error);

    NSString *targetPath = [directory stringByAppendingPathComponent:name];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    BOOL overwrite = [(request.query ?: @{})[@"overwrite"] isEqualToString:@"1"];
    if ([fileManager fileExistsAtPath:targetPath]) {
        if (!overwrite) return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(409, @"conflict", @"exists"));
        [fileManager removeItemAtPath:targetPath error:NULL];
    }

    // Copy rather than move: GCDWebServer owns the temporary file and removes it
    // when the request is released.
    if (![fileManager copyItemAtPath:file.temporaryPath toPath:targetPath error:&error]) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(500, @"internal", error.localizedDescription ?: @"cannot store upload"));
    }

    NSString *finalVirtual = FilzaRemoteConsoleVirtualPathForAbsolutePath(targetPath) ?: targetPath;
    long long size = (long long)FilzaRemoteConsoleFileSize(targetPath);
    FilzaDiagnosticsAppend(FilzaRemoteConsoleFileOpsComponent,
                           [NSString stringWithFormat:@"multipart upload stored: %@ (%lld bytes)", finalVirtual, size]);
    return FilzaRemoteConsoleJSONReply(FilzaRemoteConsoleOK(@{
        @"path": finalVirtual,
        @"size": @(size),
        @"complete": @YES,
        @"offset": @(size),
        @"uploaded": @[finalVirtual],
        @"failed": @[],
    }), 200);
}

#pragma mark - Mutations

static GCDWebServerResponse *FilzaRemoteConsoleRequireWrites(void)
{
    if (!FilzaRemoteConsoleWritesEnabled()) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(403, @"forbidden", @"writes_disabled"));
    }
    return nil;
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleMkdir(GCDWebServerRequest *request)
{
    GCDWebServerResponse *denied = FilzaRemoteConsoleRequireWrites();
    if (denied) return denied;

    NSError *error = nil;
    NSString *virtualPath = FilzaRemoteConsoleRequestJSON(request)[@"path"];
    if (![virtualPath isKindOfClass:NSString.class]) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"path is required"));
    }
    NSString *rootName = nil;
    NSString *absolute = FilzaRemoteConsoleResolveVirtualPath(virtualPath, &rootName, &error);
    if (!absolute) return FilzaRemoteConsoleFail(error);

    NSArray<NSString *> *segments = [virtualPath componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *nonEmpty = [[segments filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSString *segment, __unused NSDictionary *bindings) { return segment.length > 0; }]] mutableCopy];
    if (nonEmpty.count < 2) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(409, @"conflict", @"already exists"));
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    if ([fileManager fileExistsAtPath:absolute]) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(409, @"conflict", @"already exists"));
    }
    if (![fileManager createDirectoryAtPath:absolute withIntermediateDirectories:NO attributes:nil error:&error]) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(500, @"internal", error.localizedDescription ?: @"mkdir failed"));
    }
    FilzaDiagnosticsAppend(FilzaRemoteConsoleFileOpsComponent, [NSString stringWithFormat:@"mkdir %@", virtualPath]);
    return FilzaRemoteConsoleJSONReply(FilzaRemoteConsoleOK(@{@"path": virtualPath}), 200);
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleRename(GCDWebServerRequest *request)
{
    GCDWebServerResponse *denied = FilzaRemoteConsoleRequireWrites();
    if (denied) return denied;

    NSDictionary *body = FilzaRemoteConsoleRequestJSON(request);
    NSString *fromVirtual = body[@"from"];
    NSString *toVirtual = body[@"to"];
    if (![fromVirtual isKindOfClass:NSString.class] || ![toVirtual isKindOfClass:NSString.class]) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"from and to are required"));
    }

    NSError *error = nil;
    NSString *fromRoot = nil;
    NSString *toRoot = nil;
    NSString *from = FilzaRemoteConsoleResolveVirtualPath(fromVirtual, &fromRoot, &error);
    if (!from) return FilzaRemoteConsoleFail(error);
    NSString *to = FilzaRemoteConsoleResolveVirtualPath(toVirtual, &toRoot, &error);
    if (!to) return FilzaRemoteConsoleFail(error);
    if (![fromRoot isEqualToString:toRoot]) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"rename must stay inside one root"));
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    if ([fileManager fileExistsAtPath:to]) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(409, @"conflict", @"target exists"));
    }
    if (![fileManager moveItemAtPath:from toPath:to error:&error]) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(500, @"internal", error.localizedDescription ?: @"rename failed"));
    }
    FilzaDiagnosticsAppend(FilzaRemoteConsoleFileOpsComponent, [NSString stringWithFormat:@"rename %@ -> %@", fromVirtual, toVirtual]);
    return FilzaRemoteConsoleJSONReply(FilzaRemoteConsoleOK(@{@"path": toVirtual}), 200);
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleDelete(GCDWebServerRequest *request)
{
    GCDWebServerResponse *denied = FilzaRemoteConsoleRequireWrites();
    if (denied) return denied;
    if (!FilzaRemoteConsoleDeletesEnabled()) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(403, @"forbidden", @"deletes_disabled"));
    }

    NSArray *paths = FilzaRemoteConsoleRequestJSON(request)[@"paths"];
    if (![paths isKindOfClass:NSArray.class] || !paths.count) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"paths[] is required"));
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *deleted = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *failed = [NSMutableArray array];

    for (id item in paths) {
        if (![item isKindOfClass:NSString.class]) continue;
        NSString *virtualPath = item;
        NSError *error = nil;
        NSString *absolute = FilzaRemoteConsoleResolveVirtualPath(virtualPath, NULL, &error);
        if (!absolute) {
            [failed addObject:@{@"path": virtualPath, @"error": error.userInfo[@"filzaErrorCode"] ?: @"internal",
                                @"message": error.localizedDescription ?: @""}];
            continue;
        }
        NSArray<NSString *> *segments = [virtualPath componentsSeparatedByString:@"/"];
        NSUInteger meaningful = 0;
        for (NSString *segment in segments) if (segment.length) meaningful += 1;
        if (meaningful < 2) {
            [failed addObject:@{@"path": virtualPath, @"error": @"forbidden", @"message": @"refusing to delete a root"}];
            continue;
        }
        if (![fileManager removeItemAtPath:absolute error:&error]) {
            [failed addObject:@{@"path": virtualPath, @"error": @"internal", @"message": error.localizedDescription ?: @"delete failed"}];
            continue;
        }
        [deleted addObject:virtualPath];
    }

    FilzaDiagnosticsAppend(FilzaRemoteConsoleFileOpsComponent,
                           [NSString stringWithFormat:@"delete: %lu ok, %lu failed", (unsigned long)deleted.count, (unsigned long)failed.count]);
    return FilzaRemoteConsoleJSONReply(FilzaRemoteConsoleOK(@{@"deleted": deleted, @"failed": failed}), 200);
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleTransfer(GCDWebServerRequest *request, BOOL isMove)
{
    GCDWebServerResponse *denied = FilzaRemoteConsoleRequireWrites();
    if (denied) return denied;

    NSDictionary *body = FilzaRemoteConsoleRequestJSON(request);
    NSArray *paths = body[@"paths"];
    NSString *destVirtual = body[@"dest"];
    if (![paths isKindOfClass:NSArray.class] || !paths.count) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"paths[] is required"));
    }
    if (![destVirtual isKindOfClass:NSString.class]) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"dest is required"));
    }

    NSError *error = nil;
    NSString *dest = FilzaRemoteConsoleResolveVirtualPath(destVirtual, NULL, &error);
    if (!dest) return FilzaRemoteConsoleFail(error);
    if (!FilzaRemoteConsolePathIsDirectory(dest)) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"dest must be a directory"));
    }

    BOOL overwrite = [body[@"overwrite"] boolValue];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *done = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *failed = [NSMutableArray array];

    for (id item in paths) {
        if (![item isKindOfClass:NSString.class]) continue;
        NSString *virtualPath = item;
        NSError *itemError = nil;
        NSString *source = FilzaRemoteConsoleResolveVirtualPath(virtualPath, NULL, &itemError);
        if (!source) {
            [failed addObject:@{@"path": virtualPath, @"error": itemError.userInfo[@"filzaErrorCode"] ?: @"internal",
                                @"message": itemError.localizedDescription ?: @""}];
            continue;
        }
        NSString *target = [dest stringByAppendingPathComponent:source.lastPathComponent];
        if ([target isEqualToString:source]) {
            [failed addObject:@{@"path": virtualPath, @"error": @"conflict", @"message": @"source and destination are the same"}];
            continue;
        }
        if ([fileManager fileExistsAtPath:target]) {
            if (!overwrite) {
                [failed addObject:@{@"path": virtualPath, @"error": @"conflict", @"message": @"target exists"}];
                continue;
            }
            [fileManager removeItemAtPath:target error:NULL];
        }
        BOOL ok = isMove
            ? [fileManager moveItemAtPath:source toPath:target error:&itemError]
            : [fileManager copyItemAtPath:source toPath:target error:&itemError];
        if (!ok) {
            [failed addObject:@{@"path": virtualPath, @"error": @"internal", @"message": itemError.localizedDescription ?: @"operation failed"}];
            continue;
        }
        NSString *targetVirtual = FilzaRemoteConsoleVirtualPathForAbsolutePath(target) ?: target;
        [done addObject:targetVirtual];
    }

    return FilzaRemoteConsoleJSONReply(FilzaRemoteConsoleOK(@{
        isMove ? @"moved" : @"copied": done,
        @"failed": failed,
    }), 200);
}

#pragma mark - ZIP (streamed, store-only with data descriptors)

static uint32_t FilzaRemoteConsoleCRC32Update(uint32_t previous, const uint8_t *bytes, NSUInteger length)
{
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t index = 0; index < 256; index++) {
            uint32_t value = index;
            for (int bit = 0; bit < 8; bit++) {
                value = (value & 1) ? (0xEDB88320u ^ (value >> 1)) : (value >> 1);
            }
            table[index] = value;
        }
    });
    uint32_t crc = previous ^ 0xFFFFFFFFu;
    for (NSUInteger index = 0; index < length; index++) {
        crc = table[(crc ^ bytes[index]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}

static void FilzaRemoteConsoleAppendUInt16(NSMutableData *data, uint16_t value)
{
    uint8_t bytes[2] = {(uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void FilzaRemoteConsoleAppendUInt32(NSMutableData *data, uint32_t value)
{
    uint8_t bytes[4] = {
        (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF), (uint8_t)((value >> 24) & 0xFF),
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void FilzaRemoteConsoleDOSDateTime(NSDate *date, uint16_t *outTime, uint16_t *outDate)
{
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"] ?: NSTimeZone.defaultTimeZone;
    NSDateComponents *components = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                                         NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
                                               fromDate:date ?: NSDate.date];
    NSInteger year = MAX(1980, components.year);
    *outTime = (uint16_t)(((MAX(0, components.hour) & 0x1F) << 11) |
                          ((MAX(0, components.minute) & 0x3F) << 5) |
                          ((MAX(0, components.second) / 2) & 0x1F));
    *outDate = (uint16_t)((((year - 1980) & 0x7F) << 9) |
                          ((MAX(1, components.month) & 0x0F) << 5) |
                          (MAX(1, components.day) & 0x1F));
}

/// Store-only ZIP writer that emits into a bounded pending buffer, so a folder of
/// any size is archived with flat memory use. Sizes and CRCs travel in the
/// trailing data descriptor (general purpose bit 3), which is why one pass over
/// each file is enough.
@interface FilzaRemoteConsoleZipWriter : NSObject
@property (nonatomic, readonly) NSUInteger pendingLength;
- (instancetype)initWithFlushThreshold:(NSUInteger)threshold;
- (BOOL)needsFlush;
- (NSData *)takePending;
- (void)beginEntryNamed:(NSString *)name modified:(NSDate *)modified;
- (void)appendData:(NSData *)data;
- (void)endEntryWithModified:(NSDate *)modified isDirectory:(BOOL)isDirectory;
- (void)finishArchive;
@property (nonatomic, readonly) BOOL finished;
@end

@implementation FilzaRemoteConsoleZipWriter {
    NSUInteger _threshold;
    NSMutableData *_pending;
    NSMutableArray<NSDictionary<NSString *, id> *> *_entries;
    NSData *_currentName;
    uint64_t _currentOffset;
    uint32_t _currentCRC;
    uint64_t _currentSize;
    uint64_t _offset;
    BOOL _finished;
}

- (instancetype)initWithFlushThreshold:(NSUInteger)threshold
{
    if ((self = [super init])) {
        _threshold = MAX(64 * 1024, threshold);
        _pending = [NSMutableData data];
        _entries = [NSMutableArray array];
    }
    return self;
}

- (NSUInteger)pendingLength { return _pending.length; }
- (BOOL)needsFlush { return _pending.length >= _threshold; }
- (BOOL)finished { return _finished; }

- (NSData *)takePending
{
    if (!_pending.length) return nil;
    NSData *data = [_pending copy];
    [_pending setLength:0];
    return data;
}

- (void)beginEntryNamed:(NSString *)name modified:(NSDate *)modified
{
    NSString *entryName = name;
    while ([entryName hasPrefix:@"/"]) entryName = [entryName substringFromIndex:1];
    _currentName = [entryName dataUsingEncoding:NSUTF8StringEncoding];
    _currentOffset = _offset;
    _currentCRC = 0;
    _currentSize = 0;

    uint16_t time = 0;
    uint16_t datePart = 0;
    FilzaRemoteConsoleDOSDateTime(modified, &time, &datePart);

    // Local header with zeroed CRC/sizes: the real values follow the payload in
    // the data descriptor (general purpose bit 3), so the file is read once.
    FilzaRemoteConsoleAppendUInt32(_pending, 0x04034B50);
    FilzaRemoteConsoleAppendUInt16(_pending, 20);
    FilzaRemoteConsoleAppendUInt16(_pending, 0x0808);   // data descriptor + UTF-8 names
    FilzaRemoteConsoleAppendUInt16(_pending, 0);        // method: stored
    FilzaRemoteConsoleAppendUInt16(_pending, time);
    FilzaRemoteConsoleAppendUInt16(_pending, datePart);
    FilzaRemoteConsoleAppendUInt32(_pending, 0);
    FilzaRemoteConsoleAppendUInt32(_pending, 0);
    FilzaRemoteConsoleAppendUInt32(_pending, 0);
    FilzaRemoteConsoleAppendUInt16(_pending, (uint16_t)_currentName.length);
    FilzaRemoteConsoleAppendUInt16(_pending, 0);
    [_pending appendData:_currentName];

    _offset += (uint64_t)(30 + _currentName.length);
}

- (void)appendData:(NSData *)data
{
    if (!data.length) return;
    _currentCRC = FilzaRemoteConsoleCRC32Update(_currentCRC, data.bytes, data.length);
    _currentSize += data.length;
    [_pending appendData:data];
    _offset += data.length;
}

- (void)endEntryWithModified:(NSDate *)modified isDirectory:(BOOL)isDirectory
{
    // Data descriptor: signature + CRC + compressed size + uncompressed size.
    FilzaRemoteConsoleAppendUInt32(_pending, 0x08074B50);
    FilzaRemoteConsoleAppendUInt32(_pending, _currentCRC);
    FilzaRemoteConsoleAppendUInt32(_pending, (uint32_t)_currentSize);
    FilzaRemoteConsoleAppendUInt32(_pending, (uint32_t)_currentSize);
    _offset += 16;

    uint16_t time = 0;
    uint16_t datePart = 0;
    FilzaRemoteConsoleDOSDateTime(modified, &time, &datePart);
    [_entries addObject:@{
        @"name": _currentName ?: [NSData data],
        @"crc": @(_currentCRC),
        @"size": @(_currentSize),
        @"offset": @(_currentOffset),
        @"time": @(time),
        @"date": @(datePart),
        @"directory": @(isDirectory),
    }];
    _currentName = nil;
}

- (void)finishArchive
{
    if (_finished) return;
    uint64_t centralStart = _offset;
    for (NSDictionary<NSString *, id> *entry in _entries) {
        NSData *name = entry[@"name"];
        FilzaRemoteConsoleAppendUInt32(_pending, 0x02014B50);
        FilzaRemoteConsoleAppendUInt16(_pending, 20);
        FilzaRemoteConsoleAppendUInt16(_pending, 20);
        FilzaRemoteConsoleAppendUInt16(_pending, 0x0800);
        FilzaRemoteConsoleAppendUInt16(_pending, 0);         // method: stored
        FilzaRemoteConsoleAppendUInt16(_pending, (uint16_t)[entry[@"time"] unsignedShortValue]);
        FilzaRemoteConsoleAppendUInt16(_pending, (uint16_t)[entry[@"date"] unsignedShortValue]);
        FilzaRemoteConsoleAppendUInt32(_pending, (uint32_t)[entry[@"crc"] unsignedIntValue]);
        FilzaRemoteConsoleAppendUInt32(_pending, (uint32_t)[entry[@"size"] unsignedLongLongValue]);
        FilzaRemoteConsoleAppendUInt32(_pending, (uint32_t)[entry[@"size"] unsignedLongLongValue]);
        FilzaRemoteConsoleAppendUInt16(_pending, (uint16_t)name.length);
        FilzaRemoteConsoleAppendUInt16(_pending, 0);
        FilzaRemoteConsoleAppendUInt16(_pending, 0);
        FilzaRemoteConsoleAppendUInt16(_pending, 0);
        FilzaRemoteConsoleAppendUInt16(_pending, 0);
        FilzaRemoteConsoleAppendUInt32(_pending, [entry[@"directory"] boolValue] ? 0x41ED0010 : 0x81A40000);
        FilzaRemoteConsoleAppendUInt32(_pending, (uint32_t)[entry[@"offset"] unsignedLongLongValue]);
        [_pending appendData:name];
        // Every central-directory record must advance the running archive offset,
        // otherwise the end-of-central-directory record points at the wrong place.
        _offset += (uint64_t)(46 + name.length);
    }
    uint64_t centralSize = _offset - centralStart;
    NSUInteger count = MIN(_entries.count, 0xFFFF);
    FilzaRemoteConsoleAppendUInt32(_pending, 0x06054B50);
    FilzaRemoteConsoleAppendUInt16(_pending, 0);
    FilzaRemoteConsoleAppendUInt16(_pending, 0);
    FilzaRemoteConsoleAppendUInt16(_pending, (uint16_t)count);
    FilzaRemoteConsoleAppendUInt16(_pending, (uint16_t)count);
    FilzaRemoteConsoleAppendUInt32(_pending, (uint32_t)centralSize);
    FilzaRemoteConsoleAppendUInt32(_pending, (uint32_t)centralStart);
    FilzaRemoteConsoleAppendUInt16(_pending, 0);
    _offset += 22;
    _finished = YES;
}

@end

/// Collects files (recursively for folders) with the names they get in the ZIP.
static NSArray<NSDictionary<NSString *, id> *> *FilzaRemoteConsoleZipWorkItems(NSArray<NSString *> *virtualPaths,
                                                                              NSError **error)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray array];
    NSMutableArray<NSString *> *directories = [NSMutableArray array];

    for (NSString *virtualPath in virtualPaths) {
        NSString *absolute = FilzaRemoteConsoleResolveVirtualPath(virtualPath, NULL, error);
        if (!absolute) return nil;
        [directories addObject:absolute];
    }

    while (directories.count && items.count < FilzaRemoteConsoleZipEntryLimit) {
        NSString *directory = directories.firstObject;
        [directories removeObjectAtIndex:0];
        NSString *baseVirtual = FilzaRemoteConsoleVirtualPathForAbsolutePath(directory);
        NSString *baseName = baseVirtual.lastPathComponent ?: directory.lastPathComponent;

        if (!FilzaRemoteConsolePathIsDirectory(directory)) {
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:directory error:NULL];
            [items addObject:@{
                @"absolute": directory,
                @"name": baseName,
                @"size": @([attributes[NSFileSize] unsignedLongLongValue]),
                @"mtime": attributes[NSFileModificationDate] ?: NSDate.date,
                @"directory": @NO,
            }];
            continue;
        }

        [items addObject:@{
            @"absolute": directory,
            @"name": [baseName stringByAppendingString:@"/"],
            @"size": @0,
            @"mtime": [fileManager attributesOfItemAtPath:directory error:NULL][NSFileModificationDate] ?: NSDate.date,
            @"directory": @YES,
        }];

        for (NSString *name in [fileManager contentsOfDirectoryAtPath:directory error:NULL]) {
            if ([name hasSuffix:FilzaRemoteConsolePartialSuffix]) continue;
            NSString *child = [directory stringByAppendingPathComponent:name];
            if (FilzaRemoteConsolePathIsDirectory(child)) {
                [directories addObject:child];
            } else {
                if (items.count >= FilzaRemoteConsoleZipEntryLimit) break;
                NSDictionary *attributes = [fileManager attributesOfItemAtPath:child error:NULL];
                [items addObject:@{
                    @"absolute": child,
                    @"name": [baseName stringByAppendingPathComponent:name],
                    @"size": @([attributes[NSFileSize] unsignedLongLongValue]),
                    @"mtime": attributes[NSFileModificationDate] ?: NSDate.date,
                    @"directory": @NO,
                }];
            }
        }
    }
    return items;
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleZip(GCDWebServerRequest *request)
{
    NSMutableArray<NSString *> *virtualPaths = [FilzaRemoteConsoleQueryValues(request, @"paths") mutableCopy];
    NSString *single = (request.query ?: @{})[@"path"];
    if (single.length) [virtualPaths insertObject:single atIndex:0];
    if (!virtualPaths.count) {
        return FilzaRemoteConsoleFail(FilzaRemoteConsoleMakeError(400, @"bad_request", @"path or paths[] is required"));
    }

    NSError *error = nil;
    NSArray<NSDictionary<NSString *, id> *> *work = FilzaRemoteConsoleZipWorkItems(virtualPaths, &error);
    if (!work) return FilzaRemoteConsoleFail(error);

    NSString *archiveName = virtualPaths.count == 1
        ? [virtualPaths.firstObject.lastPathComponent stringByAppendingString:@".zip"]
        : @"filzaremote-selection.zip";

    FilzaDiagnosticsAppend(FilzaRemoteConsoleFileOpsComponent,
                           [NSString stringWithFormat:@"zip %@ (%lu entries)", archiveName, (unsigned long)work.count]);

    __block NSMutableArray<NSDictionary<NSString *, id> *> *queue = [work mutableCopy];
    __block FilzaRemoteConsoleZipWriter *writer = [[FilzaRemoteConsoleZipWriter alloc] initWithFlushThreshold:FilzaRemoteConsoleZipFlushThreshold];
    __block NSFileHandle *handle = nil;
    __block BOOL entryOpen = NO;

    GCDWebServerStreamedResponse *response = [GCDWebServerStreamedResponse responseWithContentType:@"application/zip"
        asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock completionBlock) {
        @try {
            while (YES) {
                if (writer.finished) {
                    completionBlock([writer takePending], nil);
                    return;
                }
                if (!entryOpen) {
                    if (!queue.count) {
                        [writer finishArchive];
                        completionBlock([writer takePending], nil);
                        return;
                    }
                    NSDictionary *item = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    [writer beginEntryNamed:item[@"name"] modified:item[@"mtime"]];
                    entryOpen = YES;
                    if ([item[@"directory"] boolValue]) {
                        [writer endEntryWithModified:item[@"mtime"] isDirectory:YES];
                        entryOpen = NO;
                        if (writer.needsFlush) {
                            completionBlock([writer takePending], nil);
                            return;
                        }
                        continue;
                    }
                    handle = [NSFileHandle fileHandleForReadingAtPath:item[@"absolute"]];
                    if (!handle) {
                        // Unreadable file: keep the entry but empty, so the archive
                        // stays valid and the failure is visible as a 0-byte member.
                        [writer endEntryWithModified:item[@"mtime"] isDirectory:NO];
                        entryOpen = NO;
                        continue;
                    }
                    continue;
                }

                NSData *chunk = [handle readDataOfLength:128 * 1024];
                if (chunk.length) {
                    [writer appendData:chunk];
                    if (writer.needsFlush) {
                        completionBlock([writer takePending], nil);
                        return;
                    }
                    continue;
                }
                [handle closeFile];
                handle = nil;
                [writer endEntryWithModified:NSDate.date isDirectory:NO];
                entryOpen = NO;
            }
        } @catch (NSException *exception) {
            FilzaDiagnosticsAppend(FilzaRemoteConsoleFileOpsComponent,
                                   [NSString stringWithFormat:@"zip stream failed: %@", exception.reason]);
            completionBlock(nil, [NSError errorWithDomain:@"FilzaRemoteConsole" code:500 userInfo:@{NSLocalizedDescriptionKey: @"zip stream failed"}]);
        }
    }];
    [response setValue:[NSString stringWithFormat:@"attachment; filename*=UTF-8''%@",
                        [archiveName stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet]]
 forAdditionalHeader:@"Content-Disposition"];
    return response;
}

#pragma mark - Server-sent events

static NSDictionary<NSString *, NSNumber *> *FilzaRemoteConsoleDirectorySnapshot(NSString *directory)
{
    NSMutableDictionary<NSString *, NSNumber *> *snapshot = [NSMutableDictionary dictionary];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]) {
        if ([name hasSuffix:FilzaRemoteConsolePartialSuffix]) continue;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:[directory stringByAppendingPathComponent:name] error:NULL];
        NSDate *modified = attributes[NSFileModificationDate];
        unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
        snapshot[name] = @((int64_t)(modified.timeIntervalSince1970 * 1000.0) ^ (int64_t)(size & 0xFFFFFFFF));
    }
    return snapshot;
}

static GCDWebServerResponse *FilzaRemoteConsoleHandleEvents(GCDWebServerRequest *request)
{
    NSError *error = nil;
    NSString *virtualPath = (request.query ?: @{})[@"path"];
    if (!virtualPath.length) virtualPath = @"/App";
    NSString *directory = FilzaRemoteConsoleResolveVirtualPath(virtualPath, NULL, &error);
    if (!directory) return FilzaRemoteConsoleFail(error);

    __block NSDictionary<NSString *, NSNumber *> *previous = FilzaRemoteConsoleDirectorySnapshot(directory);
    __block NSDate *lastHeartbeat = NSDate.date;

    GCDWebServerStreamedResponse *response = [GCDWebServerStreamedResponse responseWithContentType:@"text/event-stream; charset=utf-8"
        asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock completionBlock) {
        // One call per second per client: no busy loop, and the 15s heartbeat is
        // what keeps intermediaries from closing the stream.
        dispatch_semaphore_t tick = dispatch_semaphore_create(0);
        dispatch_semaphore_wait(tick, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));

        NSMutableData *payload = [NSMutableData data];
        NSDictionary<NSString *, NSNumber *> *current = FilzaRemoteConsoleDirectorySnapshot(directory);
        if (![current isEqualToDictionary:previous]) {
            for (NSString *name in current) {
                NSNumber *previousValue = previous[name];
                if (previousValue && [previousValue isEqual:current[name]]) continue;
                NSString *wire = [virtualPath stringByAppendingPathComponent:name];
                NSDictionary *event = @{
                    @"type": @"fs",
                    @"op": previousValue ? @"modify" : @"create",
                    @"name": name,
                    @"path": wire,
                    @"mtime": current[name],
                };
                NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
                if (json) [payload appendData:[@"data: " dataUsingEncoding:NSUTF8StringEncoding]];
                if (json) [payload appendData:json];
                if (json) [payload appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
            }
            for (NSString *name in previous) {
                if (current[name]) continue;
                NSDictionary *event = @{@"type": @"fs", @"op": @"delete", @"name": name,
                                        @"path": [virtualPath stringByAppendingPathComponent:name]};
                NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
                if (json) [payload appendData:[@"data: " dataUsingEncoding:NSUTF8StringEncoding]];
                if (json) [payload appendData:json];
                if (json) [payload appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
            }
            previous = current;
        }
        if (!payload.length && [NSDate.date timeIntervalSinceDate:lastHeartbeat] >= 15.0) {
            [payload appendData:[@": hb\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
            lastHeartbeat = NSDate.date;
        }
        completionBlock(payload.length ? [payload copy] : [NSData data], nil);
    }];
    [response setValue:@"no-cache, no-transform" forAdditionalHeader:@"Cache-Control"];
    [response setValue:@"no" forAdditionalHeader:@"X-Accel-Buffering"];
    return response;
}

#pragma mark - Registration

void FilzaRemoteConsoleInstallFileOpsHandlers(GCDWebServer *server)
{
    if (!server) return;

    // Uploads: bodies go to a temporary file managed by GCDWebServer.
    FilzaRemoteConsoleAddHandlerWithClass(server, @"PUT", @"/api/v1/upload",
                                          NSClassFromString(@"GCDWebServerFileRequest"),
                                          ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleUploadRaw(request);
    });
    FilzaRemoteConsoleAddHandlerWithClass(server, @"POST", @"/api/v1/upload",
                                          NSClassFromString(@"GCDWebServerMultiPartFormRequest"),
                                          ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleUploadMultipart(request);
    });

    FilzaRemoteConsoleAddHandler(server, @"POST", @"/api/v1/mkdir", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleMkdir(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"POST", @"/api/v1/rename", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleRename(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"POST", @"/api/v1/delete", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleDelete(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"POST", @"/api/v1/move", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleTransfer(request, YES);
    });
    FilzaRemoteConsoleAddHandler(server, @"POST", @"/api/v1/copy", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleTransfer(request, NO);
    });

    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/zip", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleZip(request);
    });
    FilzaRemoteConsoleAddHandler(server, @"GET", @"/api/v1/events", ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return FilzaRemoteConsoleHandleEvents(request);
    });
}
