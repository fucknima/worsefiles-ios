//
//  WFInstalledApps.m
//  WorseFiles
//
//  LSApplicationWorkspace lives in MobileCoreServices on iOS. It is loaded
//  with dlopen so the app has no link-time dependency on the private
//  framework, and every property is read through respondsToSelector because
//  the class has changed shape across releases.
//

#import "WFInstalledApps.h"
#import <objc/message.h>
#import <dlfcn.h>

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

static id WFWorkspace(void) {
    WFOpenFramework(@"/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices");
    WFOpenFramework(@"/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices");
    WFOpenFramework(@"/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices");
    WFOpenFramework(@"/System/Library/Frameworks/CoreServices.framework/CoreServices");

    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls || ![cls respondsToSelector:@selector(defaultWorkspace)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(defaultWorkspace));
}

static NSArray *WFAllApplications(id workspace) {
    for (NSString *name in @[@"allApplications", @"allInstalledApplications"]) {
        id value = WFGet(workspace, name);
        if ([value isKindOfClass:NSArray.class] && [value count] > 0) {
            return value;
        }
    }
    return nil;
}

NSArray<NSDictionary<NSString *, id> *> *WFInstalledApps(void) {
    id workspace = WFWorkspace();
    if (!workspace) return nil;

    NSArray *proxies = WFAllApplications(workspace);
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

        // PluginKit containers belong to extensions, not to the app proxy.
        // Newer LaunchServices exposes their data container on the plugin
        // proxy; when it does not, the inode delta still covers them.
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

    return result;
}

static id WFProxyForIdentifier(NSString *identifier) {
    id workspace = WFWorkspace();
    if (workspace) {
        SEL selector = NSSelectorFromString(@"applicationsWithBundleIdentifier:");
        if ([workspace respondsToSelector:selector]) {
            id apps = ((id (*)(id, SEL, id))objc_msgSend)(workspace, selector, identifier);
            if ([apps isKindOfClass:NSArray.class] && [apps count] > 0) {
                return [apps firstObject];
            }
        }
    }

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [proxyClass respondsToSelector:proxySelector]) {
        return ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySelector, identifier);
    }
    return nil;
}

NSData *WFAppIconData(NSString *identifier) {
    if (identifier.length == 0) return nil;
    id proxy = WFProxyForIdentifier(identifier);
    if (!proxy) return nil;

    SEL selector = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:selector]) return nil;
    for (NSNumber *variant in @[@2, @1, @0, @3]) {
        id data = ((id (*)(id, SEL, int))objc_msgSend)(proxy, selector, variant.intValue);
        if ([data isKindOfClass:NSData.class] && [data length] > 0) {
            return data;
        }
    }
    return nil;
}

NSString *WFContainerPathForIdentifier(NSString *identifier) {
    if (identifier.length == 0) return nil;

    WFOpenFramework(@"/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager");

    SEL selector = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
    for (NSString *className in @[@"MCMAppContainer", @"MCMAppDataContainer"]) {
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
