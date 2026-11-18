#import "../main/VMAppSelectViewController.h"
#import "../../utils/helpers/VMUIHelper.h"
#import "../patch/VMBackupListViewController.h"
#import "../memory/VMProcessAuditViewController.h"
#import "../../utils/managers/VMBackupManager.h"
#import "include/VMIconHelper.h"
#import "include/VMLocalization.h"
#import "include/VMMemoryEngine.h"
#import "include/VMPointerChain.h"
#import "include/VMPointerManager.h"
#import "include/VMLockManager.h"
#include <signal.h>
#include <libproc.h>
#include <mach/mach_host.h>
#include <mach/vm_statistics.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#define TR(key) ([[VMLocalization shared] localizedString:key])
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define PROC_PIDPATHINFO_MAXSIZE 4096

@class VMSystemMemoryMonitorViewController;

// 0=Running, 1=All, 2=System
typedef NS_ENUM(NSInteger, VMAppFilterMode) {
  VMAppFilterRunning = 0,
  VMAppFilterAll     = 1,
  VMAppFilterSystem  = 2,
};

@interface VMAppSelectViewController () <UISearchBarDelegate>
@property(nonatomic, strong) NSMutableArray *userApps;
@property(nonatomic, strong) NSMutableArray *systemApps;
@property(nonatomic, strong) NSMutableArray *allInstalledApps;
@property(nonatomic, strong) NSArray *displayedApps;
@property(nonatomic, strong) UISegmentedControl *segmentControl;
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, strong) NSCache *iconCache;
@property(nonatomic, assign) VMAppFilterMode filterMode;
@end
@implementation VMAppSelectViewController

- (instancetype)init {
  if (self = [super initWithStyle:UITableViewStylePlain]) {
    _iconCache = [[NSCache alloc] init];
    _filterMode = VMAppFilterRunning;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.title = TR(@"App_Title");
  self.view.backgroundColor = [UIColor systemBackgroundColor];

  self.userApps = [NSMutableArray array];
  self.systemApps = [NSMutableArray array];
  self.allInstalledApps = [NSMutableArray array];

  // Right nav: live system memory monitor + backup manager
  UIBarButtonItem *memoryItem =
      [[UIBarButtonItem alloc] initWithTitle:@"RAM"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(openSystemMemoryMonitor)];
  memoryItem.image = [UIImage systemImageNamed:@"memorychip"];
  UIBarButtonItem *backupItem =
      [[UIBarButtonItem alloc] initWithTitle:TR(@"Backups_Global_Title")
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(openGlobalBackup)];
  self.navigationItem.rightBarButtonItems = @[ memoryItem, backupItem ];

  self.navigationItem.leftBarButtonItem = nil;

  self.searchBar = [[UISearchBar alloc]
      initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
  self.searchBar.placeholder = TR(@"App_Search");
  self.searchBar.delegate = self;
  self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
  self.searchBar.returnKeyType = UIReturnKeySearch;
  self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  self.tableView.tableHeaderView = self.searchBar;
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

  self.segmentControl = [[UISegmentedControl alloc]
      initWithItems:@[ TR(@"Filter_Running"), TR(@"Filter_All"), TR(@"App_Sys") ]];
  self.segmentControl.selectedSegmentIndex = 0;
  [self.segmentControl addTarget:self
                          action:@selector(segmentChanged)
                forControlEvents:UIControlEventValueChanged];
  self.navigationItem.titleView = self.segmentControl;

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(loadProcesses)
                                               name:@"VMReqProcessRefresh"
                                             object:nil];

  UIRefreshControl *ref = [[UIRefreshControl alloc] init];
  ref.attributedTitle =
      [[NSAttributedString alloc] initWithString:TR(@"Pull_Idle")];
  [ref addTarget:self
                action:@selector(handleRefresh:)
      forControlEvents:UIControlEventValueChanged];
  self.tableView.refreshControl = ref;

  [self loadProcesses];
  [self loadInstalledApps];

  [VMUIHelper addFixedFooterTo:self forTableView:self.tableView];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Navigation

- (void)openGlobalBackup {
  VMBackupListViewController *vc = [[VMBackupListViewController alloc] init];
  [self.navigationController pushViewController:vc animated:YES];
}

- (void)openSystemMemoryMonitor {
  UIViewController *vc = [[VMSystemMemoryMonitorViewController alloc] init];
  [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Segment

- (void)segmentChanged {
  self.filterMode = (VMAppFilterMode)self.segmentControl.selectedSegmentIndex;

  if (self.filterMode == VMAppFilterRunning) {
    self.displayedApps = self.userApps;
  } else if (self.filterMode == VMAppFilterAll) {
    self.displayedApps = self.allInstalledApps;
  } else {
    self.displayedApps = self.systemApps;
    static BOOL warned = NO;
    if (!warned) {
      UIAlertController *alert = [UIAlertController
          alertControllerWithTitle:TR(@"Alert_Warn")
                           message:TR(@"App_Sys_Warn")
                    preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Confirm")
                                                style:UIAlertActionStyleDestructive
                                              handler:nil]];
      [self presentViewController:alert animated:YES completion:nil];
      warned = YES;
    }
  }

  // Re-apply search filter if active
  if (self.searchBar.text.length > 0) {
    [self searchBar:self.searchBar textDidChange:self.searchBar.text];
  } else {
    [self.tableView reloadData];
  }
}

#pragma mark - Localized App Name

- (NSString *)smartLocalizedNameForPath:(NSString *)bundlePath
                           originalName:(NSString *)originalName {
  if (!bundlePath || bundlePath.length == 0)
    return originalName;

  NSString *currentLang = [[VMLocalization shared] currentLanguage];
  if ([currentLang isEqualToString:@"Auto"])
    return originalName;

  NSArray *targetLprojs = nil;
  if ([currentLang isEqualToString:@"zh-Hans"]) {
    targetLprojs = @[ @"zh-Hans", @"zh_CN", @"zh-Hant", @"zh" ];
  } else {
    targetLprojs = @[ @"en", @"English", @"Base" ];
  }

  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *lproj in targetLprojs) {
    NSString *stringsPath = [[bundlePath
        stringByAppendingPathComponent:[lproj stringByAppendingString:@".lproj"]]
        stringByAppendingPathComponent:@"InfoPlist.strings"];
    if ([fm fileExistsAtPath:stringsPath]) {
      NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:stringsPath];
      if (dict) {
        NSString *name = dict[@"CFBundleDisplayName"];
        if (!name) name = dict[@"CFBundleName"];
        if (name && name.length > 0) return name;
      }
    }
  }
  return originalName;
}

#pragma mark - Refresh

- (void)handleRefresh:(UIRefreshControl *)sender {
  sender.attributedTitle =
      [[NSAttributedString alloc] initWithString:TR(@"Pull_Loading")];

  [self loadProcesses];
  [self loadInstalledApps];

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [sender endRefreshing];
        sender.attributedTitle =
            [[NSAttributedString alloc] initWithString:TR(@"Pull_Idle")];
      });
}

