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

            for container in containers {
                guard (try? broker.access(container, quiet: true)) != nil else { continue }
                defer { broker.release(container, quiet: true) }
                if let names = WFLaunchServicesNames(container) as? [String: String],
                   !names.isEmpty {
                    found = names
                    break
                }
            }

            let result = found
            await MainActor.run {
                self.loading = false
                guard !result.isEmpty else { return }
                self.database = result
                self.databaseCount = result.count
                self.loaded = true
                self.publish()
            }
        }
    }

    private func baseName(_ identifier: String) -> String? {
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
        for (identifier, name) in database {
            names[identifier] = name
        }
        _ = Catalog.shared.setAppNames(names)
        Log.info("app names loaded: \(databaseCount) from LaunchServices store")
        NotificationCenter.default.post(name: .worseFilesNamesUpdated, object: nil)
    }
}
