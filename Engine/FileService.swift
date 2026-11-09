//
//  FileService.swift
//  WorseFiles
//
//  Every filesystem call runs on one serial queue. Sandbox extension
//  consumption is serialized by the broker anyway, and this keeps a paste
//  from moving the ground under a directory listing.
//

import Foundation

struct TextReadResult {
    let text: String
    let truncated: Bool
    let bytes: Int64
    let encoding: String
}

final class FileService: @unchecked Sendable {
    static let shared = FileService()

    private let queue = DispatchQueue(label: "com.kestrel.worsefiles.fs")
    private let manager = FileManager.default
    private let broker = SandboxBroker.shared
    private let tempRoot: URL

    private init() {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorseFiles", isDirectory: true)
    }

    // MARK: - Lifecycle

    func prepare() {
        queue.sync {
            try? manager.removeItem(at: tempRoot)
            try? manager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            Log.info("temp root ready at \(tempRoot.path)")
        }
    }

    var temporaryRoot: URL { tempRoot }

    // MARK: - Listing

    func list(path: String,
              includeHidden: Bool,
              resolveIdentifiers: Bool = false) throws -> [FSItem] {
        try queue.sync {
            let key = PathTool.canonical(path)
            try grantLocked(key, preferParent: false)
            let directory = URL(fileURLWithPath: key)
            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey,
                .contentModificationDateKey
            ]
            let children = try manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )

            var items: [FSItem] = []
            items.reserveCapacity(children.count)

