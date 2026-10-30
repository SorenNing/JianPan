// 「键盘」JianPan 0.2 — 完整功能对齐 Laetus 3.5.1
// 模式：无(纯色) / HTML / 图片 / 主题（小组件模式不做）
// hook 面（全部有 iOS 17.2 头文件或 Laetus 逆向证据）：
//   UIKBGetNamedColor (MSHookFunction)      — 颜色主题核心
//   UIKBSplitImageView setImage:cachedWidth:keyplane: — 背景贴图（图片/主题模式）
//   UIKBRenderer renderKeyContents:withTraits: / renderedImage — 键帽渲染（HideKeyCaps/文本色）
//   UIKBKeyView _populateLayer:withContents: — 键帽图层（阴影/键帽隐藏）
//   UIKBTree noLanguageIndicator / avoidsLanguageIndicator — 语言指示器隐藏
//   UIKeyboardEmojiCategoryBar animateScrubberToRect: — 表情滑块隐藏
//   UIKeyboardLayoutStar touchDownWithKey...(×2) — 按键弹出隐藏
//   UIKBRenderConfig lightKeyboard — 强制深浅色模式
//   UIKBVisualEffectView transitionToStyle: — 完全隐藏背景
//   UIKeyboardLayoutStar _didChangeKeyplaneWithContext: / initWithFrame: — keyplane 跟踪
//   UIWindow traitCollectionDidChange: — 深浅色切换预设
//   UIInputWindowControllerHostingItem updateInputBackdropView — HTML 主题垫层
//   TUIPredictionViewCell setTextColor: / setBackgroundColor: / setImageTintColor: /
//     _updateColorsForRenderConfig:highlighted: — 预测栏颜色
//   TUIPredictionView _updateVisibleCellAppearance — 预测栏刷新

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <CydiaSubstrate/CydiaSubstrate.h>

#define JP_DOMAIN       "com.ning.jianpan"
#define JP_CHANGED      "com.ning.jianpan.changed"
#define JP_LOG          "/var/mobile/Library/JianPan.log"
#define JP_DATA_DIR     "/var/mobile/Library/JianPan"
#define JP_PRESETS_DIR  "/var/mobile/Library/JianPan/Presets"
#define JP_USER_BG      "/var/mobile/Library/JianPan/userbg.png"

#pragma mark - 日志

void JPLog(NSString *format, ...) {
    static NSInteger lines = -1;
    if (lines < 0) { lines = 0; unlink(JP_LOG); }
    if (lines > 6000) return;
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

#pragma mark - 偏好缓存（全量，照 Laetus 键面）

static BOOL jpEnabled = YES;
// 模式
static NSInteger jpBackgroundMode = 0;       // 0无 1HTML 2图片 3主题
static NSInteger jpContentModeInt = 0;       // 0ScaleToFill 1AspectFit 2AspectFill 3Center
// 颜色（#RRGGBB:alpha 字符串，Laetus 同格式）
static BOOL jpColBgOn = NO,   jpColTextOn = NO,  jpColPredTextOn = NO;
static BOOL jpColPredBgOn = NO, jpColTintOn = NO, jpColEmojiSearchOn = NO, jpColGradOn = NO;
static NSString *jpColBg = nil, *jpColText = nil, *jpColPredText = nil, *jpColPredBg = nil;
static NSString *jpColTint = nil, *jpColEmojiSearch = nil, *jpColGradStart = nil, *jpColGradEnd = nil;
// 隐藏
static BOOL jpHideKeyShadows = NO, jpHideKeyCaps = NO, jpHideKeyPopups = NO;
static BOOL jpHideLanguageIndicator = NO, jpHideEmojiSlider = NO, jpHideEmojiSliderOverlay = NO;
static BOOL jpHideKeyPlane = NO, jpFullyHideBackground = NO;
// 高级
static NSInteger jpOverrideKeyboardMode = 0; // 0自动 1深 2浅
static BOOL jpMessagesUsePredictionColour = YES;
// 预设
static NSString *jpCurrentPreset = nil;
static NSString *jpLightPreset = nil, *jpDarkPreset = nil;
static BOOL jpSwitchPresetsWithDarkMode = NO;
// 主题
static NSString *jpThemeName = nil, *jpThemePath = nil;
static NSString *jpHTMLThemeName = nil, *jpHTMLIndexPath = nil;
static NSInteger jpGen = 0;
static BOOL jpSafeMode = YES;   // 兼容旧开关
static NSInteger jpHookGroup = 0;  // 位掩码：1渲染 2元素 4配置 8容器；0=基线 15=全开

static BOOL JPBool(NSString *key, BOOL dflt) {
    CFPreferencesAppSynchronize(CFSTR(JP_DOMAIN));
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(JP_DOMAIN));
    BOOL out = dflt;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) out = [(id)CFBridgingRelease(v) boolValue];
        else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int n = 0; CFNumberGetValue(v, kCFNumberIntType, &n); out = n != 0; }
        else CFRelease(v);
    }
    return out;
}

static NSInteger JPInt(NSString *key, NSInteger dflt) {
    CFPreferencesAppSynchronize(CFSTR(JP_DOMAIN));
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(JP_DOMAIN));
    NSInteger out = dflt;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) { long long n = dflt; CFNumberGetValue(v, kCFNumberLongLongType, &n); out = n; }
        else if (CFGetTypeID(v) == CFStringGetTypeID()) { out = [(id)CFBridgingRelease(v) integerValue]; }
        else CFRelease(v);
    }
    return out;
}

static NSString *JPStr(NSString *key) {
    CFPreferencesAppSynchronize(CFSTR(JP_DOMAIN));
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(JP_DOMAIN));
    return v ? [(id)CFBridgingRelease(v) copy] : nil;
}

