import AppKit
import SwiftUI

// Copyright (C) 2026 Uberit s.r.o.
// SPDX-License-Identifier: AGPL-3.0-only
// Additional terms: ../../../../ADDITIONAL_TERMS.md

@main
struct LLMChatApp: App {
    @StateObject private var viewModel = AppViewModel.bootstrap()

    init() {
        if let iconURL = Bundle.module.url(forResource: "logo", withExtension: "png"),
           let image = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .task {
                    await viewModel.refreshLLMStatus()
                }
        }
        .defaultSize(width: 1320, height: 860)
    }
}