#pragma mark - Load Running Processes

- (void)loadProcesses {
  NSMutableArray *tempUser = [NSMutableArray array];
  NSMutableArray *tempSys = [NSMutableArray array];

  NSArray *customSystemList = @[
    @"SpringBoard", @"backboardd", @"mediaserverd",
    @"com.apple.WebKit", @"Search",
  ];

  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size;
  sysctl(mib, 4, NULL, &size, NULL, 0);
  struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
  if (sysctl(mib, 4, procs, &size, NULL, 0) == -1) {
    free(procs);
    return;
  }

  int count = size / sizeof(struct kinfo_proc);
  pid_t myPid = getpid();

  for (int i = 0; i < count; i++) {
    pid_t pid = procs[i].kp_proc.p_pid;
    if (pid <= 0 || pid == myPid) continue;

    NSString *procName =
        [NSString stringWithUTF8String:procs[i].kp_proc.p_comm];
    if (!procName) procName = TR(@"App_Unknown");

    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
    bzero(pathBuffer, PROC_PIDPATHINFO_MAXSIZE);
    proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    NSString *fullPath = [NSString stringWithUTF8String:pathBuffer];

    NSString *bundleID = @"";
    NSString *version = @"";
    NSString *displayName = procName;
    NSString *bundlePath = @"";

    if (fullPath && fullPath.length > 0) {
      bundlePath = [fullPath stringByDeletingLastPathComponent];
      if ([bundlePath.pathExtension isEqualToString:@"app"]) {
        NSDictionary *inf = [NSDictionary
            dictionaryWithContentsOfFile:
                [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
        if (inf) {
          bundleID = inf[@"CFBundleIdentifier"];
          version = inf[@"CFBundleShortVersionString"];
          NSString *baseName = inf[@"CFBundleDisplayName"] ?: inf[@"CFBundleName"] ?: procName;
          displayName = [self smartLocalizedNameForPath:bundlePath originalName:baseName];
        }
      }
    }

    NSDictionary *item = @{
      @"name" : displayName ?: (procName ?: @"Unknown"),
      @"pid" : @(pid),
      @"path" : fullPath ?: @"",
      @"bid" : bundleID ?: @"",
      @"ver" : version ?: @"",
      @"bundlePath" : bundlePath ?: @""
    };

    BOOL isSystem = YES;
    if (bundleID && bundleID.length > 0) {
      if (![bundleID hasPrefix:@"com.apple."]) {
        if ([fullPath rangeOfString:@"/containers/" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [fullPath rangeOfString:@"/Application/" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [fullPath rangeOfString:@"/TrollStore/" options:NSCaseInsensitiveSearch].location != NSNotFound) {
          isSystem = NO;
        }
      }
    }
    if ([customSystemList containsObject:procName] ||
        (bundleID.length > 0 && [customSystemList containsObject:bundleID])) {
      isSystem = YES;
    }

    if (isSystem) [tempSys addObject:item];
    else [tempUser addObject:item];
  }
  free(procs);

  NSComparator sortByStarred = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    BOOL aStarred = [VMMemoryEngine isProcessStarred:a[@"bid"]];
    BOOL bStarred = [VMMemoryEngine isProcessStarred:b[@"bid"]];
    if (aStarred && !bStarred) return NSOrderedAscending;
    if (!aStarred && bStarred) return NSOrderedDescending;
    return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
  };

  [tempUser sortUsingComparator:sortByStarred];
  [tempSys sortUsingComparator:sortByStarred];

  dispatch_async(dispatch_get_main_queue(), ^{
    self.userApps = tempUser;
    self.systemApps = tempSys;

    if (self.filterMode != VMAppFilterAll) {
      [self segmentChanged];
    }

    if (self.userApps.count == 0 && self.systemApps.count == 0 && self.filterMode != VMAppFilterAll) {
      UILabel *emptyLabel = [[UILabel alloc]
          initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 300)];
      emptyLabel.text = TR(@"App_Empty_Processes");
      emptyLabel.textColor = [UIColor systemGrayColor];
      emptyLabel.textAlignment = NSTextAlignmentCenter;
      emptyLabel.numberOfLines = 0;
      emptyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
      self.tableView.backgroundView = emptyLabel;
    } else {
      self.tableView.backgroundView = nil;
    }

    [self.tableView reloadData];
    if (self.tableView.refreshControl.isRefreshing) {
      [self.tableView.refreshControl endRefreshing];
    }
  });
}

#pragma mark - Load All Installed Apps

- (void)loadInstalledApps {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSMutableArray *temp = [NSMutableArray array];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id workspace = [NSClassFromString(@"LSApplicationWorkspace")
        performSelector:NSSelectorFromString(@"defaultWorkspace")];
    NSArray *proxies = [workspace performSelector:NSSelectorFromString(@"allInstalledApplications")];

    for (id proxy in proxies) {
      NSString *type = [proxy performSelector:NSSelectorFromString(@"applicationType")];
      NSString *bid = [proxy performSelector:NSSelectorFromString(@"applicationIdentifier")];
      NSURL *bundleURL = [proxy performSelector:NSSelectorFromString(@"bundleURL")];
      NSURL *dataContainerURL = [proxy performSelector:NSSelectorFromString(@"dataContainerURL")];
      NSString *canonicalPath = [proxy performSelector:NSSelectorFromString(@"canonicalExecutablePath")];

      if ([bid isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) continue;

      BOOL shouldShow = NO;
      if ([type isEqualToString:@"User"]) shouldShow = YES;
      if ([bid hasPrefix:@"com.apple."]) shouldShow = NO;
      else shouldShow = YES;

      if (!dataContainerURL && canonicalPath.length > 0 &&
          [[NSFileManager defaultManager] isExecutableFileAtPath:canonicalPath]) {
        if (![bid hasPrefix:@"com.apple."]) shouldShow = YES;
      }

      if (shouldShow) {
        NSString *sysName = [proxy performSelector:NSSelectorFromString(@"localizedName")];
        NSString *name = [self smartLocalizedNameForPath:bundleURL.path originalName:sysName];
        NSString *ver = [proxy performSelector:NSSelectorFromString(@"shortVersionString")];
        if (!ver) ver = [proxy performSelector:NSSelectorFromString(@"bundleVersion")];

        [temp addObject:@{
          @"name": name ?: TR(@"App_Unknown"),
          @"bid": bid ?: @"",
          @"ver": ver ?: @"",
          @"path": bundleURL.path ?: @"",
          @"bundlePath": bundleURL.path ?: @""
        }];
      }
    }
#pragma clang diagnostic pop

    [temp sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
      self.allInstalledApps = temp;
      if (self.filterMode == VMAppFilterAll) {
        [self segmentChanged];
      }
    });
  });
}