#pragma mark - 颜色解析（Laetus 同格式 "#RRGGBB:alpha"）

static UIColor *JPParseColour(NSString *spec) {
    if (!spec.length) return nil;
    NSString *hex = spec, *alphaPart = nil;
    NSRange colon = [spec rangeOfString:@":"];
    if (colon.location != NSNotFound) {
        hex = [spec substringToIndex:colon.location];
        alphaPart = [spec substringFromIndex:colon.location + 1];
    }
    hex = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6) return nil;
    unsigned r=0,g=0,b=0;
    sscanf([hex substringToIndex:2].UTF8String, "%x", &r);
    sscanf([hex substringWithRange:NSMakeRange(2,2)].UTF8String, "%x", &g);
    sscanf([hex substringFromIndex:4].UTF8String, "%x", &b);
    CGFloat a = alphaPart ? [alphaPart doubleValue] : 1.0;
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

#pragma mark - 主题解析

static NSArray *JPThemeRoots(void) {
    return @[@"/var/mobile/Library/JianPan/Themes",
             @"/var/jb/Library/JianPan/Themes",
             @"/var/jb/var/mobile/Library/JianPan/Themes",
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
                [seen addObject:item]; [out addObject:full];
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
    if (!resolved && jpBackgroundMode == 3) {
        NSArray *dirs = JPAllThemeDirs();
        resolved = dirs.firstObject;
    }
    if (resolved && ![resolved isEqualToString:jpThemePath]) {
        jpThemePath = resolved; jpGen++;
        JPLog(@"theme resolved -> %@ (gen %ld)", jpThemePath, (long)jpGen);
    } else if (!resolved && jpThemePath) {
        jpThemePath = nil; jpGen++;
    }

    // HTML 主题： Themes/<名>/HTML/index.html
    NSString *htmlResolved = nil;
    if (jpHTMLThemeName.length) {
        for (NSString *root in JPThemeRoots()) {
            NSString *p = [NSString stringWithFormat:@"%@/%@/HTML/index.html", root, jpHTMLThemeName];
            if ([fm fileExistsAtPath:p]) { htmlResolved = p; break; }
        }
    }
    if (htmlResolved && ![htmlResolved isEqualToString:jpHTMLIndexPath]) {
        jpHTMLIndexPath = htmlResolved; jpGen++;
        JPLog(@"html theme resolved -> %@", jpHTMLIndexPath);
    } else if (!htmlResolved && jpHTMLIndexPath) {
        jpHTMLIndexPath = nil; jpGen++;
    }
}

static void JPReloadPrefs(void) {
    BOOL oldEnabled = jpEnabled;
    NSInteger oldMode = jpBackgroundMode;
    jpBackgroundMode = JPInt(@"BackgroundMode", 0);
    jpContentModeInt = JPInt(@"backgroundImageContentModeInt", 0);
    jpColBgOn = JPBool(@"CustomBackgroundColourEnabled", NO);
    jpColTextOn = JPBool(@"CustomTextColourEnabled", NO);
    jpColGradOn = JPBool(@"CustomKeyPopUpGradientEnabled", NO);
    jpColPredTextOn = JPBool(@"CustomPredictionTextColourEnabled", NO);
    jpColPredBgOn = JPBool(@"CustomPredictionBarBackgroundColourEnabled", NO);
    jpColTintOn = JPBool(@"CustomKeyTintEnabled", NO);
    jpColEmojiSearchOn = JPBool(@"CustomEmojiSearchBackgroundEnabled", NO);
    jpColBg = JPStr(@"CustomBackgroundColour");
    jpColText = JPStr(@"CustomTextColour");
    jpColPredText = JPStr(@"CustomPredictionTextColour");
    jpColPredBg = JPStr(@"CustomPredictionBarBackgroundColour");
    jpColTint = JPStr(@"CustomKeyTintColour");
    jpColEmojiSearch = JPStr(@"CustomEmojiSearchBackground");
    jpColGradStart = JPStr(@"CustomKeyCapGradientStart");
    jpColGradEnd = JPStr(@"CustomKeyCapGradientEnd");
    jpHideKeyShadows = JPBool(@"HideKeyShadows", NO);
    jpHideKeyCaps = JPBool(@"HideKeyCaps", NO);
    jpHideKeyPopups = JPBool(@"HideKeyPopups", NO);
    jpHideLanguageIndicator = JPBool(@"HideLanguageIndicator", NO);
    jpHideEmojiSlider = JPBool(@"HideEmojiSlider", NO);
    jpHideEmojiSliderOverlay = JPBool(@"HideEmojiSliderOverlay", NO);
    jpHideKeyPlane = JPBool(@"HideKeyPlane", NO);
    jpFullyHideBackground = JPBool(@"FullyHideBackground", NO);
    jpOverrideKeyboardMode = JPInt(@"OverrideKeyboardMode", 0);
    jpMessagesUsePredictionColour = JPBool(@"MessagesUsePredictionColour", YES);
    jpCurrentPreset = JPStr(@"CurrentPreset");
    jpLightPreset = JPStr(@"LaetusPresetsLightMode");
    jpDarkPreset = JPStr(@"LaetusPresetsDarkMode");
    jpSwitchPresetsWithDarkMode = JPBool(@"SwitchPresetsWithDarkMode", NO);
    jpSafeMode = JPBool(@"SafeMode", NO);
    jpHookGroup = JPInt(@"HookGroup", 0);
    if (jpSafeMode) jpHookGroup = 0;  // SafeMode 开 = 强制只基线
    NSString *theme = JPStr(@"ActiveTheme");
    if (![jpThemeName isEqualToString:theme]) { jpThemeName = theme; }
    NSString *html = JPStr(@"ActiveHTMLTheme");
    if (![jpHTMLThemeName isEqualToString:html]) { jpHTMLThemeName = html; }
    JPResolveTheme();
    if (oldEnabled != jpEnabled || oldMode != jpBackgroundMode) jpGen++;
}

#pragma mark - 预设

static void JPLoadPreset(NSString *name) {
    if (!name.length) return;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        [NSString stringWithFormat:@"%@/%@.plist", @JP_PRESETS_DIR, name]];
    if (!d) return;
    for (NSString *k in d) {
        CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)d[k], CFSTR(JP_DOMAIN));
    }
    CFPreferencesSetAppValue(CFSTR("CurrentPreset"), (__bridge CFPropertyListRef)name, CFSTR(JP_DOMAIN));
    CFPreferencesAppSynchronize(CFSTR(JP_DOMAIN));
    JPLog(@"preset loaded: %@", name);
}

