//
//  BrowserModel.swift
//  WorseFiles
//

import Foundation
import SwiftUI

enum LoadState: Equatable {
    case idle
    case loading
    case refreshing
    case loaded
    case failed(String)
}

struct LabelProgress: Equatable {
    var done: Int
    var total: Int
}

struct TextPrompt: Identifiable {
    enum Kind {
        case newFolder
        case rename(FSItem)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String?
    let initial: String
    let actionTitle: String
}

enum BrowserSheet {
    case info(FSItem)
    case preview(URL)
    case text(FSItem)
    case share([URL])
    case prompt(TextPrompt)
    case importer
}

struct SheetPayload: Identifiable {
    let id = UUID()
    let content: BrowserSheet
}

@MainActor
final class BrowserModel: ObservableObject {
    let path: String

    @Published private(set) var title: String
    @Published private(set) var items: [FSItem] = []
    @Published private(set) var state: LoadState = .idle
    @Published var query = ""
    @Published var errorMessage: String?
    @Published var selectionMode = false
    @Published var selected: Set<String> = []
    @Published var labelProgress: LabelProgress?
    @Published var sheet: SheetPayload?
    @Published var busy: String?
    @Published var sortOrder: SortOrder
    @Published var showHidden: Bool
    @Published var confirmDelete = false
    @Published var pendingDelete: [FSItem] = []
    @Published var appScope: AppDataScope {
        didSet {
            guard oldValue != appScope else { return }
            AppSettings.appDataScope = appScope
            applyScope()
        }
    }

    private let catalog = Catalog.shared
    private var allItems: [FSItem] = []
    private var started = false
    private var loadGeneration = 0
    private var rootUsesIndex = false
    private var labelToken: CancelToken?
    private var labelTask: Task<Void, Never>?
    private var autoLabelSuppressed = false

    init(target: BrowseTarget) {
        let canonical = PathTool.canonical(target.path)
        path = canonical
        if let spec = Roots.spec(for: canonical) {
            title = spec.title
        } else if let label = Catalog.shared.label(for: canonical) {
            title = Catalog.shared.appName(for: label) ?? AppNames.shared.name(for: label) ?? label
        } else {
            title = target.title ?? PathTool.name(of: canonical)
        }
        sortOrder = AppSettings.sortOrder
        showHidden = AppSettings.showHidden
        appScope = AppSettings.appDataScope
    }

    // MARK: - Derived

    var visibleItems: [FSItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || ($0.identifier?.localizedCaseInsensitiveContains(needle) ?? false)
                || ($0.appName?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var selectedItems: [FSItem] {
        items.filter { selected.contains($0.path) }
    }

    var isRootContainer: Bool { Roots.spec(for: path) != nil }

    var isAppRoot: Bool { PathTool.canonical(Roots.dataApplication.path) == path }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        await load(forceScan: false)
    }

    func refresh() async {
        if let spec = Roots.spec(for: path) {
            loadGeneration += 1
            let generation = loadGeneration
            await loadRoot(spec, forceScan: true, generation: generation)
        } else {
            await loadDirectory()
        }
    }

    // MARK: - Loading

    func load(forceScan: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration

        if let spec = Roots.spec(for: path) {
            await loadRoot(spec, forceScan: forceScan, generation: generation)
            return
        }
        await loadDirectory(generation: generation)
    }

    private func loadDirectory(generation: Int? = nil) async {
        let currentGeneration = generation ?? {
            loadGeneration += 1
            return loadGeneration
        }()
        let current = path

        if items.isEmpty { state = .loading } else { state = .refreshing }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try FileService.shared.list(path: current,
                                            includeHidden: AppSettings.showHidden,
                                            resolveIdentifiers: true)
            }.value
            guard currentGeneration == loadGeneration else { return }
            absorbIdentifiers(from: loaded)
            let sorted = Sorter.sorted(enrich(loaded), order: sortOrder)
            applyItems(sorted)
            state = .loaded
            resolveLabel(for: current)
        } catch {
            guard currentGeneration == loadGeneration else { return }
            if items.isEmpty {
                state = .failed(error.localizedDescription)
            } else {
                state = .loaded
                errorMessage = error.localizedDescription
            }
            Log.error("list \(current): \(error.localizedDescription)")
        }
    }