#pragma mark - App Icon

- (UIImage *)getAppIcon:(NSString *)exePath isSystem:(BOOL)isSystem {
  if (!exePath || exePath.length == 0) {
    return isSystem ? [UIImage systemImageNamed:@"gear"]
                    : [VMIconHelper compatibleSystemImageNamed:@"app.fill"];
  }
  UIImage *cached = [self.iconCache objectForKey:exePath];
  if (cached) return cached;

  NSString *bundlePath = exePath;
  // For running processes, exePath is the executable; for installed apps, it's the .app dir
  if (![bundlePath.pathExtension isEqualToString:@"app"]) {
    bundlePath = [exePath stringByDeletingLastPathComponent];
  }

  NSString *iconName = nil;
  if ([bundlePath.pathExtension isEqualToString:@"app"]) {
    NSDictionary *info = [NSDictionary
        dictionaryWithContentsOfFile:
            [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    if (info) {
      NSDictionary *icons = info[@"CFBundleIcons"];
      NSArray *files = icons[@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
      if (files.count > 0) iconName = files.lastObject;
    }
    if (!iconName) {
      NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
      for (NSString *f in files)
        if ([f hasPrefix:@"AppIcon"] && [f containsString:@"60x60"])
          iconName = f;
    }
    if (iconName) {
      NSString *p = [bundlePath stringByAppendingPathComponent:iconName];
      if (![[NSFileManager defaultManager] fileExistsAtPath:p])
        p = [p stringByAppendingString:@"@2x.png"];
      UIImage *img = [UIImage imageWithContentsOfFile:p];
      if (img) {
        [self.iconCache setObject:img forKey:exePath];
        return img;
      }
    }
  }
  return isSystem ? [UIImage systemImageNamed:@"gear"]
                  : [VMIconHelper compatibleSystemImageNamed:@"app.fill"];
}

#pragma mark - Search Delegate

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
  [searchBar resignFirstResponder];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  if (searchText.length == 0) {
    [self segmentChanged];
    return;
  }
  NSArray *source;
  if (self.filterMode == VMAppFilterRunning) source = self.userApps;
  else if (self.filterMode == VMAppFilterAll) source = self.allInstalledApps;
  else source = self.systemApps;

  NSString *fmt = (self.filterMode == VMAppFilterAll)
    ? @"name CONTAINS[c] %@ OR bid CONTAINS[c] %@"
    : @"name CONTAINS[c] %@ OR bid CONTAINS[c] %@ OR pid.stringValue CONTAINS %@";

  NSPredicate *pred;
  if (self.filterMode == VMAppFilterAll) {
    pred = [NSPredicate predicateWithFormat:fmt, searchText, searchText];
  } else {
    pred = [NSPredicate predicateWithFormat:fmt, searchText, searchText, searchText];
  }
  self.displayedApps = [source filteredArrayUsingPredicate:pred];
  [self.tableView reloadData];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
  [self.searchBar resignFirstResponder];
}

#pragma mark - TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.displayedApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *cid = @"proc";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
  }

  NSDictionary *item = self.displayedApps[indexPath.row];
  NSString *bid = item[@"bid"];
  BOOL isStarred = [VMMemoryEngine isProcessStarred:bid];

  NSString *displayName = item[@"name"];
  if (isStarred) displayName = [NSString stringWithFormat:@"⭐ %@", displayName];

  cell.textLabel.text = displayName;
  cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];

  NSMutableString *detail = [NSMutableString string];
  if (self.filterMode != VMAppFilterAll && item[@"pid"]) {
    [detail appendFormat:@"PID: %@", item[@"pid"]];
    if ([bid length] > 0) [detail appendFormat:@" | %@", bid];
  } else {
    if ([bid length] > 0) [detail appendString:bid];
  }
  if ([item[@"ver"] length] > 0) [detail appendFormat:@" (v%@)", item[@"ver"]];

  cell.detailTextLabel.text = detail;
  cell.detailTextLabel.textColor = [UIColor systemGrayColor];

  BOOL isSystem = (self.filterMode == VMAppFilterSystem);
  NSString *iconPath = (self.filterMode == VMAppFilterAll) ? item[@"path"] : item[@"path"];
  UIImage *icon = [self getAppIcon:iconPath isSystem:isSystem];

  CGSize itemSize = CGSizeMake(29, 29);
  UIGraphicsBeginImageContextWithOptions(itemSize, NO, UIScreen.mainScreen.scale);
  [icon drawInRect:CGRectMake(0, 0, 29, 29)];
  cell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  cell.imageView.layer.cornerRadius = 6;
  cell.imageView.clipsToBounds = YES;

  cell.accessoryType = (self.filterMode == VMAppFilterAll)
    ? UITableViewCellAccessoryDisclosureIndicator
    : UITableViewCellAccessoryNone;

  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  [self.searchBar resignFirstResponder];

  NSDictionary *item = self.displayedApps[indexPath.row];
  [self showMenuForApp:item atIndexPath:indexPath];
}

