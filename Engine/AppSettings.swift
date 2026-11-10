//
//  AppSettings.swift
//  WorseFiles
//

import Foundation

enum SettingsKey {
    static let showHidden = "showHidden"
    static let foldersFirst = "foldersFirst"
    static let sortKey = "sortKey"
    static let sortAscending = "sortAscending"
    static let maxInode = "maxInodeOverride"
    static let autoResolveLabels = "autoResolveLabels"
    static let cleanupIncludesDaemons = "cleanupIncludesDaemons"
    static let restoreSnapshot = "restoreSnapshot"
    static let hasSeenIntro = "hasSeenIntro"
}

enum AppSettings {
    static let defaultGroupID = "group.com.kestrel.worsefiles"

    // Never a user-editable preference: the group is whatever the signer
    // actually granted. SandboxBroker and FileService ask this every time.
    static var appGroupID: String { AppGroupResolver.active }

    static var autoResolveLabels: Bool {
        get {
            if UserDefaults.standard.object(forKey: SettingsKey.autoResolveLabels) == nil { return true }
            return UserDefaults.standard.bool(forKey: SettingsKey.autoResolveLabels)
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.autoResolveLabels) }
    }

    static var showHidden: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKey.showHidden) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.showHidden) }
    }

    // Off by default: a cache cleanup should not touch system daemons.
    static var cleanupIncludesDaemons: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKey.cleanupIncludesDaemons) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.cleanupIncludesDaemons) }
    }

    // Snapshot the destination folder before a restore overwrites it.
    static var restoreSnapshot: Bool {
        get {
            if UserDefaults.standard.object(forKey: SettingsKey.restoreSnapshot) == nil { return true }
            return UserDefaults.standard.bool(forKey: SettingsKey.restoreSnapshot)
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.restoreSnapshot) }
    }

    static var hasSeenIntro: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKey.hasSeenIntro) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.hasSeenIntro) }
    }

    static var foldersFirst: Bool {
        get {
            if UserDefaults.standard.object(forKey: SettingsKey.foldersFirst) == nil { return true }
            return UserDefaults.standard.bool(forKey: SettingsKey.foldersFirst)
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.foldersFirst) }
    }

    static var sortKey: SortKey {
        get {
            let raw = UserDefaults.standard.string(forKey: SettingsKey.sortKey) ?? ""
            return SortKey(rawValue: raw) ?? .name
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.sortKey) }
    }

    static var sortAscending: Bool {
        get {
            if UserDefaults.standard.object(forKey: SettingsKey.sortAscending) == nil { return true }
            return UserDefaults.standard.bool(forKey: SettingsKey.sortAscending)
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.sortAscending) }
    }

    // Blank means "use the inode of a freshly created file as the upper bound",
    // the same trick worse_query's own demo uses.
    static var maxInodeOverride: UInt64? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: SettingsKey.maxInode),
                  let value = UInt64(raw), value > 0 else { return nil }
            return value
        }
        set {
            if let value = newValue {
                UserDefaults.standard.set(String(value), forKey: SettingsKey.maxInode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.maxInode)
            }
        }
    }

    static var sortOrder: SortOrder {
        SortOrder(key: sortKey, ascending: sortAscending, foldersFirst: foldersFirst)
    }

    static func save(_ order: SortOrder) {
        sortKey = order.key
        sortAscending = order.ascending
        foldersFirst = order.foldersFirst
    }
}