    private func loadRoot(_ spec: RootSpec, forceScan: Bool, generation: Int) async {
        // Opening any container root is a good moment to notice that an app
        // was installed or removed while the app was in the background.
        _ = await ContainerIndex.shared.reconcileIfNeeded(minInterval: forceScan ? 0 : 15)

        let cached = catalog.items(for: spec.path)
        if !cached.isEmpty {
            applyItems(Sorter.sorted(cached, order: sortOrder))
            state = .loaded
        } else {
            applyItems([])
            state = .loading
        }
        rootUsesIndex = true

        if spec.access == .list {
            do {
                let listed = try await Task.detached(priority: .userInitiated) {
                    try FileService.shared.list(path: spec.path,
                                                includeHidden: true,
                                                resolveIdentifiers: true)
                }.value
                guard generation == loadGeneration else { return }
                absorbIdentifiers(from: listed)
                let sorted = Sorter.sorted(enrich(listed), order: sortOrder)
                applyItems(sorted)
                state = .loaded
                rootUsesIndex = false
                autoResolveLabelsIfNeeded()
                return
            } catch {
                Log.info("parent listing failed for \(spec.path): \(error.localizedDescription)")
            }
        }

        let recordExists = catalog.scanRecord(for: spec.path) != nil
        let needsScan = forceScan || !recordExists || ContainerIndex.shared.shouldRefreshOnOpen
        var scanError: Error?
        if needsScan {
            do {
                let full = forceScan && AppSettings.maxInodeOverride != nil
                _ = try await ContainerIndex.shared.ensureScanned(full: full)
            } catch let error as ContainerIndexError {
                if case .cancelled = error {
                    Log.info("index scan cancelled")
                } else {
                    scanError = error
                }
            } catch {
                scanError = error
            }
        }

        guard generation == loadGeneration else { return }
        let refreshed = catalog.items(for: spec.path)
        applyItems(Sorter.sorted(refreshed, order: sortOrder))
        if let scanError {
            if items.isEmpty {
                state = .failed(scanError.localizedDescription)
            } else {
                state = .loaded
                errorMessage = scanError.localizedDescription
            }
        } else {
            state = .loaded
        }
        autoResolveLabelsIfNeeded()
    }

    func reloadAfterIndexUpdate() {
        guard rootUsesIndex, let spec = Roots.spec(for: path) else { return }
        let refreshed = catalog.items(for: spec.path)
        applyItems(Sorter.sorted(refreshed, order: sortOrder))
        if !items.isEmpty || ContainerIndex.shared.progress == nil {
            state = .loaded
        }
        autoResolveLabelsIfNeeded()
    }

    // MARK: - Names

    private func resolveLabel(for target: String) {
        if let spec = Roots.spec(for: target) {
            title = spec.title
            return
        }
        if let label = catalog.label(for: target) {
            title = catalog.appName(for: label) ?? AppNames.shared.name(for: label) ?? label
            return
        }
        Task {
            let facts = await Task.detached(priority: .utility) {
                FileService.shared.facts(for: target)
            }.value
            guard path == target, let facts, let identifier = facts.identifier, !identifier.isEmpty else { return }
            catalog.setLabel(identifier, for: target)
            if let name = facts.displayName, !name.isEmpty {
                catalog.setAppNames([identifier: name])
            }
            title = catalog.appName(for: identifier) ?? AppNames.shared.name(for: identifier) ?? identifier
        }
    }