#pragma mark - Unified Action Sheet

- (void)showMenuForApp:(NSDictionary *)item atIndexPath:(NSIndexPath *)indexPath {
  NSString *name = item[@"name"];
  NSString *bid = item[@"bid"];
  NSString *bPath = item[@"bundlePath"] ?: item[@"path"] ?: @"";

  // Resolve PID: from item dict (running mode) or by searching (all mode)
  pid_t pid = 0;
  if (item[@"pid"]) {
    pid = [item[@"pid"] intValue];
  } else if (bid.length > 0) {
    pid = [self findPidForBundleID:bid];
  }
  BOOL isRunning = (pid > 0);

  NSMutableString *subtitle = [NSMutableString string];
  if (isRunning) [subtitle appendFormat:@"PID: %d\n", pid];
  if (bid.length > 0) [subtitle appendString:bid];

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:name message:subtitle
      preferredStyle:UIAlertControllerStyleActionSheet];

  // === Process actions (only when running) ===
  if (isRunning) {
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Act_Attach")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      BOOL success = [[VMMemoryEngine shared] attachToPid:pid];
      if (success) {
        if (bid.length > 0) {
          [VMMemoryEngine shared].currentBundleID = bid;
          [VMMemoryEngine shared].currentProcessName = name;
        }
        UIAlertController *toast = [UIAlertController
            alertControllerWithTitle:TR(@"Msg_Attached") message:nil
            preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:toast animated:YES completion:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
          [toast dismissViewControllerAnimated:YES completion:^{
            self.tabBarController.selectedIndex = 1;
          }];
        });
      } else {
        UIAlertController *err = [UIAlertController
            alertControllerWithTitle:TR(@"Alert_Fail") message:TR(@"Msg_Attach_Fail")
            preferredStyle:UIAlertControllerStyleAlert];
        [err addAction:[UIAlertAction actionWithTitle:TR(@"Btn_OK") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:err animated:YES completion:nil];
      }
    }]];
  }

  // Open App
  if (bid.length > 0) {
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Act_Open")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      id ws = [NSClassFromString(@"LSApplicationWorkspace") performSelector:NSSelectorFromString(@"defaultWorkspace")];
      [ws performSelector:NSSelectorFromString(@"openApplicationWithBundleID:") withObject:bid];
#pragma clang diagnostic pop
    }]];
  }

  // Copy PID (only when running)
  if (isRunning) {
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Act_Copy_PID")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      [[UIPasteboard generalPasteboard] setString:[NSString stringWithFormat:@"%d", pid]];
      [self showToast:TR(@"Msg_Copied")];
    }]];
  }

  // Copy Bundle ID
  if (bid.length > 0) {
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Act_Copy_Bid")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      [[UIPasteboard generalPasteboard] setString:bid];
      [self showToast:TR(@"Msg_Copied")];
    }]];
  }

  // Star/Unstar
  if (bid.length > 0) {
    BOOL isStarred = [VMMemoryEngine isProcessStarred:bid];
    [alert addAction:[UIAlertAction actionWithTitle:(isStarred ? TR(@"Act_Unstar") : TR(@"Act_Star"))
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      if (isStarred) { [VMMemoryEngine unstarProcess:bid]; [self showToast:TR(@"Msg_Unstarred")]; }
      else { [VMMemoryEngine starProcess:bid]; [self showToast:TR(@"Msg_Starred")]; }
      [self loadProcesses];
    }]];
  }

  // Add Pointer
  if (bid.length > 0) {
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Act_Add_Pointer")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      [self showAddPointerAlertForBundleID:bid appName:name];
    }]];
  }

  // === App management actions ===
  // Create Backup
  if (bid.length > 0) {
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Create_New_Backup")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      [self createBackupForBid:bid name:name];
    }]];
  }

  // Process Audit
  if (bid.length > 0) {
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Audit_Title")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      VMProcessAuditViewController *vc = [[VMProcessAuditViewController alloc] init];
      vc.appName = name;
      vc.bundleID = bid;
      vc.bundlePath = bPath;
      [self.navigationController pushViewController:vc animated:YES];
    }]];
  }

  // Kill (only when running)
  if (isRunning) {
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Act_Kill")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
      kill(pid, SIGKILL);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{ [self loadProcesses]; });
    }]];
  }

  [alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Cancel") style:UIAlertActionStyleCancel handler:nil]];

  if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
    alert.popoverPresentationController.sourceView = self.tableView;
    alert.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
  }
  [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Backup Helper

- (void)createBackupForBid:(NSString *)bid name:(NSString *)name {
  UIView *customContentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 80)];

  UILabel *tipLabel = [[UILabel alloc] init];
  tipLabel.text = TR(@"Backuping");
  tipLabel.font = [UIFont systemFontOfSize:16];
  tipLabel.textAlignment = NSTextAlignmentCenter;
  tipLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [customContentView addSubview:tipLabel];

  UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  spin.translatesAutoresizingMaskIntoConstraints = NO;
  [spin startAnimating];
  [customContentView addSubview:spin];

  [NSLayoutConstraint activateConstraints:@[
    [tipLabel.centerXAnchor constraintEqualToAnchor:customContentView.centerXAnchor],
    [tipLabel.topAnchor constraintEqualToAnchor:customContentView.topAnchor constant:10],
    [spin.centerXAnchor constraintEqualToAnchor:customContentView.centerXAnchor],
    [spin.topAnchor constraintEqualToAnchor:tipLabel.bottomAnchor constant:10],
    [spin.bottomAnchor constraintEqualToAnchor:customContentView.bottomAnchor constant:-10]
  ]];

  UIAlertController *loading = [UIAlertController alertControllerWithTitle:nil message:@"\n\n" preferredStyle:UIAlertControllerStyleAlert];
  customContentView.translatesAutoresizingMaskIntoConstraints = NO;
  [loading.view addSubview:customContentView];
  [NSLayoutConstraint activateConstraints:@[
    [customContentView.centerXAnchor constraintEqualToAnchor:loading.view.centerXAnchor],
    [customContentView.centerYAnchor constraintEqualToAnchor:loading.view.centerYAnchor],
    [customContentView.widthAnchor constraintEqualToConstant:200],
    [customContentView.heightAnchor constraintEqualToConstant:80]
  ]];

  [self presentViewController:loading animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(0, 0), ^{
    NSString *folderPath = [[VMBackupManager shared] backupApp:bid name:name];
    dispatch_async(dispatch_get_main_queue(), ^{
      [loading dismissViewControllerAnimated:YES completion:^{
        if (folderPath) [self showToast:TR(@"Msg_Backup_Done_Internal")];
        else [self showToast:TR(@"Backup_Failed")];
      }];
    });
  });
}

