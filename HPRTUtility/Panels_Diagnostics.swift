//
//  Panels_Diagnostics.swift
//  HPRT Utility
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Overview

struct OverviewPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PanelScaffold(title: "Overview",
                      subtitle: "Everything between this Mac and the printer, checked end to end.") {

            let (status, title, detail) = state.headline
            HeadlineBanner(status: status, title: title, detail: detail)

            pipelineStrip

            Card(title: "System", systemImage: "cpu") {
                checkList(state.systemChecks)
            }
            if !state.hardwareChecks.isEmpty {
                Card(title: "Hardware & Battery", systemImage: "battery.100") {
                    checkList(state.hardwareChecks)
                }
            }
            Card(title: "Driver", systemImage: "shippingbox") {
                checkList(state.driverChecks)
            }
            Card(title: "Connection", systemImage: "cable.connector") {
                checkList(state.usbChecks + state.btClassicChecks + state.bridgeChecks)
            }
            Card(title: "Print queue", systemImage: "list.bullet.rectangle") {
                checkList(state.queueChecks)
            }

            if !state.activity.isEmpty {
                Card(title: "Activity", systemImage: "clock.arrow.circlepath") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(state.activity.prefix(12)) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                StatusChip(status: entry.status, compact: true).frame(width: 16)
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A visual of the five hops a page has to survive.
    private var pipelineStrip: some View {
        let stages: [(String, String, CheckStatus)] = [
            ("Document", "doc",
             .ok),
            ("macOS raster", "square.grid.3x3",
             state.driver.installed ? .ok : .unknown),
            ("HPRT filter", "gearshape.2",
             state.driver.installed
             ? (state.driver.filters.allSatisfy(\.isUniversal) || state.system.rosettaInstalled ? .ok : .failure)
             : .failure),
            ("Transport", "cable.connector",
             state.usb.devices.isEmpty && !state.bridge.portOpen && !state.btPrinterConnected ? .failure : .ok),
            ("Printer", "printer",
             state.usb.devices.isEmpty && !state.bridge.portOpen && !state.btPrinterConnected ? .unknown : .ok)
        ]

        return Card(title: "Print path", subtitle: "Each hop a page must survive", systemImage: "arrow.right") {
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    VStack(spacing: 7) {
                        ZStack {
                            Circle()
                                .fill(stage.2.tint.opacity(0.14))
                                .frame(width: 42, height: 42)
                            Image(systemName: stage.1)
                                .foregroundStyle(stage.2.tint)
                                .imageScale(.medium)
                        }
                        Text(stage.0)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    if index < stages.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 1)
                            .frame(maxWidth: 40)
                            .offset(y: -12)
                    }
                }
            }
        }
    }

    private func checkList(_ checks: [Check]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(checks) { check in
                CheckRow(check: check) { state.apply($0) }
                if check.id != checks.last?.id { Divider().opacity(0.4) }
            }
        }
    }
}

// MARK: - Driver

struct DriverPanel: View {
    @EnvironmentObject private var state: AppState
    @State private var dmgURL: URL?
    @State private var modelName = ""
    @State private var queueName = ""
    @State private var density = 3
    @State private var installing = false
    @State private var installOutput: String?
    @State private var showUninstallConfirm = false