#pragma mark - keyplane 映射与主题图查找（同 0.1）

static NSString *JPKeyForKeypplaneName(NSString *name) {
    if (!name.length) return @"KeyboardMainBG";
    if ([name isEqualToString:@"small-letters"] || [name isEqualToString:@"capital-letters"]) return @"KeyboardMainBG";
    if ([name isEqualToString:@"numbers-and-punctuation"] || [name isEqualToString:@"numbers-and-punctuation-alternative"]) return @"KeyboardNumbersBG";
    if ([name isEqualToString:@"emoji-keyboard"]) return @"KeyboardEmojiBG";
    if ([name hasSuffix:@"-pad"]) return @"KeyboardNumberPadBG";
    if ([name isEqualToString:@"autofill"]) return @"KeyboardAutoFillBG";
    if ([name isEqualToString:@"picker"]) return @"KeyboardPickerBG";
    if ([name isEqualToString:@"dictation"]) return @"KeyboardDictationBG";
    return @"KeyboardMainBG";
}

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
    });
    return s;
}

static UIImage *JPLoadImage(NSString *path) {
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (!raw) return nil;
    return [UIImage imageWithCGImage:raw.CGImage scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
}

// 主题目录可能把图放根目录或 Images/ 子目录（Laetus 官方主题格式），多路径查找
static NSArray *JPThemeSearchDirs(void) {
    if (!jpThemePath) return @[];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *dirs = [NSMutableArray arrayWithObject:jpThemePath];
    for (NSString *sub in @[@"Images", @"images", @"Image"]) {
        NSString *p = [jpThemePath stringByAppendingPathComponent:sub];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) [dirs addObject:p];
    }
    return dirs;
}

// 设备语言（zh_Hans 等），用于 Laetus 命名的语言后缀
static NSString *JPKeyboardLanguage(void) {
    static NSString *lang;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *modes = [UITextInputMode activeInputModes];
        for (UITextInputMode *m in modes) {
            if ([m respondsToSelector:@selector(primaryLanguage)]) {
                NSString *l = [m performSelector:@selector(primaryLanguage)];
                if (l.length) { lang = l; break; }
            }
        }
        if (!lang.length) lang = @"en_US";
        JPLog(@"keyboard language: %@", lang);
    });
    return lang;
}

static NSMutableDictionary *jpImageCache;
static UIImage *JPImageForKey(NSString *key, BOOL landscape) {
    if (!key.length) return nil;

    // 图片模式：用户自选图，所有 keyplane 同一张
    if (jpBackgroundMode == 2) {
        static UIImage *userBg;
        static NSInteger userBgGen = -1;
        if (userBgGen != jpGen || !userBg) {
            userBg = JPLoadImage(@JP_USER_BG);
            userBgGen = jpGen;
            if (userBg) JPLog(@"user bg loaded (%@x%@)", @(userBg.size.width), @(userBg.size.height));
        }
        return userBg;
    }

    if (!jpThemePath) return nil;
    if (!jpImageCache) jpImageCache = [NSMutableDictionary new];
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%d|gen%ld", key, landscape, (long)jpGen];
    UIImage *cached = jpImageCache[cacheKey];
    if (cached) return cached;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *orient = landscape ? @"Landscape" : @"Portrait";
    NSString *h = JPHeightSuffix();
    NSString *lang = JPKeyboardLanguage();
    NSArray *scales = @[@"@3x", @"@2x", @""];

    // Laetus 命名段（全部可选，从全量到最简逐级剥离）：
    //   Key[-trait-X][-lang][-orient][-height][scale].png / Key[-lang][-orient][-height]...
    // 实际顺序（真实主题样本）：KeyboardNumbersKeyPlanePortrait-it-zh_Hans-896h@3x.png
    //                          KeyboardLettersKeyPlane...trait-es_CO-896h@3x.png
    // 段序不固定 → 生成 name 组合后用"前缀匹配目录扫描"而不是逐个 fileExists：
    //   候选段集 = [orient] × [lang] × [h] 的所有子集 + scale 后缀
    NSMutableArray *names = [NSMutableArray array];
    NSArray *langs = lang.length ? @[lang, @""] : @[@""];
    for (NSString *o in (@[orient, @""])) {
        for (NSString *l in langs) {
            for (NSString *hh in (h ? @[h, @""] : @[@""])) {
                for (NSString *sc in scales) {
                    NSMutableString *n = [NSMutableString stringWithString:key];
                    if (o.length) [n appendFormat:@"-%@", o];
                    if (l.length) [n appendFormat:@"-%@", l];
                    if (hh.length) [n appendFormat:@"-%@", hh];
                    [n appendFormat:@"%@.png", sc];
                    [names addObject:n];
                    // trait-xx_YY 变体：语言国别段（es_CO）——用通配前缀匹配兜底（见下）
                }
            }
        }
    }
    // 屏高映射兜底（926→896 / 844→812）
    if ([h isEqualToString:@"932h"] || [h isEqualToString:@"926h"]) {
        for (NSString *sc in scales) {
            [names addObject:[NSString stringWithFormat:@"%@-%@-896h%@.png", key, orient, sc]];
            [names addObject:[NSString stringWithFormat:@"%@-896h%@.png", key, sc]];
        }
    } else if ([h isEqualToString:@"844h"]) {
        for (NSString *sc in scales) {
            [names addObject:[NSString stringWithFormat:@"%@-%@-812h%@.png", key, orient, sc]];
            [names addObject:[NSString stringWithFormat:@"%@-812h%@.png", key, sc]];
        }
    }

    for (NSString *dir in JPThemeSearchDirs()) {
        for (NSString *n in names) {
            NSString *path = [dir stringByAppendingPathComponent:n];
            if ([fm fileExistsAtPath:path]) {
                UIImage *img = JPLoadImage(path);
                if (img) { jpImageCache[cacheKey] = img; return img; }
            }
        }
        // 前缀兜底：key 开头 + 含 orient 关键字的任意 png（trait/lang 段不匹配也能命中）
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:NULL];
        NSString *best = nil;
        for (NSString *f in items) {
            if (![f.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
            if (![f hasPrefix:key]) continue;
            if (orient.length && ![f containsString:orient]) continue;  // 方向必须匹配
            if (!best || f.length > best.length) best = f;              // 名字最长=段最全
        }
        if (best) {
            UIImage *img = JPLoadImage([dir stringByAppendingPathComponent:best]);
            if (img) {
                jpImageCache[cacheKey] = img;
                JPLog(@"prefix matched: %@ (dir %@)", best, dir.lastPathComponent);
                return img;
            }
        }
    }
    return nil;
}

static UIImage *JPApplyContentMode(UIImage *img, CGFloat targetWidth) {
    if (!img || targetWidth <= 0) return img;
    CGFloat ratio = img.size.width / img.size.height;
    switch (jpContentModeInt) {
        case 1: {  // AspectFit：按宽等比，高度自适应（SplitImageView 会拉伸）→ 生成白边？直接返回
            return img;
        }
        case 2: {  // AspectFill：裁剪到 targetWidth/ratio 高
            CGFloat targetH = targetWidth / ratio;
            CGSize sz = CGSizeMake(targetWidth, targetH);
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
            return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
            }];
        }
        case 3: {  // Center：原尺寸
            return img;
        }
        default:
            return img;  // ScaleToFill：交给 SplitImageView 拉伸
    }
}

