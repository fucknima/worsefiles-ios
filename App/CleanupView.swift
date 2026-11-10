//
//  CleanupView.swift
//  WorseFiles
//

import SwiftUI
import UIKit

enum CleanupAlert: Identifiable {
    case confirm(Int, Int64)
    case report(CleanupReport)
    case error(String)

    var id: String {
        switch self {
        case .confirm: return "confirm"
        case .report: return "report"
        case .error: return "error"
        }
    }
}

@MainActor
final class CleanupModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case cleaning
    }

    @Published var mode: CleanupMode = .safe {
        didSet {
            guard oldValue != mode, phase == .idle else { return }
            plan = nil
            scan()
        }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: CleanupPlan?
    @Published private(set) var progress: CleanupProgress?
    @Published var alert: CleanupAlert?
    @Published var selected: Set<String> = []
    @Published private(set) var lastResult: CleanupReport?
    @Published private(set) var appIdentifiers: Set<String> = []
    @Published var includeDaemons: Bool = AppSettings.cleanupIncludesDaemons {
        didSet {
            guard oldValue != includeDaemons else { return }
            AppSettings.cleanupIncludesDaemons = includeDaemons
            guard phase == .idle else { return }
            plan = nil
            scan()
        }
    }

    private var token: CancelToken?
    private var lastProgressAt = Date.distantPast

    var isBusy: Bool { phase != .idle }
    var selectedTargets: [CleanupTarget] {
        (plan?.targets ?? []).filter { selected.contains($0.id) }
    }
    var selectedBytes: Int64 { selectedTargets.reduce(0) { $0 + $1.bytes } }
    var canClean: Bool { !isBusy && selectedBytes > 0 }

    // App data containers own the icon. A plugin container's identifier is
    // its own bundle id; walk up until it matches an installed app's data
    // container so the row shows the parent app icon instead of a box.
    func iconIdentifier(for target: CleanupTarget) -> String? {
        guard let identifier = target.identifier ?? Catalog.shared.label(for: target.containerPath) else {
            return nil
        }
        if appIdentifiers.contains(identifier) { return identifier }
        var candidate = identifier
        while let dot = candidate.lastIndex(of: ".") {
            candidate = String(candidate[..<dot])
            if appIdentifiers.contains(candidate) { return candidate }
        }
        return identifier
    }

    func toggle(_ target: CleanupTarget) {
        if selected.contains(target.id) {
            selected.remove(target.id)
        } else {
            selected.insert(target.id)
        }
    }

    func selectAll() {
        selected = Set((plan?.targets ?? []).map { $0.id })
    }

    func selectNone() {
        selected.removeAll()
    }

    func selectLarge(_ megabytes: Int64) {
        let threshold = megabytes * 1024 * 1024
        selected = Set((plan?.targets ?? []).filter { $0.bytes >= threshold }.map { $0.id })
    }

    func scan() {
        guard phase == .idle else { return }
        let containers = containerList()
        guard !containers.isEmpty else {
            plan = CleanupPlan(targets: [],
                               totalBytes: 0,
                               totalFiles: 0,
                               scanned: 0,
                               failed: [],
                               date: Date())
            return
        }

        phase = .scanning
        progress = CleanupProgress(phase: "扫描", done: 0, total: containers.count, current: nil)
        let mode = mode
        let token = CancelToken()
        self.token = token

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CleanupEngine.shared.scan(mode: mode,
                                          containers: containers,
                                          token: token) { value in
                    Task { @MainActor [weak self] in
                        self?.receive(value)
                    }
                }
            }.value

            guard self.token === token else { return }
            self.token = nil
            self.lastResult = nil
            self.plan = result
            self.selected = Set(result.targets.map { $0.id })
            self.phase = .idle
            self.progress = nil
            self.appIdentifiers = Set(Catalog.shared.items(for: Roots.dataApplication.path)
                .compactMap { $0.identifier })
            AppIconStore.shared.prefetch(result.targets.compactMap { self.iconIdentifier(for: $0) })
            Log.info("cleanup scan \(mode.rawValue): targets=\(result.targets.count) identified=\(result.targets.filter { $0.identifier != nil }.count) apps=\(self.appIdentifiers.count)")
        }
    }

    func clean() {
        guard phase == .idle, let plan else { return }
        let targets = selectedTargets
        guard !targets.isEmpty else { return }
        let filtered = CleanupPlan(targets: targets,
                                   totalBytes: targets.reduce(0) { $0 + $1.bytes },
                                   totalFiles: targets.reduce(0) { $0 + $1.files },
                                   scanned: plan.scanned,
                                   failed: plan.failed,
                                   date: plan.date)
        phase = .cleaning
        progress = CleanupProgress(phase: "清理", done: 0, total: targets.count, current: nil)
        let token = CancelToken()
        self.token = token

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CleanupEngine.shared.clean(plan: filtered, token: token) { value in
                    Task { @MainActor [weak self] in
                        self?.receive(value)
                    }
                }
            }.value

            guard self.token === token else { return }
            self.token = nil
            self.lastResult = result
            self.alert = .report(result)
            if let plan = self.plan {
                let remaining = plan.targets.filter { !result.cleaned.contains($0.id) }
                self.plan = CleanupPlan(targets: remaining,
                                        totalBytes: remaining.reduce(0) { $0 + $1.bytes },
                                        totalFiles: remaining.reduce(0) { $0 + $1.files },
                                        scanned: plan.scanned,
                                        failed: result.failed,
                                        date: Date())
            }
            self.selected.removeAll()
            self.phase = .idle
            self.progress = nil
        }
    }

    func cancel() {
        token?.cancel()
    }

    private func receive(_ value: CleanupProgress) {
        let finished = value.done >= value.total
        guard finished
            || value.done % 4 == 0
            || Date().timeIntervalSince(lastProgressAt) > 0.12 else { return }
        lastProgressAt = Date()
        progress = value
    }

    private func containerList() -> [CleanupContainer] {
        var roots = [Roots.dataApplication, Roots.pluginKit]
        if includeDaemons {
            roots.append(Roots.internalDaemon)
        }
        return roots.flatMap { root in
            Catalog.shared.items(for: root.path).map { item in
                CleanupContainer(path: item.path,
                                 identifier: item.identifier,
                                 displayName: item.displayName)
            }
        }
    }
}