#pragma mark - PID Lookup

- (pid_t)findPidForBundleID:(NSString *)bundleID {
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size = 0;
  if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return 0;

  struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
  if (!procs) return 0;
  if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) { free(procs); return 0; }

  int count = (int)(size / sizeof(struct kinfo_proc));
  pid_t found = 0;

  for (int i = 0; i < count; i++) {
    pid_t pid = procs[i].kp_proc.p_pid;
    if (pid <= 1) continue;
    char pathBuf[4096];
    if (proc_pidpath(pid, pathBuf, sizeof(pathBuf)) > 0) {
      NSString *path = [NSString stringWithUTF8String:pathBuf];
      if ([path containsString:bundleID]) { found = pid; break; }
    }
  }
  free(procs);
  return found;
}

#pragma mark - Toast

- (void)showToast:(NSString *)msg {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:nil message:msg
          preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:alert animated:YES completion:nil];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
      });
}

#pragma mark - Scroll

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
  if (self.tableView.refreshControl.isRefreshing) return;

  CGFloat baseOffset = scrollView.adjustedContentInset.top;
  CGFloat pullDistance = -(scrollView.contentOffset.y + baseOffset);
  CGFloat triggerHeight = 45.0;

  NSString *currentText = self.tableView.refreshControl.attributedTitle.string;
  if (pullDistance > triggerHeight) {
    if (![currentText isEqualToString:TR(@"Pull_Ready")]) {
      self.tableView.refreshControl.attributedTitle =
          [[NSAttributedString alloc] initWithString:TR(@"Pull_Ready")];
    }
  } else if (pullDistance > 0) {
    if (![currentText isEqualToString:TR(@"Pull_Idle")]) {
      self.tableView.refreshControl.attributedTitle =
          [[NSAttributedString alloc] initWithString:TR(@"Pull_Idle")];
    }
  }
}

