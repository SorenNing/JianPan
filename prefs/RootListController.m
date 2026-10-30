#import "RootListController.h"

#define JP_DOMAIN @"com.ning.jianpan"
#define JP_CHANGED @"com.ning.jianpan.changed"
#define JP_THEMES_DIR @"/var/jb/Library/JianPan/Themes"

@implementation JianPanRootListController

-(instancetype)init {
    if ((self = [super init])) self.title = @"键盘";
    return self;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"键盘";
    [[NSFileManager defaultManager] createDirectoryAtPath:JP_THEMES_DIR
                              withIntermediateDirectories:YES attributes:nil error:NULL];
}

-(id)preferencesPlistName {
    return @"Root";
}

-(id)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
    }
    return _specifiers;
}

-(id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: JP_DOMAIN;
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)domain);
    if (value) return (__bridge_transfer id)value;
    return [specifier propertyForKey:@"default"];
}

-(void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return;
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: JP_DOMAIN;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)JP_CHANGED, NULL, NULL, true);
}

#pragma mark - 主题操作

// 多根扫描主题目录（与 tweak 一致）
+ (NSArray *)jpAllThemeDirs {
    NSArray *roots = @[JP_THEMES_DIR,
                       @"/var/mobile/Library/JianPan/Themes",
                       @"/Library/JianPan/Themes"];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in roots) {
        for (NSString *item in [fm contentsOfDirectoryAtPath:root error:NULL]) {
            if ([item hasPrefix:@"."]) continue;
            NSString *full = [root stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir && ![seen containsObject:item]) {
                [seen addObject:item];
                [out addObject:full];
            }
        }
    }
    return out;
}

-(void)jpAlert:(NSString *)title message:(NSString *)msg copyPath:(NSString *)path {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    if (path.length) {
        [alert addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            UIPasteboard.generalPasteboard.string = path;
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter = self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:alert animated:YES completion:nil];
}

-(void)pickTheme:(PSSpecifier *)specifier {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择主题"
                                                                   message:@"未选择时自动使用第一个主题"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"自动（第一个主题）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        CFPreferencesSetAppValue(CFSTR("ActiveTheme"), (__bridge CFPropertyListRef)@"",
                                 (__bridge CFStringRef)JP_DOMAIN);
        CFPreferencesAppSynchronize((__bridge CFStringRef)JP_DOMAIN);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)JP_CHANGED, NULL, NULL, true);
        [self reloadSpecifiers];
    }]];

    for (NSString *dir in [JianPanRootListController jpAllThemeDirs]) {
        NSString *name = dir.lastPathComponent;
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            CFPreferencesSetAppValue(CFSTR("ActiveTheme"), (__bridge CFPropertyListRef)name,
                                     (__bridge CFStringRef)JP_DOMAIN);
            CFPreferencesAppSynchronize((__bridge CFStringRef)JP_DOMAIN);
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 (__bridge CFStringRef)JP_CHANGED, NULL, NULL, true);
            [self reloadSpecifiers];
        }]];
    }

    if (![JianPanRootListController jpAllThemeDirs].count) {
        sheet.message = @"还没有主题。点「打开主题目录」建一个文件夹放入 PNG。";
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2,
                                                                     self.view.bounds.size.height/2, 1, 1);
    }
    UIViewController *presenter = self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

-(void)openThemesFolder:(PSSpecifier *)specifier {
    [[NSFileManager defaultManager] createDirectoryAtPath:JP_THEMES_DIR
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSArray<NSString *> *candidates = @[
        [NSString stringWithFormat:@"filza://view%@", JP_THEMES_DIR],
        [NSString stringWithFormat:@"shareddocuments://%@", JP_THEMES_DIR],
    ];
    [self tryOpenURLs:candidates index:0];
}

-(void)tryOpenURLs:(NSArray<NSString *> *)candidates index:(NSUInteger)i {
    if (i >= candidates.count) {
        [self jpAlert:@"主题目录" message:[NSString stringWithFormat:@"没能打开文件管理器，请用 Filza 进入：\n%@", JP_THEMES_DIR] copyPath:JP_THEMES_DIR];
        return;
    }
    NSURL *url = [NSURL URLWithString:candidates[i]];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL ok) {
        if (!ok) [self tryOpenURLs:candidates index:i+1];
    }];
}

-(void)listThemes:(PSSpecifier *)specifier {
    NSMutableString *msg = [NSMutableString stringWithString:@"已发现的主题：\n\n"];
    NSArray *dirs = [JianPanRootListController jpAllThemeDirs];
    for (NSString *dir in dirs) {
        NSUInteger n = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL].count;
        [msg appendFormat:@"• %@（%lu 个文件）\n", dir.lastPathComponent, (unsigned long)n];
    }
    if (!dirs.count) [msg appendString:@"（还没有主题）"];
    NSString *current = nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)JP_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("ActiveTheme"), (__bridge CFStringRef)JP_DOMAIN);
    current = v ? [(id)CFBridgingRelease(v) copy] : nil;
    [msg appendFormat:@"\n当前选择：%@", current.length ? current : @"自动"];
    [self jpAlert:@"主题列表" message:msg copyPath:JP_THEMES_DIR];
}

@end
