//
//  AppCatalog.swift
//  WorseFiles
//
//  The data root contains every data container, including services and
//  extensions. An app row needs a top-level .app bundle from the same
//  LaunchServices store; everything else is a service container. Splitting
//  the list here keeps the browser honest without hiding the raw containers:
//  the "all" scope still shows every row.
//

import Foundation
import Combine

extension Notification.Name {
    static let worseFilesAppCatalogUpdated = Notification.Name("WorseFilesAppCatalogUpdated")
}

enum AppDataKind: String, CaseIterable, Identifiable, Hashable {
    case user
    case system
    case service

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user: return "用户 App"
        case .system: return "系统 App"
        case .service: return "服务与扩展"
        }
    }

    var shortTitle: String {
        switch self {
        case .user: return "用户"
        case .system: return "系统"
        case .service: return "服务"
        }
    }
}

enum AppDataScope: String, CaseIterable, Identifiable {
    case user
    case system
    case service
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user: return "用户"
        case .system: return "系统"
        case .service: return "服务"
        case .all: return "全部"
        }
    }

    func contains(_ kind: AppDataKind) -> Bool {
        switch self {
        case .user: return kind == .user
        case .system: return kind == .system
        case .service: return kind == .service
        case .all: return true
        }
    }
}

struct AppDataSection: Identifiable {
    let kind: AppDataKind
    let items: [FSItem]
    var id: AppDataKind { kind }
}

@MainActor
final class AppCatalog: ObservableObject {
    static let shared = AppCatalog()

    @Published private(set) var revision = 0

    private var containerBundleIDs: [String: String] = [:]
    private var bundlePaths: [String: String] = [:]

    var hasMaps: Bool { !containerBundleIDs.isEmpty || !bundlePaths.isEmpty }

    private init() {}

    func setMaps(containerBundleIDs: [String: String], bundlePaths: [String: String]) {
        guard containerBundleIDs != self.containerBundleIDs || bundlePaths != self.bundlePaths else {
            return
        }
        self.containerBundleIDs = containerBundleIDs
        self.bundlePaths = bundlePaths
        revision += 1
        NotificationCenter.default.post(name: .worseFilesAppCatalogUpdated, object: nil)
        Log.info("app catalog: \(containerBundleIDs.count) containers, \(bundlePaths.count) bundle paths")
    }

    func kind(forContainerPath path: String) -> AppDataKind {
        let key = PathTool.canonical(path)
        let identifier = Catalog.shared.label(for: key)
            ?? containerBundleIDs[key]
            ?? containerBundleIDs[path]
        guard let identifier, !identifier.isEmpty else { return .service }
        let bundlePath = bundlePaths[identifier]
        return Self.classify(identifier: identifier, bundlePath: bundlePath)
    }

    func identifier(forContainerPath path: String) -> String? {
        let key = PathTool.canonical(path)
        if let label = Catalog.shared.label(for: key) { return label }
        return containerBundleIDs[key] ?? containerBundleIDs[path]
    }

    func bundlePath(for identifier: String) -> String? {
        bundlePaths[identifier]
    }

    func counts(for paths: [String]) -> [AppDataKind: Int] {
        var result: [AppDataKind: Int] = [:]
        for path in paths {
            let kind = kind(forContainerPath: path)
            result[kind, default: 0] += 1
        }
        return result
    }

    func dataRootCounts() -> [AppDataKind: Int] {
        let paths = Catalog.shared.scanRecord(for: Roots.dataApplication.path)?.paths ?? []
        return counts(for: paths)
    }

    private static func classify(identifier: String, bundlePath: String?) -> AppDataKind {
        guard let raw = bundlePath, !raw.isEmpty else { return approximate(identifier) }
        var path = raw
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasSuffix(".app"), !path.contains(".app/") else { return .service }

        if path.hasPrefix("/private/var/containers/Bundle/Application/")
            || path.hasPrefix("/var/containers/Bundle/Application/") {
            // Installed into the user bundle container, including Apple apps
            // downloaded from the App Store.
            return .user
        }
        if path.hasPrefix("/Applications/")
            || path.hasPrefix("/System/Applications/")
            || path.hasPrefix("/private/preboot/")
            || path.contains("/Cryptexes/") {
            return .system
        }
        // A top-level .app outside the known roots is an Apple internal app.
        return identifier.hasPrefix("com.apple.") ? .system : .user
    }

    // When the store maps a container but not its bundle, prefer showing a
    // third-party app over hiding it as a service. Apple ids and obvious
    // extension names stay services; everything else is an approximate user.
    private static func approximate(_ identifier: String) -> AppDataKind {
        if identifier.hasPrefix("com.apple.") { return .service }
        let lower = identifier.lowercased()
        let serviceWords = [".appex", ".extension", ".widget", ".keyboard", ".share",
                            ".service", ".plugin", ".notification", ".intent", ".siri",
                            "remoteuiservice", "proxyservice", "spotlight"]
        if serviceWords.contains(where: { lower.contains($0) }) { return .service }
        return .user
    }
}