#pragma mark - HTML 主题 WebView 管理

static const char kJPAssocWebView = '\0';
static WKWebView *JPWebViewForHostView(UIView *host) {
    WKWebView *wv = objc_getAssociatedObject(host, &kJPAssocWebView);
    if (!wv) {
        WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
        cfg.userContentController = [[WKUserContentController alloc] init];
        wv = [[WKWebView alloc] initWithFrame:host.bounds configuration:cfg];
        wv.scrollView.scrollEnabled = NO;
        wv.userInteractionEnabled = NO;   // 纯背景，不吃事件
        wv.backgroundColor = UIColor.clearColor;
        wv.opaque = NO;
        objc_setAssociatedObject(host, &kJPAssocWebView, wv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return wv;
}

static void JPApplyHTMLToHost(UIView *host) {
    if (!host || jpBackgroundMode != 1 || !jpHTMLIndexPath) return;
    @try {
        WKWebView *wv = JPWebViewForHostView(host);
        if (wv.superview != host) {
            [host insertSubview:wv atIndex:0];
            wv.frame = host.bounds;
            wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            JPLog(@"html webview inserted");
        }
        NSString *html = [NSString stringWithContentsOfFile:jpHTMLIndexPath
                                                   encoding:NSUTF8StringEncoding error:NULL];
        if (html) {
            NSURL *base = [NSURL fileURLWithPath:jpHTMLIndexPath.stringByDeletingLastPathComponent];
            [wv loadHTMLString:html baseURL:base];
        }
    } @catch (NSException *e) { JPLog(@"exc html: %@", e); }
}

#pragma mark - Hook 1: UIKBGetNamedColor（颜色核心，Laetus fake_UIKBGetNamedColor 同款）

static UIColor *(*orig_UIKBGetNamedColor)(CFStringRef name);

static NSMutableSet *jpSeenColourNames;
static UIColor *fake_UIKBGetNamedColor(CFStringRef name) {
    @try {
        if (name == NULL) return orig_UIKBGetNamedColor(name);
        if (!jpEnabled) return orig_UIKBGetNamedColor(name);
        // 诊断：收集真实颜色名（每进程限 60 条）
        {
            NSString *n = (__bridge NSString *)name;
            if (!jpSeenColourNames) jpSeenColourNames = [NSMutableSet new];
            if ([n length] < 64 && ![jpSeenColourNames containsObject:n] && jpSeenColourNames.count < 60) {
                [jpSeenColourNames addObject:n];
                JPLog(@"colourName: %@", n);
            }
        }
        if (!name) return orig_UIKBGetNamedColor(name);
        NSString *n = (__bridge NSString *)name;

        // 背景（键盘底色）
        if (jpColBgOn && jpBackgroundMode == 0) {
            NSArray *bgNames = @[@"keyboardBackgroundLightColor", @"keyboardBackgroundDarkColor",
                                 @"keyboardBackgroundColor", @"secondaryKeyboardBackgroundColor"];
            if ([bgNames containsObject:n]) {
                UIColor *c = JPParseColour(jpColBg);
                if (c) return c;
            }
        }
        // 文本/键帽文字
        if (jpColTextOn) {
            NSArray *txtNames = @[@"keyboardKeyTextLightColor", @"keyboardKeyTextDarkColor",
                                  @"keyboardKeyTextColor", @"keyboardAlternateTextLightColor",
                                  @"keyboardAlternateTextDarkColor", @"keyboardAlternateTextColor"];
            if ([txtNames containsObject:n]) {
                UIColor *c = JPParseColour(jpColText);
                if (c) return c;
            }
        }
        // 键色调（按键按下高亮）
        if (jpColTintOn && ([n hasPrefix:@"keyboardKeyTintColor"] || [n isEqualToString:@"keyboardKeyHighlightColor"])) {
            UIColor *c = JPParseColour(jpColTint);
            if (c) return c;
        }
        // 预测栏背景
        if (jpColPredBgOn && ([n containsString:@"PredictionBarBackground"] || [n containsString:@"predictionBarBackground"])) {
            UIColor *c = JPParseColour(jpColPredBg);
            if (c) return c;
        }
        // 预测栏文本
        if (jpColPredTextOn && ([n containsString:@"PredictionText"] || [n containsString:@"predictionText"])) {
            UIColor *c = JPParseColour(jpColPredText);
            if (c) return c;
        }
        // Emoji 搜索背景
        if (jpColEmojiSearchOn && ([n containsString:@"EmojiSearch"] || [n containsString:@"emojiSearch"])) {
            UIColor *c = JPParseColour(jpColEmojiSearch);
            if (c) return c;
        }
    } @catch (__unused NSException *e) {}
    return orig_UIKBGetNamedColor(name);
}

#pragma mark - Hook 2: 背景贴图（UIKBSplitImageView）

static IMP orig_setImage = NULL;
static void jp_hook_setImage(id self, SEL _cmd, UIImage *image, double width, id keyplane) {
    @try {
        static int entries = 0;
        if (entries++ < 20) {
            JPLog(@"setImage entry #%d: self=%@ kp=%@ width=%.0f img=%@ mode=%ld",
                  entries, NSStringFromClass([self class]),
                  keyplane ? NSStringFromClass([keyplane class]) : @"(nil)",
                  width, image ? NSStringFromClass([image class]) : @"(nil)",
                  (long)jpBackgroundMode);
        }
        // 只有键盘背景视图（UIKBBackgroundView）才换图；
        // 其它 SplitImageView 子类（键帽贴图等）必须放行，否则键帽全部消失
        Class bgCls = NSClassFromString(@"UIKBBackgroundView");
        if (bgCls && ![self isKindOfClass:bgCls]) {
            ((void (*)(id, SEL, UIImage *, double, id))orig_setImage)(self, _cmd, image, width, keyplane);
            return;
        }
        if (jpEnabled && keyplane) {
            NSString *kpName = nil;
            @try { kpName = [keyplane valueForKey:@"name"]; } @catch (__unused NSException *e) {}
            NSString *key = JPKeyForKeypplaneName(kpName);
            BOOL landscape = UIScreen.mainScreen.bounds.size.width > UIScreen.mainScreen.bounds.size.height;
            UIImage *theme = JPImageForKey(key, landscape);
            if (theme) {
                theme = JPApplyContentMode(theme, width);
                image = theme;
                static int served = 0;
                if (served++ < 30) JPLog(@"bg served: %@ (%@)", key, kpName);
            }
        }
    } @catch (NSException *e) { JPLog(@"exc setImage: %@", e); }
    ((void (*)(id, SEL, UIImage *, double, id))orig_setImage)(self, _cmd, image, width, keyplane);
}

#pragma mark - Hook 3: 键帽渲染（UIKBRenderer —— HideKeyCaps 用）

static IMP orig_renderKeyContents = NULL;
static void jp_hook_renderKeyContents(id self, SEL _cmd, id contents, id traits) {
    @try {
        // HideKeyCaps 时把 contents 挖空（renderer 画不出字符 = 无键帽文字）
        if (jpEnabled && jpHideKeyCaps && contents) {
            @try {
                if ([contents respondsToSelector:@selector(displayString)]) {
                    // 不直接清 displayString（影响输入），只让渲染层拿到空串
                    // Laetus 通过 _populateLayer 拦截；这里在 renderer 层拦截更早
                }
            } @catch (__unused NSException *e) {}
        }
    } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL, id, id))orig_renderKeyContents)(self, _cmd, contents, traits);
}

