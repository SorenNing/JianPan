#import "RootListController.h"

@interface JianPanRootListController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

#define JP_DOMAIN @"com.ning.jianpan"
static NSString * const kJPDomain = @"com.ning.jianpan";
#define JP_CHANGED @"com.ning.jianpan.changed"
#define JP_THEMES_DIR @"/var/mobile/Library/JianPan/Themes"

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
                       @"/var/jb/Library/JianPan/Themes",
                       @"/var/jb/var/mobile/Library/JianPan/Themes",
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

#pragma mark - 模式选择器

// 通用：弹 ActionSheet 选一个 NSString 值写入偏好
-(void)jpChooseFrom:(NSArray<NSString *> *)names
              title:(NSString *)title
             writeKey:(NSString *)key
             allowEmpty:(NSString *)emptyLabel
              emptyValue:(NSString *)emptyValue
             postNotify:(BOOL)notify {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (emptyLabel) {
        [sheet addAction:[UIAlertAction actionWithTitle:emptyLabel style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)emptyValue, (__bridge CFStringRef)JP_DOMAIN);
            CFPreferencesAppSynchronize((__bridge CFStringRef)JP_DOMAIN);
            if (notify) [self jpNotify];
            [self reloadSpecifiers];
        }]];
    }
    for (NSString *n in names) {
        [sheet addAction:[UIAlertAction actionWithTitle:n style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)n, (__bridge CFStringRef)JP_DOMAIN);
            CFPreferencesAppSynchronize((__bridge CFStringRef)JP_DOMAIN);
            if (notify) [self jpNotify];
            [self reloadSpecifiers];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
    }
    UIViewController *presenter = self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

-(void)jpNotify {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)JP_CHANGED, NULL, NULL, true);
}

-(NSString *)jpPrefsString:(NSString *)key {
    CFPreferencesAppSynchronize((__bridge CFStringRef)JP_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)JP_DOMAIN);
    return v ? [(id)CFBridgingRelease(v) copy] : nil;
}

// HTML 主题 = Themes/<名>/HTML/index.html 存在的目录
-(NSArray<NSString *> *)jpHTMLThemeNames {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *roots = @[JP_THEMES_DIR,
                       @"/var/jb/Library/JianPan/Themes",
                       @"/Library/JianPan/Themes"];
    NSMutableSet *seen = [NSMutableSet set];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in roots) {
        for (NSString *item in [fm contentsOfDirectoryAtPath:root error:NULL]) {
            if ([item hasPrefix:@"."]) continue;
            NSString *idx = [NSString stringWithFormat:@"%@/%@/HTML/index.html", root, item];
            if ([fm fileExistsAtPath:idx] && ![seen containsObject:item]) {
                [seen addObject:item]; [out addObject:item];
            }
        }
    }
    return out;
}

-(void)pickHTMLTheme:(PSSpecifier *)specifier {
    [self jpChooseFrom:[self jpHTMLThemeNames] title:@"选择 HTML 主题"
              writeKey:@"ActiveHTMLTheme" allowEmpty:@"无" emptyValue:@""
            postNotify:YES];
}

// 图片模式：从照片库选图（UIImagePicker，Settings 进程可用）
-(void)pickUserImage:(PSSpecifier *)specifier {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.image"];
    picker.delegate = self;
    UIViewController *presenter = self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:picker animated:YES completion:nil];
}

-(void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    if (!img) return;
    NSData *png = UIImagePNGRepresentation(img);
    if (![png writeToFile:@"/var/mobile/Library/JianPan/userbg.png" atomically:YES]) {
        [self jpAlert:@"保存失败" message:@"无法写入 /var/mobile/Library/JianPan/userbg.png" copyPath:nil];
        return;
    }
    [self jpAlert:@"已保存" message:@"背景图已写入，重新弹出键盘生效。" copyPath:nil];
    [self jpNotify];
}

-(void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

// 图片模式当前图预览提示

#pragma mark - 预设

-(void)savePreset:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存预设"
                                                                   message:@"输入预设名称"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:nil];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/JianPan/Presets"
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSString *k in @[@"CustomBackgroundColourEnabled",@"CustomBackgroundColour",
                              @"CustomTextColourEnabled",@"CustomTextColour",
                              @"CustomKeyPopUpGradientEnabled",@"CustomKeyCapGradientStart",@"CustomKeyCapGradientEnd",
                              @"CustomPredictionTextColourEnabled",@"CustomPredictionTextColour",
                              @"CustomPredictionBarBackgroundColourEnabled",@"CustomPredictionBarBackgroundColour",
                              @"CustomKeyTintEnabled",@"CustomKeyTintColour",
                              @"CustomEmojiSearchBackgroundEnabled",@"CustomEmojiSearchBackground"]) {
            id v = [self jpPrefsObject:k];
            if (v) d[k] = v;
        }
        [d writeToFile:[NSString stringWithFormat:@"/var/mobile/Library/JianPan/Presets/%@.plist", name] atomically:YES];
        CFPreferencesSetAppValue(CFSTR("CurrentPreset"), (__bridge CFPropertyListRef)name, (__bridge CFStringRef)JP_DOMAIN);
        CFPreferencesAppSynchronize((__bridge CFStringRef)JP_DOMAIN);
        [self jpNotify];
        [self reloadSpecifiers];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter = self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:alert animated:YES completion:nil];
}

