//
//  WFInstalledApps.m
//  WorseFiles
//
//  LaunchServices' API refuses this app on iOS 27, so the installed-app list
//  is best effort. Names come from the lsd CSStore (WQNames.m) and icons from
//  UIKit; this file keeps the optional list and the MCM path fallback.
//

#import "WFInstalledApps.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>

@interface UIImage (WorseFilesPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID
                                               format:(int)format
                                                scale:(CGFloat)scale;
@end

static void WFOpenFramework(NSString *path) {
    static NSMutableSet<NSString *> *opened = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        opened = [NSMutableSet set];
    });
    @synchronized (opened) {
        if ([opened containsObject:path]) return;
        [opened addObject:path];
    }
    dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
}

static id WFGet(id object, NSString *selectorName) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *WFString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value path];
    return nil;
}

#pragma mark - LaunchServices

static id WFWorkspace(void) {
    WFOpenFramework(@"/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices");
    WFOpenFramework(@"/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices");
    WFOpenFramework(@"/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices");
    WFOpenFramework(@"/System/Library/Frameworks/CoreServices.framework/CoreServices");

    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls || ![cls respondsToSelector:@selector(defaultWorkspace)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(defaultWorkspace));
}

static NSArray *WFAllLaunchServicesApplications(id workspace) {
    for (NSString *name in @[@"allApplications", @"allInstalledApplications"]) {
        id value = WFGet(workspace, name);
        if ([value isKindOfClass:NSArray.class] && [value count] > 0) {
            return value;
        }
    }
    return nil;
}

static NSArray *WFAppsFromLaunchServices(void) {
    id workspace = WFWorkspace();
    if (!workspace) return nil;

    NSArray *proxies = WFAllLaunchServicesApplications(workspace);
    if (!proxies) return nil;

    NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (id proxy in proxies) {
        if (!proxy) continue;

        NSString *identifier = WFGet(proxy, @"applicationIdentifier");
        if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
            identifier = WFGet(proxy, @"bundleIdentifier");
        }
        if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) continue;
        if ([seen containsObject:identifier]) continue;
        [seen addObject:identifier];

        NSURL *dataURL = WFGet(proxy, @"dataContainerURL");
        NSString *dataPath = [dataURL isKindOfClass:NSURL.class] ? dataURL.path : nil;
        NSURL *bundleURL = WFGet(proxy, @"bundleURL");
        NSString *bundlePath = [bundleURL isKindOfClass:NSURL.class] ? bundleURL.path : nil;
        NSString *name = WFGet(proxy, @"localizedName");
        if (![name isKindOfClass:NSString.class] || name.length == 0) {
            name = WFGet(proxy, @"itemName");
        }
        if (![name isKindOfClass:NSString.class]) name = nil;
        NSString *type = WFGet(proxy, @"applicationType");
        if (![type isKindOfClass:NSString.class]) type = nil;

        [result addObject:@{
            @"identifier": identifier,
            @"dataPath": dataPath ?: @"",
            @"bundlePath": bundlePath ?: @"",
            @"name": name ?: @"",
            @"type": type ?: @"",
        }];

        NSArray *plugins = WFGet(proxy, @"plugInKitPlugins");
        if (![plugins isKindOfClass:NSArray.class]) continue;
        for (id plugin in plugins) {
            NSString *pluginID = WFGet(plugin, @"pluginIdentifier");
            if (![pluginID isKindOfClass:NSString.class] || pluginID.length == 0) {
                pluginID = WFGet(plugin, @"bundleIdentifier");
            }
            if (![pluginID isKindOfClass:NSString.class] || pluginID.length == 0) continue;
            if ([seen containsObject:pluginID]) continue;

            NSURL *pluginData = WFGet(plugin, @"dataContainerURL");
            if (![pluginData isKindOfClass:NSURL.class] || pluginData.path.length == 0) continue;
            NSString *pluginName = WFGet(plugin, @"localizedName");
            if (![pluginName isKindOfClass:NSString.class] || pluginName.length == 0) {
                pluginName = WFGet(plugin, @"itemName");
            }
            if (![pluginName isKindOfClass:NSString.class]) pluginName = nil;
            [seen addObject:pluginID];
            [result addObject:@{
                @"identifier": pluginID,
                @"dataPath": pluginData.path,
                @"bundlePath": @"",
                @"name": pluginName ?: @"",
                @"type": @"plugin",
            }];
        }
    }

    return result.count > 0 ? result : nil;
}

#pragma mark - MobileInstallation

