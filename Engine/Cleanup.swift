//
//  Cleanup.swift
//  WorseFiles
//
//  Cache cleanup stays inside a short allowlist. Nothing here walks a whole
//  container: each rule is an exact directory, measured with allocated bytes
//  and removed as a unit, then recreated empty.
//

import Foundation

enum CleanupRule: String, CaseIterable, Identifiable, Hashable {
    case caches
    case temp
    case logs
    case savedState
    case splashBoard

    var id: String { rawValue }

    var relative: String {
        switch self {
        case .caches: return "Library/Caches"
        case .temp: return "tmp"
        case .logs: return "Library/Logs"
        case .savedState: return "Library/Saved Application State"
        case .splashBoard: return "Library/SplashBoard"
        }
    }

    var title: String {
        switch self {
        case .caches: return "Caches"
        case .temp: return "tmp"
        case .logs: return "日志"
        case .savedState: return "应用状态快照"
        case .splashBoard: return "启动图缓存"
        }
    }

    var detail: String {
        switch self {
        case .caches: return "Library/Caches，可再生成的缓存"
        case .temp: return "tmp，临时文件"
        case .logs: return "Library/Logs，诊断日志"
        case .savedState: return "Library/Saved Application State"
        case .splashBoard: return "Library/SplashBoard"
        }
    }

    var isSafe: Bool {
        self == .caches || self == .temp
    }
}

enum CleanupMode: String, CaseIterable, Identifiable {
    case safe
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safe: return "安全"
        case .standard: return "标准"
        }
    }

    var rules: [CleanupRule] {
        switch self {
        case .safe: return [.caches, .temp]
        case .standard: return [.caches, .temp, .logs, .savedState, .splashBoard]
        }
    }
}

struct CleanupContainer {
    let path: String
    let identifier: String?
    let displayName: String
}

struct CleanupTarget: Identifiable {
    let containerPath: String
    let identifier: String?
    let displayName: String
    let bytesByRule: [CleanupRule: Int64]
    let files: Int

    var id: String { containerPath }
    var bytes: Int64 { bytesByRule.values.reduce(0, +) }
    var rules: [CleanupRule] { CleanupRule.allCases.filter { bytesByRule[$0] != nil } }
}

struct CleanupPlan {
    let targets: [CleanupTarget]
    let totalBytes: Int64
    let totalFiles: Int
    let scanned: Int
    let failed: [String]
    let date: Date
}

struct CleanupReport {
    let freed: Int64
    let targets: Int
    let failed: [String]

    var summary: String {
        if failed.isEmpty {
            return "已清理 \(targets) 个 App，释放约 \(Format.bytes(freed))。"
        }
        return "已清理 \(targets) 个 App，释放约 \(Format.bytes(freed))；\(failed.count) 项失败。"
    }
}

struct CleanupProgress {
    let phase: String
    let done: Int
    let total: Int
    let current: String?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(done) / Double(total))
    }
}

final class CleanupEngine: @unchecked Sendable {
    static let shared = CleanupEngine()

    private let broker = SandboxBroker.shared

    func scan(mode: CleanupMode,
              containers: [CleanupContainer],
              token: CancelToken,
              progress: @escaping (CleanupProgress) -> Void) -> CleanupPlan {
        let manager = FileManager.default
        var targets: [CleanupTarget] = []
        var failed: [String] = []
        var scanned = 0

        for (index, container) in containers.enumerated() {
            if token.isCancelled { break }
            progress(CleanupProgress(phase: "扫描",
                                     done: index,
                                     total: containers.count,
                                     current: container.displayName))

            defer { broker.release(container.path, quiet: true) }
            guard (try? broker.access(container.path, quiet: true)) != nil else {
                if failed.count < 30 {
                    failed.append("\(container.displayName)：无法取得访问权限")
                }
                continue
            }

            var bytesByRule: [CleanupRule: Int64] = [:]
            var files = 0
            for rule in mode.rules {
                let directory = container.path + "/" + rule.relative
                guard Self.isRealDirectory(directory) else { continue }

                var bytes: Int64 = 0
                var count = 0
                _ = try? FileWalk.walk(root: directory, token: token) { entry in
                    guard !entry.isSymbolicLink, !entry.isDirectory else { return }
                    bytes += entry.allocated > 0 ? entry.allocated : entry.size
                    count += 1
                }
                guard bytes > 0 || count > 0 else { continue }
                bytesByRule[rule] = bytes
                files += count
            }

            if !bytesByRule.isEmpty {
                targets.append(CleanupTarget(containerPath: container.path,
                                             identifier: container.identifier,
                                             displayName: container.displayName,
                                             bytesByRule: bytesByRule,
                                             files: files))
            }
            scanned += 1
        }

        progress(CleanupProgress(phase: "扫描",
                                 done: containers.count,
                                 total: containers.count,
                                 current: nil))

        let sorted = targets.sorted { $0.bytes > $1.bytes }
        return CleanupPlan(targets: sorted,
                           totalBytes: sorted.reduce(0) { $0 + $1.bytes },
                           totalFiles: sorted.reduce(0) { $0 + $1.files },
                           scanned: scanned,
                           failed: failed,
                           date: Date())
    }

    func clean(plan: CleanupPlan,
               token: CancelToken,
               progress: @escaping (CleanupProgress) -> Void) -> CleanupReport {
        let manager = FileManager.default
        var freed: Int64 = 0
        var completed = 0
        var failed: [String] = []

        for (index, target) in plan.targets.enumerated() {
            if token.isCancelled { break }
            progress(CleanupProgress(phase: "清理",
                                     done: index,
                                     total: plan.targets.count,
                                     current: target.displayName))

            defer { broker.release(target.containerPath, quiet: true) }
            guard (try? broker.access(target.containerPath, quiet: true)) != nil else {
                failed.append("\(target.displayName)：无法取得访问权限")
                continue
            }

            var targetFailed = false
            for rule in target.rules {
                let directory = target.containerPath + "/" + rule.relative
                guard Self.isRealDirectory(directory) else { continue }
                do {
                    try manager.removeItem(atPath: directory)
                    try manager.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
                    freed += target.bytesByRule[rule] ?? 0
                } catch {
                    targetFailed = true
                    if failed.count < 30 {
                        failed.append("\(target.displayName) \(rule.title)：\(error.localizedDescription)")
                    }
                }
            }
            if !targetFailed { completed += 1 }
        }

        progress(CleanupProgress(phase: "清理",
                                 done: plan.targets.count,
                                 total: plan.targets.count,
                                 current: nil))
        return CleanupReport(freed: freed, targets: completed, failed: failed)
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink != true
    }
}
