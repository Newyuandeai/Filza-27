//
//  FilzaRemoteConsolePreferences.m
//  Filza-27 (FilzaApplySandboxExt)
//
//  Adds a "REMOTE CONSOLE" section to Filza's own preferences table
//  (TGPreferencesTableViewController), mirroring FilzaSSHPreferencesV2.m —
//  including its IMP-swap installation pattern and its diagnostics breadcrumbs.
//
//  Difference from SSH: the synthetic section is APPENDED to the end of the table
//  instead of being inserted mid-table, so Filza's own section/row indices never
//  need remapping and the hook cannot shift existing rows.
//

@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "FilzaDiagnostics.h"
#import "FilzaRemoteConsole.h"

static NSInteger (*FilzaRemoteConsoleOriginalSections)(id, SEL, UITableView *) = NULL;
static NSInteger (*FilzaRemoteConsoleOriginalRows)(id, SEL, UITableView *, NSInteger) = NULL;
static NSString *(*FilzaRemoteConsoleOriginalHeader)(id, SEL, UITableView *, NSInteger) = NULL;
static NSString *(*FilzaRemoteConsoleOriginalFooter)(id, SEL, UITableView *, NSInteger) = NULL;
static UITableViewCell *(*FilzaRemoteConsoleOriginalCell)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*FilzaRemoteConsoleOriginalDidSelect)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static BOOL FilzaRemoteConsolePreferencesInstalled = NO;

typedef NS_ENUM(NSInteger, FilzaRemoteConsoleRow) {
    FilzaRemoteConsoleRowStatus = 0,
    FilzaRemoteConsoleRowPort,
    FilzaRemoteConsoleRowRotateToken,
    FilzaRemoteConsoleRowWrites,
    FilzaRemoteConsoleRowDeletes,
    FilzaRemoteConsoleRowEnable,
    FilzaRemoteConsoleRowCount,
};

#pragma mark - Section math

static NSInteger FilzaRemoteConsoleOriginalSectionCount(id controller, UITableView *table)
{
    if (!FilzaRemoteConsoleOriginalSections) return 0;
    return FilzaRemoteConsoleOriginalSections(controller, @selector(numberOfSectionsInTableView:), table);
}

static BOOL FilzaRemoteConsoleIsSyntheticSection(id controller, UITableView *table, NSInteger section)
{
    return section == FilzaRemoteConsoleOriginalSectionCount(controller, table);
}

#pragma mark - Helpers

static void FilzaRemoteConsoleReload(id controller)
{
    UITableView *table = nil;
    if ([controller isKindOfClass:UITableViewController.class]) table = ((UITableViewController *)controller).tableView;
    if (!table && [controller respondsToSelector:@selector(tableView)]) {
        id candidate = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
        if ([candidate isKindOfClass:UITableView.class]) table = candidate;
    }
    [table reloadData];
}

static void FilzaRemoteConsolePresent(id controller, UIViewController *next)
{
    if (!next || ![controller respondsToSelector:@selector(navigationController)]) return;
    UINavigationController *navigation = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(navigationController));
    if (![navigation isKindOfClass:UINavigationController.class]) return;
    [navigation pushViewController:next animated:YES];
}