typedef CFDictionaryRef (*WFMobileInstallationLookupFn)(CFDictionaryRef);

static WFMobileInstallationLookupFn WFMobileInstallationLookup(void) {
    static WFMobileInstallationLookupFn function = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WFOpenFramework(@"/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation");
        void *symbol = dlsym(RTLD_DEFAULT, "MobileInstallationLookup");
        if (!symbol) {
            void *handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation",
                                  RTLD_NOW | RTLD_LOCAL);
            if (handle) symbol = dlsym(handle, "MobileInstallationLookup");
        }
        function = (WFMobileInstallationLookupFn)symbol;
    });
    return function;
}

static NSArray *WFAppsFromMobileInstallation(void) {
    WFMobileInstallationLookupFn lookup = WFMobileInstallationLookup();
    if (!lookup) return nil;

    NSDictionary *options = @{@"ApplicationType": @"Any"};
    CFDictionaryRef reference = lookup((__bridge CFDictionaryRef)options);
    if (!reference) reference = lookup((__bridge CFDictionaryRef)@{});
    if (!reference) return nil;

    NSDictionary *apps = (__bridge_transfer NSDictionary *)reference;
    if (![apps isKindOfClass:NSDictionary.class] || apps.count == 0) return nil;

    NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (id key in apps) {
        id value = apps[key];
        if (![value isKindOfClass:NSDictionary.class]) continue;

        NSString *identifier = WFString(((NSDictionary *)value)[@"CFBundleIdentifier"]);
        if (identifier.length == 0) identifier = WFString(key);
        if (identifier.length == 0) continue;
        if ([seen containsObject:identifier]) continue;
        [seen addObject:identifier];

        NSString *bundlePath = WFString(((NSDictionary *)value)[@"Path"]);
        if (bundlePath.length == 0) bundlePath = WFString(((NSDictionary *)value)[@"BundlePath"]);

        NSString *dataPath = WFString(((NSDictionary *)value)[@"Container"]);
        if (dataPath.length == 0) dataPath = WFString(((NSDictionary *)value)[@"DataContainer"]);
        if (dataPath.length == 0) dataPath = WFString(((NSDictionary *)value)[@"ApplicationContainer"]);

        NSString *name = WFString(((NSDictionary *)value)[@"CFBundleDisplayName"]);
        if (name.length == 0) name = WFString(((NSDictionary *)value)[@"CFBundleName"]);

        NSString *type = WFString(((NSDictionary *)value)[@"ApplicationType"]);

        [result addObject:@{
            @"identifier": identifier,
            @"dataPath": dataPath ?: @"",
            @"bundlePath": bundlePath ?: @"",
            @"name": name ?: @"",
            @"type": type ?: @"",
        }];
    }

    return result.count > 0 ? result : nil;
}

#pragma mark - Public

static NSString *WFLastSource = nil;
static NSObject *WFSourceLock = nil;

static void WFSetSource(NSString *source) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WFSourceLock = [NSObject new];
    });
    @synchronized (WFSourceLock) {
        WFLastSource = source;
    }
}

NSArray<NSDictionary<NSString *, id> *> *WFInstalledApps(void) {
    NSArray *apps = WFAppsFromLaunchServices();
    if (apps.count > 0) {
        WFSetSource(@"LaunchServices");
        return apps;
    }

    apps = WFAppsFromMobileInstallation();
    if (apps.count > 0) {
        WFSetSource(@"MobileInstallation");
        return apps;
    }

    WFSetSource(nil);
    return nil;
}

NSString *WFInstalledAppsSource(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WFSourceLock = [NSObject new];
    });
    @synchronized (WFSourceLock) {
        return WFLastSource;
    }
}

// LaunchServices' API is unavailable on iOS 27, but UIKit still resolves app
// icons by bundle id. A fake bundle id returns iOS's generic placeholder, so
// that image is fingerprinted and rejected. Technique from WQ Files.
static NSData *WFIconFingerprint(UIImage *image) {
    const size_t side = 12;
    uint8_t pixels[12 * 12 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4,
                                                  space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    if (image.CGImage) CGContextDrawImage(context, CGRectMake(0, 0, side, side), image.CGImage);
    CGContextRelease(context);
    return [NSData dataWithBytes:pixels length:sizeof(pixels)];
}

static NSData *WFIconPNGFromImage(UIImage *raw) {
    if (!raw || !raw.CGImage) return nil;
    CGFloat side = 40;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *rounded = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:side * 0.225] addClip];
        [raw drawInRect:CGRectMake(0, 0, side, side)];
    }];
    return rounded ? UIImagePNGRepresentation(rounded) : nil;
}

