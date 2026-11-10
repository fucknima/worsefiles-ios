//
//  WorseFilesApp.swift
//  WorseFiles
//

import SwiftUI

@main
struct WorseFilesApp: App {
    @StateObject private var app = AppModel()

    init() {
        JobCenter.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .tint(.indigo)
        }
    }
}
