//
//  SettingsView.swift
//  WorseFiles
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = Catalog.shared

    @AppStorage(SettingsKey.showHidden) private var showHidden = false
    @AppStorage(SettingsKey.autoResolveLabels) private var autoResolveLabels = true
    @AppStorage(SettingsKey.foldersFirst) private var foldersFirst = true
    @AppStorage(SettingsKey.sortKey) private var sortRaw = SortKey.name.rawValue
    @AppStorage(SettingsKey.sortAscending) private var sortAscending = true
    @AppStorage(SettingsKey.maxInode) private var maxInode = ""

    @State private var groupSnapshot = AppGroupResolver.snapshot()
    @State private var clearTarget: ClearTarget?
    @State private var showIntro = false

    private enum ClearTarget: String, Identifiable, Equatable {
        case scans = "扫描结果"
        case labels = "名称缓存"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                groupSection
                browsingSection
                cacheSection
                sandboxSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                groupSnapshot = AppGroupResolver.snapshot(refresh: true)
            }
            .sheet(isPresented: $showIntro) {
                IntroView()
            }
            .confirmationDialog("清除缓存",
                                isPresented: Binding(
                                    get: { clearTarget != nil },
                                    set: { if !$0 { clearTarget = nil } }
                                ),
                                titleVisibility: .visible,
                                presenting: clearTarget) { target in
                Button("清除\(target.rawValue)", role: .destructive) {
                    if target == .scans {
                        catalog.clearScans()
                    } else {
                        catalog.clearLabels()
                    }
                    clearTarget = nil
                    app.flash("已清除\(target.rawValue)")
                }
                Button("取消", role: .cancel) { clearTarget = nil }
            } message: { target in
                Text(target == .scans
                     ? "已发现的容器路径会全部丢弃，下次打开根目录重新扫描。"
                     : "已缓存的 bundle identifier 会清空，界面回到 UUID 显示。")
            }
        }
    }

    // MARK: - Sections

    private var groupSection: some View {
        Section {
            LabeledContent("当前使用") {
                Text(groupSnapshot.active)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            LabeledContent("容器访问") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(groupSnapshot.hasAccessible ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(groupSnapshot.hasAccessible ? "可用" : "不可用")
                        .foregroundStyle(.secondary)
                }
            }
            if let groupURL = groupContainerURL {
                Text(groupURL.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if groupSnapshot.groups.isEmpty {
                Label("签名里没有读到 App Group。重签时必须授予 App Groups entitlement。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                ForEach(groupSnapshot.groups, id: \.self) { group in
                    HStack(spacing: 7) {
                        Image(systemName: groupSnapshot.accessible.contains(group)
                              ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(groupSnapshot.accessible.contains(group)
                                             ? Color.green : Color.secondary)
                        Text(group)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Button {
                groupSnapshot = AppGroupResolver.refresh()
                app.flash("已重新检测 App Group")
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise")
            }
            Button {
                FileService.shared.releaseAllExtensions()
                app.flash("已释放沙盒句柄")
            } label: {
                Label("释放所有沙盒句柄", systemImage: "lock.open")
            }
            NavigationLink {
                DiagnosticsContent()
            } label: {
                Label("运行诊断", systemImage: "stethoscope")
            }
        } header: {
            Text("App Group")
        } footer: {
            Text("应用从自己的代码签名读取 App Group，不需要手动填写。重签时必须授予 App Groups entitlement；免费 Apple ID 通常不支持 App Groups。")
        }
    }

    private var browsingSection: some View {
        Section {
            Toggle("显示隐藏文件", isOn: $showHidden)
            Toggle("扫描后自动识别容器名称", isOn: $autoResolveLabels)
            Toggle("文件夹优先", isOn: $foldersFirst)
            Picker("默认排序", selection: $sortRaw) {
                ForEach(SortKey.allCases) { key in
                    Text(key.title).tag(key.rawValue)
                }
            }
            Toggle("升序", isOn: $sortAscending)
            HStack {
                Text("inode 上限")
                Spacer()
                TextField("自动", text: $maxInode)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 130)
            }
        } header: {
            Text("浏览")
        } footer: {
            Text("inode 上限留空时，使用新建临时文件的 inode 作为扫描终点。填写数字后，下拉刷新会对该根路径全量扫描 1…N 并重建缓存；设备不同，数字差别很大。")
        }
    }

    private var cacheSection: some View {
        Section {
            LabeledContent("已缓存根路径", value: "\(catalog.disk.scans.count)")
            LabeledContent("已知容器名称", value: "\(catalog.disk.labels.count)")
            Button(role: .destructive) {
                clearTarget = .scans
            } label: {
                Text("清除扫描结果")
            }
            Button(role: .destructive) {
                clearTarget = .labels
            } label: {
                Text("清除名称缓存")
            }
        } header: {
            Text("缓存")
        } footer: {
            Text("扫描结果保存在本应用 Application Support，删除应用即清除。")
        }
    }

    private var sandboxSection: some View {
        Section {
            LabeledContent("系统", value: "iOS \(Roots.majorVersion)")
            LabeledContent("逃逸支持", value: escapeStatus)
            LabeledContent("已消费句柄", value: "\(SandboxBroker.shared.count)")
        } header: {
            Text("沙盒")
        } footer: {
            Text("只在 iOS 27.0.1 实测；worse_query 文档区间为 iOS 26.0–26.7.2 / 27.2。不是越狱，也不提供越狱能力。")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: versionText)
            Button {
                showIntro = true
            } label: {
                Label("使用说明", systemImage: "questionmark.circle")
            }
            Link(destination: URL(string: "https://github.com/fucknima/worsefiles-ios")!) {
                Label("WorseFiles 源码（GPL-3.0）", systemImage: "arrow.up.right.square")
            }
            Link(destination: URL(string: "https://github.com/forcequitOS/worse_query")!) {
                Label("worse_query 项目", systemImage: "arrow.up.right.square")
            }
            Link(destination: URL(string: "https://github.com/forcequitOS/bad_query")!) {
                Label("bad_query 项目", systemImage: "arrow.up.right.square")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("worse_query 与 pathleak © 2026 Taj C (forcequit)，GPL-3.0。WorseFiles 是派生作品，同样以 GPL-3.0 发布；完整源码与 NOTICE 见项目仓库。")
        }
    }

    // MARK: - Helpers

    private var groupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupSnapshot.active)
    }

    private var escapeStatus: String {
        if !Roots.escapeSupported { return "不可用" }
        if Roots.verifiedVersion { return "已实测（27.0.1）" }
        return Roots.testedWindow ? "未实测（尽力而为）" : "未测试"
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
