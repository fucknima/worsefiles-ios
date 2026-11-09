//
//  CleanupView.swift
//  WorseFiles
//

import SwiftUI
import UIKit

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
    @Published var report: CleanupReport?
    @Published private(set) var progress: CleanupProgress?
    @Published var confirmClean = false
    @Published var errorMessage: String?

    private var token: CancelToken?
    private var lastProgressAt = Date.distantPast

    var isBusy: Bool { phase != .idle }
    var canClean: Bool { !isBusy && (plan?.totalBytes ?? 0) > 0 }

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
            self.phase = .idle
            self.progress = nil
        }
    }

    func clean() {
        guard phase == .idle, let plan, plan.totalBytes > 0 else { return }
        confirmClean = false
        phase = .cleaning
        progress = CleanupProgress(phase: "清理", done: 0, total: plan.targets.count, current: nil)
        let token = CancelToken()
        self.token = token

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CleanupEngine.shared.clean(plan: plan, token: token) { value in
                    Task { @MainActor [weak self] in
                        self?.receive(value)
                    }
                }
            }.value

            guard self.token === token else { return }
            self.token = nil
            self.report = result
            self.plan = nil
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
                            row(target)
                        }
                    } header: {
                        HStack {
                            Text("可清理")
                            Spacer()
                            Text("\(plan.targets.count) 个 App")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("共 \(Format.bytes(plan.totalBytes))，约 \(plan.totalFiles) 个文件。清理只删上述目录的内容，目录本身会重建。")
                    }

                    Section {
                        Button(role: .destructive) {
                            model.confirmClean = true
                        } label: {
                            Label("清理 \(Format.bytes(plan.totalBytes))", systemImage: "trash")
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
            }
        }
        .task {
            if model.plan == nil { model.scan() }
        }
        .alert("确认清理", isPresented: $model.confirmClean) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { model.clean() }
        } message: {
            Text("将删除 \(model.plan?.targets.count ?? 0) 个 App 的缓存，约 \(Format.bytes(model.plan?.totalBytes ?? 0))。无法撤销。")
        }
        .alert("清理完成", isPresented: reportBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.report?.summary ?? "")
        }
        .alert("操作失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func row(_ target: CleanupTarget) -> some View {
        HStack(spacing: 10) {
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

    private var reportBinding: Binding<Bool> {
        Binding(get: { model.report != nil },
                set: { if !$0 { model.report = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}
