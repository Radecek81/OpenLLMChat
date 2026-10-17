import AppKit
import SwiftUI

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