static void FilzaRemoteConsoleCopyToPasteboard(NSString *text, id controller)
{
    UIPasteboard.generalPasteboard.string = text ?: @"";
    UIViewController *presenter = [controller isKindOfClass:UIViewController.class] ? controller : nil;
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已复制到剪贴板"
                                                                  message:text
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Port controller

@interface FilzaRemoteConsolePortController : UITableViewController
@end

@implementation FilzaRemoteConsolePortController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Console Port"; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section { return 4; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray<NSNumber *> *ports = @[@8788, @8888, @9090, @18088];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FilzaRemoteConsolePort"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FilzaRemoteConsolePort"];
    NSInteger port = ports[indexPath.row].integerValue;
    cell.textLabel.text = [NSString stringWithFormat:@"%ld", (long)port];
    cell.accessoryType = (FilzaRemoteConsoleConfiguredPort() == port) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = (port == 8788) ? @"default" : nil;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSNumber *> *ports = @[@8788, @8888, @9090, @18088];
    FilzaRemoteConsoleSetConfiguredPort(ports[indexPath.row].integerValue);
    if (FilzaRemoteConsoleIsRunning()) {
        FilzaRemoteConsoleStop();
        NSError *error = nil;
        if (!FilzaRemoteConsoleStart(&error)) {
            FilzaDiagnosticsAppend(@"RemoteConsole", [NSString stringWithFormat:@"restart on port %ld failed: %@",
                                                      (long)FilzaRemoteConsoleConfiguredPort(), error.localizedDescription]);
        }
    }
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - Table overrides

static NSInteger FilzaRemoteConsoleSections(id controller, SEL selector, UITableView *table)
{
    return FilzaRemoteConsoleOriginalSectionCount(controller, table) + 1;
}

static NSInteger FilzaRemoteConsoleRows(id controller, SEL selector, UITableView *table, NSInteger section)
{
    if (FilzaRemoteConsoleIsSyntheticSection(controller, table, section)) return FilzaRemoteConsoleRowCount;
    return FilzaRemoteConsoleOriginalRows ? FilzaRemoteConsoleOriginalRows(controller, selector, table, section) : 0;
}

static NSString *FilzaRemoteConsoleHeader(id controller, SEL selector, UITableView *table, NSInteger section)
{
    if (FilzaRemoteConsoleIsSyntheticSection(controller, table, section)) return @"REMOTE CONSOLE";
    return FilzaRemoteConsoleOriginalHeader ? FilzaRemoteConsoleOriginalHeader(controller, selector, table, section) : nil;
}

static NSString *FilzaRemoteConsoleFooter(id controller, SEL selector, UITableView *table, NSInteger section)
{
    if (FilzaRemoteConsoleIsSyntheticSection(controller, table, section)) {
        return @"浏览器远程文件查看器。手机与电脑需在同一局域网；令牌等同于全部权限，请勿截图或分享。";
    }
    return FilzaRemoteConsoleOriginalFooter ? FilzaRemoteConsoleOriginalFooter(controller, selector, table, section) : nil;
}

static UITableViewCell *FilzaRemoteConsoleCell(id controller, SEL selector, UITableView *table, NSIndexPath *indexPath)
{
    if (!FilzaRemoteConsoleIsSyntheticSection(controller, table, indexPath.section)) {
        return FilzaRemoteConsoleOriginalCell ? FilzaRemoteConsoleOriginalCell(controller, selector, table, indexPath) : nil;
    }

    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"FilzaRemoteConsoleRow"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"FilzaRemoteConsoleRow"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.detailTextLabel.text = nil;

    switch ((FilzaRemoteConsoleRow)indexPath.row) {
        case FilzaRemoteConsoleRowStatus: {
            cell.textLabel.text = @"Pairing URL";
            NSString *pairing = FilzaRemoteConsolePairingURLString();
            cell.detailTextLabel.text = pairing.length ? @"点击复制配对链接" : @"未运行";
            cell.accessoryType = pairing.length ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
            cell.selectionStyle = pairing.length ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
            break;
        }
        case FilzaRemoteConsoleRowPort:
            cell.textLabel.text = @"Port";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)FilzaRemoteConsoleConfiguredPort()];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case FilzaRemoteConsoleRowRotateToken:
            cell.textLabel.text = @"Pairing token";
            cell.detailTextLabel.text = @"轮换";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case FilzaRemoteConsoleRowWrites: {
            cell.textLabel.text = @"Allow writes (upload/rename/move)";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *toggle = UISwitch.new;
            toggle.on = FilzaRemoteConsoleWritesEnabled();
            [toggle addTarget:controller action:NSSelectorFromString(@"filzaRemoteConsoleWritesChanged:") forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            break;
        }
        case FilzaRemoteConsoleRowDeletes: {
            cell.textLabel.text = @"Allow delete";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *toggle = UISwitch.new;
            toggle.on = FilzaRemoteConsoleDeletesEnabled();
            [toggle addTarget:controller action:NSSelectorFromString(@"filzaRemoteConsoleDeletesChanged:") forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            break;
        }
        case FilzaRemoteConsoleRowEnable: {
            cell.textLabel.text = @"Enable remote console";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *toggle = UISwitch.new;
            toggle.on = FilzaRemoteConsoleIsRunning();
            [toggle addTarget:controller action:NSSelectorFromString(@"filzaRemoteConsoleSwitchChanged:") forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            break;
        }
        default:
            cell.textLabel.text = @"";
            break;
    }
    return cell;
}

static void FilzaRemoteConsoleDidSelect(id controller, SEL selector, UITableView *table, NSIndexPath *indexPath)
{
    if (!FilzaRemoteConsoleIsSyntheticSection(controller, table, indexPath.section)) {
        if (FilzaRemoteConsoleOriginalDidSelect) {
            FilzaRemoteConsoleOriginalDidSelect(controller, selector, table, indexPath);
        }
        return;
    }
    [table deselectRowAtIndexPath:indexPath animated:YES];

    switch ((FilzaRemoteConsoleRow)indexPath.row) {
        case FilzaRemoteConsoleRowStatus: {
            NSString *pairing = FilzaRemoteConsolePairingURLString();
            if (pairing.length) FilzaRemoteConsoleCopyToPasteboard(pairing, controller);
            break;
        }
        case FilzaRemoteConsoleRowPort:
            FilzaRemoteConsolePresent(controller, FilzaRemoteConsolePortController.new);
            break;
        case FilzaRemoteConsoleRowRotateToken: {
            NSString *fresh = FilzaRemoteConsoleRotateToken();
            FilzaRemoteConsoleReload(controller);
            FilzaRemoteConsoleCopyToPasteboard(fresh, controller);
            break;
        }
        default:
            break;
    }
}

#pragma mark - Switch actions

static void FilzaRemoteConsoleSwitchChanged(id controller, __unused SEL selector, UISwitch *toggle)
{
    if (toggle.on) {
        NSError *error = nil;
        if (FilzaRemoteConsoleStart(&error)) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:FilzaRemoteConsoleEnabledKey];
            FilzaDiagnosticsAppend(@"RemoteConsole", @"remote console enabled from preferences after verified listener start");
        } else {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaRemoteConsoleEnabledKey];
            toggle.on = NO;
            UIViewController *presenter = [controller isKindOfClass:UIViewController.class] ? controller : nil;
            if (presenter) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Remote Console"
                                                                              message:error.localizedDescription
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [presenter presentViewController:alert animated:YES completion:nil];
            }
        }
    } else {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaRemoteConsoleEnabledKey];
        FilzaRemoteConsoleStop();
    }
    FilzaRemoteConsoleReload(controller);
}

