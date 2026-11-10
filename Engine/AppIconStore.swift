//
//  AppIconStore.swift
//  WorseFiles
//
//  Container rows show the app icon when LaunchServices can supply one.
//  Icons are resolved off the main thread and cached in Application Support,
//  so a second visit does not ask LaunchServices again.
//

import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppIconStore: ObservableObject {
    static let shared = AppIconStore()

    // Bumped after an icon lands; the browser re-reads the cached data.
    @Published private(set) var revision = 0
    private(set) var missCount = 0

    var cachedCount: Int { memory.count }

    private var memory: [String: Data] = [:]
    private var pending: Set<String> = []
    private let directory: URL?
    private let queue = DispatchQueue(label: "com.kestrel.worsefiles.icons", qos: .utility)

    private init() {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory,
                                         in: .userDomainMask).first else {
            directory = nil
            return
        }
        let base = support.appendingPathComponent("WorseFiles", isDirectory: true)
        // v2: format-2 only. Old files may hold alternate-format glyphs,
        // which is why some rows showed another app's icon.
        try? manager.removeItem(at: base.appendingPathComponent("icons", isDirectory: true))
        let url = base.appendingPathComponent("icons-v2", isDirectory: true)
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
    }

    // Memory first, then the on-disk cache. Never schedules a fetch.
    func cachedIcon(for identifier: String) -> Data? {
        if let data = memory[identifier] { return data }
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(Self.fileName(identifier))
        guard let data = try? Data(contentsOf: url) else { return nil }
        memory[identifier] = data
        return data
    }

    // Returns a cached icon and starts a background fetch when it is missing.
    func icon(for identifier: String) -> Data? {
        if let data = cachedIcon(for: identifier) { return data }
        request(identifier)
        return nil
    }

    // WQ Files draws the icon while configuring the cell. Do the same here:
    // UIKit alone, on the main thread, no proxy or bundle reads. This is what
    // makes a visible row show the real icon immediately instead of waiting
    // behind a serial background queue.
    func iconNow(for identifier: String) -> Data? {
        if let data = cachedIcon(for: identifier) { return data }
        guard let data = Self.quickIcon(identifier) else { return nil }
        memory[identifier] = data
        if let directory {
            let fileURL = directory.appendingPathComponent(Self.fileName(identifier))
            queue.async {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        return data
    }

    nonisolated private static func quickIcon(_ identifier: String) -> Data? {
        if let data = WFQuickIconData(identifier) { return data }
        // Extensions and services: closest parent that UIKit knows.
        var candidate = identifier
        while let dot = candidate.lastIndex(of: ".") {
            candidate = String(candidate[..<dot])
            guard candidate.contains(".") else { break }
            if let data = WFQuickIconData(candidate) { return data }
        }
        return nil
    }

    func prefetch(_ identifiers: [String], limit: Int = 80) {
        var seen = Set<String>()
        var count = 0
        for identifier in identifiers {
            guard !identifier.isEmpty, seen.insert(identifier).inserted else { continue }
            request(identifier)
            count += 1
            if count >= limit { break }
        }
    }

    // Called by a row when it becomes visible, so a long list fetches icons
    // as it scrolls instead of asking UIKit for a thousand icons at once.
    func requestVisible(_ identifier: String) {
        request(identifier)
    }

    private func request(_ identifier: String) {
        guard !identifier.isEmpty, !pending.contains(identifier) else { return }
        guard memory[identifier] == nil else { return }
        pending.insert(identifier)

        let directory = self.directory
        let bundlePath = Catalog.shared.appBundlePath(for: identifier)
        queue.async { [weak self] in
            let fileURL = directory?.appendingPathComponent(Self.fileName(identifier))

            if let fileURL, let cached = try? Data(contentsOf: fileURL) {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(identifier)
                    self.memory[identifier] = cached
                }
                return
            }

            let data = Self.fetchIcon(identifier, bundlePath: bundlePath)
            if let data, let fileURL {
                try? data.write(to: fileURL, options: .atomic)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(identifier)
                guard let data else {
                    self.missCount += 1
                    return
                }
                self.memory[identifier] = data
                self.revision += 1
            }
        }
    }

    nonisolated private static func fetchIcon(_ identifier: String, bundlePath: String?) -> Data? {
        if let data = WFAppIconData(identifier) { return data }

        // A plugin or daemon often has no proxy of its own. Walk up the
        // reverse-DNS identifier until an installed app answers. Try this
        // before bundle reads, which are usually refused on iOS 27.
        var candidate = identifier
        while let dot = candidate.lastIndex(of: ".") {
            candidate = String(candidate[..<dot])
            guard candidate.contains(".") else { break }
            if let data = WFAppIconData(candidate) { return data }
        }

        if let bundlePath, let data = bundleIcon(bundlePath) { return data }
        if let path = InstalledApps.bundlePath(for: identifier),
           let data = bundleIcon(path) {
            return data
        }
        return nil
    }

    nonisolated private static func bundleIcon(_ path: String) -> Data? {
        let broker = SandboxBroker.shared
        var leases: [String] = []
        if (try? broker.access(path, quiet: true)) != nil {
            leases.append(path)
        }
        if leases.isEmpty {
            let container = (path as NSString).deletingLastPathComponent
            if (try? broker.access(container, quiet: true)) != nil {
                leases.append(container)
            }
        }
        defer {
            for lease in leases {
                broker.release(lease, quiet: true)
            }
        }
        return WFBundleIconData(path) as Data?
    }

    nonisolated private static func fileName(_ identifier: String) -> String {
        let safe = identifier.map { character -> Character in
            if character.isLetter || character.isNumber || character == "." || character == "-" {
                return character
            }
            return "_"
        }
        return String(safe) + ".png"
    }
}
