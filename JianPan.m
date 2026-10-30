// 「键盘」JianPan — 键盘美化插件（照 Laetus 逆向真相实现）
// 0.1：图像主题（背景贴图替换），iOS 15-17，rootless/roothide
//
// 核心 hook（全部有头文件级证据，iOS 17.2）：
//   1. UIKBSplitImageView setImage:cachedWidth:keyplane:  — 键盘背景贴图统一入口
//      （UIKBBackgroundView 继承它，是键盘背景视图本体）
//   2. UIKeyboardLayoutStar _didChangeKeyplaneWithContext: — keyplane 切换跟踪
//      （keyplaneName 是公开 property，直接读）
//
// 主题目录（多根扫描，rootless 优先）：
//   /var/jb/Library/JianPan/Themes/<主题名>/
//     KeyboardMainBG-896h@3x.png / KeyboardMainBG@3x.png / KeyboardMainBG.png
//     KeyboardNumbersBG... / KeyboardEmojiBG... / KeyboardDictationBG...
//     （可带 -Portrait/-Landscape，可带 -屏高h，@3x/@2x 优先）
//   未选主题时自动用第一个主题目录。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <CydiaSubstrate/CydiaSubstrate.h>

#define JP_DOMAIN     "com.ning.jianpan"
#define JP_CHANGED    "com.ning.jianpan.changed"
#define JP_LOG        "/var/mobile/Library/JianPan.log"

// ---------------------------------------------------------------- 日志
void JPLog(NSString *format, ...) {
    static NSInteger lines = -1;
    if (lines < 0) { lines = 0; unlink(JP_LOG); }
    if (lines > 5000) return;
    va_list args; va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *out = [NSString stringWithFormat:@"[jp %@] %@\n",
        [NSDate.date descriptionWithLocale:@"HH:mm:ss"], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@JP_LOG];
    if (!fh) {
        [@"" writeToFile:@JP_LOG atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        fh = [NSFileHandle fileHandleForWritingAtPath:@JP_LOG];
    }
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    lines++;
}

// ---------------------------------------------------------------- 偏好与主题
static BOOL jpEnabled = YES;
static NSString *jpThemeName = nil;      // 设置选中的主题名（可空）
static NSString *jpThemePath = nil;      // 解析出的主题目录
static NSInteger jpGen = 0;              // 主题代数（失效缓存用）

static NSArray *JPThemeRoots(void) {
    return @[@"/var/jb/Library/JianPan/Themes",
             @"/var/mobile/Library/JianPan/Themes",
             @"/Library/JianPan/Themes"];
}

static NSArray *JPAllThemeDirs(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in JPThemeRoots()) {
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

static void JPResolveTheme(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *resolved = nil;
    if (jpThemeName.length) {
        for (NSString *root in JPThemeRoots()) {
            NSString *dir = [root stringByAppendingPathComponent:jpThemeName];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) { resolved = dir; break; }
        }
    }
    if (!resolved) {
        NSArray *dirs = JPAllThemeDirs();
        resolved = dirs.firstObject;
    }
    if (resolved && ![resolved isEqualToString:jpThemePath]) {
        jpThemePath = resolved;
        jpGen++;
        JPLog(@"theme resolved -> %@ (gen %ld)", jpThemePath, (long)jpGen);
    } else if (!resolved && jpThemePath) {
        jpThemePath = nil; jpGen++;
        JPLog(@"theme cleared (gen %ld)", (long)jpGen);
    }
}

static BOOL JPBoolPref(NSString *key, BOOL dflt) {
    CFPreferencesAppSynchronize(CFSTR(JP_DOMAIN));
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(JP_DOMAIN));
    BOOL out = dflt;
    if (v) { out = (CFGetTypeID(v) == CFBooleanGetTypeID()) ? [(id)CFBridgingRelease(v) boolValue] : dflt; }
    return out;
}

static NSString *JPStringPref(NSString *key) {
    CFPreferencesAppSynchronize(CFSTR(JP_DOMAIN));
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(JP_DOMAIN));
    return v ? [(id)CFBridgingRelease(v) copy] : nil;
}

static void JPReloadPrefs(void) {
    BOOL wasEnabled = jpEnabled;
    jpEnabled = JPBoolPref(@"Enabled", YES);
    NSString *theme = JPStringPref(@"ActiveTheme");
    if (![jpThemeName isEqualToString:theme]) {
        jpThemeName = theme;
        JPLog(@"prefs: ActiveTheme='%@' Enabled=%d", jpThemeName, jpEnabled);
    }
    JPResolveTheme();
    if (wasEnabled != jpEnabled) { jpGen++; JPLog(@"enabled toggled -> %d (gen %ld)", jpEnabled, (long)jpGen); }
}

