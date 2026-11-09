# WorseFiles / 容器文件

一个基于 [worse_query](https://github.com/forcequitOS/worse_query) 的 iOS 容器文件管理器。SwiftUI，iPhone，中文界面。

浏览 `worse_query` 覆盖的容器路径，读取应用数据、App Group、扩展与系统容器；支持目录进出、排序、搜索、复制/剪切/粘贴、删除、重命名、导入、分享、QuickLook 和文本编辑。需要 App Group entitlement，只在自己的设备上使用。

**这不是越狱，也不会变成越狱。** 只覆盖 `worse_query` 列出的路径，不涉及内核。

## 适用范围

| 项目 | 值 |
| --- | --- |
| 运行系统 | iOS 26.0–26.7.2 / 27.2 |
| 构建目标 | iOS 18.0+，需要能编译 SwiftUI 的 Xcode |
| 设备 | iPhone 真机（`TARGETED_DEVICE_FAMILY = 1`）；模拟器只能验证界面 |
| 必需能力 | App Groups entitlement |
| 签名 | 支持 App Groups 的开发者证书或团队；免费 Apple ID 通常不行 |

低于 iOS 26 也能安装启动，但只剩本应用沙盒与自己的 App Group 可浏览。iOS 27 的系统容器入口只在 27 及以上显示。

## 功能

- 根路径：
  - 应用数据 `/private/var/mobile/Containers/Data/Application`
  - 应用扩展 `/private/var/mobile/Containers/Data/PluginKitPlugin`
  - 系统守护进程 `/private/var/mobile/Containers/Data/InternalDaemon`
  - App 组 `/private/var/mobile/Containers/Shared/AppGroup`
  - iOS 27：`/private/var/containers/Data/System`、`/private/var/containers/Shared/SystemGroup`
  - 本应用沙盒、Documents、App Group 根目录
- 应用数据/扩展/守护进程/系统组的父目录不可列举时，按 inode 扫描发现容器；一次扫描按文件系统分组遍历，同时匹配所有容器根路径，不会为每个入口重复全扫。
- App 组和 iOS 27 系统路径优先直接列举父目录，失败时自动回退到 inode 扫描。
- 读取容器的 `com.apple.containermanager.identifier` 与 `.com.apple.mobile_container_manager.metadata.plist`，把 UUID 行显示成 bundle identifier；扫描后默认自动解析，也可在菜单手动重试或停止。
- 容器行显示 App 名称与图标：名称来自 LaunchServices 的 localizedName，图标来自 iconDataForVariant 并缓存到 Application Support；插件图标回退到父 App。
- 维护 → 清理缓存：安全模式只删 Library/Caches 与 tmp，标准模式再加日志、Saved Application State、SplashBoard；先按 App 汇总可释放空间，确认后删除并重建目录。不含 Documents、App Group、系统容器。
- 备份与恢复：容器或其中任意文件夹可备份到 Documents/Backups；manifest 记录容器 identifier 与容器内相对路径，App 重装换 UUID 后仍能找回新容器。默认跳过缓存，文件优先用 clonefile 克隆，失败回退 copyfile；恢复为同名覆盖。
- 备份可在列表里导出 ZIP（NSFileCoordinator 打包）后分享；备份放在应用自己的 Documents，删除 App 会一起消失。
- 文件操作：新建文件夹、重命名、删除、拷贝、剪切、粘贴、制作副本、导入（文件选择器）、分享（导出到临时目录后交给系统）、QuickLook 预览、2 MB 内文本编辑。
- 多选、全选、目录搜索、隐藏文件开关、按名称/日期/大小/类型排序、文件夹优先。
- 原生 NavigationStack 推入/返回动画和边缘右滑；面包屑从当前导航链开始，点任意一级直接弹回该层。
- 前台自动同步：回到 WorseFiles 时用 LaunchServices 枚举已安装 App/扩展的数据容器，直接补进或移出索引；inode 被卸载释放后又被新 App 复用也能发现。
- 每次同步会对索引里的容器路径做 lstat 校验，只剔除 ENOENT 的项；权限不足的路径保留。
- 诊断日志写入 Documents/WorseFiles.log，可复制、导出，也可在“文件”App 里直接取。
- 设置：App Group 自动检测、扫描后自动识别容器名称、隐藏文件、默认排序、inode 上限、缓存清理、句柄释放、诊断与日志。

## 构建

### GitHub Actions

推送 `main` 后，`.github/workflows/build.yml` 在 macOS 15 runner 上安装 xcodegen、构建未签名 IPA，上传 `worsefiles-unsigned-<sha>` artifact。推 `v*` tag 会创建 release。签名需自己完成。

### 本地

```sh
brew install xcodegen
./scripts/build.sh
```

产物是 `WorseFiles-unsigned.ipa`，未签名。未签名 IPA 不携带已生效的 entitlements；用 SideStore/AltStore 或其他工具重签时，必须把 `App/WorseFiles.entitlements` 里的 App Group 一并授予，否则运行时会提示 App Group 不可用。

### Xcode

```sh
xcodegen generate
open WorseFiles.xcodeproj
```

在 target 的 Signing & Capabilities 里：

1. 选择自己的 Team。
2. 新建一个 App Group（Xcode 会注册到你的账号），例如 `group.com.yourname.worsefiles`。
3. 把 `App/WorseFiles.entitlements` 里的 group 改成自己的值，或保留默认。应用从签名里自动读取 App Group，不需要在应用内填写。用一个只给 WorseFiles 的 App Group，不要和其他 App 或扩展共用：每次容器查询都会删除并重建该组的 `Library/Caches`。
4. 把 `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER` 改成自己唯一的 bundle id；如果已经生成过项目，直接改 target 的 Bundle Identifier。
5. 安装到 iPhone。App Group 由签名描述文件提供，运行时不会弹系统权限框。

应用启动后从自己的代码签名读取 App Groups entitlement，并在设置页显示检测结果。若显示不可用，检查重签是否真的授予了 App Group，而不是去改应用内字段。`worse_query` 在拿不到可用 group 时返回 `-1`。

## 使用

1. 打开“容器文件”。顶部状态显示 App Group 是否可用（从签名自动检测）；版本落在测试区间内才显示“环境就绪”。
2. 点“应用数据”。第一次需要 inode 扫描，进度条会显示当前区间；结果会写进缓存，之后打开先显示缓存，下拉刷新做增量扫描。
3. 扫描完成后会自动逐个读取容器标识，UUID 行会变成 bundle identifier；每个容器需要一次容器查询，所以名称是逐步出现的，可在进度条处停止。已有缓存重新打开根目录也会自动补齐名称，不需要重扫。
4. 长按或左滑文件行：信息、重命名、拷贝/剪切、制作副本、分享、删除；目录还能收藏。底部剪贴板条可粘贴到当前目录。
5. 右上角勾选图标进入多选；底部出现拷贝、剪切、删除、分享。
6. 右上角 `…` 有排序、隐藏文件、导入、收藏、手动识别容器名称、当前目录信息、导出当前目录。
7. 文件点击默认 QuickLook。文本文件可以用“文本编辑”修改，保存直接写回容器。
8. 进入目录和返回使用系统原生推入/返回动画，左边缘右滑也是原生返回；点面包屑任意一级会直接弹回那层。

删除会真实删除容器里的内容，没有回收站。先导出备份。

## 扫描与缓存

`pathleak` 的做法是从 1 开始暴力枚举 inode，用 `fsgetpath` 反查路径，再筛选父目录的直接子项。WorseFiles 把它拆成 40,000 个 inode 一块，用多核并行扫，并把上次扫描到的 inode 水位记在本地。

- 上限默认取“在 App 临时目录新建一个文件后的 inode”。这个值随设备变化，一般比容器目录的最新 inode 只多不少。
- 六个根路径共用一次 inode 遍历和同一个水位；第一个需要扫描的入口全扫，其余入口直接读结果。扫描结果保存在 Application Support/WorseFiles/catalog.json；设置里可清除扫描结果与名称缓存。
- App 回到前台时先同步已安装应用列表，再从上次水位做增量扫描；根目录视图通过通知自动刷新。
- 增量扫描只补 inode 高于水位的容器，不能覆盖 inode 复用；应用列表负责这一块，插件/守护进程仍由扫描补齐。
- 手动填写“inode 上限”会用它替代自动值；设置后下拉刷新会全量扫描 `1…N` 并重建该根路径缓存。填得太小会漏容器，填得太大只是更慢。
- inode 可能被复用；应用容器由 LaunchServices 列表兜底，插件与守护进程容器仍可能落在水位下，极端情况需要清除扫描结果再全扫。
- 已存在的缓存不会每次全量重扫；前台同步只补应用容器并校验失效项，完整的容器发现仍靠增量扫描或清除后全扫。
- 卸载后容器消失，下一次前台同步会用 lstat 把它从索引和名称缓存里剔除；SystemGroup 等无法 stat 的路径只在确认 ENOENT 时移除。
- 恢复需要目标 App 仍然安装；卸载后只剩备份，重装后按 bundle identifier 找回新容器路径再恢复。
- 清理与备份都不修改 App Group、系统容器；清理会重建被删的 Caches/tmp 目录，恢复不删除目标里备份之外的文件。

## 原理

`worse_query` 通过 `libsystem_containermanager` 创建 class 7（appGroup）查询，把 App Group 的 `Library/Caches` 换成指向目标路径的符号链接，让 containermanagerd 为解析后的目标签发 sandbox extension，再 `sandbox_extension_consume`。

WorseFiles 在它的外面加了两层：

- `SandboxBroker`：最多缓存 6 个扩展句柄，串行化查询，按 LRU 释放。所有文件操作都先确保目标（或父目录）的扩展已消费。
- `FileService`：单串行队列，避免扫描/粘贴/删除交错；导出到临时目录后再给 QuickLook 或分享面板，避免系统组件持有被回收的沙盒路径。

**重要副作用：** 每次调用都会删除并重建 App Group 的 `Library/Caches`。不要往这个目录放持久数据。WorseFiles 的缓存放在自己的 Application Support，不在 App Group。

## 边界

- 只访问 `worse_query` 能返回扩展的路径；`/var/containers/Bundle/Application` 不在范围内。
- 父目录扩展取决于系统版本与容器类型；失败时只能靠 inode 扫描发现子项。iOS 27 的 `/private/var/containers/Shared/SystemGroup` 父目录拿不到扩展，因此“系统组”改为扫描策略；能扫到子容器不等于父目录可列举。扫描发现路径也不等于一定拿得到扩展，进入失败会显示错误。
- 沙盒扩展可能按路径签发。读取、预览、导出单个文件时会分别尝试目标路径与父目录；目录递归复制/导出仍依赖目录扩展覆盖子树，失败会明确报错。
- 文本编辑上限 2 MB；超过时只读显示前 2 MB，保存禁用，避免截断。
- 预览和分享会把目标复制到 App 临时目录，大目录/大文件会占磁盘并耗时。
- 自动识别名称会对每个容器消费一次 sandbox extension；容器很多时会持续一段时间，可在设置里关闭或点进度条的停止。离开目录（推入子目录或返回主页）会暂停当前识别，回来再继续，避免多个根目录同时刷容器查询。
- 日志文件在应用自己的 Documents（不是 App Group），会保留历史并在 1.5 MB 时轮转；诊断页可复制/导出。
- App Group 由签名授予，应用只读取、不要求填写；没有该 entitlement 的签名无法使用容器路径。
- 没有网络、上传、越狱、内核利用或绕过签名。
- 不保证在所有 26.x/27.x 小版本上都能拿到扩展；`worse_query` 本身有版本窗口。

## 文件结构

```
App/        SwiftUI 界面、入口、设置、诊断、QuickLook/分享/文件选择器
Engine/     沙盒句柄、文件服务、inode 扫描、目录缓存、模型、排序
Bridge/     worse_query / pathleak 原文件，加 pathleak_range
Resources/  AppIcon、AccentColor
scripts/    build.sh
project.yml xcodegen 工程描述
```

## 许可

GPL-3.0。`worse_query` 与 `pathleak` © 2026 Taj C (forcequit)，GPL-3.0；`pathleak_range.m` 是 `pathleak.m` 的派生文件。完整声明见 `NOTICE`，许可证全文见 `LICENSE`。

与 Apple、forcequitOS 无隶属关系。仅供自己的设备、开发和调试使用。