#pragma mark - Add Pointer Chain

- (VMPointerChain *)parsePointerChainFromString:(NSString *)input {
  if (!input || input.length == 0) return nil;

  NSString *cleanInput = [input stringByReplacingOccurrencesOfString:@" " withString:@""];

  NSRegularExpression *baseRegex = [NSRegularExpression
      regularExpressionWithPattern:@"^\\[([^\\+]+)\\+0x([0-9A-Fa-f]+)\\]"
                           options:0 error:nil];

  NSTextCheckingResult *baseMatch = [baseRegex firstMatchInString:cleanInput
      options:0 range:NSMakeRange(0, cleanInput.length)];
  if (!baseMatch) return nil;

  NSString *moduleName = [cleanInput substringWithRange:[baseMatch rangeAtIndex:1]];
  NSString *baseOffsetStr = [cleanInput substringWithRange:[baseMatch rangeAtIndex:2]];
  uint64_t baseOffset = strtoull([baseOffsetStr UTF8String], NULL, 16);

  NSString *remaining = [cleanInput substringFromIndex:baseMatch.range.length];
  NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];

  NSRegularExpression *offsetRegex = [NSRegularExpression
      regularExpressionWithPattern:@"([\\+\\-]?)0x([0-9A-Fa-f]+)"
                           options:0 error:nil];

  NSArray *offsetMatches = [offsetRegex matchesInString:remaining
      options:0 range:NSMakeRange(0, remaining.length)];

  for (NSTextCheckingResult *match in offsetMatches) {
    NSString *sign = [remaining substringWithRange:[match rangeAtIndex:1]];
    NSString *offsetStr = [remaining substringWithRange:[match rangeAtIndex:2]];
    int64_t offset = strtoull([offsetStr UTF8String], NULL, 16);
    if ([sign isEqualToString:@"-"]) offset = -offset;
    [offsets addObject:@(offset)];
  }

  VMPointerChain *chain = [[VMPointerChain alloc] init];
  chain.moduleName = moduleName;
  chain.baseOffset = baseOffset;
  chain.offsets = offsets;
  return chain;
}

- (void)showAddPointerAlertForBundleID:(NSString *)bundleID appName:(NSString *)appName {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:TR(@"Act_Add_Pointer")
                       message:TR(@"Ptr_Add_Hint")
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = TR(@"Ptr_Add_Placeholder");
    tf.keyboardType = UIKeyboardTypeASCIICapable;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 45, 30)];
    l.text = TR(@"Ptr_Label_Chain");
    l.font = [UIFont systemFontOfSize:12];
    tf.leftView = l;
    tf.leftViewMode = UITextFieldViewModeAlways;
  }];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = TR(@"Placeholder_Note");
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 45, 30)];
    l.text = TR(@"Lab_Note_Colon");
    l.font = [UIFont systemFontOfSize:12];
    tf.leftView = l;
    tf.leftViewMode = UITextFieldViewModeAlways;
  }];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = @"0";
    tf.keyboardType = UIKeyboardTypeNumberPad;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 45, 30)];
    l.text = TR(@"Lab_Value_Colon");
    l.font = [UIFont systemFontOfSize:12];
    tf.leftView = l;
    tf.leftViewMode = UITextFieldViewModeAlways;
  }];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = TR(@"Placeholder_Author_Default");
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 45, 30)];
    l.text = TR(@"Lab_Auth_Colon");
    l.font = [UIFont systemFontOfSize:12];
    tf.leftView = l;
    tf.leftViewMode = UITextFieldViewModeAlways;

  }];

  UIViewController *contentVC = [[UIViewController alloc] init];
  contentVC.preferredContentSize = CGSizeMake(270, 40);
  UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[
    TR(@"Type_I8"), TR(@"Type_I16"), TR(@"Type_I32"), TR(@"Type_I64"),
    TR(@"Type_F32"), TR(@"Type_F64")
  ]];
  seg.frame = CGRectMake(0, 5, 270, 30);
  seg.selectedSegmentIndex = 2;
  [contentVC.view addSubview:seg];
  [alert setValue:contentVC forKey:@"contentViewController"];

  [alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Confirm")
      style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    UITextField *tfChain = alert.textFields[0];
    UITextField *tfNote = alert.textFields[1];
    UITextField *tfValue = alert.textFields[2];
    UITextField *tfAuthor = alert.textFields[3];

    NSString *chainStr = tfChain.text;
    if (!chainStr || chainStr.length == 0) {
      [self showToast:TR(@"Err_Invalid_Base_Ptr")];
      return;
    }

    VMPointerChain *chain = [self parsePointerChainFromString:chainStr];
    if (!chain) {
      [self showToast:TR(@"Err_Invalid_Base_Ptr")];
      return;
    }

    chain.bundleID = bundleID;
    chain.appName = appName;
    chain.note = tfNote.text.length > 0 ? tfNote.text : TR(@"Lock_Default_Note_Ptr");
    chain.lockValue = tfValue.text.length > 0 ? tfValue.text : @"0";
    chain.author = tfAuthor.text.length > 0 ? tfAuthor.text : TR(@"Placeholder_Author_Default");
    chain.lockEnabled = NO;
    chain.isImported = NO;

    static const VMDataType typeMap[] = {
      VMDataTypeInt8, VMDataTypeInt16, VMDataTypeInt32,
      VMDataTypeInt64, VMDataTypeFloat, VMDataTypeDouble
    };
    NSInteger idx = seg.selectedSegmentIndex;
    chain.lockType = (idx >= 0 && idx < 6) ? typeMap[idx] : VMDataTypeInt32;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id proxy = [NSClassFromString(@"LSApplicationProxy")
        performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")
             withObject:bundleID];
    if (proxy) {
      NSString *ver = [proxy performSelector:NSSelectorFromString(@"shortVersionString")];
      if (!ver) ver = [proxy performSelector:NSSelectorFromString(@"bundleVersion")];
      chain.appVersion = ver;
    }
#pragma clang diagnostic pop

    [[VMLockManager shared] addPointerToLock:chain];
    [self showToast:TR(@"Ptr_Lock_Success")];
  }]];

  [alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Cancel")
      style:UIAlertActionStyleCancel handler:nil]];

  [self presentViewController:alert animated:YES completion:nil];
}