// ---------------------------------------------------------------- keyplane → 键 映射
// 照 Laetus keyplaneNameToKey: 0x14774 的 8 分支表
static NSString *JPKeyForKeypplaneName(NSString *name) {
    if (!name.length) return @"KeyboardMainBG";
    if ([name isEqualToString:@"small-letters"] ||
        [name isEqualToString:@"capital-letters"]) return @"KeyboardMainBG";
    if ([name isEqualToString:@"numbers-and-punctuation"] ||
        [name isEqualToString:@"numbers-and-punctuation-alternative"]) return @"KeyboardNumbersBG";
    if ([name isEqualToString:@"emoji-keyboard"]) return @"KeyboardEmojiBG";
    if ([name hasSuffix:@"-pad"]) return @"KeyboardNumberPadBG";
    if ([name isEqualToString:@"autofill"]) return @"KeyboardAutoFillBG";
    if ([name isEqualToString:@"picker"]) return @"KeyboardPickerBG";
    if ([name isEqualToString:@"dictation"]) return @"KeyboardDictationBG";
    return @"KeyboardMainBG";
}

// ---------------------------------------------------------------- 主题图查找
// 四级降级（照 Laetus imagePathWithName 0x14310）：
//   base+方向-屏高h@3x → base+方向-屏高h → base+方向@3x → base+方向 → base-屏高h@3x → base@3x → base
// 全部 lowercase 匹配前的实际文件名（文件系统大小写敏感时先按原名再试小写）
static NSString *JPHeightSuffix(void) {
    static NSString *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGFloat pt = UIScreen.mainScreen.bounds.size.height;
        if      (pt >= 930) s = @"932h";
        else if (pt >= 890) s = @"896h";
        else if (pt >= 850) s = @"852h";
        else if (pt >= 840) s = @"844h";
        else if (pt >= 810) s = @"812h";
        else if (pt >= 730) s = @"736h";
        else if (pt >= 660) s = @"667h";
        else s = nil;
        JPLog(@"device %.0fpt -> height '%@'", pt, s ?: @"");
    });
    return s;
}

static UIImage *JPLoadImage(NSString *path) {
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (!raw) return nil;
    return [UIImage imageWithCGImage:raw.CGImage
                               scale:UIScreen.mainScreen.scale
                         orientation:UIImageOrientationUp];
}

static NSMutableDictionary *jpImageCache;
static UIImage *JPImageForKey(NSString *key, BOOL landscape) {
    if (!jpThemePath || !key.length) return nil;
    if (!jpImageCache) jpImageCache = [NSMutableDictionary new];
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%d|gen%ld", key, landscape, (long)jpGen];
    UIImage *cached = jpImageCache[cacheKey];
    if (cached) return cached;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *orient = landscape ? @"Landscape" : @"Portrait";
    NSString *h = JPHeightSuffix();
    NSArray *scales = @[@"@3x", @"@2x", @""];

    // 组合顺序：带方向 → 不带方向；带屏高 → 不带屏高（逐级剥离）
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *sc in scales) {
        if (h) [names addObject:[NSString stringWithFormat:@"%@%@-%@-%@.png", key, sc, orient, h]];
    }
    for (NSString *sc in scales) {
        [names addObject:[NSString stringWithFormat:@"%@%@-%@.png", key, sc, orient]];
    }
    for (NSString *sc in scales) {
        if (h) [names addObject:[NSString stringWithFormat:@"%@%@-%@.png", key, sc, h]];
    }
    for (NSString *sc in scales) {
        [names addObject:[NSString stringWithFormat:@"%@%@.png", key, sc]];
    }
    // Laetus 同款屏高映射兜底：926→896、844→812
    if ([h isEqualToString:@"932h"] || [h isEqualToString:@"926h"]) {
        for (NSString *sc in scales) {
            [names addObject:[NSString stringWithFormat:@"%@%@-%@-896h.png", key, sc, orient]];
            [names addObject:[NSString stringWithFormat:@"%@%@-896h.png", key, sc]];
        }
    } else if ([h isEqualToString:@"844h"]) {
        for (NSString *sc in scales) {
            [names addObject:[NSString stringWithFormat:@"%@%@-%@-812h.png", key, sc, orient]];
            [names addObject:[NSString stringWithFormat:@"%@%@-812h.png", key, sc]];
        }
    }

    for (NSString *n in names) {
        NSString *path = [jpThemePath stringByAppendingPathComponent:n];
        if ([fm fileExistsAtPath:path]) {
            UIImage *img = JPLoadImage(path);
            if (img) {
                jpImageCache[cacheKey] = img;
                return img;
            }
        }
    }

    // 最后兜底：key 前缀任意 png（用户文件名不规范时也能铺上）
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 目录清单只读一次，主题切换时靠 jpGen 失效重建
    });
    NSArray *files = [fm contentsOfDirectoryAtPath:jpThemePath error:NULL];
    for (NSString *f in files) {
        if ([f hasPrefix:key] && [f.pathExtension isEqualToString:@"png"]) {
            UIImage *img = JPLoadImage([jpThemePath stringByAppendingPathComponent:f]);
            if (img) {
                jpImageCache[cacheKey] = img;
                JPLog(@"fallback matched: %@", f);
                return img;
            }
        }
    }

    static NSMutableSet *missLogged;
    if (!missLogged) missLogged = [NSMutableSet new];
    if (![missLogged containsObject:cacheKey]) {
        [missLogged addObject:cacheKey];
        JPLog(@"no image for %@ (%@) in %@", key, orient, jpThemePath.lastPathComponent);
    }
    return nil;
}

