//
//  WQNames.m
//  WorseFiles
//
//  CSStore2 layout used here was documented by WQ Files: Bundle records are
//  0x250 bytes, preceded by [u32][u32 0x250]. At +0x0c, +0x6c, +0x74 are
//  string references (string id << 2) for bundle id, bundle name and display
//  name. Strings are [u32 id][u32 length][UTF-8][NUL].
//
//  Derived from WQAccess.m in WQ Files by kolbicz, GPL-3.0-or-later.
//

#import "WQNames.h"
#include <stdlib.h>
#include <string.h>

static NSString *const kWQNamesStoreKey = @"WorseFiles.launchServicesStore";

static uint32_t WFRead32(const uint8_t *p) {
    uint32_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static NSString *WFCSString(const uint8_t *bytes, size_t count, size_t offset) {
    if (offset + 8 > count) return nil;
    uint32_t length = WFRead32(bytes + offset + 4);
    if (length == 0 || length >= 0x800) return nil;
    if (offset + 8 + (size_t)length >= count) return nil;
    if (bytes[offset + 8 + length] != 0) return nil;
    if (memchr(bytes + offset + 8, 0, length) != NULL) return nil;

    NSString *string = [[NSString alloc] initWithBytes:bytes + offset + 8
                                                length:length
                                              encoding:NSUTF8StringEncoding];
    if (!string) return nil;
    if ([string rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        return nil;
    }
    return string;
}

static BOOL WFLooksLikeBundleID(NSString *string) {
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
    });
    return string.length > 2
        && [string containsString:@"."]
        && ![string hasPrefix:@"."]
        && [string rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static BOOL WFGoodName(NSString *string) {
    return string.length > 0
        && ![string hasPrefix:@"/"]
        && ![string containsString:@".app/"];
}

static NSDictionary<NSString *, NSString *> *WFParseStore(NSData *data) {
    const uint8_t *bytes = data.bytes;
    size_t count = data.length;
    if (count < 0x1000 || memcmp(bytes, "bdsl", 4) != 0) return @{};

    NSRange heapRange = [data rangeOfData:[NSData dataWithBytes:"<string>" length:8]
                                  options:0
                                    range:NSMakeRange(0, count)];
    size_t heap = heapRange.location == NSNotFound ? 0 : heapRange.location;

    const size_t kIDs = 0x1000000;
    uint8_t *needed = calloc(kIDs / 8, 1);
    uint8_t *inHeap = calloc(kIDs / 8, 1);
    if (!needed || !inHeap) {
        free(needed);
        free(inHeap);
        return @{};
    }

    NSMutableData *records = [NSMutableData data];
    for (size_t offset = 0; offset + 8 + 0x250 <= count; offset += 4) {
        if (WFRead32(bytes + offset + 4) != 0x250) continue;
        const uint8_t *unit = bytes + offset + 8;
        uint32_t refs[3] = {
            WFRead32(unit + 0x0c),
            WFRead32(unit + 0x6c),
            WFRead32(unit + 0x74),
        };
        if (!refs[0] || (refs[0] & 3) || (refs[0] >> 2) >= kIDs) continue;

        [records appendBytes:refs length:sizeof(refs)];
        for (int index = 0; index < 3; index++) {
            uint32_t ref = refs[index];
            if (ref && !(ref & 3) && (ref >> 2) < kIDs) {
                needed[(ref >> 2) / 8] |= 1 << ((ref >> 2) % 8);
            }
        }
    }

    NSMutableDictionary<NSNumber *, NSString *> *strings = [NSMutableDictionary dictionary];
    for (size_t offset = 0; offset + 8 < count; offset += 4) {
        uint32_t stringID = WFRead32(bytes + offset);
        if (!stringID || stringID >= kIDs) continue;
        if (!(needed[stringID / 8] & (1 << (stringID % 8)))) continue;

        BOOL here = offset >= heap;
        BOOL had = strings[@(stringID)] != nil;
        if (had && (!here || (inHeap[stringID / 8] & (1 << (stringID % 8))))) continue;

        NSString *string = WFCSString(bytes, count, offset);
        if (!string) continue;
        strings[@(stringID)] = string;
        if (here) inHeap[stringID / 8] |= 1 << (stringID % 8);
    }

    free(needed);
    free(inHeap);

    NSMutableDictionary<NSString *, NSString *> *display = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *bundleName = [NSMutableDictionary dictionary];
    const uint32_t *refs = records.bytes;
    for (NSUInteger index = 0; index < records.length / sizeof(uint32_t); index += 3) {
        NSString *identifier = strings[@(refs[index] >> 2)];
        if (!WFLooksLikeBundleID(identifier)) continue;

        NSString *name = (refs[index + 1] & 3) ? nil : strings[@(refs[index + 1] >> 2)];
        NSString *displayName = (refs[index + 2] & 3) ? nil : strings[@(refs[index + 2] >> 2)];

        if (WFGoodName(displayName) && !display[identifier]) display[identifier] = displayName;
        if (WFGoodName(name) && !bundleName[identifier]) bundleName[identifier] = name;
    }

    for (NSString *identifier in bundleName) {
        if (!display[identifier]) display[identifier] = bundleName[identifier];
    }
    return display;
}

static NSString *WFFindStoreInContainer(NSString *container) {
    NSString *caches = [container stringByAppendingPathComponent:@"Library/Caches"];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [manager contentsOfDirectoryAtPath:caches error:nil];
    if (!entries) return nil;

    NSString *best = nil;
    NSDate *bestDate = nil;
    for (NSString *name in entries) {
        if (![name hasPrefix:@"com.apple.LaunchServices-"]) continue;
        if (![name hasSuffix:@".csstore"]) continue;
        NSString *path = [caches stringByAppendingPathComponent:name];
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
        NSDate *date = attributes[NSFileModificationDate];
        if (!best || (date && (!bestDate || [date compare:bestDate] == NSOrderedDescending))) {
            best = path;
            bestDate = date;
        }
    }
    return best;
}

NSDictionary<NSString *, NSString *> *WFLaunchServicesNames(NSString *container) {
    if (container.length == 0) return @{};

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *cached = [defaults stringForKey:kWQNamesStoreKey];
    NSFileManager *manager = NSFileManager.defaultManager;

    if (cached.length && [manager fileExistsAtPath:cached]) {
        NSData *data = [NSData dataWithContentsOfFile:cached];
        NSDictionary *names = nil;
        if (data) {
            @autoreleasepool { names = WFParseStore(data); }
        }
        if (names.count > 0) return names;
        [defaults removeObjectForKey:kWQNamesStoreKey];
    }

    NSString *path = WFFindStoreInContainer(container);
    if (!path) return @{};
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length < 0x1000) return @{};

    NSDictionary *names = nil;
    @autoreleasepool { names = WFParseStore(data); }
    if (names.count > 0) {
        [defaults setObject:path forKey:kWQNamesStoreKey];
    }
    return names;
}

NSString *WFBuiltinAppName(NSString *identifier) {
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @"com.apple.AppStore": @"App Store", @"com.apple.mobilesafari": @"Safari",
            @"com.apple.weather": @"Weather", @"com.apple.news": @"News",
            @"com.apple.stocks": @"Stocks", @"com.apple.mobilemail": @"Mail",
            @"com.apple.MobileSMS": @"Messages", @"com.apple.mobilephone": @"Phone",
            @"com.apple.mobileslideshow": @"Photos", @"com.apple.camera": @"Camera",
            @"com.apple.mobilecal": @"Calendar", @"com.apple.mobilenotes": @"Notes",
            @"com.apple.reminders": @"Reminders", @"com.apple.Maps": @"Maps",
            @"com.apple.Music": @"Music", @"com.apple.tv": @"TV",
            @"com.apple.podcasts": @"Podcasts", @"com.apple.iBooks": @"Books",
            @"com.apple.Health": @"Health", @"com.apple.Passbook": @"Wallet",
            @"com.apple.Preferences": @"Settings", @"com.apple.mobiletimer": @"Clock",
            @"com.apple.calculator": @"Calculator", @"com.apple.compass": @"Compass",
            @"com.apple.VoiceMemos": @"Voice Memos", @"com.apple.facetime": @"FaceTime",
            @"com.apple.MobileAddressBook": @"Contacts", @"com.apple.DocumentsApp": @"Files",
            @"com.apple.findmy": @"Find My", @"com.apple.Home": @"Home",
            @"com.apple.shortcuts": @"Shortcuts", @"com.apple.Translate": @"Translate",
            @"com.apple.Fitness": @"Fitness", @"com.apple.Bridge": @"Watch",
            @"com.apple.freeform": @"Freeform", @"com.apple.journal": @"Journal",
            @"com.apple.Passwords": @"Passwords", @"com.apple.measure": @"Measure",
            @"com.apple.Magnifier": @"Magnifier", @"com.apple.tips": @"Tips",
            @"com.apple.siri": @"Siri", @"com.apple.games": @"Games",
            @"com.apple.gamecenter": @"Game Center", @"com.apple.Image-Playground": @"Image Playground",
            @"com.apple.Keynote": @"Keynote", @"com.apple.Pages": @"Pages",
            @"com.apple.Numbers": @"Numbers", @"com.apple.mobileme.fmip1": @"Find iPhone",
            @"com.apple.store.Jolly": @"Apple Store", @"com.apple.supportapp": @"Apple Support",
            @"com.apple.Diagnostics": @"Diagnostics", @"com.apple.PosterBoard": @"Wallpaper",
            @"com.apple.MercuryPoster": @"Wallpaper (Mercury)",
            @"com.apple.WallpaperKit.CollectionsPoster": @"Wallpaper Collections",
            @"com.apple.PhotosUIPrivate.PhotosPosterProvider": @"Photo Wallpaper",
            @"com.apple.chrono.WidgetRenderer-Default": @"Widgets",
            @"com.apple.ScreenshotServicesService": @"Screenshots",
            @"com.apple.Sharing.AirDrop": @"AirDrop",
            @"com.apple.AppleMediaServicesUI": @"Apple Media Services",
            @"com.apple.AppleMediaServices": @"Apple Media Services",
            @"com.apple.ClarityCamera": @"Assistive Access Camera",
            @"com.apple.ClarityPhotos": @"Assistive Access Photos",
            @"com.apple.SystemVoiceAssistant": @"Voice Assistant",
            @"com.apple.ShazamEventsApp": @"Shazam",
            @"com.apple.ScreenTimeWidgetApplication": @"Screen Time",
            @"com.apple.CBRemoteSetup": @"Remote Setup", @"com.apple.DemoApp": @"Demo",
            @"com.apple.AAUIViewService": @"Apple Account",
            @"com.apple.AccountAuthenticationDialog": @"Account Sign-In",
            @"com.apple.StoreKitUISceneService": @"App Store Sheets",
            @"com.apple.NewDeviceOutreachApp": @"New Device Setup",
            @"com.apple.PDUIApp": @"Printing", @"com.apple.EventViewService": @"Events",
            @"com.apple.MXUIService": @"Media Picker", @"com.apple.ctkui": @"Smart Card",
            @"com.apple.InCallService": @"Call Screen", @"com.apple.springboard": @"SpringBoard",
            @"com.apple.SafariViewService": @"Safari View",
            @"com.apple.mobilesms.compose": @"Message Compose",
            @"com.apple.CompanionViewService": @"Companion",
            @"com.apple.musicrecognition": @"Music Recognition",
            @"com.apple.FontInstallViewService": @"Font Install",
            @"com.apple.CMViewSrvc": @"Continuity Markup",
            @"com.apple.AppleCashStickerPackHost": @"Apple Cash Stickers",
            @"com.apple.TVSetupUIService": @"Apple TV Setup", @"com.apple.HearingApp": @"Hearing",
            @"com.apple.CompanionSetup": @"Companion Setup",
            @"com.apple.CarPlayWallpaper": @"CarPlay Wallpaper",
            @"com.apple.CloudKit.ShareBear": @"iCloud Sharing",
            @"com.apple.EnhancedLogging": @"Enhanced Logging",
            @"com.apple.tcc.AuthorizationPromptService": @"Privacy Prompts",
            @"com.apple.WebContentFilter.remoteUI.WebContentAnalysisUI": @"Content Filter",
            @"com.apple.SystemPaperViewService": @"Quick Note",
            @"com.apple.HeadphoneProxService": @"Headphones",
            @"com.apple.datadetectors.DDActionsService": @"Data Detectors",
            @"com.apple.ServicesPaymentAngel": @"Apple Pay",
            @"com.apple.HomeCaptiveViewService": @"Wi-Fi Login",
            @"com.apple.DiagnosticsService": @"Diagnostics",
            @"com.apple.CarTirePressure": @"Tire Pressure",
            @"com.apple.FCAuthenticationUI": @"Authentication",
            @"com.apple.icloud.FindMyDevice.FindMyExtensionContainer": @"Find My",
            @"com.apple.messages.RemoteAlerts": @"Messages Alerts",
            @"com.apple.AccessoryNotifications.SourceSelection": @"Accessory Source",
            @"com.apple.printcenter": @"Print Center", @"com.apple.BarcodeScanner": @"Code Scanner",
            @"com.apple.chrono.WidgetRenderer-Snapshots": @"Widget Snapshots",
            @"com.apple.AMSEngagementViewService": @"Apple Media Services",
            @"com.apple.appManagedFeatures.Restrictions": @"Restrictions",
            @"com.apple.CarRadio": @"Car Radio", @"com.apple.PassbookUIService": @"Wallet Sheets",
            @"com.apple.Spotlight": @"Spotlight", @"com.apple.InputUI": @"Keyboard",
        };
    });
    return names[identifier];
}
