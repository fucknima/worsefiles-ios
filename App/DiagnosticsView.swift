//
//  DiagnosticsView.swift
//  WorseFiles
//

import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DiagnosticsContent()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

struct DiagnosticsContent: View {
    @EnvironmentObject private var app: AppModel

    @State private var lines: [String] = []
    @State private var logText = ""
    @State private var running = true
    @State private var copied = false
    @State private var copiedLog = false
    @State private var exportFile: ExportFile?

    private struct ExportFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        List {
            Section {
                if running {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("检测中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lines.indices, id: \.self) { index in
                            Text(lines[index])
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("检测结果")
            }

            Section {
                if logText.isEmpty {
                    Text("暂无日志")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(logText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                HStack {
                    Text("日志")
                    Spacer()
                    Text("\(Log.lines.count) 行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if let path = Log.filePath {
                    Text("文件：\(path)（Documents，可在“文件”App 或应用内 Documents 查看）")
                }
            }

            Section {
                Button {
                    Task { await run() }
                } label: {
                    Label("重新运行", systemImage: "arrow.clockwise")
                }
                .disabled(running)

                Button {
                    Task {
                        running = true
                        _ = await ContainerIndex.shared.reconcileIfNeeded(minInterval: 0)
                        await run()
                    }
                } label: {
                    Label("同步已安装应用", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(running)

                Button {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                    copied = true
                    app.flash("已复制诊断结果")
                } label: {
                    Label(copied ? "已复制" : "复制诊断结果", systemImage: "doc.on.doc")
                }
                .disabled(running || lines.isEmpty)

                Button {
                    let text = Log.exportText
                    if text.isEmpty {
                        app.flash("暂无日志")
                    } else {
                        UIPasteboard.general.string = text
                        copiedLog = true
                        app.flash("已复制日志")
                    }
                } label: {
                    Label(copiedLog ? "日志已复制" : "复制日志", systemImage: "doc.on.doc")
                }

                Button {
                    if let url = Log.exportFileURL() {
                        exportFile = ExportFile(url: url)
                    } else {
                        app.flash("暂无日志")
                    }
                } label: {
                    Label("导出日志", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    Log.clear()
                    logText = ""
                    copiedLog = false
                    app.flash("日志已清空")
                } label: {
                    Label("清空日志", systemImage: "trash")
                }
            } header: {
                Text("操作")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await run() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(running)
            }
        }
        .task {
            await run()
        }
        .sheet(item: $exportFile) { payload in
            ShareSheet(items: [payload.url]) {
                exportFile = nil
            }
            .ignoresSafeArea()
        }
    }

    private func run() async {
        running = true
        copied = false
        copiedLog = false
        let result = await Task.detached(priority: .userInitiated) {
            FileService.shared.diagnose()
        }.value
        var detail = result
        for root in Roots.all {
            detail.append("\(root.title)：\(Catalog.shared.count(for: root.path)) 项")
        }
        if let version = Catalog.shared.scanVersion {
            detail.append("索引版本：\(version)")
        }
        let index = ContainerIndex.shared
        let names = AppNames.shared
        detail.append("应用名称库：\(names.loaded ? "\(names.databaseCount) 条" : "未加载")")
        let probes = ["com.apple.mobilesafari"]
            + [Catalog.shared.disk.labels.first?.value ?? "com.kestrel.worsefiles"]
        for probe in probes {
            detail.append("图标 \(probe)：\(WFIconReport(probe))")
        }
        detail.append("已安装应用：\(index.installedAppCount)（数据容器 \(index.installedPathCount)）")
        detail.append("应用列表：\(index.installedListAvailable ? "可用" : "不可用")")
        detail.append("上次同步：\(Format.date(index.lastReconciled))")
        lines = detail
        logText = Log.tail
        running = false
    }
}
