//
//  Components.swift
//  WorseFiles
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileGlyph: View {
    let item: FSItem

    var body: some View {
        if let data = item.iconData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let identifier = item.identifier, item.isDirectory {
            let style = ServiceGlyph.style(for: identifier)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(style.color.gradient)
                    .frame(width: 36, height: 36)
                Image(systemName: style.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        } else {
            let style = FileGlyph.style(for: item)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(style.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: style.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(style.color)
            }
        }
    }

    static func style(for item: FSItem) -> (symbol: String, color: Color) {
        if item.isDirectory {
            if item.identifier != nil {
                return ("shippingbox.fill", .teal)
            }
            return ("folder.fill", .blue)
        }
        let ext = (item.name as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else {
            return ("doc.fill", .gray)
        }
        if type.conforms(to: .image) { return ("photo.fill", .purple) }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return ("film.fill", .orange) }
        if type.conforms(to: .audio) { return ("music.note", .pink) }
        if type.conforms(to: .archive) { return ("archivebox.fill", .brown) }
        if type.conforms(to: .sourceCode) { return ("chevron.left.forwardslash.chevron.right", .indigo) }
        if type.conforms(to: .json) || type.conforms(to: .propertyList) { return ("curlybraces", .mint) }
        if type.conforms(to: .pdf) { return ("doc.richtext.fill", .red) }
        if type.conforms(to: .text) { return ("doc.text.fill", .gray) }
        return ("doc.fill", .gray)
    }
}

enum ServiceGlyph {
    private static let rules: [(words: [String], symbol: String, color: Color)] = [
        (["emoji"], "face.smiling.inverse", .orange),
        (["keyboard", "inputui", "textinput", "dictation"], "keyboard.fill", .gray),
        (["airdrop", "sharing", "sharesheet"], "antenna.radiowaves.left.and.right", .blue),
        (["widget", "chrono"], "square.grid.2x2.fill", .blue),
        (["screenshot", "screencapture"], "camera.viewfinder", .indigo),
        (["poster", "wallpaper"], "photo.on.rectangle.angled", .purple),
        (["siri", "assistant"], "waveform", .indigo),
        (["camera"], "camera.fill", .gray),
        (["photo"], "photo.fill", .orange),
        (["music", "audio", "shazam"], "music.note", .pink),
        (["headphone", "airpod", "bluetooth"], "headphones", .gray),
        (["hearing"], "ear.fill", .blue),
        (["weather"], "cloud.sun.fill", .teal),
        (["location", "maps", "navigation"], "location.fill", .blue),
        (["health", "fitness", "workout"], "heart.fill", .red),
        (["pay", "wallet", "passbook", "cash", "finance"], "creditcard.fill", .green),
        (["mail"], "envelope.fill", .blue),
        (["message", "sms", "imessage"], "message.fill", .green),
        (["facetime", "video"], "video.fill", .green),
        (["phone", "call", "telephony"], "phone.fill", .green),
        (["notification", "bulletin"], "bell.fill", .red),
        (["shortcut", "workflow", "intent"], "square.on.square", .indigo),
        (["safari", "web"], "safari.fill", .blue),
        (["news", "stocks"], "newspaper.fill", .red),
        (["calendar", "event"], "calendar", .red),
        (["note", "paper"], "note.text", .orange),
        (["reminder"], "checklist", .blue),
        (["game"], "gamecontroller.fill", .purple),
        (["auth", "account", "sso", "password", "keychain", "tcc", "privacy"], "lock.fill", .gray),
        (["print"], "printer.fill", .gray),
        (["clarity", "accessib"], "accessibility", .blue),
        (["home"], "house.fill", .orange),
        (["findmy", "fmd", "fmip"], "location.circle.fill", .green),
        (["carplay", "carradio", "cartrip"], "car.fill", .gray),
        (["tvremote", "tvsetup"], "tv.fill", .gray),
        (["book"], "book.fill", .orange),
        (["podcast"], "mic.fill", .purple),
        (["spotlight", "search"], "magnifyingglass", .gray),
        (["diagnostic", "logging", "crash", "analytics"], "stethoscope", .gray),
        (["font"], "textformat", .gray),
        (["translate"], "character.bubble.fill", .blue),
        (["file", "document", "cloud"], "folder.fill", .blue),
        (["setup", "buddy", "onboarding"], "gearshape.2.fill", .gray),
    ]

    static func style(for identifier: String) -> (symbol: String, color: Color) {
        let key = identifier.lowercased()
        for rule in rules {
            if rule.words.contains(where: { key.contains($0) }) {
                return (rule.symbol, rule.color)
            }
        }
        return ("shippingbox.fill", .teal)
    }
}

struct RootRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }
}

struct NoticeBanner: View {
    let notice: Notice

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.red : Color.green)
            Text(notice.text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct BusyOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            HStack(spacing: 10) {
                ProgressView()
                Text(text)
                    .font(.subheadline)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .transition(.opacity)
    }
}

struct EmptyDirectoryView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("无法读取")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

struct ScanProgressView: View {
    let status: ScanStatus
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("正在扫描 inode", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("停止", action: stop)
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            ProgressView(value: status.fraction)
            Text("\(status.done.formatted()) / \(status.total.formatted())")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
    }
}

struct LabelProgressView: View {
    let progress: LabelProgress
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("读取容器标识", systemImage: "tag")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("停止", action: stop)
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            Text("\(progress.done) / \(progress.total)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
    }
}
