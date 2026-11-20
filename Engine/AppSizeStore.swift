//
//  AppSizeStore.swift
//  WorseFiles
//
//  Per-container data size for the app list. Measuring a container means
//  walking the whole tree, so results are cached in memory and on disk and
//  only requested when a row becomes visible. A pull-to-refresh clears the
//  cache and lets visible rows measure again.
//

import Foundation
import Combine

@MainActor
final class AppSizeStore: ObservableObject {
    static let shared = AppSizeStore()

    @Published private(set) var revision = 0
    var cachedCount: Int { sizes.count }

    private var sizes: [String: Int64] = [:]
    private var failed: Set<String> = []
    private var pending: Set<String> = []
    private var generation = 0
    private let queue = DispatchQueue(label: "com.kestrel.worsefiles.sizes", qos: .utility)
    private let fileURL: URL?

    private init() {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory,
                                         in: .userDomainMask).first else {
            fileURL = nil
            return
        }
        let directory = support.appendingPathComponent("WorseFiles", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("app-sizes.json")
        fileURL = url
        if let data = try? Data(contentsOf: url),
           let disk = try? JSONDecoder().decode([String: Int64].self, from: data) {
            sizes = disk
        }
    }

    // Returns a cached value and starts a background measurement when needed.
    // Nil means "not ready"; hasFailed() tells the row whether to show a dash.
    func size(for path: String) -> Int64? {
        let key = PathTool.canonical(path)
        if let bytes = sizes[key] { return bytes }
        guard !failed.contains(key), !pending.contains(key) else { return nil }
        request(key)
        return nil
    }

    func cachedSize(for path: String) -> Int64? {
        sizes[PathTool.canonical(path)]
    }

    func hasFailed(_ path: String) -> Bool {
        failed.contains(PathTool.canonical(path))
    }

    func invalidateAll() {
        generation += 1
        sizes.removeAll()
        failed.removeAll()
        pending.removeAll()
        revision += 1
        save()
        Log.info("app sizes cleared")
    }

    func invalidate(_ path: String) {
        generation += 1
        let key = PathTool.canonical(path)
        sizes.removeValue(forKey: key)
        failed.remove(key)
        pending.removeAll()
        revision += 1
        save()
    }

    private func request(_ path: String) {
        let key = PathTool.canonical(path)
        let requestGeneration = generation
        pending.insert(key)
        queue.async {
            let bytes = Self.measure(key)
            DispatchQueue.main.async { [weak self] in
                guard let self, requestGeneration == self.generation else { return }
                self.pending.remove(key)
                if let bytes {
                    self.sizes[key] = bytes
                } else {
                    self.failed.insert(key)
                }
                self.revision += 1
                self.save()
            }
        }
    }

    nonisolated private static func measure(_ path: String) -> Int64? {
        let broker = SandboxBroker.shared
        guard (try? broker.access(path, quiet: true)) != nil else { return nil }
        defer { broker.release(path, quiet: true) }

        var total: Int64 = 0
        do {
            _ = try FileWalk.walk(root: path) { entry in
                guard !entry.isDirectory, !entry.isSymbolicLink else { return }
                total += entry.allocated > 0 ? entry.allocated : entry.size
            }
        } catch {
            return nil
        }
        return total
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot = sizes
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
