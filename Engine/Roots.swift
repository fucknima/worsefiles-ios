//
//  Roots.swift
//  WorseFiles
//

import Foundation

struct RootSpec: Identifiable, Hashable {
    enum Access: String {
        // Enumerate the parent directory with a sandbox extension.
        case list
        // The parent cannot be listed, so brute force child paths by inode.
        case scan
    }

    let path: String
    let title: String
    let subtitle: String
    let symbol: String
    let access: Access
    let requiresIOS27: Bool

    var id: String { path }
}

enum Roots {
    static let dataApplication = RootSpec(
        path: "/private/var/mobile/Containers/Data/Application",
        title: "应用数据",
        subtitle: "每个 App 的 Documents、Library 与 tmp",
        symbol: "square.stack.3d.up.fill",
        access: .scan,
        requiresIOS27: false
    )

    static let pluginKit = RootSpec(
        path: "/private/var/mobile/Containers/Data/PluginKitPlugin",
        title: "应用扩展",
        subtitle: "PluginKit 扩展容器",
        symbol: "puzzlepiece.extension.fill",
        access: .scan,
        requiresIOS27: false
    )

    static let internalDaemon = RootSpec(
        path: "/private/var/mobile/Containers/Data/InternalDaemon",
        title: "系统守护进程",
        subtitle: "InternalDaemon 容器",
        symbol: "gearshape.2.fill",
        access: .scan,
        requiresIOS27: false
    )

    static let appGroup = RootSpec(
        path: "/private/var/mobile/Containers/Shared/AppGroup",
        title: "App 组",
        subtitle: "多个 App 共享的 App Group 容器",
        symbol: "person.2.fill",
        access: .list,
        requiresIOS27: false
    )

    static let systemData27 = RootSpec(
        path: "/private/var/containers/Data/System",
        title: "系统数据",
        subtitle: "iOS 27 系统容器",
        symbol: "externaldrive.fill",
        access: .list,
        requiresIOS27: true
    )

    static let systemGroup27 = RootSpec(
        path: "/private/var/containers/Shared/SystemGroup",
        title: "系统组",
        subtitle: "iOS 27 SystemGroup 容器（inode 扫描）",
        symbol: "rectangle.3.group.fill",
        access: .scan,
        requiresIOS27: true
    )

    static var majorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    static var isIOS27OrLater: Bool { majorVersion >= 27 }

    static var escapeSupported: Bool { majorVersion >= 26 }

    // The window worse_query documents. Outside it the app still tries, but
    // the UI says so instead of claiming support.
    static var testedWindow: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        switch version.majorVersion {
        case 26:
            return version.minorVersion < 7 || (version.minorVersion == 7 && version.patchVersion <= 2)
        case 27:
            return version.minorVersion <= 2
        default:
            return false
        }
    }

    // Builds are only exercised on iOS 27.0.1. Everything else inside the
    // documented window is best effort, and the UI must not imply otherwise.
    static var verifiedVersion: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == 27
            && version.minorVersion == 0
            && version.patchVersion == 1
    }

    static var all: [RootSpec] {
        var specs = [dataApplication, pluginKit, internalDaemon, appGroup]
        if isIOS27OrLater {
            specs.append(systemData27)
            specs.append(systemGroup27)
        }
        return specs
    }

    static var containerParents: [String] {
        all.map { PathTool.canonical($0.path) }
    }

    static func spec(for path: String) -> RootSpec? {
        let key = PathTool.canonical(path)
        return all.first { PathTool.canonical($0.path) == key }
    }

    static func isContainerParent(_ path: String) -> Bool {
        spec(for: path) != nil
    }

    static var ownSandbox: String {
        PathTool.canonical(NSHomeDirectory())
    }
}
