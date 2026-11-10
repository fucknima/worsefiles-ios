//
//  Backup.swift
//  WorseFiles
//
//  A backup is a folder snapshot under the app's own Documents. Files are
//  copied with clonefile when APFS allows it, so a backup of another app's
//  container normally costs metadata rather than a second copy of every byte.
//  The manifest records where the source lived inside its container, which is
//  what makes restore work after the app is reinstalled with a new UUID.
//

import Foundation
import Combine

enum BackupMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case userData
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userData: return "仅用户数据"
        case .full: return "完整"
        }
    }

    var detail: String {
        switch self {
        case .userData: return "跳过 Library/Caches、tmp、日志、状态快照与启动图缓存"
        case .full: return "包含缓存与临时文件，体积更大"
        }
    }
}

struct BackupRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var createdAt: Date
    var sourcePath: String
    var sourceTitle: String
    var containerIdentifier: String?
    var containerName: String?
    var containerRelative: String
    var mode: BackupMode
    var bytes: Int64
    var files: Int
    var failures: Int?
}

struct BackupManifest: Codable {
    static let currentVersion = 1
    var version: Int
    var record: BackupRecord
}

struct BackupRequest: Identifiable {
    let id = UUID()
    let sourcePath: String
    let title: String
    let containerIdentifier: String?
    let containerName: String?
    let containerRelative: String
}

struct BackupProgress {
    let phase: String
    let bytes: Int64
    let files: Int
    let totalBytes: Int64
    let current: String?

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(bytes) / Double(totalBytes))
    }
}

struct BackupResult {
    let report: BackupRestoreReport
}

struct BackupRestoreReport {
    let bytes: Int64
    let files: Int
    let skipped: Int
    let errors: [String]
    let snapshot: BackupRecord?

    var summary: String {
        var text = "已恢复 \(files) 个文件，约 \(Format.bytes(bytes))。"
        if skipped > 0 { text += "跳过 \(skipped) 项。" }
        if !errors.isEmpty { text += "\(errors.count) 项失败。" }
        if let snapshot {
            text += "\n恢复前已快照到「\(snapshot.name)」。"
        }
        return text
    }
}

enum BackupError: LocalizedError {
    case missingSource(String)
    case missingDestination(String)
    case notDirectory(String)
    case copyFailed(String)
    case unsafePath(String)
    case unsupportedVersion(Int)
    case manifestMismatch

    var errorDescription: String? {
        switch self {
        case .missingSource(let path): return "备份源不存在：\(path)"
        case .missingDestination(let path): return "目标容器不存在：\(path)"
        case .notDirectory(let path): return "不是文件夹：\(path)"
        case .copyFailed(let path): return "复制失败：\(path)"
        case .unsafePath(let path): return "路径不在容器内，已拒绝：\(path)"
        case .unsupportedVersion(let version): return "备份格式版本 \(version) 高于当前应用支持的 \(BackupManifest.currentVersion)，请更新应用。"
        case .manifestMismatch: return "备份清单与记录不匹配，已拒绝恢复。"
        }
    }
}

enum BackupPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    static var root: URL {
        documents.appendingPathComponent("Backups", isDirectory: true)
    }

    static var index: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? documents
        return support
            .appendingPathComponent("WorseFiles", isDirectory: true)
            .appendingPathComponent("backups.json")
    }

    static func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }
}

private struct BackupDisk: Codable {
    var records: [BackupRecord] = []
}

@MainActor
final class BackupStore: ObservableObject {
    static let shared = BackupStore()

    @Published private(set) var records: [BackupRecord] = []

    private let manager = FileManager.default

    private init() {
        try? manager.createDirectory(at: BackupPaths.root, withIntermediateDirectories: true)
        reload()
    }

    var totalBytes: Int64 {
        records.reduce(0) { $0 + $1.bytes }
    }

    func reload() {
        try? manager.createDirectory(at: BackupPaths.root, withIntermediateDirectories: true)

        var byID: [String: BackupRecord] = [:]
        if let data = try? Data(contentsOf: BackupPaths.index),
           let disk = try? Self.decoder.decode(BackupDisk.self, from: data) {
            for record in disk.records where folderExists(record.id) {
                byID[record.id] = record
            }
        }

        for record in Self.scanManifests(root: BackupPaths.root) where byID[record.id] == nil {
            byID[record.id] = record
        }

        let sorted = byID.values.sorted { $0.createdAt > $1.createdAt }
        records = sorted
        save()
    }