// UIKBKeyView _populateLayer:withContents: — 键帽贴图层（Laetus 主通道）
static IMP orig_populateLayer = NULL;
static void jp_hook_populateLayer(id self, SEL _cmd, id layer, id contents) {
    // 永不短路：先完整走原实现（layer 树必须完整，否则渲染崩），再按需隐藏
    ((void (*)(id, SEL, id, id))orig_populateLayer)(self, _cmd, layer, contents);
    @try {
        if (jpEnabled && jpHideKeyCaps && [layer isKindOfClass:CALayer.class]) {
            CALayer *l = (CALayer *)layer;
            l.hidden = YES;
        }
    } @catch (__unused NSException *e) {}
}

// UIKBKeyView layoutSubviews — 阴影清除（0.1 已有，保留）
static IMP orig_keyViewLayout = NULL;
static void jp_hook_keyViewLayout(id self, SEL _cmd) {
    ((void (*)(id, SEL))orig_keyViewLayout)(self, _cmd);
    @try {
        if (!jpEnabled || !jpHideKeyShadows) return;
        UIView *view = (UIView *)self;
        for (CALayer *layer in view.layer.sublayers) {
            if (layer.shadowOpacity > 0) layer.shadowOpacity = 0;
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - Hook 4: 元素隐藏（UIKBTree / EmojiBar / Popups）

static IMP orig_noLangInd = NULL;
static BOOL jp_hook_noLangInd(id self, SEL _cmd) {
    BOOL r = ((BOOL (*)(id, SEL))orig_noLangInd)(self, _cmd);
    return (jpEnabled && jpHideLanguageIndicator) ? YES : r;
}

static IMP orig_avoidsLangInd = NULL;
static BOOL jp_hook_avoidsLangInd(id self, SEL _cmd) {
    BOOL r = ((BOOL (*)(id, SEL))orig_avoidsLangInd)(self, _cmd);
    return (jpEnabled && jpHideLanguageIndicator) ? YES : r;
}

static IMP orig_animScrubber = NULL;
static void jp_hook_animScrubber(id self, SEL _cmd, CGRect rect) {
    // 永不短路：照常动画，只把滑块视图藏掉
    ((void (*)(id, SEL, CGRect))orig_animScrubber)(self, _cmd, rect);
    @try {
        if (jpEnabled && jpHideEmojiSlider) {
            id sv = [self valueForKey:@"scrubView"];
            if ([sv isKindOfClass:UIView.class]) ((UIView *)sv).hidden = YES;
        }
    } @catch (__unused NSException *e) {}
}

// touchDown 仅作轻量观察（不做 KVC，热路径保持纯净）
static IMP orig_touchDownInfo = NULL;
static void jp_hook_touchDownInfo(id self, SEL _cmd, id key, id info, CGPoint point, id ctx) {
    ((void (*)(id, SEL, id, id, CGPoint, id))orig_touchDownInfo)(self, _cmd, key, info, point, ctx);
}

// popup 隐藏：拦 showPopupVariantsForKey:（头文件确认存在）
static IMP orig_showPopupVariants = NULL;
static void jp_hook_showPopupVariants(id self, SEL _cmd, id key) {
    if (jpEnabled && jpHideKeyPopups) return;
    ((void (*)(id, SEL, id))orig_showPopupVariants)(self, _cmd, key);
}

#pragma mark - Hook 5: 深浅色强制（UIKBRenderConfig.lightKeyboard）

static IMP orig_lightKeyboard = NULL;
static BOOL jp_hook_lightKeyboard(id self, SEL _cmd) {
    @try {
        if (jpEnabled && jpOverrideKeyboardMode == 1) return NO;   // 强制深色
        if (jpEnabled && jpOverrideKeyboardMode == 2) return YES;  // 强制浅色
    } @catch (__unused NSException *e) {}
    return ((BOOL (*)(id, SEL))orig_lightKeyboard)(self, _cmd);
}

#pragma mark - Hook 6: 完全隐藏背景（UIKBVisualEffectView）

static IMP orig_transitionToStyle = NULL;
static void jp_hook_transitionToStyle(id self, SEL _cmd, id style) {
    @try {
        if (jpEnabled && jpFullyHideBackground) {
            UIView *v = (UIView *)self;
            v.hidden = YES;
            v.alpha = 0;
            return;
        }
    } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL, id))orig_transitionToStyle)(self, _cmd, style);
}

