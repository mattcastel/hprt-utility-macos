//
//  HPRTUtilityApp.swift
//  HPRT Utility
//
//  A native control panel for HPRT MT800-family thermal printers on macOS.
//

import SwiftUI

@main
struct HPRTUtilityApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Diagnostics") {
                Button("Refresh All Checks") { state.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Permissions & Setup…") { state.showOnboarding = true }
                Divider()
                ForEach(Panel.allCases) { panel in
                    Button(panel.title) { state.selection = panel }
                }
            }

            CommandGroup(replacing: .help) {
                Link("HPRT MT800 product page",
                     destination: URL(string: "https://www.hprt.com/Product/Mobile-printer-for-A4-paper-MT800.html")!)
                Link("HPRT driver downloads",
                     destination: URL(string: "https://download.hprt.com/mt800/drivers.html")!)
            }
        }
    }
}
