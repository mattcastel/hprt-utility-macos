//
//  RootView.swift
//  HPRT Utility
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingReport = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .navigationTitle("")
        .frame(minWidth: 1_060, minHeight: 720)
        .onAppear {
            // Show onboarding on first launch and hold the Bluetooth prompt until
            // the user asks for it there — otherwise every grant fires at once.
            state.presentOnboardingIfNeeded()
            state.refreshAll()
            state.usb.onChange = { [weak state] in
                state?.log("USB topology changed.", .unknown)
                state?.refreshAll()
            }
            if state.hasOnboarded { state.ble.start() }
        }
        .sheet(isPresented: $showingReport) {
            ReportSheet(markdown: state.markdownReport())
        }
        .sheet(isPresented: $state.showOnboarding) {
            OnboardingView().environmentObject(state)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        // Explicit Button rows rather than List(selection:). The selection-binding
        // form of a NavigationSplitView sidebar does not reliably commit on macOS,
        // which left every click stuck on Overview. A Button that writes
        // state.selection directly is the same mechanism the Diagnostics menu uses,
        // and it always works.
        List {
            Section {
                ForEach(Panel.allCases) { panel in
                    sidebarRow(panel)
                }
            } header: {
                Text("Diagnostics")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 218, ideal: 232, max: 280)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private func sidebarRow(_ panel: Panel) -> some View {
        let selected = (state.selection ?? .overview) == panel
        let failures = badge(for: panel)
        return Button {
            state.selection = panel
        } label: {
            HStack(spacing: 10) {
                Image(systemName: panel.symbol)
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(panel.title).foregroundStyle(.primary)
                    Text(panel.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if failures > 0 {
                    Text("\(failures)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                StatusChip(status: state.headline.0, compact: true)
                Text(state.headline.1)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            if let last = state.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// A small red count on panels that currently hold a failure.
    private func badge(for panel: Panel) -> Int {
        let checks: [Check]
        switch panel {
        case .overview: checks = []
        case .printer:  checks = state.usbChecks + state.btClassicChecks + state.bridgeChecks
        case .driver:   checks = state.systemChecks + state.driverChecks
        case .queue:    checks = state.queueChecks
        default:        checks = []
        }
        return checks.filter { $0.status == .failure }.count
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch state.selection ?? .overview {
        case .overview: OverviewPanel()
        case .printer:  PrinterPanel()
        case .driver:   DriverPanel()
        case .queue:    QueuePanel()
        case .printing: PrintPanel()
        case .raster:   RasterLabPanel()
        case .console:  ConsolePanel()
        case .logs:     LogPanel()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Image(systemName: "printer.fill")
                Text("HPRT Utility").font(.headline)
            }
        }
        ToolbarItemGroup {
            if state.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                showingReport = true
            } label: {
                Label("Report", systemImage: "square.and.arrow.up")
            }
            .help("Build a diagnostic report you can copy or save")

            Button {
                state.refreshAll()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Re-run every check (⌘R)")
        }
    }
}

// MARK: - Report sheet

struct ReportSheet: View {
    let markdown: String
    @Environment(\.dismiss) private var dismiss
    @State private var saved: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diagnostic Report").font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                Text(markdown)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            Divider()

            HStack {
                if let saved {
                    Text(saved).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                    saved = "Copied to the clipboard."
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    save()
                } label: {
                    Label("Save as Markdown…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding()
        }
        .frame(width: 760, height: 620)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hprt-diagnostic.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
            saved = "Saved to \(url.lastPathComponent)."
        }
    }
}
