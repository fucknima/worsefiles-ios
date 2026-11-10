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

static BOOL WFHasCJK(NSString *string) {
    for (NSUInteger index = 0; index < string.length; index++) {
        unichar character = [string characterAtIndex:index];
        if (character >= 0x4E00 && character <= 0x9FFF) return YES;
    }
    return NO;
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

        if (WFGoodName(displayName)) {
            NSString *old = display[identifier];
            if (!old || (!WFHasCJK(old) && WFHasCJK(displayName))) {
                display[identifier] = displayName;
            }
        }
        if (WFGoodName(name)) {
            NSString *old = bundleName[identifier];
            if (!old || (!WFHasCJK(old) && WFHasCJK(name))) {
                bundleName[identifier] = name;
            }
        }
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
            @"com.apple.weather": @"天气", @"com.apple.news": @"新闻",
            @"com.apple.stocks": @"股市", @"com.apple.mobilemail": @"邮件",
            @"com.apple.MobileSMS": @"信息", @"com.apple.mobilephone": @"电话",
            @"com.apple.mobileslideshow": @"照片", @"com.apple.camera": @"相机",
            @"com.apple.mobilecal": @"日历", @"com.apple.mobilenotes": @"备忘录",
            @"com.apple.reminders": @"提醒事项", @"com.apple.Maps": @"地图",
            @"com.apple.Music": @"音乐", @"com.apple.tv": @"视频",
            @"com.apple.podcasts": @"播客", @"com.apple.iBooks": @"图书",
            @"com.apple.Health": @"健康", @"com.apple.Passbook": @"钱包",
            @"com.apple.Preferences": @"设置", @"com.apple.mobiletimer": @"时钟",
            @"com.apple.calculator": @"计算器", @"com.apple.compass": @"指南针",
            @"com.apple.VoiceMemos": @"语音备忘录", @"com.apple.facetime": @"FaceTime",
            @"com.apple.MobileAddressBook": @"通讯录", @"com.apple.DocumentsApp": @"文件",
            @"com.apple.findmy": @"查找", @"com.apple.Home": @"家庭",
            @"com.apple.shortcuts": @"快捷指令", @"com.apple.Translate": @"翻译",
            @"com.apple.Fitness": @"健身", @"com.apple.Bridge": @"Watch",
            @"com.apple.freeform": @"无边记", @"com.apple.journal": @"手记",
            @"com.apple.Passwords": @"密码", @"com.apple.measure": @"测距仪",
            @"com.apple.Magnifier": @"放大器", @"com.apple.tips": @"提示",
            @"com.apple.siri": @"Siri", @"com.apple.games": @"游戏",
            @"com.apple.gamecenter": @"游戏中心", @"com.apple.Image-Playground": @"图像游乐场",
            @"com.apple.Keynote": @"Keynote 讲演", @"com.apple.Pages": @"Pages 文稿",
            @"com.apple.Numbers": @"Numbers 表格", @"com.apple.mobileme.fmip1": @"查找 iPhone",
            @"com.apple.store.Jolly": @"Apple Store", @"com.apple.supportapp": @"Apple 支持",
            @"com.apple.Diagnostics": @"诊断", @"com.apple.PosterBoard": @"壁纸",
            @"com.apple.MercuryPoster": @"壁纸（Mercury）",
            @"com.apple.WallpaperKit.CollectionsPoster": @"壁纸合集",
            @"com.apple.PhotosUIPrivate.PhotosPosterProvider": @"照片壁纸",
            @"com.apple.chrono.WidgetRenderer-Default": @"小组件",
            @"com.apple.ScreenshotServicesService": @"截屏",
            @"com.apple.Sharing.AirDrop": @"隔空投送",
            @"com.apple.AppleMediaServicesUI": @"Apple 媒体服务",
            @"com.apple.AppleMediaServices": @"Apple 媒体服务",
            @"com.apple.ClarityCamera": @"辅助使用相机",
            @"com.apple.ClarityPhotos": @"辅助使用照片",
            @"com.apple.SystemVoiceAssistant": @"语音助手",
            @"com.apple.ShazamEventsApp": @"Shazam",
            @"com.apple.ScreenTimeWidgetApplication": @"屏幕使用时间",
            @"com.apple.CBRemoteSetup": @"远程设置", @"com.apple.DemoApp": @"演示",
            @"com.apple.AAUIViewService": @"Apple 账户",
            @"com.apple.AccountAuthenticationDialog": @"账户登录",
            @"com.apple.StoreKitUISceneService": @"App Store 表单",
            @"com.apple.NewDeviceOutreachApp": @"新设备设置",
            @"com.apple.PDUIApp": @"打印", @"com.apple.EventViewService": @"事件",
            @"com.apple.MXUIService": @"媒体选择器", @"com.apple.ctkui": @"智能卡",
            @"com.apple.InCallService": @"来电界面", @"com.apple.springboard": @"主屏幕",
            @"com.apple.SafariViewService": @"Safari 视图",
            @"com.apple.mobilesms.compose": @"编写信息",
            @"com.apple.CompanionViewService": @"伴侣",
            @"com.apple.musicrecognition": @"音乐识别",
            @"com.apple.FontInstallViewService": @"字体安装",
            @"com.apple.CMViewSrvc": @"连续互通标记",
            @"com.apple.AppleCashStickerPackHost": @"Apple Cash 贴纸",
            @"com.apple.TVSetupUIService": @"Apple TV 设置", @"com.apple.HearingApp": @"听觉",
            @"com.apple.CompanionSetup": @"伴侣设置",
            @"com.apple.CarPlayWallpaper": @"CarPlay 壁纸",
            @"com.apple.CloudKit.ShareBear": @"iCloud 共享",
            @"com.apple.EnhancedLogging": @"增强日志",
            @"com.apple.tcc.AuthorizationPromptService": @"隐私提示",
            @"com.apple.WebContentFilter.remoteUI.WebContentAnalysisUI": @"内容过滤",
            @"com.apple.SystemPaperViewService": @"快速备忘录",
            @"com.apple.HeadphoneProxService": @"耳机",
            @"com.apple.datadetectors.DDActionsService": @"数据检测器",
            @"com.apple.ServicesPaymentAngel": @"Apple Pay",
            @"com.apple.HomeCaptiveViewService": @"Wi-Fi 登录",
            @"com.apple.DiagnosticsService": @"诊断",
            @"com.apple.CarTirePressure": @"胎压",
            @"com.apple.FCAuthenticationUI": @"认证",
            @"com.apple.icloud.FindMyDevice.FindMyExtensionContainer": @"查找",
            @"com.apple.messages.RemoteAlerts": @"信息提醒",
            @"com.apple.AccessoryNotifications.SourceSelection": @"配件来源",
            @"com.apple.printcenter": @"打印中心", @"com.apple.BarcodeScanner": @"扫描代码",
            @"com.apple.chrono.WidgetRenderer-Snapshots": @"小组件快照",
            @"com.apple.AMSEngagementViewService": @"Apple 媒体服务",
            @"com.apple.appManagedFeatures.Restrictions": @"限制",
            @"com.apple.CarRadio": @"车载收音机", @"com.apple.PassbookUIService": @"钱包表单",
            @"com.apple.Spotlight": @"聚焦", @"com.apple.InputUI": @"键盘",
        };
    });
    return names[identifier];
}