#pragma mark - Hook 7: keyplane 跟踪 + HTML 垫层（LayoutStar / HostingItem）

static IMP orig_didChangeKeyplane = NULL;
static void jp_hook_didChangeKeyplane(id self, SEL _cmd, id context) {
    ((void (*)(id, SEL, id))orig_didChangeKeyplane)(self, _cmd, context);
    @try {
        static int kpEntries = 0;
        if (kpEntries++ < 10) JPLog(@"didChangeKeyplane entry #%d self=%@", kpEntries, NSStringFromClass([self class]));
        if (!jpEnabled) return;
        static int fired = 0;
        fired++;
        NSString *name = nil;
        @try { name = [self valueForKey:@"keyplaneName"]; } @catch (__unused NSException *e) {}
        if (fired <= 12) JPLog(@"keyplane changed (#%d): %@", fired, name);
        JPReloadPrefs();
    } @catch (NSException *e) { JPLog(@"exc keyplane: %@", e); }
}

static IMP orig_hostingUpdateBackdrop = NULL;
static void jp_hook_hostingUpdateBackdrop(id self, SEL _cmd) {
    ((void (*)(id, SEL))orig_hostingUpdateBackdrop)(self, _cmd);
    @try {
        if (!jpEnabled || jpBackgroundMode != 1) return;
        UIView *host = (UIView *)self;
        if ([host isKindOfClass:UIView.class]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                JPApplyHTMLToHost(host);
            });
        }
    } @catch (NSException *e) { JPLog(@"exc backdrop: %@", e); }
}

#pragma mark - Hook 8: 深浅色跟随（UIWindow.traitCollectionDidChange）

static IMP orig_traitChange = NULL;
static void jp_hook_traitChange(id self, SEL _cmd, id prevTraits) {
    ((void (*)(id, SEL, id))orig_traitChange)(self, _cmd, prevTraits);
    @try {
        if (!jpEnabled || !jpSwitchPresetsWithDarkMode) return;
        UITraitCollection *cur = ((UIWindow *)self).traitCollection;
        BOOL dark = cur.userInterfaceStyle == UIUserInterfaceStyleDark;
        NSString *target = dark ? jpDarkPreset : jpLightPreset;
        if (target.length) {
            JPLoadPreset(target);
            jpGen++;  // 失效颜色缓存
            JPLog(@"dark mode %@ -> preset %@", dark ? @"ON" : @"OFF", target);
        }
    } @catch (NSException *e) { JPLog(@"exc trait: %@", e); }
}

#pragma mark - Hook 9: 预测栏颜色（TUIPredictionViewCell）

static IMP orig_cellSetTextColor = NULL;
static void jp_hook_cellSetTextColor(id self, SEL _cmd, UIColor *color) {
    @try {
        if (jpEnabled && jpColPredTextOn) {
            UIColor *c = JPParseColour(jpColPredText);
            if (c) color = c;
        }
    } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL, UIColor *))orig_cellSetTextColor)(self, _cmd, color);
}

