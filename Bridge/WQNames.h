//
//  WQNames.h
//  WorseFiles
//
//  App display names from LaunchServices' own CSStore database. The
//  LaunchServices API refuses this app on iOS 27, but lsd keeps the store in
//  an InternalDaemon container that worse_query can read.
//
//  Parser and built-in name table derived from WQ Files by kolbicz,
//  GPL-3.0-or-later: https://github.com/kolbicz/WQFiles
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Parses the newest com.apple.LaunchServices-*.csstore inside
// <container>/Library/Caches. The caller must hold a sandbox extension for
// the container. Returns an empty dictionary when this container has no store.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *WFLaunchServicesNames(NSString *container);

// Apple's own apps and services that only have localized names in the store.
FOUNDATION_EXPORT NSString * _Nullable WFBuiltinAppName(NSString *identifier);

NS_ASSUME_NONNULL_END
