//
//  AppNames.swift
//  WorseFiles
//
//  Display names for bundle identifiers. LaunchServices' API is unavailable
//  on iOS 27, so the name database is parsed out of lsd's CSStore inside an
//  InternalDaemon container, with a built-in table for Apple's apps.
//  CSStore parser and table derived from WQ Files by kolbicz, GPL-3.0.
//

import Foundation
import Combine

extension Notification.Name {
    static let worseFilesNamesUpdated = Notification.Name("WorseFilesNamesUpdated")
}

@MainActor
final class AppNames: ObservableObject {
    static let shared = AppNames()

    @Published private(set) var databaseCount = 0
    @Published private(set) var loaded = false

    private var database: [String: String] = [:]
    private var localized: [String: String] = [:]
    private var attempted: Set<String> = []
    private var enriching = false
    private var loading = false

    // Exact name, built-in name, or the closest parent app plus the last
    // identifier component (extensions and services).
    func name(for identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        if let exact = baseName(identifier) { return exact }

        var parts = identifier.split(separator: ".").map(String.init)
        guard let leaf = parts.last else { return nil }
        while parts.count > 2 {
            parts.removeLast()
            let prefix = parts.joined(separator: ".")
            if let parent = baseName(prefix) {
                return "\(parent) · \(leaf)"
            }
        }
        return nil
    }

    func ensureLoaded(daemonContainers: [String]) {
        guard !loaded, !loading, !daemonContainers.isEmpty else { return }
        loading = true
        let containers = daemonContainers

        Task.detached(priority: .utility) {
            let broker = SandboxBroker.shared
            var found: [String: String] = [:]
            var containersByPath: [String: String] = [:]
            var bundlePaths: [String: String] = [:]

            for container in containers {
                guard (try? broker.access(container, quiet: true)) != nil else { continue }
                defer { broker.release(container, quiet: true) }
                guard WFLaunchCatalogLoadFromContainer(container) else { continue }
                let snapshot = WFLaunchCatalogSnapshot()
                let display = snapshot["displayNames"] as? [String: String] ?? [:]
                let bundleNames = snapshot["bundleNames"] as? [String: String] ?? [:]
                containersByPath = snapshot["containers"] as? [String: String] ?? [:]
                bundlePaths = snapshot["bundlePaths"] as? [String: String] ?? [:]
                found = bundleNames.merging(display) { _, displayName in displayName }
                if !found.isEmpty { break }
            }

            let result = found
            let paths = containersByPath
            let bundles = bundlePaths
            await MainActor.run {
                self.loading = false
                AppCatalog.shared.setMaps(containerBundleIDs: paths, bundlePaths: bundles)
                guard !result.isEmpty else { return }
                self.database = result
                self.databaseCount = result.count
                self.loaded = true
                self.publish()
            }
        }
    }

    // Reads zh-Hans InfoPlist.strings from the app bundle when the bundle is
    // reachable. MCM may refuse the path; a miss is cached for this launch.
    func enrich(_ identifiers: [String]) {
        guard !enriching else { return }
        var todo: [String] = []
        for identifier in Set(identifiers) {
            guard !identifier.isEmpty,
                  localized[identifier] == nil,
                  !attempted.contains(identifier) else { continue }
            attempted.insert(identifier)
            todo.append(identifier)
        }
        guard !todo.isEmpty else { return }

        enriching = true
        let batch = Array(todo.prefix(400))
        Task.detached(priority: .utility) {
            let broker = SandboxBroker.shared
            var names: [String: String] = [:]
            var bundles: [String: String] = [:]

            for identifier in batch {
                guard let bundle = InstalledApps.bundlePath(for: identifier) else { continue }
                var leases: [String] = []
                if (try? broker.access(bundle, quiet: true)) != nil {
                    leases.append(bundle)
                } else {
                    let parent = PathTool.parent(of: bundle)
                    if (try? broker.access(parent, quiet: true)) != nil {
                        leases.append(parent)
                    }
                }
                defer {
                    for lease in leases {
                        broker.release(lease, quiet: true)
                    }
                }
                if let name = WFLocalizedNameAtBundlePath(bundle), !name.isEmpty {
                    names[identifier] = name
                }
                bundles[identifier] = bundle
            }

            let foundNames = names
            let foundBundles = bundles
            await MainActor.run {
                self.enriching = false
                if !foundNames.isEmpty {
                    self.localized.merge(foundNames) { _, new in new }
                }
                if !foundBundles.isEmpty {
                    _ = Catalog.shared.setAppBundlePaths(foundBundles)
                }
                if !foundNames.isEmpty {
                    self.publish()
                }
            }
        }
    }

    private func baseName(_ identifier: String) -> String? {
        if let name = localized[identifier], !name.isEmpty { return name }
        if let name = database[identifier], !name.isEmpty { return name }
        if let name = WFBuiltinAppName(identifier), !name.isEmpty { return name }
        return nil
    }

    private func publish() {
        var names: [String: String] = [:]
        for (_, identifier) in Catalog.shared.disk.labels {
            if let name = name(for: identifier) {
                names[identifier] = name
            }
        }
        for (identifier, databaseName) in database {
            names[identifier] = name(for: identifier) ?? databaseName
        }
        _ = Catalog.shared.setAppNames(names)
        Log.info("app names loaded: \(databaseCount) from LaunchServices store")
        NotificationCenter.default.post(name: .worseFilesNamesUpdated, object: nil)
    }
}
