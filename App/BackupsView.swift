//
//  BackupsView.swift
//  WorseFiles
//

import SwiftUI
import UIKit

@MainActor
final class BackupCreateModel: ObservableObject {
    let request: BackupRequest
    @Published var mode: BackupMode = .userData
    @Published private(set) var busy = false
    @Published private(set) var progress: BackupProgress?
    @Published private(set) var completed = false
    @Published var errorMessage: String?

    private let onFinished: (BackupRecord) -> Void
    private var token: CancelToken?
    private var lastProgressAt = Date.distantPast

    init(request: BackupRequest, onFinished: @escaping (BackupRecord) -> Void) {
        self.request = request
        self.onFinished = onFinished
    }

    func start() {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        completed = false
        progress = BackupProgress(phase: "备份", bytes: 0, files: 0, totalBytes: 0, current: nil)

        let token = CancelToken()
        self.token = token
        let mode = mode
        let request = request
        UIApplication.shared.isIdleTimerDisabled = true

        Task {
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    try BackupEngine.shared.create(request: request,
                                                   mode: mode,
                                                   token: token) { value in
                        Task { @MainActor [weak self] in
                            self?.receive(value)
                        }
                    }
                }.value

                guard self.token === token else { return }
                self.token = nil
                self.busy = false
                self.progress = nil
                UIApplication.shared.isIdleTimerDisabled = false
                BackupStore.shared.add(record)
                self.onFinished(record)
                self.completed = true
            } catch is CancellationError {
                guard self.token === token else { return }
                self.token = nil
                self.busy = false
                self.progress = nil
                UIApplication.shared.isIdleTimerDisabled = false
                self.errorMessage = "备份已取消。"
            } catch {
                guard self.token === token else { return }
                self.token = nil
                self.busy = false
                self.progress = nil
                UIApplication.shared.isIdleTimerDisabled = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        guard busy else { return }
        token?.cancel()
    }

    private func receive(_ value: BackupProgress) {
        let finished = value.current == nil
        guard finished || Date().timeIntervalSince(lastProgressAt) > 0.1 else { return }
        lastProgressAt = Date()
        progress = value
    }
}

