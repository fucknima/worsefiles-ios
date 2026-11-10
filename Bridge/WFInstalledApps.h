//
//  WFInstalledApps.h
//  WorseFiles
//
//  Installed app containers from LaunchServices. The app list is what makes
//  installs and uninstalls visible without walking inodes again: a reused
//  inode no longer hides a freshly installed app, and a removed container is
//  gone from the next snapshot.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns one dictionary per installed app and plugin:
// identifier, dataPath, bundlePath, name, type.
// nil means LaunchServices could not be queried; an empty array is a real
// empty answer and should not be used to prune anything.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> * _Nullable WFInstalledApps(void);

// Last-resort lookup for an app whose proxy has no dataContainerURL.
FOUNDATION_EXPORT NSString * _Nullable WFContainerPathForIdentifier(NSString *identifier);

// Bundle container path, used for localized names and icon files.
FOUNDATION_EXPORT NSString * _Nullable WFBundlePathForIdentifier(NSString *identifier);

// Localized CFBundleDisplayName/CFBundleName from zh-Hans InfoPlist.strings.
// The caller must hold a sandbox extension for the bundle or its parent.
FOUNDATION_EXPORT NSString * _Nullable WFLocalizedNameAtBundlePath(NSString *bundlePath);

// Which path routes answer for a bundle identifier, for the diagnostics view.
FOUNDATION_EXPORT NSString *WFContainerLookupReport(NSString *identifier);

// Which source produced the last WFInstalledApps() answer.
FOUNDATION_EXPORT NSString * _Nullable WFInstalledAppsSource(void);

// Reads an icon from an app bundle's Info.plist, icon files, or Assets.car.
// The caller must hold a sandbox extension for the bundle or its container.
FOUNDATION_EXPORT NSData * _Nullable WFBundleIconData(NSString *bundlePath);

// PNG icon for an installed app. Tries UIKit then the LaunchServices proxy;
// callers fall back to the parent app's icon.
FOUNDATION_EXPORT NSData * _Nullable WFAppIconData(NSString *identifier);

// Human-readable icon resolution details for the diagnostics screen.
FOUNDATION_EXPORT NSString *WFIconReport(NSString *identifier);

NS_ASSUME_NONNULL_END