@end


#pragma mark - Device-wide Read-only Memory Monitor

@interface VMSystemMemoryMonitorViewController : UITableViewController
@property(nonatomic, assign) uint64_t totalMemory;
@property(nonatomic, assign) uint64_t freeMemory;
@property(nonatomic, assign) uint64_t activeMemory;
@property(nonatomic, assign) uint64_t inactiveMemory;
@property(nonatomic, assign) uint64_t wiredMemory;
@property(nonatomic, assign) uint64_t compressedMemory;
@property(nonatomic, strong) NSArray<NSDictionary *> *processes;
@property(nonatomic, assign) BOOL hasVMStatistics;
@property(nonatomic, assign) BOOL isRefreshing;
@end

@implementation VMSystemMemoryMonitorViewController

- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"System Memory";
  self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
  self.processes = @[];
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                    target:self
                                                    action:@selector(refreshSnapshot)];
  UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
  [refresh addTarget:self action:@selector(refreshSnapshot)
    forControlEvents:UIControlEventValueChanged];
  self.refreshControl = refresh;
  [self refreshSnapshot];
}

- (NSString *)formattedBytes:(uint64_t)value {
  return [NSByteCountFormatter stringFromByteCount:(long long)value
                                        countStyle:NSByteCountFormatterCountStyleMemory];
}

