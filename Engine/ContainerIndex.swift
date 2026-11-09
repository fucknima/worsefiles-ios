//
//  ContainerIndex.swift
//  WorseFiles
//
//  One inode walk feeds every container root. The shared watermark also
//  makes foreground refreshes cheap: only inodes allocated since the last
//  scan are walked, which is where a newly installed app's container lives.
//

import Foundation
import Combine

extension Notification.Name {
    static let worseFilesIndexUpdated = Notification.Name("WorseFilesIndexUpdated")
}

struct ContainerScanSummary {
    let added: Int
    let total: Int
    let full: Bool
}

struct ContainerReconcileSummary {
    let added: Int
    let removed: Int
    let installedApps: Int
    let installedPaths: Int
    let usedInstalledList: Bool
}

enum ContainerIndexError: LocalizedError {
    case noBaseline
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noBaseline:
            return "无法确定 inode 上限。请在设置里填写一个上限，或先让 App 创建临时文件。"
        case .cancelled:
            return "扫描已停止。"
        }
    }
}

@MainActor
final class ContainerIndex: ObservableObject {
    static let shared = ContainerIndex()
    static let indexVersion = 2

    @Published private(set) var progress: ScanStatus?
    @Published private(set) var lastCompleted: Date?
    @Published private(set) var lastAdded = 0
    @Published private(set) var lastReconciled: Date?
    @Published private(set) var installedAppCount = 0
    @Published private(set) var installedPathCount = 0
    @Published private(set) var installedListAvailable = false
    @Published private(set) var installedListSource: String?

    private var running: Task<ContainerScanSummary, Error>?
    private var reconcileTask: Task<ContainerReconcileSummary, Never>?
    private var lastReconcileAt: Date?
    private var loggedReconcile = false
    private var token: CancelToken?

    var isScanning: Bool { running != nil }

    var shouldRefreshOnOpen: Bool {
        guard let lastCompleted else { return true }
        return Date().timeIntervalSince(lastCompleted) > 30
    }

    // Reconcile the index against the live app list. The inode watermark
    // cannot see an install that reused a freed inode, and it never forgets an
    // uninstall. LaunchServices fixes both directions; lstat then catches
    // containers of plugins and daemons that LaunchServices omits.
    @discardableResult
    func reconcileIfNeeded(minInterval: TimeInterval = 10) async -> ContainerReconcileSummary? {
        if reconcileTask == nil,
           let lastReconcileAt,
           Date().timeIntervalSince(lastReconcileAt) < minInterval {
            return nil
        }
        if let reconcileTask {
            return await reconcileTask.value
        }

        let task = Task { await self.performReconcile() }
        reconcileTask = task
        let summary = await task.value
        reconcileTask = nil
        return summary
    }

