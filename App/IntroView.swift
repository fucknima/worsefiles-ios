//
//  IntroView.swift
//  WorseFiles
//

import SwiftUI

struct IntroView: View {
    var onClose: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("容器文件", systemImage: "folder.badge.gearshape")
                            .font(.headline)
                        Text("浏览应用数据、扩展、App Group 与系统容器。不是越狱，只覆盖 worse_query 列出的路径。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    step(1,
                         title: "确认环境",
                         detail: "首页顶部应为绿色“环境就绪”。黄色说明系统版本未完全验证或签名缺少 App Group。")
                    step(2,
                         title: "打开应用数据",
                         detail: "第一次需要 inode 扫描，可能持续一段时间；进度条旁可以停止。结果会缓存，之后只做增量扫描。")
                    step(3,
                         title: "维护里备份与清理",
                         detail: "先做备份再清理或恢复。删除没有回收站；恢复默认会先给目标目录做快照。")
                } header: {
                    Text("三步开始")
                }

                Section {
                    Label("App Group 必须是专用组", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline.weight(.semibold))
                    Text("每次容器查询都会删除并重建该 App Group 的 Library/Caches。如果和别的 App 共用，那个 App 的缓存会被清掉。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("签名前提")
                }

                Section {
                    Text("应用数据、备份和日志都在 WorseFiles 自己的沙盒里。删除应用会一起删除备份，重要数据请用“导出全部备份”带走。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("遇到问题到“诊断与日志”点“复制完整报告（含日志）”，里面包含设备、系统、索引和图标探针结果。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("数据在哪")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("开始使用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("开始") {
                        onClose()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                onClose()
            }
        }
    }

    private func step(_ index: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