- (void)refreshSnapshot {
  if (self.isRefreshing) return;
  self.isRefreshing = YES;
  [self.refreshControl beginRefreshing];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    uint64_t total = 0;
    size_t totalSize = sizeof(total);
    sysctlbyname("hw.memsize", &total, &totalSize, NULL, 0);

    uint64_t freeBytes = 0, activeBytes = 0, inactiveBytes = 0;
    uint64_t wiredBytes = 0, compressedBytes = 0;
    BOOL statsOK = NO;
    vm_statistics64_data_t vmStats = {};
    mach_msg_type_number_t vmCount = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t kr = host_statistics64(host, HOST_VM_INFO64,
                                         (host_info64_t)&vmStats, &vmCount);
    mach_port_deallocate(mach_task_self(), host);
    if (kr == KERN_SUCCESS) {
      uint64_t pageSize = (uint64_t)vm_page_size;
      freeBytes = ((uint64_t)vmStats.free_count +
                   (uint64_t)vmStats.speculative_count) * pageSize;
      activeBytes = (uint64_t)vmStats.active_count * pageSize;
      inactiveBytes = (uint64_t)vmStats.inactive_count * pageSize;
      wiredBytes = (uint64_t)vmStats.wire_count * pageSize;
      compressedBytes = (uint64_t)vmStats.compressor_page_count * pageSize;
      statsOK = YES;
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t procBytes = 0;
    if (sysctl(mib, 4, NULL, &procBytes, NULL, 0) == 0 && procBytes > 0) {
      struct kinfo_proc *entries = (struct kinfo_proc *)calloc(1, procBytes);
      if (entries) {
        if (sysctl(mib, 4, entries, &procBytes, NULL, 0) == 0) {
          size_t count = procBytes / sizeof(struct kinfo_proc);
          for (size_t i = 0; i < count; i++) {
            pid_t pid = entries[i].kp_proc.p_pid;
            if (pid <= 0) continue;

            struct proc_taskinfo taskInfo = {};
            int infoBytes = proc_pidinfo(pid, PROC_PIDTASKINFO, 0,
                                         &taskInfo, sizeof(taskInfo));
            NSString *name = [NSString stringWithUTF8String:entries[i].kp_proc.p_comm];
            if (name.length == 0) name = [NSString stringWithFormat:@"PID %d", pid];

            NSMutableDictionary *row = [@{
              @"pid": @(pid),
              @"name": name,
              @"resident": @((infoBytes == sizeof(taskInfo)) ? taskInfo.pti_resident_size : 0),
              @"virtual": @((infoBytes == sizeof(taskInfo)) ? taskInfo.pti_virtual_size : 0),
              @"available": @(infoBytes == sizeof(taskInfo))
            } mutableCopy];
            [rows addObject:row];
          }
        }
        free(entries);
      }
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      unsigned long long av = [a[@"resident"] unsignedLongLongValue];
      unsigned long long bv = [b[@"resident"] unsignedLongLongValue];
      if (av > bv) return NSOrderedAscending;
      if (av < bv) return NSOrderedDescending;
      return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
      self.totalMemory = total;
      self.freeMemory = freeBytes;
      self.activeMemory = activeBytes;
      self.inactiveMemory = inactiveBytes;
      self.wiredMemory = wiredBytes;
      self.compressedMemory = compressedBytes;
      self.hasVMStatistics = statsOK;
      self.processes = rows;
      self.isRefreshing = NO;
      [self.refreshControl endRefreshing];
      [self.tableView reloadData];
    });
  });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return section == 0 ? 7 : self.processes.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return section == 0 ? @"PHYSICAL MEMORY" : [NSString stringWithFormat:@"RUNNING PROCESSES · %lu", (unsigned long)self.processes.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  if (section == 0) {
    return @"System counters are read-only. Kernel pages and protected memory contents are not exposed by these APIs.";
  }
  return @"Resident size is per-process resident memory, not a guaranteed physical-footprint or exclusive-RAM figure. Some processes may deny metadata queries.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *identifier = @"VMSystemMemoryCell";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                  reuseIdentifier:identifier];
  }
  cell.selectionStyle = indexPath.section == 1 ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
  cell.accessoryType = UITableViewCellAccessoryNone;
  cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

  if (indexPath.section == 0) {
    NSArray<NSString *> *labels = @[
      @"Installed physical RAM",
      @"Free + speculative",
      @"Active pages",
      @"Inactive pages",
      @"Wired pages",
      @"Compressed pages",
      @"Kernel memory access"
    ];
    uint64_t values[] = {
      self.totalMemory, self.freeMemory, self.activeMemory,
      self.inactiveMemory, self.wiredMemory, self.compressedMemory, 0
    };
    cell.textLabel.text = labels[indexPath.row];
    if (indexPath.row == 6) {
      cell.detailTextLabel.text = @"Not exposed";
    } else if (indexPath.row == 0) {
      cell.detailTextLabel.text = self.totalMemory ? [self formattedBytes:values[indexPath.row]] : @"Unavailable";
    } else {
      cell.detailTextLabel.text = self.hasVMStatistics ? [self formattedBytes:values[indexPath.row]] : @"Unavailable";
    }
    cell.imageView.image = [UIImage systemImageNamed:(indexPath.row == 6 ? @"lock.fill" : @"memorychip")];
    cell.imageView.tintColor = indexPath.row == 6 ? [UIColor tertiaryLabelColor] : [UIColor systemBlueColor];
  } else {
    NSDictionary *process = self.processes[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  ·  PID %@", process[@"name"], process[@"pid"]];
    BOOL available = [process[@"available"] boolValue];
    if (available) {
      cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ resident · %@ virtual",
        [self formattedBytes:[process[@"resident"] unsignedLongLongValue]],
        [self formattedBytes:[process[@"virtual"] unsignedLongLongValue]]];
    } else {
      cell.detailTextLabel.text = @"Memory details unavailable";
    }
    cell.imageView.image = [UIImage systemImageNamed:@"app"];
    cell.imageView.tintColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section != 1) return;

  NSDictionary *process = self.processes[indexPath.row];
  pid_t pid = [process[@"pid"] intValue];
  NSString *name = process[@"name"] ?: [NSString stringWithFormat:@"PID %d", pid];
  UIAlertController *menu = [UIAlertController
      alertControllerWithTitle:name
                       message:[NSString stringWithFormat:@"PID %d\\nResident: %@",
                         pid, [self formattedBytes:[process[@"resident"] unsignedLongLongValue]]]
                preferredStyle:UIAlertControllerStyleActionSheet];

  [menu addAction:[UIAlertAction actionWithTitle:@"Attach in Memory Debug"
      style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    BOOL attached = [[VMMemoryEngine shared] attachToPid:pid];
    if (attached) {
      self.tabBarController.selectedIndex = 1;
    } else {
      UIAlertController *error = [UIAlertController
          alertControllerWithTitle:@"Attach unavailable"
                           message:@"task_for_pid was denied for this process in the current signing or privilege environment. The process inventory remains read-only."
                    preferredStyle:UIAlertControllerStyleAlert];
      [error addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
      [self presentViewController:error animated:YES completion:nil];
    }
  }]];
  [menu addAction:[UIAlertAction actionWithTitle:@"Copy PID"
      style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%d", pid];
  }]];
  [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
    menu.popoverPresentationController.sourceView = self.tableView;
    menu.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
  }
  [self presentViewController:menu animated:YES completion:nil];
}

@end
