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

    private var token: CancelToken?
    private var lastProgressAt = Date.distantPast

    var isBusy: Bool { phase != .idle }
    var selectedTargets: [CleanupTarget] {
        (plan?.targets ?? []).filter { selected.contains($0.id) }
    }
    var selectedBytes: Int64 { selectedTargets.reduce(0) { $0 + $1.bytes } }
    var canClean: Bool { !isBusy && selectedBytes > 0 }

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
            self.plan = result
            self.selected = Set(result.targets.map { $0.id })
            self.phase = .idle
            self.progress = nil
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
            self.alert = .report(result)
            self.plan = nil
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
        let roots = [Roots.dataApplication, Roots.pluginKit, Roots.internalDaemon]
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
    @ObservedObject private var icons = AppIconStore.shared

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
                        Text(model.isBusy ? "扫描中…" : "没有发现可清理的缓存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
        .toolbar {
            if model.isBusy {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("停止") {
                        model.cancel()
                    }
                }
            } else if model.plan != nil {
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

    private func row(_ target: CleanupTarget) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.selected.contains(target.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19))
                .foregroundStyle(model.selected.contains(target.id) ? Color.accentColor : Color.secondary.opacity(0.55))

            if let identifier = target.identifier,
               let data = icons.cachedIcon(for: identifier),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 34, height: 34)
                    .background(Color.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
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