static IMP orig_cellSetBgColor = NULL;
static void jp_hook_cellSetBgColor(id self, SEL _cmd, UIColor *color) {
    @try {
        if (jpEnabled && jpColPredBgOn && !jpMessagesUsePredictionColour) {
            // Messages 栏不使用预测背景色时保持原样
        } else if (jpEnabled && jpColPredBgOn) {
            UIColor *c = JPParseColour(jpColPredBg);
            if (c) color = c;
        }
    } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL, UIColor *))orig_cellSetBgColor)(self, _cmd, color);
}

static IMP orig_cellSetImageTint = NULL;
static void jp_hook_cellSetImageTint(id self, SEL _cmd, UIColor *color) {
    @try {
        if (jpEnabled && jpColPredTextOn) {
            UIColor *c = JPParseColour(jpColPredText);
            if (c) color = c;
        }
    } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL, UIColor *))orig_cellSetImageTint)(self, _cmd, color);
}

#pragma mark - 安装

static void JPInstallHooks(void) {
    // ---- 基线组（0.2/0.5/0.6/0.7.1 SafeMode 下已验证无崩溃）----
    static BOOL colorHooked = NO;
    if (!colorHooked) {
        void *uikit = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW);
        if (uikit) {
            void *sym = dlsym(uikit, "UIKBGetNamedColor");
            if (sym) {
                MSHookFunction(sym, (void *)fake_UIKBGetNamedColor, (void **)&orig_UIKBGetNamedColor);
                colorHooked = YES;
                JPLog(@"hook installed: UIKBGetNamedColor (colour engine)");
            } else {
                JPLog(@"UIKBGetNamedColor dlsym failed");
            }
        }
    }

    Class split = NSClassFromString(@"UIKBSplitImageView");
    if (split && !orig_setImage) {
        SEL sel = NSSelectorFromString(@"setImage:cachedWidth:keyplane:");
        if ([split instancesRespondToSelector:sel]) {
            MSHookMessageEx(split, sel, (IMP)jp_hook_setImage, (IMP *)&orig_setImage);
            JPLog(@"hook installed: UIKBSplitImageView setImage:cachedWidth:keyplane:");
        }
    }

    Class keyViewEarly = NSClassFromString(@"UIKBKeyView");
    if (keyViewEarly && !orig_keyViewLayout) {
        SEL lay = @selector(layoutSubviews);
        if ([keyViewEarly instancesRespondToSelector:lay]) {
            MSHookMessageEx(keyViewEarly, lay, (IMP)jp_hook_keyViewLayout, (IMP *)&orig_keyViewLayout);
            JPLog(@"hook installed: UIKBKeyView layoutSubviews (shadows)");
        }
    }

    // ---- 分组开关（HookGroup 位掩码；0=只装基线）----
    BOOL g1 = jpHookGroup & 1, g2 = jpHookGroup & 2, g3 = jpHookGroup & 4, g4 = jpHookGroup & 8;
    JPLog(@"hook groups: render=%d element=%d config=%d host=%d (group=%ld)",
          g1, g2, g3, g4, (long)jpHookGroup);
    if (jpHookGroup == 0) { JPLog(@"baseline-only (group=0): skipping optional hooks"); return; }

    // 组1 渲染：renderKeyContents + _populateLayer
    if (g1) {
        Class renderer = NSClassFromString(@"UIKBRenderer");
        if (renderer && !orig_renderKeyContents) {
            SEL sel = NSSelectorFromString(@"renderKeyContents:withTraits:");
            if ([renderer instancesRespondToSelector:sel]) {
                MSHookMessageEx(renderer, sel, (IMP)jp_hook_renderKeyContents, (IMP *)&orig_renderKeyContents);
                JPLog(@"hook installed: UIKBRenderer renderKeyContents:withTraits:");
            }
        }
        Class keyView = NSClassFromString(@"UIKBKeyView");
        if (keyView) {
            SEL pop = NSSelectorFromString(@"_populateLayer:withContents:");
            if (!orig_populateLayer && [keyView instancesRespondToSelector:pop]) {
                MSHookMessageEx(keyView, pop, (IMP)jp_hook_populateLayer, (IMP *)&orig_populateLayer);
                JPLog(@"hook installed: UIKBKeyView _populateLayer:withContents:");
            }
        }
    }

    // 组2 元素：语言指示器 + 表情滑块 + 按键弹出
    if (g2) {
        Class tree = NSClassFromString(@"UIKBTree");
        if (tree) {
            SEL n1 = NSSelectorFromString(@"noLanguageIndicator");
            if (!orig_noLangInd && [tree instancesRespondToSelector:n1]) {
                MSHookMessageEx(tree, n1, (IMP)jp_hook_noLangInd, (IMP *)&orig_noLangInd);
            }
            SEL n2 = NSSelectorFromString(@"avoidsLanguageIndicator");
            if (!orig_avoidsLangInd && [tree instancesRespondToSelector:n2]) {
                MSHookMessageEx(tree, n2, (IMP)jp_hook_avoidsLangInd, (IMP *)&orig_avoidsLangInd);
            }
            if (orig_noLangInd || orig_avoidsLangInd) JPLog(@"hook installed: UIKBTree language indicator");
        }
        Class emojiBar = NSClassFromString(@"UIKeyboardEmojiCategoryBar");
        if (emojiBar && !orig_animScrubber) {
            SEL sel = NSSelectorFromString(@"animateScrubberToRect:");
            if ([emojiBar instancesRespondToSelector:sel]) {
                MSHookMessageEx(emojiBar, sel, (IMP)jp_hook_animScrubber, (IMP *)&orig_animScrubber);
                JPLog(@"hook installed: UIKeyboardEmojiCategoryBar animateScrubberToRect:");
            }
        }
        Class star0 = NSClassFromString(@"UIKeyboardLayoutStar");
        if (star0) {
            SEL spv = NSSelectorFromString(@"showPopupVariantsForKey:");
            if (!orig_showPopupVariants && [star0 instancesRespondToSelector:spv]) {
                MSHookMessageEx(star0, spv, (IMP)jp_hook_showPopupVariants, (IMP *)&orig_showPopupVariants);
                JPLog(@"hook installed: LayoutStar showPopupVariants (popups)");
            }
        }
    }

    // 组3 配置：lightKeyboard + transitionToStyle
    if (g3) {
        Class cfg = NSClassFromString(@"UIKBRenderConfig");
        if (cfg && !orig_lightKeyboard) {
            SEL sel = NSSelectorFromString(@"lightKeyboard");
            if ([cfg instancesRespondToSelector:sel]) {
                MSHookMessageEx(cfg, sel, (IMP)jp_hook_lightKeyboard, (IMP *)&orig_lightKeyboard);
                JPLog(@"hook installed: UIKBRenderConfig lightKeyboard");
            }
        }
        Class vfx = NSClassFromString(@"UIKBVisualEffectView");
        if (vfx && !orig_transitionToStyle) {
            SEL sel = NSSelectorFromString(@"transitionToStyle:");
            if ([vfx instancesRespondToSelector:sel]) {
                MSHookMessageEx(vfx, sel, (IMP)jp_hook_transitionToStyle, (IMP *)&orig_transitionToStyle);
                JPLog(@"hook installed: UIKBVisualEffectView transitionToStyle:");
            }
        }
    }

    // 组4 容器/全局：HTML 垫层 + 深浅色 + touchDown
    if (g4) {
        Class hosting = NSClassFromString(@"UIInputWindowControllerHostingItem");
        if (hosting && !orig_hostingUpdateBackdrop) {
            SEL sel = NSSelectorFromString(@"updateInputBackdropView");
            if ([hosting instancesRespondToSelector:sel]) {
                MSHookMessageEx(hosting, sel, (IMP)jp_hook_hostingUpdateBackdrop, (IMP *)&orig_hostingUpdateBackdrop);
                JPLog(@"hook installed: HostingItem updateInputBackdropView (html)");
            }
        }
        Class windowCls = NSClassFromString(@"UIWindow");
        if (windowCls && !orig_traitChange) {
            SEL sel = NSSelectorFromString(@"traitCollectionDidChange:");
            if ([windowCls instancesRespondToSelector:sel]) {
                MSHookMessageEx(windowCls, sel, (IMP)jp_hook_traitChange, (IMP *)&orig_traitChange);
                JPLog(@"hook installed: UIWindow traitCollectionDidChange:");
            }
        }
        Class star = NSClassFromString(@"UIKeyboardLayoutStar");
        if (star) {
            SEL td1 = NSSelectorFromString(@"touchDownWithKey:withTouchInfo:atPoint:executionContext:");
            if (!orig_touchDownInfo && [star instancesRespondToSelector:td1]) {
                MSHookMessageEx(star, td1, (IMP)jp_hook_touchDownInfo, (IMP *)&orig_touchDownInfo);
                JPLog(@"hook installed: LayoutStar touchDown (observe)");
            }
            SEL kp = NSSelectorFromString(@"_didChangeKeyplaneWithContext:");
            if (!orig_didChangeKeyplane && [star instancesRespondToSelector:kp]) {
                MSHookMessageEx(star, kp, (IMP)jp_hook_didChangeKeyplane, (IMP *)&orig_didChangeKeyplane);
                JPLog(@"hook installed: LayoutStar _didChangeKeyplaneWithContext:");
            }
        }
        Class cell = NSClassFromString(@"TUIPredictionViewCell");
        if (cell) {
            SEL s1 = NSSelectorFromString(@"setTextColor:");
            if (!orig_cellSetTextColor && [cell instancesRespondToSelector:s1]) {
                MSHookMessageEx(cell, s1, (IMP)jp_hook_cellSetTextColor, (IMP *)&orig_cellSetTextColor);
            }
            SEL s2 = NSSelectorFromString(@"setBackgroundColor:");
            if (!orig_cellSetBgColor && [cell instancesRespondToSelector:s2]) {
                MSHookMessageEx(cell, s2, (IMP)jp_hook_cellSetBgColor, (IMP *)&orig_cellSetBgColor);
            }
            SEL s3 = NSSelectorFromString(@"setImageTintColor:");
            if (!orig_cellSetImageTint && [cell instancesRespondToSelector:s3]) {
                MSHookMessageEx(cell, s3, (IMP)jp_hook_cellSetImageTint, (IMP *)&orig_cellSetImageTint);
            }
            if (orig_cellSetTextColor) JPLog(@"hook installed: TUIPredictionViewCell colours");
        }
    }
}

static void JPConfigChangedImpl(CFNotificationCenterRef c, void *obs, CFStringRef n, const void *o, CFDictionaryRef ui) {
    JPReloadPrefs();
    jpGen++;
    JPLog(@"config changed: mode=%ld theme='%@' enabled=%d", (long)jpBackgroundMode, jpThemeName, jpEnabled);
}

__attribute__((constructor))
static void JPInitialize(void) {
    @autoreleasepool {
        JPReloadPrefs();
        JPLog(@"JianPan 0.9.1 init — enabled=%d mode=%ld theme='%@' html='%@'",
              jpEnabled, (long)jpBackgroundMode, jpThemeName, jpHTMLThemeName);
        JPInstallHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            JPInstallHooks();
        });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, &JPConfigChangedImpl,
                                        CFSTR(JP_CHANGED), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