static UIImage *WFRawUIKitIcon(NSString *identifier, int variant) {
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        return nil;
    }
    return [UIImage _applicationIconImageForBundleIdentifier:identifier
                                                      format:variant
                                                       scale:UIScreen.mainScreen.scale];
}

static BOOL WFIconMatchesPlaceholder(UIImage *raw, NSData *placeholder) {
    if (!raw || !raw.CGImage) return YES;
    NSData *fingerprint = WFIconFingerprint(raw);
    if (placeholder.length == 0 || fingerprint.length != placeholder.length) return NO;
    const uint8_t *a = fingerprint.bytes;
    const uint8_t *b = placeholder.bytes;
    unsigned long difference = 0;
    for (NSUInteger index = 0; index < fingerprint.length; index++) {
        difference += (unsigned long)abs((int)a[index] - (int)b[index]);
    }
    return difference / fingerprint.length < 8;
}

static NSData *WFQuickIconPNG(NSString *identifier);

// Same as the quick path: WQ Files uses format 2 only. Rotating through
// other formats can return a different rendering or another app's glyph.
static NSData *WFUIKitIconPNG(NSString *identifier) {
    return WFQuickIconPNG(identifier);
}

static NSData *WFProxyIconPNG(NSString *identifier) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:proxySelector]) return nil;
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySelector, identifier);
    if (!proxy) return nil;

    SEL iconSelector = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:iconSelector]) return nil;
    for (NSNumber *variant in @[@2]) {
        id data = ((id (*)(id, SEL, int))objc_msgSend)(proxy, iconSelector, variant.intValue);
        if (![data isKindOfClass:NSData.class] || [data length] == 0) continue;
        UIImage *image = [UIImage imageWithData:data];
        NSData *png = WFIconPNGFromImage(image);
        if (png.length > 0) return png;
    }
    return nil;
}

// Fallback for apps whose icon is only present in the bundle. Bundle
// containers are usually closed, so this is best effort.
NSData *WFBundleIconData(NSString *bundlePath) {
    if (bundlePath.length == 0) return nil;
    NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![info isKindOfClass:NSDictionary.class]) return nil;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    id single = info[@"CFBundleIconFile"];
    if ([single isKindOfClass:NSString.class] && [single length] > 0) {
        [candidates addObject:single];
    }
    id files = info[@"CFBundleIconFiles"];
    if ([files isKindOfClass:NSArray.class]) {
        [candidates addObjectsFromArray:files];
    }
    NSDictionary *icons = info[@"CFBundleIcons"];
    if ([icons isKindOfClass:NSDictionary.class]) {
        NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
        if ([primary isKindOfClass:NSDictionary.class]) {
            id primaryFiles = primary[@"CFBundleIconFiles"];
            if ([primaryFiles isKindOfClass:NSArray.class]) {
                [candidates addObjectsFromArray:primaryFiles];
            }
            id iconName = primary[@"CFBundleIconName"];
            if ([iconName isKindOfClass:NSString.class]) {
                [candidates addObject:iconName];
            }
        }
    }

    for (NSString *name in candidates) {
        if (![name isKindOfClass:NSString.class] || name.length == 0) continue;
        NSString *stem = [name stringByDeletingPathExtension];
        for (NSString *suffix in @[@"@3x.png", @"@2x.png", @".png", @""]) {
            NSString *file = [stem stringByAppendingString:suffix];
            NSString *path = [bundlePath stringByAppendingPathComponent:file];
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (data.length > 0) return data;
        }
    }
    return nil;
}

// WQ Files uses format 2 only. Other formats can be a different rendering
// (or another app's glyph), so the quick path must not rotate through them.
static NSData *WFQuickIconPNG(NSString *identifier) {
    static NSData *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImage *none = WFRawUIKitIcon(@"cz.kolbi.wqfiles.no-such-app", 2);
        placeholder = WFIconFingerprint(none) ?: [NSData data];
    });
    UIImage *raw = WFRawUIKitIcon(identifier, 2);
    if (!raw || !raw.CGImage) return nil;
    if (WFIconMatchesPlaceholder(raw, placeholder)) return nil;
    return WFIconPNGFromImage(raw);
}

