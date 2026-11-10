//
//  Catalog.swift
//  WorseFiles
//

import Foundation
import Combine

final class CatalogStore: @unchecked Sendable {
    private let fileURL: URL?

    init() {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory,
                                         in: .userDomainMask).first else {
            fileURL = nil
            return
        }
        let directory = support.appendingPathComponent("WorseFiles", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("catalog.json")
        } catch {
            Log.error("catalog directory: \(error.localizedDescription)")
            fileURL = nil
        }
    }

    func load() -> CatalogDisk {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return CatalogDisk() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CatalogDisk.self, from: data)
        } catch {
            Log.error("catalog decode: \(error.localizedDescription)")
            return CatalogDisk()
        }
    }

    func save(_ disk: CatalogDisk) {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = []
            let data = try encoder.encode(disk)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("catalog save: \(error.localizedDescription)")
        }
    }
}

final class Catalog: ObservableObject {
    static let shared = Catalog()

    @Published private(set) var disk: CatalogDisk

    private let store: CatalogStore

    init(store: CatalogStore = CatalogStore()) {
        self.store = store
        self.disk = store.load()
    }

    func scanRecord(for root: String) -> ContainerScanRecord? {
        disk.scans[PathTool.canonical(root)]
    }

    func count(for root: String) -> Int {
        scanRecord(for: root)?.paths.count ?? 0
    }

    var sharedWatermark: UInt64 { disk.sharedScanWatermark ?? 0 }
    var hasSharedScan: Bool { disk.sharedScanWatermark != nil }
    var scanVersion: Int? { disk.scanVersion }
    var installedAppIDs: Set<String> { Set(disk.installedAppIDs ?? []) }
    var installedAppDate: Date? { disk.installedAppDate }

    func items(for root: String) -> [FSItem] {
        let key = PathTool.canonical(root)
        guard let record = disk.scans[key] else { return [] }
        return record.paths.map { path in
            let identifier = disk.labels[path]
            let name = identifier.flatMap { appName(for: $0) }
            return FSItem(path: path,
                          name: PathTool.name(of: path),
                          isDirectory: true,
                          isSymbolicLink: false,
                          isHidden: false,
                          size: 0,
                          modified: nil,
                          identifier: identifier,
                          appName: name)
        }
    }

    func label(for path: String) -> String? {
        disk.labels[PathTool.canonical(path)]
    }

    func setLabel(_ label: String, for path: String) {
        setLabels([path: label])
    }

    func path(forIdentifier identifier: String) -> String? {
        disk.labels.first { $0.value == identifier }?.key
    }

    func appName(for identifier: String) -> String? {
        disk.appNames?[identifier]
    }

    func displayName(for path: String) -> String? {
        guard let identifier = label(for: path) else { return nil }
        return appName(for: identifier) ?? identifier
    }

    @discardableResult
    func appBundlePath(for identifier: String) -> String? {
        disk.appBundlePaths?[identifier]
    }

    @discardableResult
    func setAppBundlePaths(_ pairs: [String: String]) -> Bool {
        var next = disk
        var paths = next.appBundlePaths ?? [:]
        var changed = false
        for (identifier, path) in pairs {
            guard !identifier.isEmpty, !path.isEmpty else { continue }
            if paths[identifier] != path {
                paths[identifier] = path
                changed = true
            }
        }
        guard changed else { return false }
        next.appBundlePaths = paths
        disk = next
        store.save(next)
        return true
    }

    func setAppNames(_ pairs: [String: String]) -> Bool {
        var next = disk
        var names = next.appNames ?? [:]
        var changed = false
        for (identifier, name) in pairs {
            guard !identifier.isEmpty, !name.isEmpty else { continue }
            if names[identifier] != name {
                names[identifier] = name
                changed = true
            }
        }
        guard changed else { return false }
        next.appNames = names
        disk = next
        store.save(next)
        return true
    }

    func setLabels(_ pairs: [String: String]) {
        var next = disk
        var changed = false
        for (path, label) in pairs {
            guard !label.isEmpty else { continue }
            let key = PathTool.canonical(path)
            if next.labels[key] != label {
                next.labels[key] = label
                changed = true
            }
        }
        guard changed else { return }
        disk = next
        store.save(next)
    }

    func mergeScan(root: String, paths: [String], watermark: UInt64, replace: Bool) {
        let key = PathTool.canonical(root)
        var next = disk
        var record = next.scans[key] ?? ContainerScanRecord(paths: [], watermark: 0, updated: nil)
        if replace {
            record.paths = paths.sorted()
        } else {
            record.paths = Array(Set(record.paths).union(paths)).sorted()
        }
        record.watermark = max(record.watermark, watermark)
        record.updated = Date()
        next.scans[key] = record
        disk = next
        store.save(next)
    }