    func add(_ record: BackupRecord) {
        var next = records.filter { $0.id != record.id }
        next.append(record)
        records = next.sorted { $0.createdAt > $1.createdAt }
        save()
    }

    @discardableResult
    func remove(_ record: BackupRecord) -> Bool {
        let folder = BackupPaths.folder(for: record.id)
        if manager.fileExists(atPath: folder.path) {
            do {
                try manager.removeItem(at: folder)
            } catch {
                return false
            }
        }
        records.removeAll { $0.id == record.id }
        save()
        return true
    }

    func folderURL(for record: BackupRecord) -> URL {
        BackupPaths.folder(for: record.id)
    }

    private func folderExists(_ id: String) -> Bool {
        var isDirectory: ObjCBool = false
        return manager.fileExists(atPath: BackupPaths.folder(for: id).path,
                                  isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func save() {
        guard let data = try? Self.encoder.encode(BackupDisk(records: records)) else { return }
        let directory = BackupPaths.index.deletingLastPathComponent()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: BackupPaths.index, options: .atomic)
    }

    private static func scanManifests(root: URL) -> [BackupRecord] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: root,
                                                             includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var records: [BackupRecord] = []
        for folder in folders {
            let manifest = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let decoded = try? decoder.decode(BackupManifest.self, from: data) else { continue }
            records.append(decoded.record)
        }
        return records
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    nonisolated static func safeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "_"
        }
        let text = String(safe).prefix(40)
        return text.isEmpty ? "backup" : String(text)
    }
}

final class BackupEngine: @unchecked Sendable {
    static let shared = BackupEngine()

    private let manager = FileManager.default
    private let broker = SandboxBroker.shared

    func create(request: BackupRequest,
                mode: BackupMode,
                token: CancelToken,
                progress: @escaping (BackupProgress) -> Void) throws -> BackupRecord {
        let source = PathTool.canonical(request.sourcePath)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source, isDirectory: &isDirectory) else {
            throw BackupError.missingSource(source)
        }
        guard isDirectory.boolValue else {
            throw BackupError.notDirectory(source)
        }

        let relative = request.containerRelative
        guard !relative.contains("..") else {
            throw BackupError.unsafePath(relative)
        }

        let id = uniqueID(title: request.title)
        let folder = BackupPaths.folder(for: id)
        let dataFolder = folder.appendingPathComponent("data", isDirectory: true)
        do {
            try manager.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        } catch {
            throw BackupError.copyFailed(folder.path)
        }

        let lease = acquire(source)
        defer {
            if let key = lease { broker.release(key, quiet: true) }
        }

        var bytes: Int64 = 0
        var files = 0
        var errors: [String] = []
        var lastReport = Date.distantPast