static void FilzaRemoteConsoleWritesChanged(id controller, __unused SEL selector, UISwitch *toggle)
{
    FilzaRemoteConsoleSetWritesEnabled(toggle.on);
    FilzaDiagnosticsAppend(@"RemoteConsole", toggle.on ? @"writes enabled from preferences" : @"writes disabled from preferences");
    FilzaRemoteConsoleWriteStatus(@"write capability changed in preferences");
    FilzaRemoteConsoleReload(controller);
}

static void FilzaRemoteConsoleDeletesChanged(id controller, __unused SEL selector, UISwitch *toggle)
{
    FilzaRemoteConsoleSetDeletesEnabled(toggle.on);
    FilzaDiagnosticsAppend(@"RemoteConsole", toggle.on ? @"deletes enabled from preferences" : @"deletes disabled from preferences");
    FilzaRemoteConsoleWriteStatus(@"delete capability changed in preferences");
    FilzaRemoteConsoleReload(controller);
}

#pragma mark - Installation

static void FilzaRemoteConsoleInstallOverride(Class cls, SEL selector, IMP replacement, IMP *original)
{
    Method inheritedOrOwn = class_getInstanceMethod(cls, selector);
    if (!inheritedOrOwn) return;
    IMP previous = method_getImplementation(inheritedOrOwn);
    const char *types = method_getTypeEncoding(inheritedOrOwn);
    if (original) *original = previous;
    if (!class_addMethod(cls, selector, replacement, types)) {
        Method own = class_getInstanceMethod(cls, selector);
        method_setImplementation(own, replacement);
    }
}

