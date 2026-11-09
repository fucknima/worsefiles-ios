//
//  InstalledApps.swift
//  WorseFiles
//
//  Thin Swift view of the LaunchServices snapshot. This is the live answer to
//  "what apps exist", which the inode watermark cannot give: an uninstall frees
//  inodes and the next install can reuse one below the watermark.
//

import Foundation

struct InstalledAppRecord: Sendable {
    let identifier: String
    let name: String?
    let dataPath: String?
    let bundlePath: String?
    let kind: String
}

enum InstalledApps {
    // nil: LaunchServices unavailable. []: a real empty answer.
    static func snapshot() -> [InstalledAppRecord]? {
        guard let raw = WFInstalledApps() as? [[String: Any]] else { return nil }

        var seen = Set<String>()
        var records: [InstalledAppRecord] = []
        records.reserveCapacity(raw.count)

        for entry in raw {
            guard let identifier = entry["identifier"] as? String, !identifier.isEmpty else { continue }
            guard seen.insert(identifier).inserted else { continue }

            let data = (entry["dataPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let bundle = (entry["bundlePath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let kind = (entry["type"] as? String) ?? ""

            records.append(InstalledAppRecord(identifier: identifier,
                                              name: name,
                                              dataPath: data,
                                              bundlePath: bundle,
                                              kind: kind))
        }
        return records
    }

    static var source: String? {
        WFInstalledAppsSource()
    }

    static func containerPath(for identifier: String) -> String? {
        guard let path = WFContainerPathForIdentifier(identifier), !path.isEmpty else { return nil }
        return path
    }
}
