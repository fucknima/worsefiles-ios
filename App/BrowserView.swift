//
//  BrowserView.swift
//  WorseFiles
//

import Combine
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BrowserView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var index = ContainerIndex.shared
    @ObservedObject private var icons = AppIconStore.shared
    @ObservedObject private var appCatalog = AppCatalog.shared
    @StateObject private var model: BrowserModel
    @State private var backupRequest: BackupRequest?

    init(target: BrowseTarget) {
        _model = StateObject(wrappedValue: BrowserModel(target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(currentPath: model.path, currentTitle: model.title)
            content
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "筛选当前目录")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.toggleSelectionMode()
                } label: {
                    Image(systemName: model.selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .accessibilityLabel(model.selectionMode ? "结束选择" : "选择")

                Menu {
                    toolbarMenu
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .task {
            await model.start()
            app.record(path: model.path, title: model.title)
        }
        .onAppear {
            model.reloadAfterIndexUpdate()
            model.resumeAutoLabels()
        }
        .onDisappear {
            model.pauseLabelResolution()
        }
        .onChange(of: model.title) { _, _ in
            app.record(path: model.path, title: model.title)
        }
        .onReceive(NotificationCenter.default.publisher(for: .worseFilesIndexUpdated)) { _ in
            model.reloadAfterIndexUpdate()
        }
        .onChange(of: icons.revision) { _, _ in
            model.attachIcons()
        }
        .onReceive(NotificationCenter.default.publisher(for: .worseFilesNamesUpdated)) { _ in
            model.namesUpdated()
        }
        .onReceive(NotificationCenter.default.publisher(for: .worseFilesAppCatalogUpdated)) { _ in
            model.catalogUpdated()
        }
        .alert("操作失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("永久删除", isPresented: $model.confirmDelete, titleVisibility: .visible) {
            Button("删除 \(model.pendingDelete.count) 项", role: .destructive) {
                model.performDelete(app: app)
            }
            Button("取消", role: .cancel) {
                model.pendingDelete = []
            }
        } message: {
            Text("这些项目会从容器中永久移除，无法撤销。")
        }
        .sheet(item: $model.sheet) { payload in
            sheetContent(payload.content)
                .environmentObject(app)
        }
        .sheet(item: $backupRequest) { request in
            NavigationStack {
                BackupCreateSheet(request: request) { record in
                    app.flash("已备份 \(record.name)")
                }
            }
            .environmentObject(app)
        }
        .overlay {
            if let busy = model.busy {
                BusyOverlay(text: busy)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: model.busy)
        .animation(.easeInOut(duration: 0.16), value: model.selectionMode)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = model.state, model.items.isEmpty {
            ScrollView {
                ErrorStateView(message: message) {
                    Task { await model.load(forceScan: false) }
                }
                .padding(.top, 40)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        } else if model.items.isEmpty,
                  model.state == .loading,
                  !(model.isRootContainer && index.progress != nil) {
            VStack(spacing: 10) {
                ProgressView()
                Text("读取目录…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        } else {
            fileList
        }
    }

    private var fileList: some View {
        List {
            if model.isRootContainer, model.items.isEmpty, let scan = index.progress {
                Section {
                    ScanProgressView(status: scan) {
                        ContainerIndex.shared.cancel()
                    }
                }
            }
            if let progress = model.labelProgress {
                Section {
                    LabelProgressView(progress: progress) {
                        model.stopLabelResolution()
                    }
                }
            }

            if model.isAppRoot {
                Section {
                    Picker("范围", selection: $model.appScope) {
                        ForEach(AppDataScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                } header: {
                    Text("应用范围")
                } footer: {
                    Text(scopeCounts)
                }
            }

            if model.appSections.isEmpty {
                Section {
                    rows
                }
            } else {
                ForEach(model.appSections, id: \.kind) { group in
                    Section {
                        ForEach(group.items) { item in
                            row(item)
                                .listRowBackground(rowBackground(item))
                        }
                    } header: {
                        HStack {
                            Text(group.kind.title)
                            Spacer()
                            Text("\(group.items.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await model.refresh()
        }
    }

    @ViewBuilder
    private var rows: some View {
        if model.visibleItems.isEmpty {
            emptyRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            ForEach(model.visibleItems) { item in
                row(item)
                    .listRowBackground(rowBackground(item))
            }
        }
    }

    private var scopeCounts: String {
        guard appCatalog.hasMaps else { return "正在读取应用分类…" }
        let counts = appCatalog.dataRootCounts()
        let user = counts[.user] ?? 0
        let system = counts[.system] ?? 0
        let service = counts[.service] ?? 0
        return "用户 \(user) · 系统 \(system) · 服务 \(service)"
    }

    @ViewBuilder
    private var emptyRow: some View {
        if model.isRootContainer, index.progress != nil {
            EmptyDirectoryView(symbol: "waveform.path.ecg",
                               title: "扫描中",
                               message: "扫描完成后会列出发现的容器；可以在这里停止。")
        } else if !model.query.isEmpty {
            EmptyDirectoryView(symbol: "magnifyingglass",
                               title: "没有匹配项",
                               message: "当前范围里没有名称包含“\(model.query)”的项目。")
        } else if model.isAppRoot && model.appScope != .all {
            EmptyDirectoryView(symbol: "square.stack.3d.up",
                               title: "该范围内没有 App",
                               message: "切到“全部”可以看到服务与扩展容器，或下拉刷新重新分类。")
        } else if model.isRootContainer {
            EmptyDirectoryView(symbol: "shippingbox",
                               title: "没有容器",
                               message: "下拉刷新开始扫描，或检查该路径在当前系统上是否可访问。")
        } else {
            EmptyDirectoryView(symbol: "folder",
                               title: "空文件夹",
                               message: "这个目录里没有可显示的项目。")
        }
    }

    private func rowBackground(_ item: FSItem) -> Color {
        if model.selectionMode && model.selected.contains(item.path) {
            return Color.accentColor.opacity(0.10)
        }
        return Color(uiColor: .secondarySystemGroupedBackground)
    }

    private func row(_ item: FSItem) -> some View {
        Button {
            openItem(item)
        } label: {
            HStack(spacing: 10) {
                if model.selectionMode {
                    Image(systemName: model.selected.contains(item.path) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(model.selected.contains(item.path) ? Color.accentColor : Color.secondary.opacity(0.6))
                }
                FileGlyph(item: item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if item.isDirectory && !model.selectionMode {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenu(for: item)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                model.requestDelete([item])
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                model.showInfo(item)
            } label: {
                Label("信息", systemImage: "info.circle")
            }
            .tint(.gray)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: FSItem) -> some View {
        if item.isDirectory {
            Button {
                push(item)
            } label: {
                Label("打开", systemImage: "folder")
            }
        } else {
            Button {
                model.preview(item)
            } label: {
                Label("预览", systemImage: "eye")
            }
            if FileService.shared.isTextCandidate(path: item.path) {
                Button {
                    model.editText(item)
                } label: {
                    Label("文本编辑", systemImage: "pencil")
                }
            }
        }

        Divider()

        Button {
            model.showInfo(item)
        } label: {
            Label("信息", systemImage: "info.circle")
        }
        Button {
            model.renamePrompt(item)
        } label: {
            Label("重命名", systemImage: "character.cursor.ibeam")
        }
        Button {
            copy([item], moving: false)
        } label: {
            Label("拷贝", systemImage: "doc.on.doc")
        }
        Button {
            copy([item], moving: true)
        } label: {
            Label("剪切", systemImage: "scissors")
        }
        Button {
            model.duplicate(item, app: app)
        } label: {
            Label("制作副本", systemImage: "plus.square.on.square")
        }
        Button {
            model.share([item])
        } label: {
            Label("分享", systemImage: "square.and.arrow.up")
        }

        if item.isDirectory {
            Button {
                backupRequest = BackupSupport.request(path: item.path, title: item.displayName)
            } label: {
                Label("备份此文件夹", systemImage: "externaldrive.badge.timemachine")
            }
        }

        Divider()

        if item.isDirectory {
            Button {
                app.toggleFavorite(path: item.path, title: item.displayName)
            } label: {
                Label(app.isFavorite(item.path) ? "取消收藏" : "收藏",
                      systemImage: app.isFavorite(item.path) ? "star.slash" : "star")
            }
        }
        Button(role: .destructive) {
            model.requestDelete([item])
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbarMenu: some View {
        Button {
            dismiss()
        } label: {
            Label("上一级", systemImage: "arrow.up")
        }

        Button {
            model.newFolderPrompt()
        } label: {
            Label("新建文件夹", systemImage: "folder.badge.plus")
        }
        Button {
            model.presentImporter()
        } label: {
            Label("导入文件", systemImage: "square.and.arrow.down")
        }
        if !model.isRootContainer {
            Button {
                backupRequest = BackupSupport.request(path: model.path, title: model.title)
            } label: {
                Label("备份当前文件夹", systemImage: "externaldrive.badge.timemachine")
            }
        }
        if let clipboard = app.clipboard {
            Button {
                model.paste(app: app)
            } label: {
                Label("粘贴 \(clipboard.paths.count) 项", systemImage: "doc.on.clipboard")
            }
        }

        Divider()

        Menu {
            ForEach(SortKey.allCases) { key in
                Button {
                    model.applySort(key)
                } label: {
                    if model.sortOrder.key == key {
                        Label(key.title, systemImage: model.sortOrder.ascending ? "arrow.up" : "arrow.down")
                    } else {
                        Text(key.title)
                    }
                }
            }
            Divider()
            Toggle("文件夹优先", isOn: Binding(
                get: { model.sortOrder.foldersFirst },
                set: { model.setFoldersFirst($0) }
            ))
        } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
        }

        Button {
            model.toggleHidden()
        } label: {
            Label(model.showHidden ? "不显示隐藏文件" : "显示隐藏文件",
                  systemImage: model.showHidden ? "eye.slash" : "eye")
        }

        Button {
            app.toggleFavorite(path: model.path, title: model.title)
        } label: {
            Label(app.isFavorite(model.path) ? "取消收藏" : "收藏当前目录",
                  systemImage: app.isFavorite(model.path) ? "star.slash" : "star")
        }

        if model.isRootContainer {
            Button {
                model.startLabelResolution(app: app)
            } label: {
                Label("识别容器名称", systemImage: "tag")
            }
            .disabled(model.labelProgress != nil)
        }

        Button {
            model.showInfo(currentDirectoryItem)
        } label: {
            Label("当前目录信息", systemImage: "info.circle")
        }

        Button {
            model.share([currentDirectoryItem])
        } label: {
            Label("导出当前目录", systemImage: "square.and.arrow.up.on.square")
        }

        Divider()

        Button {
            Task { await model.refresh() }
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        if model.selectionMode {
            VStack(spacing: 6) {
                HStack {
                    Text("已选 \(model.selected.count) 项")
                        .font(.footnote.weight(.medium))
                    Spacer()
                    Button("全选") {
                        model.selectAllVisible()
                    }
                    .font(.footnote)
                    Button("完成") {
                        model.toggleSelectionMode()
                    }
                    .font(.footnote.weight(.semibold))
                }
                HStack(spacing: 0) {
                    selectionButton("拷贝", "doc.on.doc") {
                        model.copySelection(moving: false, app: app)
                    }
                    selectionButton("剪切", "scissors") {
                        model.copySelection(moving: true, app: app)
                    }
                    selectionButton("删除", "trash", destructive: true) {
                        model.requestDelete()
                    }
                    selectionButton("分享", "square.and.arrow.up") {
                        model.share([])
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        } else if let clipboard = app.clipboard {
            HStack(spacing: 10) {
                Image(systemName: clipboard.moving ? "scissors" : "doc.on.clipboard")
                    .foregroundStyle(.indigo)
                Text("已\(clipboard.moving ? "剪切" : "复制") \(clipboard.paths.count) 项")
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button {
                    model.paste(app: app)
                } label: {
                    Text("粘贴")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    app.clearClipboard()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除剪贴板")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func selectionButton(_ title: String,
                                 _ symbol: String,
                                 destructive: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(destructive ? Color.red : Color.accentColor)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ content: BrowserSheet) -> some View {
        switch content {
        case .info(let item):
            InfoView(item: item)
        case .preview(let url):
            PreviewSheet(url: url)
        case .text(let item):
            TextEditorSheet(item: item) {
                Task { await model.refresh() }
            }
        case .share(let urls):
            ShareSheet(items: urls) {
                model.sheet = nil
            }
            .ignoresSafeArea()
        case .prompt(let prompt):
            TextPromptSheet(prompt: prompt) { value in
                model.submit(prompt: prompt, value: value, app: app)
            }
        case .importer:
            DocumentPicker(onPick: { urls in
                model.sheet = nil
                model.importPicked(urls, app: app)
            }, onCancel: {
                model.sheet = nil
            })
            .ignoresSafeArea()
        }
    }

    // MARK: - Helpers

    private func push(_ item: FSItem) {
        withAnimation(.easeInOut(duration: 0.28)) {
            app.open(BrowseTarget(path: item.path, title: item.displayName))
        }
    }

    private func openItem(_ item: FSItem) {
        if model.selectionMode {
            model.toggle(item)
        } else if item.isDirectory {
            push(item)
        } else {
            model.preview(item)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    private var currentDirectoryItem: FSItem {
        FSItem(path: model.path,
               name: model.title,
               isDirectory: true,
               isSymbolicLink: false,
               isHidden: false,
               size: 0,
               modified: nil,
               identifier: nil)
    }

    private func copy(_ items: [FSItem], moving: Bool) {
        guard !items.isEmpty else { return }
        app.setClipboard(ClipboardItem(paths: items.map { $0.path }, moving: moving))
    }

    private func detail(for item: FSItem) -> String {
        if item.isDirectory {
            if let identifier = item.identifier {
                return "\(identifier) · 容器"
            }
            if let modified = item.modified {
                return "文件夹 · \(Format.date(modified))"
            }
            return "文件夹"
        }
        var pieces = [Format.bytes(item.size)]
        if item.isSymbolicLink { pieces.append("符号链接") }
        if let modified = item.modified { pieces.append(Format.date(modified)) }
        return pieces.joined(separator: " · ")
    }
}

// MARK: - Breadcrumb

struct BreadcrumbBar: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var catalog = Catalog.shared

    let currentPath: String
    let currentTitle: String

    private struct Item: Identifiable {
        let title: String
        let path: String
        let index: Int
        var id: String { "\(index)|\(path)" }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    Image(systemName: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 2)

                    ForEach(items) { item in
                        if item.index != items.first?.index {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.quaternary)
                        }
                        Button {
                            pop(to: item)
                        } label: {
                            Text(item.title)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(item.index == app.navPath.count - 1 ? Color.primary : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .onAppear {
                scrollToEnd(proxy)
            }
            .onChange(of: app.navPath) { _, _ in
                scrollToEnd(proxy)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        Divider()
    }

    private var items: [Item] {
        var list: [Item] = []
        for (index, target) in app.navPath.enumerated() {
            let title: String
            if PathTool.canonical(target.path) == currentPath, !currentTitle.isEmpty {
                title = currentTitle
            } else if let spec = Roots.spec(for: target.path) {
                title = spec.title
            } else if let label = catalog.label(for: target.path), !label.isEmpty {
                title = AppNames.shared.name(for: label)
                    ?? catalog.appName(for: label)
                    ?? label
            } else if let targetTitle = target.title, !targetTitle.isEmpty {
                title = targetTitle
            } else {
                title = PathTool.name(of: target.path)
            }
            list.append(Item(title: title, path: target.path, index: index))
        }

        if list.isEmpty {
            let title = currentTitle.isEmpty ? PathTool.name(of: currentPath) : currentTitle
            list = [Item(title: title, path: currentPath, index: 0)]
        }
        let start = max(0, list.count - 4)
        return Array(list[start...])
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = items.last else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(last.id, anchor: .trailing)
        }
    }

    private func pop(to item: Item) {
        guard item.index < app.navPath.count - 1 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            app.navPath = Array(app.navPath.prefix(item.index + 1))
        }
    }
}