            for child in children {
                let name = child.lastPathComponent
                if !includeHidden && name.hasPrefix(".") { continue }
                let values = try? child.resourceValues(forKeys: Set(keys))
                let isDirectory = values?.isDirectory ?? false
                let isLink = values?.isSymbolicLink ?? false
                let isHidden = values?.isHidden ?? name.hasPrefix(".")
                let size = Int64(values?.fileSize ?? 0)
                let modified = values?.contentModificationDate
                var identifier: String?
                if resolveIdentifiers && isDirectory {
                    identifier = ContainerMetadata.identifier(atPath: child.path)
                }
                items.append(FSItem(path: child.path,
                                    name: name,
                                    isDirectory: isDirectory,
                                    isSymbolicLink: isLink,
                                    isHidden: isHidden,
                                    size: size,
                                    modified: modified,
                                    identifier: identifier))
            }
            return items
        }
    }

    // MARK: - Names and labels

    func releaseAllExtensions() {
        queue.sync {
            broker.releaseAll()
        }
    }

    func identifier(for path: String, ensureAccess: Bool = true) -> String? {
        queue.sync {
            let key = PathTool.canonical(path)
            if ensureAccess && !nativelyAccessible(key) {
                if (try? broker.access(key)) == nil {
                    _ = try? broker.access(PathTool.parent(of: key))
                }
            }
            return ContainerMetadata.identifier(atPath: key)
        }
    }

    func facts(for path: String, ensureAccess: Bool = true) -> ContainerFacts? {
        queue.sync {
            let key = PathTool.canonical(path)
            // The identifier xattr usually resolves without a token. Only pay
            // for a container query when the metadata plist is needed.
            if let facts = ContainerMetadata.facts(atPath: key), facts.identifier != nil {
                return facts
            }
            if ensureAccess && !nativelyAccessible(key) {
                if (try? broker.access(key)) == nil {
                    _ = try? broker.access(PathTool.parent(of: key))
                }
            }
            return ContainerMetadata.facts(atPath: key)
        }
    }

    static func nameProblem(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "名称不能为空" }
        if name == "." || name == ".." { return "名称不能是 . 或 .." }
        if name.contains("/") { return "名称不能包含 /" }
        if name.count > 255 { return "名称过长" }
        return nil
    }

    // MARK: - Read and write

    func readText(path: String, maxBytes: Int = 4_000_000) throws -> TextReadResult {
        try queue.sync {
            let key = PathTool.canonical(path)
            try grantAllLocked([key, PathTool.parent(of: key)])
            let url = URL(fileURLWithPath: key)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            let total = Int64(end)
            let data = try handle.read(upToCount: maxBytes) ?? Data()
            let truncated = total > Int64(data.count)

            let hasBOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
            if data.contains(0) && !hasBOM {
                throw NSError(domain: "WorseFiles", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "检测到二进制内容，未按文本打开。"])
            }

            if let text = String(data: data, encoding: .utf8) {
                return TextReadResult(text: text, truncated: truncated,
                                      bytes: total, encoding: "UTF-8")
            }
            if let text = String(data: data, encoding: .utf16) {
                return TextReadResult(text: text, truncated: truncated,
                                      bytes: total, encoding: "UTF-16")
            }
            if let text = String(data: data, encoding: .isoLatin1) {
                return TextReadResult(text: text, truncated: truncated,
                                      bytes: total, encoding: "Latin-1")
            }
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
    }

    func writeText(path: String, text: String, encoding sourceEncoding: String? = nil) throws {
        try queue.sync {
            let key = PathTool.canonical(path)
            try grantAllLocked([PathTool.parent(of: key), key])
            let targetEncoding: String.Encoding
            switch sourceEncoding {
            case "UTF-16": targetEncoding = .utf16
            case "Latin-1": targetEncoding = .isoLatin1
            default: targetEncoding = .utf8
            }
            guard let data = text.data(using: targetEncoding) ?? text.data(using: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            let url = URL(fileURLWithPath: key)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // A per-file extension can write the file but cannot create
                // the sibling temp file an atomic write needs.
                try data.write(to: url, options: [])
            }
            try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: key)
        }
    }

    // MARK: - Mutations

    @discardableResult
    func createFolder(in parent: String, name: String) throws -> String {
        if let problem = FileService.nameProblem(name) {
            throw NSError(domain: "WorseFiles", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: problem])
        }
        return try queue.sync {
            let parentKey = PathTool.canonical(parent)
            try grantLocked(parentKey, preferParent: false)
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = URL(fileURLWithPath: parentKey).appendingPathComponent(clean)
            if manager.fileExists(atPath: destination.path) {
                throw NSError(domain: "WorseFiles", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "已存在同名项目"])
            }
            try manager.createDirectory(at: destination, withIntermediateDirectories: false)
            broker.releaseAll()
            return destination.path
        }
    }

    func rename(path: String, to newName: String) throws -> String {
        if let problem = FileService.nameProblem(newName) {
            throw NSError(domain: "WorseFiles", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: problem])
        }
        return try queue.sync {
            let source = PathTool.canonical(path)
            let parent = PathTool.parent(of: source)
            try grantLocked(parent, preferParent: false)
            let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = URL(fileURLWithPath: parent).appendingPathComponent(clean)
            if destination.path == source { return source }
            if manager.fileExists(atPath: destination.path) {
                throw NSError(domain: "WorseFiles", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "已存在同名项目"])
            }
            try manager.moveItem(at: URL(fileURLWithPath: source), to: destination)
            broker.releaseAll()
            return destination.path
        }
    }

    func remove(paths: [String]) -> OpFailures {
        queue.sync {
            var result = OpFailures()
            for path in paths {
                let key = PathTool.canonical(path)
                do {
                    try grantLocked(key, preferParent: true)
                    try manager.removeItem(at: URL(fileURLWithPath: key))
                    result.done += 1
                } catch {
                    result.messages.append("\(PathTool.name(of: key))：\(error.localizedDescription)")
                }
            }
            broker.releaseAll()
            return result
        }
    }

    func transfer(paths: [String], to destination: String, moving: Bool) -> OpFailures {
        queue.sync {
            var result = OpFailures()
            let destinationKey = PathTool.canonical(destination)
            do {
                try grantLocked(destinationKey, preferParent: false)
            } catch {
                result.messages.append("目标目录：\(error.localizedDescription)")
                return result
            }

            for path in paths {
                let sourceKey = PathTool.canonical(path)
                let sourceParent = PathTool.parent(of: sourceKey)
                do {
                    if moving {
                        try grantAllLocked([sourceParent])
                    } else {
                        try grantAllLocked([sourceKey, sourceParent])
                    }
                } catch {
                    result.messages.append("\(PathTool.name(of: sourceKey))：\(error.localizedDescription)")
                    continue
                }

                let sourceIsDirectory = isDirectory(sourceKey)
                if sourceIsDirectory && PathTool.isDescendant(destinationKey, of: sourceKey) {
                    result.messages.append("\(PathTool.name(of: sourceKey))：不能放进自身")
                    continue
                }
                if moving && PathTool.canonical(sourceParent) == destinationKey {
                    result.done += 1
                    continue
                }

                // Keep the destination's extension alive across a multi-item
                // transfer; granting each source can push it out of the LRU.
                _ = try? broker.access(destinationKey)

                let sourceURL = URL(fileURLWithPath: sourceKey)
                let targetURL = uniqueURL(for: sourceURL,
                                          in: URL(fileURLWithPath: destinationKey),
                                          isDirectory: sourceIsDirectory)
                do {
                    if moving {
                        try manager.moveItem(at: sourceURL, to: targetURL)
                    } else {
                        try manager.copyItem(at: sourceURL, to: targetURL)
                    }
                    result.done += 1
                } catch {
                    result.messages.append("\(PathTool.name(of: sourceKey))：\(error.localizedDescription)")
                }
            }
            broker.releaseAll()
            return result
        }
    }

    func duplicate(paths: [String]) -> OpFailures {
        queue.sync {
            var result = OpFailures()
            for path in paths {
                let key = PathTool.canonical(path)
                let parent = PathTool.parent(of: key)
                do {
                    try grantAllLocked([key, parent])
                    let source = URL(fileURLWithPath: key)
                    let target = uniqueURL(for: source,
                                           in: URL(fileURLWithPath: parent),
                                           isDirectory: isDirectory(key))
                    try manager.copyItem(at: source, to: target)
                    result.done += 1
                } catch {
                    result.messages.append("\(PathTool.name(of: key))：\(error.localizedDescription)")
                }
            }
            broker.releaseAll()
            return result
        }
    }

    func importFiles(_ urls: [URL], into destination: String) -> OpFailures {
        queue.sync {
            var result = OpFailures()
            let destinationKey = PathTool.canonical(destination)
            do {
                try grantLocked(destinationKey, preferParent: false)
            } catch {
                result.messages.append("目标目录：\(error.localizedDescription)")
                return result
            }

            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let target = uniqueURL(for: url,
                                           in: URL(fileURLWithPath: destinationKey),
                                           isDirectory: isDirectory(url.path))
                    try manager.copyItem(at: url, to: target)
                    result.done += 1
                } catch {
                    result.messages.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            broker.releaseAll()
            return result
        }
    }

    // Copies items to a fresh temporary directory so QuickLook or the share
    // sheet never holds a reference to a path the sandbox can revoke.
    func export(paths: [String], prefix: String = "Share") throws -> [URL] {
        try queue.sync {
            let directory = tempRoot
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var output: [URL] = []
            for path in paths {
                let key = PathTool.canonical(path)
                try grantAllLocked([key, PathTool.parent(of: key)])
                let source = URL(fileURLWithPath: key)
                let target = uniqueURL(for: source, in: directory, isDirectory: isDirectory(key))
                try manager.copyItem(at: source, to: target)
                output.append(target)
            }
            return output
        }
    }

    func exportSingle(path: String, prefix: String = "Preview") throws -> URL {
        guard let first = try export(paths: [path], prefix: prefix).first else {
            throw CocoaError(.fileReadUnknown)
        }
        return first
    }

    // MARK: - Info

    func info(path: String) -> FileInfo {
        queue.sync {
            let key = PathTool.canonical(path)
            let granted = (try? grantAllLocked([key, PathTool.parent(of: key)])) != nil
            var status = stat()
            let statted = lstat(key, &status) == 0
            let name = PathTool.name(of: key)
            let isLink = statted && (status.st_mode & S_IFMT) == S_IFLNK
            let isDir = statted && (status.st_mode & S_IFMT) == S_IFDIR

            let attributes = try? manager.attributesOfItem(atPath: key)
            let created = attributes?[.creationDate] as? Date
            let modified = attributes?[.modificationDate] as? Date

            var total: Int64 = statted ? Int64(status.st_size) : 0
            var itemCount: Int? = isDir ? 0 : nil
            if isDir {
                let result = directorySize(URL(fileURLWithPath: key))
                total = result.size
                itemCount = result.count
            }

            var target: String?
            if isLink {
                target = try? manager.destinationOfSymbolicLink(atPath: key)
            }

            let identifier = ContainerMetadata.identifier(atPath: key)
            let mode = statted ? status.st_mode : 0
            let readable = granted
            return FileInfo(path: key,
                            name: name,
                            isDirectory: isDir,
                            isSymbolicLink: isLink,
                            readable: readable,
                            size: total,
                            itemCount: itemCount,
                            created: created,
                            modified: modified,
                            permissions: permissionString(mode: mode),
                            owner: statted ? Int(status.st_uid) : 0,
                            group: statted ? Int(status.st_gid) : 0,
                            inode: statted ? UInt64(status.st_ino) : 0,
                            linkCount: statted ? Int(status.st_nlink) : 0,
                            identifier: identifier,
                            symlinkTarget: target)
        }
    }

    func isTextCandidate(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "json", "plist", "xml", "yml", "yaml", "html", "htm",
            "css", "js", "ts", "swift", "m", "mm", "h", "c", "cc", "cpp", "py", "rb", "sh",
            "zsh", "ini", "conf", "log", "csv", "tsv", "sql", "strings", "entitlements",
            "pbxproj", "xcconfig", "gradle", "toml", "rtf", "properties"
        ]
        return textExtensions.contains(ext)
    }

    // MARK: - Diagnostics

    func diagnose() -> [String] {
        queue.sync {
            var lines: [String] = []
            let version = ProcessInfo.processInfo.operatingSystemVersion
            lines.append("系统版本：iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
            lines.append("支持区间：iOS 26.0–26.7.2 / 27.2（worse_query）")
            let snapshot = AppGroupResolver.snapshot(refresh: true)
            lines.append("App Group（自动检测）：\(snapshot.active)")
            lines.append("签名 App Groups：\(snapshot.groups.isEmpty ? "无或不可读" : snapshot.groups.joined(separator: ", "))")
            lines.append("可访问的 App Group：\(snapshot.accessible.isEmpty ? "无" : snapshot.accessible.joined(separator: ", "))")
            let group = snapshot.active
            let groupURL = manager.containerURL(forSecurityApplicationGroupIdentifier: group)
            lines.append("App Group 容器：\(groupURL?.path ?? "不可用")")

            if let groupURL {
                do {
                    let handle = try broker.access(groupURL.path)
                    lines.append("worse_query：成功（handle \(handle)）")
                } catch {
                    lines.append("worse_query：失败 — \(error.localizedDescription)")
                }
                broker.releaseAll()
            } else {
                lines.append("worse_query：跳过，App Group entitlement 不可用")
            }

            let baseline = ContainerScanner.shared.baselineInode()
            lines.append("baseline inode：\(baseline > 0 ? String(baseline) : "不可用")")

            let probeURL = tempRoot.appendingPathComponent("probe-\(UUID().uuidString)")
            if (try? Data("probe".utf8).write(to: probeURL)) != nil {
                var probeStat = stat()
                if stat(probeURL.path, &probeStat) == 0 {
                    let found = pathleak_range(tempRoot.path, UInt64(probeStat.st_ino), UInt64(probeStat.st_ino)) ?? []
                    lines.append("fsgetpath：\(found.contains(probeURL.path) ? "正常" : "未命中")")
                }
                try? manager.removeItem(at: probeURL)
            }

            lines.append("已缓存句柄：\(broker.count)")
            return lines
        }
    }

    // MARK: - Private

    private func grantLocked(_ path: String, preferParent: Bool) throws {
        let key = PathTool.canonical(path)
        if nativelyAccessible(key) { return }
        let preferred = preferParent ? PathTool.parent(of: key) : key
        do {
            try broker.access(preferred)
        } catch {
            let fallback = preferred == key ? PathTool.parent(of: key) : key
            try broker.access(fallback)
        }
    }

    // Sandbox extensions from this primitive can be per-path. Ask for every
    // useful path and succeed if at least one is issued; operations then try
    // their work against whichever grant the kernel accepted.
    private func grantAllLocked(_ paths: [String]) throws {
        var success = false
        var lastError: Error = SandboxError.notConsumed
        for path in paths {
            if nativelyAccessible(path) {
                success = true
                continue
            }
            do {
                _ = try broker.access(path)
                success = true
            } catch {
                lastError = error
            }
        }
        if !success { throw lastError }
    }

    private func nativelyAccessible(_ path: String) -> Bool {
        let key = PathTool.canonical(path)
        if PathTool.isDescendant(key, of: Roots.ownSandbox) { return true }
        if let group = manager.containerURL(forSecurityApplicationGroupIdentifier: AppSettings.appGroupID),
           PathTool.isDescendant(key, of: group.path) {
            return true
        }
        return false
    }

    private func isDirectory(_ path: String) -> Bool {
        var flag = ObjCBool(false)
        return manager.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
    }

    private func uniqueURL(for source: URL, in directory: URL, isDirectory: Bool) -> URL {
        let name = source.lastPathComponent
        var candidate = directory.appendingPathComponent(name)
        if !manager.fileExists(atPath: candidate.path) { return candidate }

        let extensionPart = isDirectory ? "" : source.pathExtension
        let stem = extensionPart.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 2
        while index < 1000 {
            let nextName = extensionPart.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(extensionPart)"
            candidate = directory.appendingPathComponent(nextName)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
        let suffix = String(UUID().uuidString.prefix(6))
        let fallbackName = extensionPart.isEmpty
            ? "\(name) \(suffix)"
            : "\(stem) \(suffix).\(extensionPart)"
        return directory.appendingPathComponent(fallbackName)
    }

    private func directorySize(_ url: URL) -> (size: Int64, count: Int) {
        var total: Int64 = 0
        var count = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = manager.enumerator(at: url,
                                                  includingPropertiesForKeys: keys,
                                                  options: [],
                                                  errorHandler: { _, _ in true }) else {
            return (0, 0)
        }
        for case let child as URL in enumerator {
            count += 1
            if count > 100_000 { break }
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return (total, count)
    }

    private func permissionString(mode: mode_t) -> String {
        let type: Character
        switch mode & S_IFMT {
        case S_IFDIR: type = "d"
        case S_IFLNK: type = "l"
        case S_IFREG: type = "-"
        case S_IFCHR: type = "c"
        case S_IFBLK: type = "b"
        case S_IFIFO: type = "p"
        case S_IFSOCK: type = "s"
        default: type = "?"
        }
        var characters: [Character] = [type]
        let bits: [mode_t] = [
            S_IRUSR, S_IWUSR, S_IXUSR,
            S_IRGRP, S_IWGRP, S_IXGRP,
            S_IROTH, S_IWOTH, S_IXOTH
        ]
        let letters: [Character] = ["r", "w", "x", "r", "w", "x", "r", "w", "x"]
        for (bit, letter) in zip(bits, letters) {
            characters.append((mode & bit) != 0 ? letter : "-")
        }
        let octal = String(mode & 0o777, radix: 8)
        return String(characters) + " (\(octal))"
    }
}