    var body: some View {
        PanelScaffold(title: "Driver",
                      subtitle: "What is installed, where it lives, and whether this Mac can run it.") {

            Card(title: "System requirements", systemImage: "cpu") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.systemChecks) { check in
                        CheckRow(check: check) { state.apply($0) }
                    }
                }
            }

            Card(title: "Installed components", systemImage: "shippingbox") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.driverChecks) { check in
                        CheckRow(check: check) { remedy in
                            if case .installDriver = remedy { prepareInstall() } else { state.apply(remedy) }
                        }
                    }
                }
            }

            if !state.driver.filters.isEmpty {
                Card(title: "Filter binaries", systemImage: "doc.badge.gearshape") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.driver.filters) { filter in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text((filter.path as NSString).lastPathComponent)
                                        .font(.system(.callout, design: .monospaced).weight(.medium))
                                    StatusChip(status: filter.isUniversal ? .ok : .warning,
                                               text: filter.architectures.joined(separator: " + "))
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(filter.sizeBytes),
                                                                  countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(filter.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if let signedBy = filter.signedBy {
                                    Text("Signed by \(signedBy)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if filter.id != state.driver.filters.last?.id { Divider().opacity(0.4) }
                        }
                    }
                }
            }

            installerCard

            Card(title: "Why the vendor package fails on this Mac",
                 subtitle: "Background",
                 systemImage: "info.circle") {
                Text("""
                HPRT's driver.pkg writes its CUPS filters to \(Paths.sealedFilterDirectory). That path sits on the \
                sealed system volume and has been read-only since macOS 11, so the payload cannot land. Modern \
                third-party printer drivers install their filters under /Library/Printers/<Vendor>/ and reference \
                them by absolute path from the PPD's *cupsFilter line — which is exactly what the installer below does.

                It also repairs two defects in the shipped PPD: the typo *DefaultPrintDarkness (which should read \
                *DefaultPrintDensity, and which stops CUPS from ever applying a default density), and the complete \
                absence of a PrintDensity block in the MT8003 PPD. The filter honours the option either way — the \
                disassembly shows it emitting GS ( K fn=49 — so the control just has to be declared.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var installerCard: some View {
        Card(title: "Install or repair",
             subtitle: "Uses HPRT's own signed filters, installed the way macOS expects",
             systemImage: "wrench.and.screwdriver") {

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button {
                        pickDMG()
                    } label: {
                        Label(dmgURL == nil ? "Choose driver .dmg…" : "Change…",
                              systemImage: "externaldrive")
                    }
                    if let dmgURL {
                        Text(dmgURL.lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("The DMG downloaded from HPRT")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        TextField("MT8003", text: $modelName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Text("Taken from the USB descriptor, not the box")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Queue name").foregroundStyle(.secondary)
                        TextField("MT8003", text: $queueName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Text("")
                    }
                    GridRow {
                        Text("Default density").foregroundStyle(.secondary)
                        Picker("", selection: $density) {
                            Text("1 — Light").tag(1)
                            Text("2 — Normal").tag(2)
                            Text("3 — Maximum").tag(3)
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Text("Injected into the PPD as *DefaultPrintDensity")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        runInstall()
                    } label: {
                        if installing {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…") }
                        } else {
                            Label("Install / Repair", systemImage: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dmgURL == nil || modelName.isEmpty || queueName.isEmpty || installing)

                    Button(role: .destructive) {
                        showUninstallConfirm = true
                    } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                    .disabled(installing)

                    Spacer()
                    Text("Requires administrator rights")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let installOutput {
                    MonoLog(lines: installOutput.components(separatedBy: .newlines).filter { !$0.isEmpty },
                            maxHeight: 140)
                }
            }
        }
        .onAppear(perform: prefill)
        .confirmationDialog("Remove the managed HPRT driver?",
                            isPresented: $showUninstallConfirm, titleVisibility: .visible) {
            Button("Remove driver and queue", role: .destructive) { runUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes \(Paths.managedPrefix), the patched PPD, and the print queue. HPRT's own installer is untouched.")
        }
    }

    private func prefill() {
        if modelName.isEmpty {
            modelName = state.usb.devices.first?.productName
                ?? state.cupsDevices.first?.firstMatch("usb://[^/]+/([^?]+)")
                ?? "MT8003"
        }
        if queueName.isEmpty { queueName = modelName }
    }

    private func prepareInstall() {
        prefill()
        if dmgURL == nil { pickDMG() }
    }

    private func pickDMG() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("com.apple.disk-image") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Select the HPRT driver disk image"
        if panel.runModal() == .OK { dmgURL = panel.url }
    }

    private func runInstall() {
        guard let dmgURL else { return }
        let uri = state.cupsDevices.first?.split(separator: " ").last.map(String.init)
            ?? state.selectedQueue?.deviceURI ?? ""
        guard !uri.isEmpty else {
            installOutput = "No device URI available. Connect the printer over USB and refresh."
            return
        }
        installing = true
        installOutput = nil
        let plan = DriverInstaller.Plan(dmg: dmgURL, model: modelName,
                                        queueName: queueName, deviceURI: uri, density: density)
        Task.detached(priority: .userInitiated) {
            let result = DriverInstaller.install(plan)
            await MainActor.run {
                installing = false
                installOutput = result.ok ? result.out : (result.err.isEmpty ? "Failed." : result.err)
                state.log(result.ok ? "Driver installed for \(plan.model)." : "Driver install failed.",
                          result.ok ? .ok : .failure)
                state.refreshAll()
            }
        }
    }

    private func runUninstall() {
        installing = true
        let queue = state.selectedQueue?.name
        Task.detached(priority: .userInitiated) {
            let result = DriverInstaller.uninstall(queueName: queue)
            await MainActor.run {
                installing = false
                installOutput = result.ok ? "Removed." : result.err
                state.log("Driver removed.", result.ok ? .ok : .failure)
                state.refreshAll()
            }
        }
    }
}

// MARK: - Queue

struct QueuePanel: View {
    @EnvironmentObject private var state: AppState
    @State private var pendingChange: String?

    var body: some View {
        PanelScaffold(title: "Print Queue",
                      subtitle: "CUPS state and every option the PPD exposes.") {

            if let queue = state.selectedQueue {
                Card(title: queue.name, subtitle: queue.modelName, systemImage: "printer") {
                    VStack(alignment: .leading, spacing: 8) {
                        KeyValueRow(key: "Device URI", value: queue.deviceURI)
                        KeyValueRow(key: "Transport", value: queue.transport.rawValue, monospaced: false)
                        KeyValueRow(key: "PPD", value: queue.ppdPath)
                        KeyValueRow(key: "State", value: queue.stateMessage, monospaced: false)
                    }
                }

                Card(title: "Health", systemImage: "stethoscope") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(state.queueChecks) { check in
                            CheckRow(check: check) { state.apply($0) }
                        }
                    }
                }

                Card(title: "PPD options",
                     subtitle: "The starred choice is what CUPS applies. Changing one here writes a new queue default.",
                     systemImage: "slider.horizontal.3") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(queue.options) { option in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.displayName)
                                    Text(option.keyword)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 220, alignment: .leading)

                                Picker("", selection: Binding(
                                    get: { option.current },
                                    set: { newValue in setOption(queue: queue.name,
                                                                keyword: option.keyword,
                                                                value: newValue) })) {
                                    ForEach(option.choices, id: \.self) { choice in
                                        Text(choice).tag(choice)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 260)

                                if option.keyword == "PrintDensity" && option.current != "3" {
                                    Text("3 is the darkest")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }

                Card(title: "Maintenance", systemImage: "wrench") {
                    HStack(spacing: 10) {
                        Button("Enable") { state.apply(.enableQueue(queue.name)) }
                        Button("Accept jobs") { state.apply(.acceptQueue(queue.name)) }
                        Button("Clear stuck jobs") { state.apply(.clearJobs(queue.name)) }
                        Button("Force density 3") { state.apply(.setDensity(queue: queue.name, value: 3)) }
                        Spacer()
                        Button("Printers & Scanners…") { state.apply(.openPrintersPane) }
                    }
                }

                if let pendingChange {
                    Text(pendingChange).font(.callout).foregroundStyle(.secondary)
                }

            } else {
                Card(title: "No queue", systemImage: "exclamationmark.triangle") {
                    EmptyHint(symbol: "printer.trianglebadge.exclamationmark",
                              title: "No HPRT print queue",
                              message: "Install the driver from the Driver panel — it creates the queue on the URI CUPS has already discovered.")
                }
            }
        }
    }

    private func setOption(queue: String, keyword: String, value: String) {
        pendingChange = "Setting \(keyword) = \(value)…"
        Task.detached(priority: .userInitiated) {
            let result = Shell.runPrivileged("/usr/sbin/lpadmin -p '\(queue)' -o \(keyword)=\(value)")
            await MainActor.run {
                pendingChange = result.ok ? "\(keyword) set to \(value)." : "Failed: \(result.err)"
                state.log(result.ok ? "\(keyword) = \(value)" : "Could not set \(keyword)",
                          result.ok ? .ok : .failure)
                state.refreshAll()
            }
        }
    }
}