struct CleanupView: View {
    @StateObject private var model = CleanupModel()

    var body: some View {
        List {
            Section {
                Picker("范围", selection: $model.mode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isBusy)
            } header: {
                Text("清理范围")
            } footer: {
                Text(model.mode == .safe
                     ? "只清理 Library/Caches 与 tmp，这两个目录本来就可以由系统回收。"
                     : "额外清理日志、应用状态快照与启动图缓存；不含 Documents、偏好设置和 App Group。")
            }

            Section {
                Toggle("包含系统守护进程", isOn: $model.includeDaemons)
                    .disabled(model.isBusy)
            } footer: {
                Text(model.includeDaemons
                     ? "守护进程容器属于系统服务，清理可能让正在运行的服务丢缓存。只在明确知道后果时开启。"
                     : "默认只处理 App 与扩展。系统守护进程容器不会出现在清理列表。")
            }

            if let progress = model.progress {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(progress.phase)…")
                            Spacer()
                            Text("\(progress.done)/\(progress.total)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress.fraction)
                        if let current = progress.current {
                            Text(current)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let plan = model.plan {
                if plan.targets.isEmpty {
                    Section {
                        Text(emptyText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            model.scan()
                        } label: {
                            Label("重新扫描", systemImage: "arrow.clockwise")
                        }
                    }
                } else {
                    Section {
                        ForEach(plan.targets) { target in
                            Button {
                                model.toggle(target)
                            } label: {
                                row(target)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("可清理")
                            Spacer()
                            Text("已选 \(model.selectedTargets.count)/\(plan.targets.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("已选 \(Format.bytes(model.selectedBytes))，共 \(plan.targets.count) 个 App。清理只删上述目录的内容，目录本身会重建。")
                    }

                    Section {
                        Button(role: .destructive) {
                            model.alert = .confirm(model.selectedTargets.count, model.selectedBytes)
                        } label: {
                            Label("清理已选 \(Format.bytes(model.selectedBytes))", systemImage: "trash")
                        }
                        .disabled(!model.canClean)
                    } footer: {
                        if !plan.failed.isEmpty {
                            Text("有 \(plan.failed.count) 个容器无法访问，已跳过。")
                        }
                    }
                }
            } else if !model.isBusy {
                Section {
                    Button {
                        model.scan()
                    } label: {
                        Label("扫描缓存", systemImage: "magnifyingglass")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("清理缓存")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            model.scan()
        }
        .toolbar {
            if model.isBusy {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("停止") {
                        model.cancel()
                    }
                }
            } else if model.plan != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.scan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新扫描")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("全选") { model.selectAll() }
                        Button("全不选") { model.selectNone() }
                        Divider()
                        Button("仅大于 50 MB") { model.selectLarge(50) }
                        Button("仅大于 200 MB") { model.selectLarge(200) }
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("选择清理项")
                }
            }
        }
        .task {
            if model.plan == nil { model.scan() }
        }
        .alert(item: $model.alert) { value in
            switch value {
            case .confirm(let count, let bytes):
                return Alert(title: Text("确认清理"),
                             message: Text("将删除 \(count) 个 App 的缓存，约 \(Format.bytes(bytes))。无法撤销。"),
                             primaryButton: .destructive(Text("清理")) { model.clean() },
                             secondaryButton: .cancel(Text("取消")))
            case .report(let report):
                return Alert(title: Text("清理完成"),
                             message: Text(report.summary),
                             dismissButton: .default(Text("好")))
            case .error(let message):
                return Alert(title: Text("操作失败"),
                             message: Text(message),
                             dismissButton: .default(Text("好")))
            }
        }
    }

    private var emptyText: String {
        if model.isBusy { return "扫描中…" }
        if let result = model.lastResult, result.targets > 0 {
            return "上次清理释放约 \(Format.bytes(result.freed))；重新扫描可查看最新缓存。"
        }
        return "没有发现可清理的缓存。"
    }

    private func title(for target: CleanupTarget) -> String {
        if let identifier = target.identifier,
           let name = AppNames.shared.name(for: identifier),
           !name.isEmpty {
            return name
        }
        return target.displayName
    }

    private func row(_ target: CleanupTarget) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.selected.contains(target.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19))
                .foregroundStyle(model.selected.contains(target.id) ? Color.accentColor : Color.secondary.opacity(0.55))

            if let identifier = model.iconIdentifier(for: target) {
                CleanupIconView(identifier: identifier)
            } else {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 34, height: 34)
                    .background(Color.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: target))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(target.rules.map { $0.title }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(target.bytes))
                    .font(.callout.monospacedDigit())
                Text("\(target.files) 个文件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

}

// A row owns its icon update so a background fetch always refreshes that
// row, even when the surrounding list is busy with selection changes.
private struct CleanupIconView: View {
    let identifier: String

    @ObservedObject private var icons = AppIconStore.shared
    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                let style = ServiceGlyph.style(for: identifier)
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(style.color.gradient)
                        .frame(width: 34, height: 34)
                    Image(systemName: style.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .onAppear { load() }
        .onChange(of: icons.revision) { _, _ in load() }
    }

    private func load() {
        if let data = icons.iconNow(for: identifier) {
            if data != self.data { self.data = data }
        } else {
            _ = icons.icon(for: identifier)
        }
    }
}