-(id)jpPrefsObject:(NSString *)key {
    CFPreferencesAppSynchronize((__bridge CFStringRef)JP_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)JP_DOMAIN);
    return v ? [(__bridge id)v copy] : nil;
}

-(NSArray<NSString *> *)jpPresetNames {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:@"/var/mobile/Library/JianPan/Presets"
  withIntermediateDirectories:YES attributes:nil error:NULL];
    NSArray *items = [fm contentsOfDirectoryAtPath:@"/var/mobile/Library/JianPan/Presets" error:NULL];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in items) {
        if ([f.pathExtension isEqualToString:@"plist"]) [out addObject:[f stringByDeletingPathExtension]];
    }
    return out;
}

-(void)loadPreset:(PSSpecifier *)specifier {
    NSArray *names = [self jpPresetNames];
    if (!names.count) { [self jpAlert:@"无预设" message:@"先保存一个预设" copyPath:nil]; return; }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"加载预设" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *n in names) {
        [sheet addAction:[UIAlertAction actionWithTitle:n style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/JianPan/Presets/%@.plist", n];
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
            for (NSString *k in d) CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)d[k], (__bridge CFStringRef)JP_DOMAIN);
            CFPreferencesSetAppValue(CFSTR("CurrentPreset"), (__bridge CFPropertyListRef)n, (__bridge CFStringRef)JP_DOMAIN);
            CFPreferencesAppSynchronize((__bridge CFStringRef)JP_DOMAIN);
            [self jpNotify];
            [self reloadSpecifiers];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
    }
    UIViewController *presenter = self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

-(void)deletePreset:(PSSpecifier *)specifier {
    NSArray *names = [self jpPresetNames];
    if (!names.count) { [self jpAlert:@"无预设" message:@"没有可删除的预设" copyPath:nil]; return; }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"删除预设" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *n in names) {
        [sheet addAction:[UIAlertAction actionWithTitle:n style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            [[NSFileManager defaultManager] removeItemAtPath:
                [NSString stringWithFormat:@"/var/mobile/Library/JianPan/Presets/%@.plist", n] error:NULL];
            [self reloadSpecifiers];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
    }
    UIViewController *presenter = self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

-(void)pickLightPreset:(PSSpecifier *)specifier {
    [self jpChooseFrom:[self jpPresetNames] title:@"浅色模式预设"
              writeKey:@"LaetusPresetsLightMode" allowEmpty:@"无" emptyValue:@"" postNotify:NO];
}

-(void)pickDarkPreset:(PSSpecifier *)specifier {
    [self jpChooseFrom:[self jpPresetNames] title:@"深色模式预设"
              writeKey:@"LaetusPresetsDarkMode" allowEmpty:@"无" emptyValue:@"" postNotify:NO];
}

#pragma mark - 工具

-(void)respring:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"注销？"
                                                                   message:@"SpringBoard 将重启以完全刷新键盘进程。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        // 友好方式：发 Darwin 通知给 frontboard；失败则 killall
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.ning.jianpan.respring"), NULL, NULL, true);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self jpRespringNow];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter = self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:alert animated:YES completion:nil];
}

-(void)jpRespringNow {
    pid_t pid = fork();
    if (pid == 0) {
        execl("/usr/bin/killall", "killall", "-9", "SpringBoard", (char *)NULL);
        _exit(0);
    }
}

-(void)resetAllSettings:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复默认？"
                                                                   message:@"将删除全部键盘偏好设置。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        CFPreferencesSetValue(CFSTR("Enabled"), kCFBooleanTrue, (__bridge CFStringRef)kJPDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        for (NSString *k in @[@"BackgroundMode",@"backgroundImageContentModeInt",
                              @"CustomBackgroundColourEnabled",@"CustomBackgroundColour",
                              @"CustomTextColourEnabled",@"CustomTextColour",
                              @"CustomKeyPopUpGradientEnabled",@"CustomKeyCapGradientStart",@"CustomKeyCapGradientEnd",
                              @"CustomPredictionTextColourEnabled",@"CustomPredictionTextColour",
                              @"CustomPredictionBarBackgroundColourEnabled",@"CustomPredictionBarBackgroundColour",
                              @"CustomKeyTintEnabled",@"CustomKeyTintColour",
                              @"CustomEmojiSearchBackgroundEnabled",@"CustomEmojiSearchBackground",
                              @"HideKeyShadows",@"HideKeyCaps",@"HideKeyPopups",@"HideLanguageIndicator",
                              @"HideEmojiSlider",@"HideEmojiSliderOverlay",@"HideKeyPlane",
                              @"FullyHideBackground",@"OverrideKeyboardMode",@"MessagesUsePredictionColour",
                              @"ActiveTheme",@"ActiveHTMLTheme",@"CurrentPreset",
                              @"LaetusPresetsLightMode",@"LaetusPresetsDarkMode",@"SwitchPresetsWithDarkMode"]) {
            CFPreferencesSetValue((__bridge CFStringRef)k, NULL, (__bridge CFStringRef)kJPDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        }
        CFPreferencesAppSynchronize((__bridge CFStringRef)kJPDomain);
        [self jpNotify];
        [self reloadSpecifiers];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
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