NSData *WFQuickIconData(NSString *identifier) {
    if (identifier.length == 0) return nil;
    __block NSData *result = nil;
    void (^work)(void) = ^{
        result = WFQuickIconPNG(identifier);
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return result;
}

NSData *WFAppIconData(NSString *identifier) {
    if (identifier.length == 0) return nil;
    __block NSData *result = nil;
    void (^work)(void) = ^{
        result = WFUIKitIconPNG(identifier);
        if (!result) result = WFProxyIconPNG(identifier);
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return result;
}

NSString *WFIconReport(NSString *identifier) {
    if (identifier.length == 0) return @"no identifier";
    __block NSString *report = nil;
    void (^work)(void) = ^{
        BOOL responds = [UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)];
        UIImage *raw = WFRawUIKitIcon(identifier, 2);
        NSData *uikit = WFUIKitIconPNG(identifier);
        NSData *proxy = WFProxyIconPNG(identifier);
        report = [NSString stringWithFormat:@"api=%@ raw=%@ uikit=%lu proxy=%lu",
                  responds ? @"yes" : @"no",
                  raw ? [NSString stringWithFormat:@"%.0fx%.0f", raw.size.width, raw.size.height] : @"nil",
                  (unsigned long)uikit.length,
                  (unsigned long)proxy.length];
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return report ?: @"nil";
}

static NSString *WFMCMContainerPath(NSString *identifier, NSArray<NSString *> *classNames) {
    WFOpenFramework(@"/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager");
    SEL selector = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls || ![cls respondsToSelector:selector]) continue;

        NSError *error = nil;
        BOOL existed = NO;
        id container = ((id (*)(id, SEL, id, BOOL, BOOL *, NSError **))objc_msgSend)(cls,
                                                                                     selector,
                                                                                     identifier,
                                                                                     NO,
                                                                                     &existed,
                                                                                     &error);
        NSURL *url = WFGet(container, @"url");
        if ([url isKindOfClass:NSURL.class] && url.path.length > 0) {
            return url.path;
        }
    }
    return nil;
}

// The all-applications list is refused on iOS 27, but asking for one proxy
// by bundle id sometimes still answers with its container URL.
static NSString *WFProxyContainerPath(NSString *identifier, NSString *key) {
    WFOpenFramework(@"/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices");
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:selector]) return nil;
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, selector, identifier);
    if (!proxy) return nil;
    NSURL *url = WFGet(proxy, key);
    if ([url isKindOfClass:NSURL.class] && url.path.length > 0) return url.path;
    return nil;
}

NSString *WFContainerPathForIdentifier(NSString *identifier) {
    if (identifier.length == 0) return nil;
    NSString *path = WFMCMContainerPath(identifier, @[@"MCMAppDataContainer", @"MCMAppContainer"]);
    if (!path) path = WFProxyContainerPath(identifier, @"dataContainerURL");
    if ([path containsString:@"/Bundle/"]) return nil;
    return path;
}

NSString *WFBundlePathForIdentifier(NSString *identifier) {
    if (identifier.length == 0) return nil;
    NSString *path = WFMCMContainerPath(identifier, @[@"MCMAppContainer"]);
    if (!path) path = WFProxyContainerPath(identifier, @"bundleURL");
    if (!path || ![path containsString:@"/Bundle/"]) return nil;
    return path;
}

NSString *WFContainerLookupReport(NSString *identifier) {
    if (identifier.length == 0) return @"no identifier";
    NSString *mcm = WFMCMContainerPath(identifier, @[@"MCMAppDataContainer", @"MCMAppContainer"]);
    NSString *proxy = WFProxyContainerPath(identifier, @"dataContainerURL");
    return [NSString stringWithFormat:@"mcm=%@ proxy=%@",
            mcm ?: @"nil", proxy ?: @"nil"];
}

NSString *WFLocalizedNameAtBundlePath(NSString *bundlePath) {
    if (bundlePath.length == 0) return nil;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    if (![info isKindOfClass:NSDictionary.class]) return nil;

    NSArray<NSString *> *languages = @[@"zh-Hans", @"zh-Hant", @"zh_CN", @"zh-Hans-CN"];
    for (NSString *language in languages) {
        for (NSString *file in @[@"InfoPlist.strings", @"Localizable.strings"]) {
            NSString *path = [[bundlePath stringByAppendingPathComponent:
                               [language stringByAppendingPathExtension:@"lproj"]]
                              stringByAppendingPathComponent:file];
            if (![manager fileExistsAtPath:path]) continue;
            NSDictionary *strings = [NSDictionary dictionaryWithContentsOfFile:path];
            if (![strings isKindOfClass:NSDictionary.class]) continue;
            for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName"]) {
                id value = strings[key];
                if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
            }
        }
    }

    for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName"]) {
        id value = info[key];
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    }
    return nil;
}
