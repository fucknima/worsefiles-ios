//
//  AppModel.swift
//  WorseFiles
//

import Foundation
import SwiftUI
import UIKit

struct Favorite: Codable, Identifiable, Hashable {
    var path: String
    var title: String
    var id: String { path }
}

struct Recent: Codable, Identifiable, Hashable {
    var path: String
    var title: String
    var date: Date
    var id: String { path }
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published var navPath: [BrowseTarget] = []
    @Published var favorites: [Favorite] = []
    @Published var recents: [Recent] = []
    @Published var clipboard: ClipboardItem?
    @Published var notice: Notice?

    private let favoritesKey = "favorites.v1"
    private let recentsKey = "recents.v1"
    private var noticeTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var didInitialIndexCheck = false

    init() {
        load()
        JobCenter.shared.register()
        FileService.shared.prepare()
        Log.info("WorseFiles started, iOS \(Roots.majorVersion)")
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshIndexOnActivate()
            }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func refreshIndexOnLaunch() async {
        guard !didInitialIndexCheck else { return }
        didInitialIndexCheck = true
        guard Catalog.shared.hasSharedScan else { return }
        await refreshIndex(announce: false)
    }

    func refreshIndexOnActivate() async {
        guard Catalog.shared.hasSharedScan else { return }
        await refreshIndex(announce: true)
    }

    private func refreshIndex(announce: Bool) async {
        AppNames.shared.ensureLoaded(daemonContainers: Catalog.shared.scanRecord(for: Roots.internalDaemon.path)?.paths ?? [])
        let reconcile = await ContainerIndex.shared.reconcileIfNeeded(minInterval: 5)
        do {
            let summary = try await ContainerIndex.shared.ensureScanned(full: false)
            guard announce else { return }
            let addedApps = summary.addedApps + (reconcile?.addedApps ?? 0)
            let removedApps = reconcile?.removedApps ?? 0
            let addedContainers = summary.added + (reconcile?.added ?? 0)
            let removedContainers = reconcile?.removed ?? 0
            if addedApps > 0 && removedApps > 0 {
                flash("已同步：新增 \(addedApps) 个 App，移除 \(removedApps) 个 App")
            } else if removedApps > 0 {
                flash("已移除 \(removedApps) 个 App")
            } else if addedApps > 0 {
                flash("已更新 \(addedApps) 个 App")
            } else if addedContainers > 0 && removedContainers > 0 {
                flash("已同步：新增 \(addedContainers) 个容器，移除 \(removedContainers) 个容器")
            } else if removedContainers > 0 {
                flash("已移除 \(removedContainers) 个失效容器")
            } else if addedContainers > 0 {
                flash("已更新 \(addedContainers) 个容器")
            }
        } catch let error as ContainerIndexError {
            if case .cancelled = error { return }
            Log.error("index refresh: \(error.localizedDescription)")
        } catch {
            Log.error("index refresh: \(error.localizedDescription)")
        }
    }

    func open(_ target: BrowseTarget) {
        navPath.append(target)
    }

    var favoritePaths: Set<String> {
        Set(favorites.map { PathTool.canonical($0.path) })
    }

    func isFavorite(_ path: String) -> Bool {
        favoritePaths.contains(PathTool.canonical(path))
    }

    func toggleFavorite(path: String, title: String) {
        let key = PathTool.canonical(path)
        if let index = favorites.firstIndex(where: { PathTool.canonical($0.path) == key }) {
            favorites.remove(at: index)
            save()
            flash("已取消收藏")
        } else {
            favorites.insert(Favorite(path: key, title: title), at: 0)
            save()
            flash("已收藏到主页")
        }
    }

    func removeFavorite(_ favorite: Favorite) {
        favorites.removeAll { $0.path == favorite.path }
        save()
        flash("已取消收藏")
    }

    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        save()
    }

    func record(path: String, title: String) {
        let key = PathTool.canonical(path)
        guard key != "/" else { return }
        let entry = Recent(path: key, title: title, date: Date())
        recents.removeAll { $0.path == key }
        recents.insert(entry, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        save()
    }

    func removeRecent(_ recent: Recent) {
        recents.removeAll { $0.path == recent.path }
        save()
    }

    func setClipboard(_ item: ClipboardItem) {
        clipboard = item
        flash(item.moving ? "已剪切 \(item.paths.count) 项" : "已复制 \(item.paths.count) 项")
    }

    func clearClipboard() {
        clipboard = nil
    }

    func flash(_ text: String, error: Bool = false) {
        noticeTask?.cancel()
        let next = Notice(text: text, isError: error)
        notice = next
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: error ? 5_000_000_000 : 2_400_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.notice?.id == next.id {
                withAnimation(.easeOut(duration: 0.2)) { self.notice = nil }
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(favorites) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
        if let data = try? encoder.encode(recents) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let stored = try? decoder.decode([Favorite].self, from: data) {
            favorites = stored
        }
        if let data = UserDefaults.standard.data(forKey: recentsKey),
           let stored = try? decoder.decode([Recent].self, from: data) {
            recents = stored
        }
    }
}
