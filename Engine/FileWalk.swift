//
//  FileWalk.swift
//  WorseFiles
//
//  Shared streaming walk used by cleanup and backups. Foundation's enumerator
//  does not descend into symbolic links; every entry is still reported so the
//  caller can keep or copy the link itself.
//

import Foundation

struct WalkEntry {
    let path: String
    let relative: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let allocated: Int64
    let modified: Date?
    let permissions: mode_t
    let symlinkTarget: String?
}

enum FileWalk {
    struct Options {
        var skip: ((String) -> Bool)?
        var maxDepth = 64
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isRegularFileKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
    ]

    @discardableResult
    static func walk(root: String,
                     options: Options = Options(),
                     token: CancelToken? = nil,
                     visit: (WalkEntry) throws -> Void) throws -> Int {
        let base = PathTool.canonical(root)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: base, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard let enumerator = manager.enumerator(at: URL(fileURLWithPath: base),
                                                  includingPropertiesForKeys: keys,
                                                  options: [],
                                                  errorHandler: { _, _ in true }) else {
            throw CocoaError(.fileReadUnknown)
        }

        var count = 0
        for case let url as URL in enumerator {
            if token?.isCancelled == true { break }

            let path = url.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            if relative.isEmpty { continue }

            let depth = relative.split(separator: "/").count
            if depth > options.maxDepth {
                enumerator.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let isLink = values?.isSymbolicLink ?? false
            let isDir = values?.isDirectory ?? false

            if let skip = options.skip, skip(relative) {
                if isDir && !isLink { enumerator.skipDescendants() }
                continue
            }

            let linkTarget = isLink
                ? try? manager.destinationOfSymbolicLink(atPath: path)
                : nil
            let entry = WalkEntry(path: path,
                                  relative: relative,
                                  isDirectory: isDir,
                                  isSymbolicLink: isLink,
                                  size: Int64(values?.fileSize ?? 0),
                                  allocated: Int64(values?.totalFileAllocatedSize ?? 0),
                                  modified: values?.contentModificationDate,
                                  permissions: 0,
                                  symlinkTarget: linkTarget)
            try visit(entry)
            count += 1

            if isDir && isLink {
                // Never recurse through a link, even if the enumerator would.
                enumerator.skipDescendants()
            }
        }
        return count
    }
}