    private func enrich(_ listed: [FSItem]) -> [FSItem] {
        listed.map { item in
            var copy = item
            if copy.identifier == nil {
                copy.identifier = catalog.label(for: item.path)
            }
            if let identifier = copy.identifier {
                copy.appName = AppNames.shared.name(for: identifier) ?? catalog.appName(for: identifier)
            }
            return copy
        }
    }

    private func absorbIdentifiers(from listed: [FSItem]) {
        var pairs: [String: String] = [:]
        for item in listed {
            if let identifier = item.identifier, !identifier.isEmpty {
                pairs[item.path] = identifier
            }
        }
        catalog.setLabels(pairs)
    }

    // MARK: - Selection

    private func applyItems(_ newItems: [FSItem]) {
        let decorated = decorate(newItems)
        if isAppRoot { allItems = decorated }
        let visible = isAppRoot ? scoped(decorated) : decorated
        if visible != items {
            items = visible
        }
        let valid = Set(visible.map { $0.path })
        selected.formIntersection(valid)
        attachIcons()
        prefetchIcons()
        AppNames.shared.enrich(items.compactMap { $0.identifier })
    }

    private func scoped(_ listed: [FSItem]) -> [FSItem] {
        guard isAppRoot, appScope != .all, AppCatalog.shared.hasMaps else { return listed }
        return listed.filter { appScope.contains(AppCatalog.shared.kind(forContainerPath: $0.path)) }
    }

    private func applyScope() {
        guard isAppRoot else { return }
        let visible = scoped(allItems)
        items = visible
        selected.formIntersection(Set(visible.map { $0.path }))
        attachIcons()
        prefetchIcons()
    }

    func catalogUpdated() {
        guard isAppRoot else { return }
        let decorated = decorate(allItems)
        allItems = decorated
        applyScope()
    }

    var appSections: [AppDataSection] {
        guard isAppRoot, appScope == .all, AppCatalog.shared.hasMaps else { return [] }
        return AppDataKind.allCases.compactMap { kind in
            let part = visibleItems.filter {
                AppCatalog.shared.kind(forContainerPath: $0.path) == kind
            }
            return part.isEmpty ? nil : AppDataSection(kind: kind, items: part)
        }
    }

    private func decorate(_ list: [FSItem]) -> [FSItem] {
        list.map { item in
            var copy = item
            if copy.identifier == nil {
                copy.identifier = catalog.label(for: copy.path)
            }
            if let identifier = copy.identifier {
                copy.appName = AppNames.shared.name(for: identifier) ?? catalog.appName(for: identifier)
            }
            return copy
        }
    }

    func namesUpdated() {
        let decorated = decorate(items)
        if decorated != items { items = decorated }
        prefetchIcons()
    }

    func attachIcons() {
        var updated = items
        var changed = false
        for index in updated.indices {
            guard let identifier = updated[index].identifier else { continue }
            let data = AppIconStore.shared.cachedIcon(for: identifier)
            if updated[index].iconData != data {
                updated[index].iconData = data
                changed = true
            }
        }
        if changed { items = updated }
    }

    private func prefetchIcons() {
        let identifiers = items.compactMap { $0.identifier }
        guard !identifiers.isEmpty else { return }
        AppIconStore.shared.prefetch(identifiers)
    }

    func toggleSelectionMode() {
        selectionMode.toggle()
        if !selectionMode { selected.removeAll() }
    }

    func toggle(_ item: FSItem) {
        if selected.contains(item.path) {
            selected.remove(item.path)
        } else {
            selected.insert(item.path)
        }
    }

    func selectAllVisible() {
        selected = Set(visibleItems.map { $0.path })
    }

