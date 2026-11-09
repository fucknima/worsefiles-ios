//
//  Sandbox.swift
//  WorseFiles
//
//  Handle pool around worse_query(). One consumed extension is enough for a
//  directory and everything under it, but a few are kept around so moving
//  between neighbouring folders does not pay for a container query every time.
//

import Foundation

enum SandboxError: LocalizedError {
    case notConsumed
    case missingGroup(String)
    case missingFunctions
    case queryFailed
    case symlinkFailed
    case rejected
    case tokenRefused
    case targetMissing(String)
    case code(Int64)

    var errorDescription: String? {
        switch self {
        case .notConsumed:
            return "没有可用的沙盒扩展。"
        case .missingGroup(let group):
            return "App Group 不可用：\(group)。当前签名没有授予可用的 App Groups entitlement，或容器无法打开。"
        case .missingFunctions:
            return "无法解析 containermanager 或 sandbox_extension 函数，当前系统可能不受支持。"
        case .queryFailed:
            return "container_query 创建失败。"
        case .symlinkFailed:
            return "无法在 App Group 的 Library/Caches 建立符号链接。"
        case .rejected:
            return "containermanagerd 拒绝了查询。目标路径可能不存在，或系统不允许。"
        case .tokenRefused:
            return "内核拒绝签发沙盒扩展。"
        case .targetMissing(let path):
            return "目标不存在：\(path)"
        case .code(let code):
            return "worse_query 返回 \(code)。"
        }
    }

    static func from(code: Int64, path: String) -> SandboxError {
        switch code {
        case -255: return .targetMissing(path)
        case -1: return .missingGroup(AppSettings.appGroupID)
        case -2: return .missingFunctions
        case -3: return .queryFailed
        case -4: return .symlinkFailed
        case -5: return .rejected
        case -6: return .tokenRefused
        default: return .code(code)
        }
    }
}

final class SandboxBroker: @unchecked Sendable {
    static let shared = SandboxBroker()

    private let queue = DispatchQueue(label: "com.kestrel.worsefiles.sandbox")
    private var handles: [String: Int64] = [:]
    private var order: [String] = []
    private let limit = 6

    @discardableResult
    func access(_ path: String, quiet: Bool = false) throws -> Int64 {
        let key = PathTool.canonical(path)
        return try queue.sync {
            if let existing = handles[key] {
                touchLocked(key)
                return existing
            }
            evictIfNeededLocked()
            let group = AppSettings.appGroupID
            let alt = SandboxBroker.needsAlternateFlags(for: key)
            let handle = worse_query(key, group, alt, false)
            guard handle >= 0 else {
                let error = SandboxError.from(code: handle, path: key)
                Log.error("access \(key): \(error.localizedDescription)")
                throw error
            }
            handles[key] = handle
            order.append(key)
            if !quiet {
                Log.info("access \(key) → \(handle)")
            }
            return handle
        }
    }

    func release(_ path: String, quiet: Bool = false) {
        let key = PathTool.canonical(path)
        queue.sync {
            releaseLocked(key, quiet: quiet)
        }
    }

    func releaseAll() {
        queue.sync {
            for (_, handle) in handles {
                worse_query_release(handle)
            }
            handles.removeAll()
            order.removeAll()
            Log.info("release all sandbox handles")
        }
    }

    var count: Int {
        queue.sync { handles.count }
    }

    // ios 26.x wants a different flag value when the target is an app group.
    private static func needsAlternateFlags(for path: String) -> Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
            && path.contains("/var/mobile/Containers/Shared/AppGroup")
    }

    private func touchLocked(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeededLocked() {
        while handles.count >= limit, let oldest = order.first {
            releaseLocked(oldest)
        }
    }

    private func releaseLocked(_ key: String, quiet: Bool = false) {
        order.removeAll { $0 == key }
        guard let handle = handles.removeValue(forKey: key) else { return }
        worse_query_release(handle)
        if !quiet {
            Log.info("release \(key)")
        }
    }
}