        var options = FileWalk.Options()
        var exclusions = mode == .userData ? Self.userDataExclusions : []
        // Never recurse into the backup folder itself when the source is our
        // own Documents directory.
        let backupRelative = PathTool.relative(BackupPaths.root.path, to: source)
        if backupRelative != BackupPaths.root.path,
           PathTool.isDescendant(BackupPaths.root.path, of: source) {
            exclusions.append(backupRelative)
        }
        if !exclusions.isEmpty {
            options.skip = { path in
                exclusions.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
        }

        do {
            _ = try FileWalk.walk(root: source, options: options, token: token) { entry in
                if token.isCancelled { throw CancellationError() }

                let destination = dataFolder.appendingPathComponent(entry.relative)

                if entry.isSymbolicLink {
                    let parent = destination.deletingLastPathComponent()
                    try? manager.createDirectory(at: parent, withIntermediateDirectories: true)
                    try? manager.removeItem(at: destination)
                    if let target = entry.symlinkTarget {
                        try? manager.createSymbolicLink(atPath: destination.path,
                                                        withDestinationPath: target)
                    }
                } else if entry.isDirectory {
                    try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
                } else {
                    let parent = destination.deletingLastPathComponent()
                    try? manager.createDirectory(at: parent, withIntermediateDirectories: true)
                    if manager.fileExists(atPath: destination.path) {
                        try? manager.removeItem(at: destination)
                    }
                    if !WFCloneItem(entry.path, destination.path) {
                        if errors.count < 30 {
                            errors.append("\(entry.relative)：复制失败")
                        }
                        return
                    }
                    bytes += entry.size
                    files += 1
                }

                if Date().timeIntervalSince(lastReport) > 0.15 {
                    lastReport = Date()
                    progress(BackupProgress(phase: "备份",
                                            bytes: bytes,
                                            files: files,
                                            totalBytes: 0,
                                            current: entry.relative))
                }
            }
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }

        if token.isCancelled {
            try? manager.removeItem(at: folder)
            throw CancellationError()
        }

        progress(BackupProgress(phase: "备份",
                                bytes: bytes,
                                files: files,
                                totalBytes: 0,
                                current: nil))

        var record = BackupRecord(id: id,
                                  name: request.title.isEmpty ? PathTool.name(of: source) : request.title,
                                  createdAt: Date(),
                                  sourcePath: source,
                                  sourceTitle: request.title,
                                  containerIdentifier: request.containerIdentifier,
                                  containerName: request.containerName,
                                  containerRelative: relative,
                                  mode: mode,
                                  bytes: bytes,
                                  files: files,
                                  failures: errors.isEmpty ? nil : errors.count)
        if !errors.isEmpty {
            Log.info("backup \(id) finished with \(errors.count) copy errors")
        }

        let manifest = BackupManifest(version: BackupManifest.currentVersion, record: record)
        do {
            let data = try Self.encoder.encode(manifest)
            try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            try? manager.removeItem(at: folder)
            throw BackupError.copyFailed(folder.appendingPathComponent("manifest.json").path)
        }

        // Keep the record's display name stable even if the folder name was
        // sanitized.
        record.name = request.title.isEmpty ? PathTool.name(of: source) : request.title
        return record
    }

    func restore(record: BackupRecord,
                 targetContainer: String,
                 snapshot: Bool = false,
                 token: CancelToken,
                 progress: @escaping (BackupProgress) -> Void) throws -> BackupRestoreReport {
        let folder = BackupPaths.folder(for: record.id)
        let sourceRoot = folder.appendingPathComponent("data", isDirectory: true)
        let target = PathTool.canonical(targetContainer)

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BackupError.missingSource(sourceRoot.path)
        }
        guard manager.fileExists(atPath: target, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BackupError.missingDestination(target)
        }
        try validateManifest(record: record, folder: folder)

        let relativeRoot = record.containerRelative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativeRoot.contains("..") else {
            throw BackupError.unsafePath(relativeRoot)
        }
        var destinationRoot = target
        if !relativeRoot.isEmpty {
            destinationRoot = PathTool.canonical(target + "/" + relativeRoot)
        }
        guard PathTool.isDescendant(destinationRoot, of: target) else {
            throw BackupError.unsafePath(destinationRoot)
        }

        var snapshotRecord: BackupRecord?
        if snapshot {
            snapshotRecord = try snapshotIfNeeded(record: record,
                                                  destinationRoot: destinationRoot,
                                                  token: token,
                                                  progress: progress)
        }

        try? manager.createDirectory(atPath: destinationRoot,
                                     withIntermediateDirectories: true,
                                     attributes: nil)

        let lease = acquire(target)
        defer {
            if let key = lease { broker.release(key, quiet: true) }
        }

        var bytes: Int64 = 0
        var files = 0
        var skipped = 0
        var errors: [String] = []
        var lastReport = Date.distantPast