    private func performReconcile() async -> ContainerReconcileSummary {
        let started = Date()
        let catalog = Catalog.shared
        let roots = Roots.all.map { PathTool.canonical($0.path) }
        let cachedPaths = roots.flatMap { catalog.scanRecord(for: $0)?.paths ?? [] }

        let snapshot = await Task.detached(priority: .utility) {
            InstalledApps.snapshot()
        }.value
        let apps = snapshot ?? []
        let hasList = !apps.isEmpty

        // lstat is allowed on container paths even when their contents need an
        // extension. ENOENT is the one answer that proves the container is gone;
        // EACCES and everything else keep the row.
        let missing = await Task.detached(priority: .utility) {
            Self.missingPaths(cachedPaths)
        }.value
        var removed = catalog.prunePaths(Set(missing))

        var added = 0
        var livePathCount = 0
        var namesChanged = false

        if hasList {
            let pairs: [(String, String)] = apps.compactMap { app in
                guard let raw = app.dataPath else { return nil }
                let path = PathTool.canonical(raw)
                guard roots.contains(PathTool.parent(of: path)) else { return nil }
                return (path, app.identifier)
            }
            let livePathMap = Dictionary(pairs, uniquingKeysWith: { first, _ in first })

            // Same bundle now lives at a different container path. Drop the
            // old record so the row is not duplicated.
            var replaced: Set<String> = []
            for path in cachedPaths {
                guard let label = catalog.label(for: path),
                      let livePath = livePathMap[label] else { continue }
                if PathTool.canonical(path) != livePath {
                    replaced.insert(PathTool.canonical(path))
                }
            }
            if !replaced.isEmpty {
                removed += catalog.prunePaths(replaced)
            }

            var grouped: [String: [String: String]] = [:]
            for (path, identifier) in livePathMap {
                grouped[PathTool.parent(of: path), default: [:]][path] = identifier
            }

            // A few proxies have no dataContainerURL; ask the container
            // manager only for identifiers the index has never seen.
            let knownLabels = Set(catalog.disk.labels.values)
            let resolved = await Task.detached(priority: .utility) {
                var result: [(String, String)] = []
                for app in apps where app.dataPath == nil {
                    guard !knownLabels.contains(app.identifier) else { continue }
                    guard let path = InstalledApps.containerPath(for: app.identifier) else { continue }
                    result.append((PathTool.canonical(path), app.identifier))
                }
                return result
            }.value

            for (path, identifier) in resolved {
                let parent = PathTool.parent(of: path)
                guard roots.contains(parent) else { continue }
                grouped[parent, default: [:]][path] = identifier
            }

            for root in roots {
                guard let labels = grouped[root], !labels.isEmpty else { continue }
                added += catalog.addPaths(Array(labels.keys), to: root, labels: labels)
            }
            catalog.setInstalledAppIDs(apps.map { $0.identifier })

            var names: [String: String] = [:]
            for app in apps {
                if let name = app.name, !name.isEmpty {
                    names[app.identifier] = name
                }
            }
            namesChanged = catalog.setAppNames(names)

            var bundles: [String: String] = [:]
            for app in apps {
                if let bundle = app.bundlePath, !bundle.isEmpty {
                    bundles[app.identifier] = bundle
                }
            }
            if catalog.setAppBundlePaths(bundles) {
                namesChanged = true
            }
            AppIconStore.shared.prefetch(apps.map { $0.identifier })

            var knownPaths = Set(livePathMap.keys)
            knownPaths.formUnion(resolved.map { $0.0 })
            livePathCount = knownPaths.count
        }

        lastReconciled = Date()
        lastReconcileAt = lastReconciled
        installedAppCount = apps.count
        installedPathCount = livePathCount
        installedListAvailable = hasList
        installedListSource = hasList ? InstalledApps.source : nil

        if !loggedReconcile {
            loggedReconcile = true
            if hasList {
                Log.info("reconcile apps=\(apps.count) paths=\(livePathCount) +\(added) -\(removed)")
            } else {
                Log.info("reconcile: LaunchServices API unavailable; using lstat and lsd names")
            }
        } else if added > 0 || removed > 0 {
            Log.info("reconcile +\(added) -\(removed)")
        }

        if added > 0 || removed > 0 || namesChanged {
            NotificationCenter.default.post(name: .worseFilesIndexUpdated, object: nil)
        }

        if added > 0 || removed > 0 || namesChanged {
            Log.info("reconcile took \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }

        return ContainerReconcileSummary(added: added,
                                         removed: removed,
                                         installedApps: apps.count,
                                         installedPaths: livePathCount,
                                         usedInstalledList: hasList)
    }

    nonisolated private static func missingPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var missing: [String] = []
        for raw in paths {
            let path = PathTool.canonical(raw)
            guard seen.insert(path).inserted else { continue }
            var info = stat()
            let gone = path.withCString { pointer -> Bool in
                lstat(pointer, &info) != 0 && errno == ENOENT
            }
            if gone { missing.append(path) }
        }
        return missing
    }

    @discardableResult
    func ensureScanned(full requestFull: Bool) async throws -> ContainerScanSummary {
        if let running {
            return try await running.value
        }

        let catalog = Catalog.shared
        let roots = Roots.all.map { PathTool.canonical($0.path) }
        let needsFull = requestFull
            || !catalog.hasSharedScan
            || catalog.scanVersion != Self.indexVersion
            || roots.contains(where: { catalog.scanRecord(for: $0) == nil })

        let task = Task { try await self.performScan(full: needsFull, roots: roots) }
        running = task
        do {
            let summary = try await task.value
            running = nil
            return summary
        } catch {
            running = nil
            throw error
        }
    }

    func cancel() {
        token?.cancel()
        token = nil
        progress = nil
    }

    private func performScan(full: Bool, roots: [String]) async throws -> ContainerScanSummary {
        let catalog = Catalog.shared
        let baseline = AppSettings.maxInodeOverride ?? ContainerScanner.shared.baselineInode()
        guard baseline > 0 else { throw ContainerIndexError.noBaseline }

        let watermark = catalog.sharedWatermark
        let replace = full || watermark == 0
        let end = baseline
        if !replace && watermark >= baseline {
            lastCompleted = Date()
            lastAdded = 0
            return ContainerScanSummary(added: 0,
                                        total: roots.reduce(0) { $0 + catalog.count(for: $1) },
                                        full: false)
        }
        let start: UInt64 = replace ? 1 : watermark + 1

        let scanToken = CancelToken()
        token = scanToken
        progress = ScanStatus(done: 0, total: end - start + 1, started: Date())
        Log.info("index scan \(start)…\(end) full=\(replace)")

        let found = await Task.detached(priority: .userInitiated) {
            ContainerScanner.shared.scan(roots: roots,
                                         start: start,
                                         end: end,
                                         token: scanToken) { done in
                Task { @MainActor [weak self] in
                    guard let self, self.token === scanToken, var status = self.progress else { return }
                    let processed = done >= start ? done - start + 1 : 0
                    status.done = min(status.total, processed)
                    self.progress = status
                }
            }
        }.value

        guard token === scanToken else { throw ContainerIndexError.cancelled }
        token = nil
        progress = nil
        if scanToken.isCancelled { throw ContainerIndexError.cancelled }

        let added = catalog.mergeRootScan(results: found,
                                          roots: roots,
                                          watermark: end,
                                          replace: replace,
                                          version: Self.indexVersion)
        let daemons = catalog.scanRecord(for: Roots.internalDaemon.path)?.paths ?? []
        AppNames.shared.ensureLoaded(daemonContainers: daemons)
        let total = roots.reduce(0) { $0 + catalog.count(for: $1) }
        lastCompleted = Date()
        lastAdded = added
        if added > 0 || replace {
            let counts = roots.map { "\(PathTool.name(of: $0)):\(catalog.count(for: $0))" }
                .joined(separator: " ")
            Log.info("index scan done: +\(added), total=\(total) [\(counts)]")
        }
        NotificationCenter.default.post(name: .worseFilesIndexUpdated, object: nil)

        return ContainerScanSummary(added: added, total: total, full: replace)
    }
}