static void FilzaRemoteConsoleInstallPreferences(void)
{
    if (FilzaRemoteConsolePreferencesInstalled) return;
    Class cls = NSClassFromString(@"TGPreferencesTableViewController");
    if (!cls) {
        FilzaDiagnosticsAppend(@"RemoteConsole", @"console preferences deferred: TGPreferencesTableViewController unavailable");
        return;
    }

    FilzaRemoteConsoleInstallOverride(cls, @selector(numberOfSectionsInTableView:), (IMP)FilzaRemoteConsoleSections, (IMP *)&FilzaRemoteConsoleOriginalSections);
    FilzaRemoteConsoleInstallOverride(cls, @selector(tableView:numberOfRowsInSection:), (IMP)FilzaRemoteConsoleRows, (IMP *)&FilzaRemoteConsoleOriginalRows);
    FilzaRemoteConsoleInstallOverride(cls, @selector(tableView:titleForHeaderInSection:), (IMP)FilzaRemoteConsoleHeader, (IMP *)&FilzaRemoteConsoleOriginalHeader);
    FilzaRemoteConsoleInstallOverride(cls, @selector(tableView:titleForFooterInSection:), (IMP)FilzaRemoteConsoleFooter, (IMP *)&FilzaRemoteConsoleOriginalFooter);
    FilzaRemoteConsoleInstallOverride(cls, @selector(tableView:cellForRowAtIndexPath:), (IMP)FilzaRemoteConsoleCell, (IMP *)&FilzaRemoteConsoleOriginalCell);
    FilzaRemoteConsoleInstallOverride(cls, @selector(tableView:didSelectRowAtIndexPath:), (IMP)FilzaRemoteConsoleDidSelect, (IMP *)&FilzaRemoteConsoleOriginalDidSelect);
    class_addMethod(cls, NSSelectorFromString(@"filzaRemoteConsoleSwitchChanged:"), (IMP)FilzaRemoteConsoleSwitchChanged, "v@:@");
    class_addMethod(cls, NSSelectorFromString(@"filzaRemoteConsoleWritesChanged:"), (IMP)FilzaRemoteConsoleWritesChanged, "v@:@");
    class_addMethod(cls, NSSelectorFromString(@"filzaRemoteConsoleDeletesChanged:"), (IMP)FilzaRemoteConsoleDeletesChanged, "v@:@");

    FilzaRemoteConsolePreferencesInstalled = YES;
    FilzaDiagnosticsAppend(@"RemoteConsole", @"REMOTE CONSOLE preferences installed (appended section)");

    // Restore a saved enable state only through the verified start path.
    if (FilzaRemoteConsoleEnabled() && !FilzaRemoteConsoleIsRunning()) {
        NSError *error = nil;
        if (!FilzaRemoteConsoleStart(&error)) {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaRemoteConsoleEnabledKey];
            FilzaDiagnosticsAppend(@"RemoteConsole", [NSString stringWithFormat:@"saved enable state could not be restored: %@", error.localizedDescription]);
        }
    }
}

__attribute__((constructor)) static void FilzaRemoteConsolePreferencesInit(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                FilzaRemoteConsoleInstallPreferences();
            });
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(__unused NSNotification *note) {
                if (!FilzaRemoteConsolePreferencesInstalled) FilzaRemoteConsoleInstallPreferences();
            }];
        });
    }
}