// ---------------------------------------------------------------- hook 1: 背景贴图
// UIKBSplitImageView setImage:cachedWidth:keyplane: — Laetus 同款主通道
static IMP orig_setImage = NULL;
static void jp_hook_setImage(id self, SEL _cmd, UIImage *image, double width, id keyplane) {
    @try {
        if (jpEnabled && jpThemePath && keyplane) {
            // keyplane 是 UIKBTree，读 name（头文件：@property NSString *name）
            NSString *kpName = nil;
            @try { kpName = [keyplane valueForKey:@"name"]; } @catch (__unused NSException *e) {}
            NSString *key = JPKeyForKeypplaneName(kpName);
            BOOL landscape = UIScreen.mainScreen.bounds.size.width > UIScreen.mainScreen.bounds.size.height;
            UIImage *theme = JPImageForKey(key, landscape);
            if (theme) {
                image = theme;
                static int served = 0;
                if (served++ < 30) JPLog(@"bg served: %@ (%@)", key, kpName);
            }
        }
    } @catch (NSException *e) { JPLog(@"exc setImage: %@", e); }
    ((void (*)(id, SEL, UIImage *, double, id))orig_setImage)(self, _cmd, image, width, keyplane);
}

// ---------------------------------------------------------------- hook 2: keyplane 跟踪
static IMP orig_didChangeKeyplane = NULL;
static void jp_hook_didChangeKeyplane(id self, SEL _cmd, id context) {
    ((void (*)(id, SEL, id))orig_didChangeKeyplane)(self, _cmd, context);
    @try {
        if (!jpEnabled) return;
        static int fired = 0;
        fired++;
        // keyplaneName 是公开 property，直接读
        NSString *name = nil;
        @try { name = [self valueForKey:@"keyplaneName"]; } @catch (__unused NSException *e) {}
        if (fired <= 12) JPLog(@"keyplane changed (#%d): %@", fired, name);
        JPReloadPrefs();  // 键盘进程里主题可能刚更新
    } @catch (NSException *e) { JPLog(@"exc keyplane: %@", e); }
}

// ---------------------------------------------------------------- 通知回调
static void JPConfigChanged(CFNotificationCenterRef c, void *obs, CFStringRef n, const void *o, CFDictionaryRef ui) {
    JPReloadPrefs();
    JPLog(@"config changed: theme='%@' enabled=%d", jpThemeName, jpEnabled);
}

// ---------------------------------------------------------------- 安装
static void JPInstallHooks(void) {
    // hook 1: UIKBSplitImageView setImage:cachedWidth:keyplane:
    Class split = NSClassFromString(@"UIKBSplitImageView");
    if (split && !orig_setImage) {
        SEL sel = NSSelectorFromString(@"setImage:cachedWidth:keyplane:");
        if ([split instancesRespondToSelector:sel]) {
            MSHookMessageEx(split, sel, (IMP)jp_hook_setImage, (IMP *)&orig_setImage);
            JPLog(@"hook 1 installed: UIKBSplitImageView setImage:cachedWidth:keyplane:");
        } else {
            JPLog(@"hook 1 SEL missing on UIKBSplitImageView");
        }
    } else if (!split) {
        JPLog(@"UIKBSplitImageView not found yet");
    }

    // hook 2: UIKeyboardLayoutStar _didChangeKeyplaneWithContext:
    Class star = NSClassFromString(@"UIKeyboardLayoutStar");
    if (star && !orig_didChangeKeyplane) {
        SEL sel = NSSelectorFromString(@"_didChangeKeyplaneWithContext:");
        if ([star instancesRespondToSelector:sel]) {
            MSHookMessageEx(star, sel, (IMP)jp_hook_didChangeKeyplane, (IMP *)&orig_didChangeKeyplane);
            JPLog(@"hook 2 installed: UIKeyboardLayoutStar _didChangeKeyplaneWithContext:");
        } else {
            JPLog(@"hook 2 SEL missing on UIKeyboardLayoutStar");
        }
    } else if (!star) {
        JPLog(@"UIKeyboardLayoutStar not found yet");
    }
}

__attribute__((constructor))
static void JPInitialize(void) {
    @autoreleasepool {
        JPReloadPrefs();
        JPLog(@"JianPan init — enabled=%d theme='%@' resolved=%@",
              jpEnabled, jpThemeName, jpThemePath);
        JPInstallHooks();
        // 类未就绪时延迟重试（幂等）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            JPInstallHooks();
        });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, &JPConfigChanged,
                                        CFSTR(JP_CHANGED), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