struct BackupCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: BackupCreateModel

    init(request: BackupRequest, onFinished: @escaping (BackupRecord) -> Void) {
        _model = StateObject(wrappedValue: BackupCreateModel(request: request,
                                                             onFinished: onFinished))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.request.title)
                        .font(.headline)
                    Text(PathTool.short(model.request.sourcePath, keep: 4))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let name = model.request.containerName {
                        Text("目标容器：\(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("来源")
            }

            Section {
                Picker("内容", selection: $model.mode) {
                    ForEach(BackupMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.busy)
            } header: {
                Text("备份内容")
            } footer: {
                Text(model.mode.detail + "。文件优先用 APFS 克隆，同一卷上通常不复制数据块。")
            }

            if let progress = model.progress {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(progress.phase)…")
                            Spacer()
                            Text("\(progress.files) 个文件")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                        Text(Format.bytes(progress.bytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let current = progress.current {
                            Text(current)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                if model.busy {
                    Button(role: .destructive) {
                        model.cancel()
                    } label: {
                        Label("停止备份", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        model.start()
                    } label: {
                        Label("开始备份", systemImage: "externaldrive.badge.timemachine")
                    }
                }
            } footer: {
                Text("备份保存在应用 Documents/Backups，可在“文件”App 里看到，也可以导出为 ZIP。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("备份")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") {
                    model.cancel()
                    dismiss()
                }
            }
        }
        .onChange(of: model.completed) { _, done in
            if done { dismiss() }
        }
        .alert("备份失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

struct BackupExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

enum BackupsAlert: Identifiable {
    case restore(BackupRecord, String)
    case delete(BackupRecord)
    case report(String)
    case error(String)

    var id: String {
        switch self {
        case .restore(let record, _): return "restore-\(record.id)"
        case .delete(let record): return "delete-\(record.id)"
        case .report: return "report"
        case .error: return "error"
        }
    }
}

@MainActor
final class BackupsModel: ObservableObject {
    @Published var alert: BackupsAlert?
    @Published private(set) var busyLabel: String?
    @Published private(set) var progress: BackupProgress?
    @Published var exportFile: BackupExportFile?

    private var token: CancelToken?
    private var lastProgressAt = Date.distantPast

    var isBusy: Bool { busyLabel != nil }

    func beginRestore(_ record: BackupRecord) {
        guard !isBusy else { return }
        busyLabel = "定位容器…"
        progress = nil
        Task {
            // Pick up a container created by a reinstall before resolving the
            // path. Incremental unless the index has never been built.
            _ = try? await ContainerIndex.shared.ensureScanned(full: false)
            busyLabel = nil
            guard let target = BackupSupport.restoreTarget(for: record) else {
                alert = .error("找不到备份对应的容器。App 可能已卸载。")
                return
            }
            alert = .restore(record, target)
        }
    }

    func restore(_ record: BackupRecord, target: String, snapshot: Bool) {
        guard !isBusy else { return }
        busyLabel = "恢复…"
        progress = BackupProgress(phase: "恢复",
                                  bytes: 0,
                                  files: 0,
                                  totalBytes: record.bytes,
                                  current: nil)
        let token = CancelToken()
        self.token = token
        UIApplication.shared.isIdleTimerDisabled = true

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BackupEngine.shared.restore(record: record,
                                                    targetContainer: target,
                                                    snapshot: snapshot,
                                                    token: token) { value in
                        Task { @MainActor [weak self] in
                            self?.receive(value)
                        }
                    }
                }.value

                guard self.token === token else { return }
                self.token = nil
                self.busyLabel = nil
                self.progress = nil
                UIApplication.shared.isIdleTimerDisabled = false
                if let snapshot = result.snapshot {
                    BackupStore.shared.add(snapshot)
                }
                var text = result.summary
                if !result.errors.isEmpty {
                    text += "\n" + result.errors.prefix(6).joined(separator: "\n")
                }
                self.alert = .report(text)
            } catch is CancellationError {
                guard self.token === token else { return }
                self.token = nil
                self.busyLabel = nil
                self.progress = nil
                UIApplication.shared.isIdleTimerDisabled = false
                self.alert = .error("恢复已取消。")
            } catch {
                guard self.token === token else { return }
                self.token = nil
                self.busyLabel = nil
                self.progress = nil
                UIApplication.shared.isIdleTimerDisabled = false
                self.alert = .error(error.localizedDescription)
            }
        }
    }

    func export(_ record: BackupRecord) {
        guard !isBusy else { return }
        busyLabel = "打包…"
        progress = nil
        let token = CancelToken()
        self.token = token
        UIApplication.shared.isIdleTimerDisabled = true

        Task {
            let url = await Task.detached(priority: .userInitiated) {
                BackupEngine.shared.exportArchive(record: record, token: token)
            }.value

            UIApplication.shared.isIdleTimerDisabled = false
            guard self.token === token else { return }
            self.token = nil
            self.busyLabel = nil
            if let url {
                self.exportFile = BackupExportFile(url: url)
            } else {
                self.alert = .error("导出失败。")
            }
        }
    }

    func delete(_ record: BackupRecord) {
        if BackupStore.shared.remove(record) {
            alert = .report("已删除备份 \(record.name)。")
        } else {
            alert = .error("删除失败，备份文件夹可能仍在使用。")
        }
    }

    func exportAll() {
        guard !isBusy, !BackupStore.shared.records.isEmpty else { return }
        busyLabel = "打包全部…"
        progress = nil
        let token = CancelToken()
        self.token = token
        UIApplication.shared.isIdleTimerDisabled = true

        Task {
            let url = await Task.detached(priority: .userInitiated) {
                BackupEngine.shared.exportAllArchives(token: token)
            }.value

            UIApplication.shared.isIdleTimerDisabled = false
            guard self.token === token else { return }
            self.token = nil
            self.busyLabel = nil
            if let url {
                self.exportFile = BackupExportFile(url: url)
            } else {
                self.alert = .error("导出全部备份失败。")
            }
        }
    }

    func cancel() {
        token?.cancel()
        if busyLabel == "定位容器…" {
            ContainerIndex.shared.cancel()
        }
    }

    private func receive(_ value: BackupProgress) {
        let finished = value.current == nil
        guard finished || Date().timeIntervalSince(lastProgressAt) > 0.1 else { return }
        lastProgressAt = Date()
        progress = value
    }
}

struct BackupsView: View {
    @ObservedObject private var store = BackupStore.shared
    @ObservedObject private var icons = AppIconStore.shared
    @StateObject private var model = BackupsModel()
    @AppStorage(SettingsKey.restoreSnapshot) private var restoreSnapshot = true

    var body: some View {
        List {
            if store.records.isEmpty {
                Section {
                    EmptyDirectoryView(symbol: "externaldrive.badge.timemachine",
                                       title: "还没有备份",
                                       message: "在容器目录的菜单里选择“备份当前文件夹”。")
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(store.records) { record in
                        row(record)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.beginRestore(record)
                            }
                            .contextMenu {
                                Button {
                                    model.beginRestore(record)
                                } label: {
                                    Label("恢复", systemImage: "arrow.counterclockwise")
                                }
                                Button {
                                    model.export(record)
                                } label: {
                                    Label("导出 ZIP", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    model.alert = .delete(record)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    model.alert = .delete(record)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("备份")
                        Spacer()
                        Text("\(store.records.count) 份 · \(Format.bytes(store.totalBytes))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("点一份备份开始恢复；同名文件会被覆盖。备份在 Documents/Backups，删除本应用会一起删除，建议定期“导出全部备份”。")
                }
            }

            Section {
                Toggle("恢复前自动快照", isOn: $restoreSnapshot)
            } header: {
                Text("恢复保护")
            } footer: {
                Text(restoreSnapshot
                     ? "恢复前把目标目录另存一份完整备份，失败可回退。APFS 克隆通常只占元数据；快照失败会中止恢复。"
                     : "关闭后恢复直接覆盖，没有回退。仅在确定备份可靠时关闭。")
            }

            if let progress = model.progress {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                        HStack {
                            Text("\(progress.phase) · \(Format.bytes(progress.bytes))")
                            Spacer()
                            Text("\(progress.files) 个文件")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isBusy {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("停止") {
                        model.cancel()
                    }
                }
            } else if !store.records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            model.exportAll()
                        } label: {
                            Label("导出全部备份", systemImage: "square.and.arrow.up.on.square")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("备份操作")
                }
            }
        }
        .onAppear {
            store.reload()
            for record in store.records {
                if let identifier = record.containerIdentifier {
                    _ = AppIconStore.shared.icon(for: identifier)
                }
            }
        }
        .sheet(item: $model.exportFile) { payload in
            ShareSheet(items: [payload.url]) {
                model.exportFile = nil
            }
            .ignoresSafeArea()
        }
        .alert(item: $model.alert) { value in
            switch value {
            case .restore(let record, let target):
                var message = "将恢复到 \(PathTool.short(target, keep: 4))；同名文件会被覆盖。"
                if restoreSnapshot {
                    message += "\n恢复前会先快照目标目录。"
                }
                if let warning = BackupSupport.spaceWarning(target: target, bytes: record.bytes) {
                    message += "\n" + warning
                }
                return Alert(title: Text("恢复备份"),
                             message: Text(message),
                             primaryButton: .destructive(Text("恢复")) {
                                 model.restore(record, target: target, snapshot: restoreSnapshot)
                             },
                             secondaryButton: .cancel(Text("取消")))
            case .delete(let record):
                return Alert(title: Text("删除备份"),
                             message: Text("会删除「\(record.name)」，无法撤销。"),
                             primaryButton: .destructive(Text("删除")) { model.delete(record) },
                             secondaryButton: .cancel(Text("取消")))
            case .report(let text):
                return Alert(title: Text("完成"),
                             message: Text(text),
                             dismissButton: .default(Text("好")))
            case .error(let message):
                return Alert(title: Text("操作失败"),
                             message: Text(message),
                             dismissButton: .default(Text("好")))
            }
        }
        .overlay {
            if let label = model.busyLabel {
                BusyOverlay(text: label)
            }
        }
    }

    private func detail(_ record: BackupRecord) -> String {
        var text = "\(Format.date(record.createdAt)) · \(record.mode.title) · \(Format.bytes(record.bytes))"
        if let failures = record.failures, failures > 0 {
            text += " · \(failures) 项失败"
        }
        return text
    }

    private func row(_ record: BackupRecord) -> some View {
        HStack(spacing: 10) {
            if let identifier = record.containerIdentifier,
               let data = icons.cachedIcon(for: identifier),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 38, height: 38)
                    .background(Color.indigo.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(PathTool.short(record.sourcePath, keep: 3))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

}