    func noteRename(from oldPath: String, to newPath: String) {
        let oldKey = PathTool.canonical(oldPath)
        let newKey = PathTool.canonical(newPath)
        let parent = PathTool.parent(of: oldKey)
        var next = disk
        guard var record = next.scans[parent],
              record.paths.contains(where: { PathTool.canonical($0) == oldKey }) else { return }
        record.paths.removeAll { PathTool.canonical($0) == oldKey }
        if !record.paths.contains(where: { PathTool.canonical($0) == newKey }) {
            record.paths.append(newKey)
            record.paths.sort()
        }
        next.scans[parent] = record
        if let label = next.labels.removeValue(forKey: oldKey) {
            next.labels[newKey] = label
        }
        disk = next
        store.save(next)
    }

    // Batch prune used by the LaunchServices reconcile. Returns the number of
    // indexed paths that were actually removed.
    @discardableResult
    func prunePaths(_ paths: Set<String>) -> Int {
        guard !paths.isEmpty else { return 0 }
        let keys = Set(paths.map { PathTool.canonical($0) })
        var next = disk
        var scans = next.scans
        var removed = 0

        for (root, record) in scans {
            let kept = record.paths.filter { !keys.contains(PathTool.canonical($0)) }
            let delta = record.paths.count - kept.count
            guard delta > 0 else { continue }
            var updated = record
            updated.paths = kept
            scans[root] = updated
            removed += delta
        }

        var labelsRemoved = false
        for key in keys {
            if next.labels.removeValue(forKey: key) != nil {
                labelsRemoved = true
            }
        }

        next.scans = scans
        guard removed > 0 || labelsRemoved else { return 0 }
        disk = next
        store.save(next)
        return removed
    }

    // Insert live container paths into one root record. Used when
    // LaunchServices knows about a container the inode watermark missed.
    @discardableResult
    func addPaths(_ paths: [String], to root: String, labels: [String: String] = [:]) -> Int {
        let key = PathTool.canonical(root)
        var next = disk
        var record = next.scans[key] ?? ContainerScanRecord(paths: [],
                                                            watermark: next.sharedScanWatermark ?? 0,
                                                            updated: nil)
        let existing = Set(record.paths.map { PathTool.canonical($0) })
        var pending: [String] = []

        for raw in paths {
            let path = PathTool.canonical(raw)
            guard PathTool.parent(of: path) == key else { continue }
            guard !existing.contains(path), !pending.contains(path) else { continue }
            pending.append(path)
        }

        var labelsChanged = false
        for (raw, label) in labels {
            let path = PathTool.canonical(raw)
            guard !label.isEmpty, PathTool.parent(of: path) == key else { continue }
            if next.labels[path] != label {
                next.labels[path] = label
                labelsChanged = true
            }
        }

        guard !pending.isEmpty || labelsChanged else { return 0 }
        if !pending.isEmpty {
            record.paths = (record.paths + pending).sorted()
            record.updated = Date()
            next.scans[key] = record
        }
        disk = next
        store.save(next)
        return pending.count
    }

    func setInstalledAppIDs(_ identifiers: [String]) {
        let sorted = Array(Set(identifiers)).sorted()
        var next = disk
        next.installedAppIDs = sorted
        next.installedAppDate = Date()
        disk = next
        store.save(next)
    }

    func removePaths(_ paths: [String]) {
        let keys = Set(paths.map { PathTool.canonical($0) })
        guard !keys.isEmpty else { return }
        var next = disk
        var scans = next.scans
        for (root, record) in scans {
            var updated = record
            updated.paths = record.paths.filter { !keys.contains(PathTool.canonical($0)) }
            scans[root] = updated
        }
        next.scans = scans
        for key in keys {
            next.labels.removeValue(forKey: key)
        }
        disk = next
        store.save(next)
    }

    // Merge one root walk into every root record and advance the shared inode
    // watermark once. Returns the number of newly added paths per root.
    @discardableResult
    func mergeRootScan(results: [String: [String]],
                       roots: [String],
                       watermark: UInt64,
                       replace: Bool,
                       version: Int) -> [String: Int] {
        var next = disk
        var addedByRoot: [String: Int] = [:]
        for root in roots {
            let key = PathTool.canonical(root)
            let paths = results[key] ?? results[root] ?? []
            var record = next.scans[key] ?? ContainerScanRecord(paths: [], watermark: 0, updated: nil)
            let before = record.paths.count
            if replace {
                record.paths = paths.sorted()
            } else {
                record.paths = Array(Set(record.paths).union(paths)).sorted()
            }
            addedByRoot[key] = max(0, record.paths.count - before)
            record.watermark = max(record.watermark, watermark)
            record.updated = Date()
            next.scans[key] = record
        }
        next.sharedScanWatermark = max(next.sharedScanWatermark ?? 0, watermark)
        next.sharedScanDate = Date()
        next.scanVersion = version
        disk = next
        store.save(next)
        return addedByRoot
    }

    func clearScans() {
        var next = disk
        next.scans.removeAll()
        next.sharedScanWatermark = nil
        next.sharedScanDate = nil
        next.scanVersion = nil
        disk = next
        store.save(next)
        Log.info("cleared scan cache")
    }

    func clearLabels() {
        var next = disk
        next.labels.removeAll()
        disk = next
        store.save(next)
        Log.info("cleared label cache")
    }

    func clearAll() {
        disk = CatalogDisk()
        store.save(disk)
        Log.info("cleared catalog")
    }
}