        do {
            _ = try FileWalk.walk(root: sourceRoot.path, token: token) { entry in
                if token.isCancelled { throw CancellationError() }

                let destination = destinationRoot + "/" + entry.relative
                guard PathTool.isDescendant(destination, of: target) else {
                    throw BackupError.unsafePath(destination)
                }

                if entry.isSymbolicLink {
                    guard let link = entry.symlinkTarget, !link.hasPrefix("/") else {
                        skipped += 1
                        return
                    }
                    let parent = (destination as NSString).deletingLastPathComponent
                    try? manager.createDirectory(atPath: parent,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
                    let resolved = URL(fileURLWithPath: destination)
                        .deletingLastPathComponent()
                        .appendingPathComponent(link)
                        .standardizedFileURL.path
                    guard PathTool.isDescendant(resolved, of: destinationRoot) else {
                        skipped += 1
                        return
                    }
                    try? manager.removeItem(atPath: destination)
                    try? manager.createSymbolicLink(atPath: destination, withDestinationPath: link)
                } else if entry.isDirectory {
                    try? manager.createDirectory(atPath: destination,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
                } else {
                    let parent = (destination as NSString).deletingLastPathComponent
                    try? manager.createDirectory(atPath: parent,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
                    if manager.fileExists(atPath: destination) {
                        do {
                            try manager.removeItem(atPath: destination)
                        } catch {
                            if errors.count < 30 {
                                errors.append("\(entry.relative)：无法覆盖")
                            }
                            skipped += 1
                            return
                        }
                    }
                    if !WFCloneItem(entry.path, destination) {
                        if errors.count < 30 {
                            errors.append("\(entry.relative)：恢复失败")
                        }
                        skipped += 1
                        return
                    }
                    bytes += entry.size
                    files += 1
                }

                if Date().timeIntervalSince(lastReport) > 0.15 {
                    lastReport = Date()
                    progress(BackupProgress(phase: "恢复",
                                            bytes: bytes,
                                            files: files,
                                            totalBytes: record.bytes,
                                            current: entry.relative))
                }
            }
        } catch {
            throw error
        }

        if token.isCancelled { throw CancellationError() }
        progress(BackupProgress(phase: "恢复",
                                bytes: bytes,
                                files: files,
                                totalBytes: record.bytes,
                                current: nil))

        return BackupRestoreReport(bytes: bytes,
                                   files: files,
                                   skipped: skipped,
                                   errors: errors,
                                   snapshot: snapshotRecord)
    }

    // Restore overwrites files in place, so a failed or partial restore can
    // destroy the previous state. Snapshot the destination first; clonefile
    // makes this cheap on the same volume. A snapshot failure aborts restore.
    private func snapshotIfNeeded(record: BackupRecord,
                                  destinationRoot: String,
                                  token: CancelToken,
                                  progress: @escaping (BackupProgress) -> Void) throws -> BackupRecord? {
        // Restoring a snapshot should not create another snapshot of the
        // restore target, or every recovery would add a new copy.
        guard !record.name.hasPrefix("恢复前快照") else { return nil }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: destinationRoot, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let contents = (try? manager.contentsOfDirectory(atPath: destinationRoot)) ?? []
        guard !contents.isEmpty else { return nil }

        let request = BackupRequest(sourcePath: destinationRoot,
                                    title: "恢复前快照 \(record.name)",
                                    containerIdentifier: record.containerIdentifier,
                                    containerName: record.containerName,
                                    containerRelative: record.containerRelative)
        return try create(request: request, mode: .full, token: token) { value in
            progress(BackupProgress(phase: "恢复前快照",
                                    bytes: value.bytes,
                                    files: value.files,
                                    totalBytes: 0,
                                    current: value.current))
        }
    }

    private func validateManifest(record: BackupRecord, folder: URL) throws {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? Self.decoder.decode(BackupManifest.self, from: data) else {
            throw BackupError.missingSource(manifestURL.path)
        }
        guard manifest.version <= BackupManifest.currentVersion else {
            throw BackupError.unsupportedVersion(manifest.version)
        }
        guard manifest.record.id == record.id else {
            throw BackupError.manifestMismatch
        }
    }

    func exportArchive(record: BackupRecord, token: CancelToken) -> URL? {
        let folder = BackupPaths.folder(for: record.id)
        guard manager.fileExists(atPath: folder.path), !token.isCancelled else { return nil }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var archive: URL?
        coordinator.coordinate(readingItemAt: folder,
                               options: .forUploading,
                               error: &coordinationError) { zipped in
            guard !token.isCancelled else { return }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(BackupStore.safeName(record.name) + "-backup.zip")
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: zipped, to: destination)) != nil {
                archive = destination
            }
        }
        return archive
    }

