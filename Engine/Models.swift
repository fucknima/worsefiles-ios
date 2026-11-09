//
//  Models.swift
//  WorseFiles
//

import Foundation

struct FSItem: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date?
    var identifier: String?
    var appName: String? = nil
    var iconData: Data? = nil

    var id: String { path }

    var url: URL { URL(fileURLWithPath: path) }

    var displayName: String {
        if let appName, !appName.isEmpty { return appName }
        if let identifier, !identifier.isEmpty { return identifier }
        return name
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name
    case modified
    case size
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .modified: return "修改时间"
        case .size: return "大小"
        case .kind: return "类型"
        }
    }
}

struct SortOrder: Equatable {
    var key: SortKey = .name
    var ascending = true
    var foldersFirst = true
}

struct FileInfo {
    let path: String
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let readable: Bool
    let size: Int64
    let itemCount: Int?
    let created: Date?
    let modified: Date?
    let permissions: String
    let owner: Int
    let group: Int
    let inode: UInt64
    let linkCount: Int
    let identifier: String?
    let symlinkTarget: String?
}

struct ClipboardItem: Equatable {
    var paths: [String]
    var moving: Bool
}

struct ScanStatus: Equatable {
    var done: UInt64
    var total: UInt64
    var started: Date

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(done) / Double(total))
    }
}

struct BrowseTarget: Hashable {
    let path: String
    let title: String?
}

struct OpFailures {
    var done = 0
    var messages: [String] = []

    var failed: Int { messages.count }

    var summary: String {
        if messages.isEmpty { return "完成 \(done) 项" }
        if done == 0 { return messages.first ?? "操作失败" }
        return "完成 \(done) 项，失败 \(failed) 项：\(messages.first ?? "")"
    }
}

struct ContainerScanRecord: Codable {
    var paths: [String]
    var watermark: UInt64
    var updated: Date?
}

struct CatalogDisk: Codable {
    var scans: [String: ContainerScanRecord] = [:]
    var labels: [String: String] = [:]
    // First version of the shared index. Optional so old catalog.json files
    // still decode without a custom initializer.
    var sharedScanWatermark: UInt64?
    var sharedScanDate: Date?
    var scanVersion: Int?
    // Bundle identifiers seen at the last LaunchServices reconcile.
    var installedAppIDs: [String]?
    var installedAppDate: Date?
    // identifier -> localized app name, also from LaunchServices.
    var appNames: [String: String]?
}