    func preview(_ item: FSItem) {
        guard !item.isDirectory else { return }
        busy = "准备预览…"
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try FileService.shared.exportSingle(path: item.path)
                }.value
                busy = nil
                sheet = SheetPayload(content: .preview(url))
            } catch {
                busy = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Sort and filter

    func applySort(_ key: SortKey) {
        if sortOrder.key == key {
            sortOrder.ascending.toggle()
        } else {
            sortOrder.key = key
            sortOrder.ascending = true
        }
        AppSettings.save(sortOrder)
        items = Sorter.sorted(items, order: sortOrder)
    }

    func setFoldersFirst(_ value: Bool) {
        sortOrder.foldersFirst = value
        AppSettings.save(sortOrder)
        items = Sorter.sorted(items, order: sortOrder)
    }

    func toggleHidden() {
        showHidden.toggle()
        AppSettings.showHidden = showHidden
        Task { await load(forceScan: false) }
    }

    // MARK: - Operations

    func copySelection(moving: Bool, app: AppModel) {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        app.setClipboard(ClipboardItem(paths: chosen.map { $0.path }, moving: moving))
        selectionMode = false
        selected.removeAll()
    }

    func paste(app: AppModel) {
        guard let clipboard = app.clipboard else { return }
        let destination = path
        busy = clipboard.moving ? "移动中…" : "拷贝中…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileService.shared.transfer(paths: clipboard.paths,
                                            to: destination,
                                            moving: clipboard.moving)
            }.value
            busy = nil
            notify(result, app: app)
            if clipboard.moving && result.failed == 0 {
                catalog.removePaths(clipboard.paths)
                app.clearClipboard()
            }
            await load(forceScan: true)
        }
    }

    func requestDelete(_ chosen: [FSItem]? = nil) {
        let targets = chosen ?? selectedItems
        guard !targets.isEmpty else { return }
        pendingDelete = targets
        confirmDelete = true
    }

    func performDelete(app: AppModel) {
        let targets = pendingDelete
        guard !targets.isEmpty else { return }
        confirmDelete = false
        pendingDelete = []
        busy = "删除中…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileService.shared.remove(paths: targets.map { $0.path })
            }.value
            busy = nil
            notify(result, app: app)
            if result.failed == 0 && result.done > 0 {
                catalog.removePaths(targets.map { $0.path })
            }
            selectionMode = false
            selected.removeAll()
            await load(forceScan: true)
        }
    }

    func newFolderPrompt() {
        sheet = SheetPayload(content: .prompt(TextPrompt(kind: .newFolder,
                                                         title: "新建文件夹",
                                                         message: "位置：\(path)",
                                                         initial: "",
                                                         actionTitle: "创建")))
    }

    func renamePrompt(_ item: FSItem) {
        sheet = SheetPayload(content: .prompt(TextPrompt(kind: .rename(item),
                                                         title: "重命名",
                                                         message: nil,
                                                         initial: item.name,
                                                         actionTitle: "重命名")))
    }

    func submit(prompt: TextPrompt, value: String, app: AppModel) {
        sheet = nil
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = FileService.nameProblem(name) {
            errorMessage = problem
            return
        }
        switch prompt.kind {
        case .newFolder:
            let parent = path
            busy = "创建中…"
            Task {
                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try FileService.shared.createFolder(in: parent, name: name)
                    }.value
                    busy = nil
                    app.flash("已创建 \(name)")
                    await load(forceScan: true)
                } catch {
                    busy = nil
                    errorMessage = error.localizedDescription
                }
            }
        case .rename(let item):
            busy = "重命名中…"
            Task {
                do {
                    let newPath = try await Task.detached(priority: .userInitiated) {
                        try FileService.shared.rename(path: item.path, to: name)
                    }.value
                    busy = nil
                    catalog.noteRename(from: item.path, to: newPath)
                    catalog.removePaths([item.path])
                    app.flash("已重命名为 \(name)")
                    await load(forceScan: true)
                } catch {
                    busy = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func importPicked(_ urls: [URL], app: AppModel) {
        guard !urls.isEmpty else { return }
        let destination = path
        busy = "导入 \(urls.count) 项…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileService.shared.importFiles(urls, into: destination)
            }.value
            busy = nil
            notify(result, app: app)
            await load(forceScan: true)
        }
    }

    func editText(_ item: FSItem) {
        guard !item.isDirectory else { return }
        sheet = SheetPayload(content: .text(item))
    }

    func showInfo(_ item: FSItem) {
        sheet = SheetPayload(content: .info(item))
    }

    func share(_ chosen: [FSItem]) {
        let targets = chosen.isEmpty ? selectedItems : chosen
        guard !targets.isEmpty else { return }
        busy = "准备分享…"
        Task {
            do {
                let urls = try await Task.detached(priority: .userInitiated) {
                    try FileService.shared.export(paths: targets.map { $0.path })
                }.value
                busy = nil
                sheet = SheetPayload(content: .share(urls))
            } catch {
                busy = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func duplicate(_ item: FSItem, app: AppModel) {
        busy = "复制中…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileService.shared.duplicate(paths: [item.path])
            }.value
            busy = nil
            notify(result, app: app)
            await load(forceScan: true)
        }
    }

    func presentImporter() {
        sheet = SheetPayload(content: .importer)
    }

    // MARK: - Container names

    func startLabelResolution(app: AppModel?, manual: Bool = true) {
        if manual { autoLabelSuppressed = false }
        guard labelTask == nil else { return }
        let targets = items.filter { $0.isDirectory && $0.identifier == nil }
        guard !targets.isEmpty else {
            if manual { app?.flash("当前没有待识别的容器") }
            return
        }
        let token = CancelToken()
        labelToken = token
        labelProgress = LabelProgress(done: 0, total: targets.count)
        labelTask = Task { [weak self] in
            guard let self else { return }
            var index = 0
            for item in targets {
                if token.isCancelled { break }
                let itemPath = item.path
                let facts = await Task.detached(priority: .utility) {
                    FileService.shared.facts(for: itemPath)
                }.value
                guard self.labelToken === token else { return }
                if let facts, let identifier = facts.identifier, !identifier.isEmpty {
                    self.catalog.setLabel(identifier, for: item.path)
                    if let name = facts.displayName, !name.isEmpty {
                        self.catalog.setAppNames([identifier: name])
                    }
                    if let position = self.items.firstIndex(where: { $0.path == item.path }) {
                        var updated = self.items
                        updated[position].identifier = identifier
                        updated[position].appName = AppNames.shared.name(for: identifier)
                            ?? self.catalog.appName(for: identifier)
                        self.items = updated
                    }
                    AppIconStore.shared.prefetch([identifier])
                }
                index += 1
                self.labelProgress = LabelProgress(done: index, total: targets.count)
            }
            guard self.labelToken === token else { return }
            self.labelProgress = nil
            self.labelTask = nil
            self.labelToken = nil
            self.items = Sorter.sorted(self.items, order: self.sortOrder)
            AppNames.shared.enrich(self.items.compactMap { $0.identifier })
            guard manual else { return }
            if token.isCancelled {
                app?.flash("已停止识别")
            } else {
                app?.flash("识别完成，共 \(targets.count) 个容器")
            }
        }
    }

    private func autoResolveLabelsIfNeeded() {
        guard AppSettings.autoResolveLabels,
              isRootContainer,
              !autoLabelSuppressed,
              labelTask == nil,
              items.contains(where: { $0.isDirectory && $0.identifier == nil }) else { return }
        startLabelResolution(app: nil, manual: false)
    }

    func pauseLabelResolution() {
        labelToken?.cancel()
        labelToken = nil
        labelTask?.cancel()
        labelTask = nil
        labelProgress = nil
    }

    func resumeAutoLabels() {
        autoResolveLabelsIfNeeded()
    }

    func stopLabelResolution() {
        autoLabelSuppressed = true
        labelToken?.cancel()
    }

    private func notify(_ result: OpFailures, app: AppModel) {
        if result.failed == 0 {
            app.flash(result.summary)
        } else {
            errorMessage = result.summary + (result.messages.count > 1 ? "\n" + result.messages.dropFirst().joined(separator: "\n") : "")
        }
    }
}