    func exportAllArchives(token: CancelToken) -> URL? {
        let root = BackupPaths.root
        guard manager.fileExists(atPath: root.path), !token.isCancelled else { return nil }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var archive: URL?
        coordinator.coordinate(readingItemAt: root,
                               options: .forUploading,
                               error: &coordinationError) { zipped in
            guard !token.isCancelled else { return }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("worsefiles-backups.zip")
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: zipped, to: destination)) != nil {
                archive = destination
            }
        }
        return archive
    }

    // A subfolder is not a container, so a direct query can be refused. Fall
    // back to the container that owns it; one extension covers the subtree.
    private func acquire(_ path: String) -> String? {
        let key = PathTool.canonical(path)
        if (try? broker.access(key, quiet: true)) != nil { return key }

        for root in Roots.all where PathTool.isDescendant(key, of: root.path) {
            let relative = PathTool.relative(key, to: root.path)
            guard let first = relative.split(separator: "/").first else { continue }
            let container = PathTool.canonical(root.path + "/" + String(first))
            if (try? broker.access(container, quiet: true)) != nil { return container }
        }
        return nil
    }

    private func uniqueID(title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let base = "\(stamp)-\(BackupStore.safeName(title))"
        var candidate = base
        var index = 2
        while manager.fileExists(atPath: BackupPaths.folder(for: candidate).path) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    private static let userDataExclusions = [
        "Library/Caches",
        "tmp",
        "Library/Logs",
        "Library/Saved Application State",
        "Library/SplashBoard",
        ".Trash",
    ]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

@MainActor
enum BackupSupport {
    static func containerPath(for path: String) -> String? {
        let canonical = PathTool.canonical(path)
        for root in Roots.all {
            guard PathTool.isDescendant(canonical, of: root.path) else { continue }
            let relative = PathTool.relative(canonical, to: root.path)
            guard let first = relative.split(separator: "/").first else { continue }
            return PathTool.canonical(root.path + "/" + String(first))
        }
        return nil
    }

    static func request(path: String, title: String) -> BackupRequest {
        let canonical = PathTool.canonical(path)
        let container = containerPath(for: canonical)
        let identifier = container.flatMap { Catalog.shared.label(for: $0) }
        let name = container.flatMap { Catalog.shared.displayName(for: $0) }
        let relative = container.map { PathTool.relative(canonical, to: $0) } ?? ""
        return BackupRequest(sourcePath: canonical,
                             title: title.isEmpty ? PathTool.name(of: canonical) : title,
                             containerIdentifier: identifier,
                             containerName: name,
                             containerRelative: relative)
    }

    static func restoreTarget(for record: BackupRecord) -> String? {
        let manager = FileManager.default
        if let identifier = record.containerIdentifier {
            // Ask the container manager first: after a reinstall the live
            // UUID is new, and the cached label map may still be stale.
            if let live = InstalledApps.containerPath(for: identifier),
               isDirectory(live, manager: manager) {
                return PathTool.canonical(live)
            }
            // MCM can refuse a data container on iOS 27. Reading the
            // identifier xattr of each container is slower but needs no
            // cached label, so restore works before the list is opened.
            if let live = xattrLookup(identifier) {
                return PathTool.canonical(live)
            }
            if let cached = Catalog.shared.path(forIdentifier: identifier),
               isDirectory(cached, manager: manager) {
                return PathTool.canonical(cached)
            }
        }
        if isDirectory(record.sourcePath, manager: manager) {
            return containerPath(for: record.sourcePath) ?? record.sourcePath
        }
        return nil
    }

    static func spaceWarning(target: String, bytes: Int64) -> String? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: target).resourceValues(forKeys: keys),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        let margin: Int64 = 256 * 1024 * 1024
        guard available < bytes + margin else { return nil }
        return "目标卷可用空间约 \(Format.bytes(available))，备份约 \(Format.bytes(bytes))；APFS 克隆失败时会改为复制，可能中途空间不足。"
    }

    private static func isDirectory(_ path: String, manager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return manager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func xattrLookup(_ identifier: String) -> String? {
        let broker = SandboxBroker.shared
        let manager = FileManager.default
        for root in [Roots.dataApplication, Roots.pluginKit] {
            var lease: String?
            if (try? broker.access(root.path, quiet: true)) != nil {
                lease = root.path
            }
            defer {
                if let lease { broker.release(lease, quiet: true) }
            }
            if let names = try? manager.contentsOfDirectory(atPath: root.path) {
                for name in names where !name.hasPrefix(".") {
                    let path = root.path + "/" + name
                    if ContainerMetadata.identifier(atPath: path) == identifier {
                        return path
                    }
                }
            }
            // Listing a container root is often refused on iOS 27, but the
            // inode index already holds the paths. Re-read their xattrs.
            if let record = Catalog.shared.scanRecord(for: root.path) {
                for path in record.paths {
                    if ContainerMetadata.identifier(atPath: path) == identifier {
                        return path
                    }
                }
            }
        }
        return nil
    }
}
