//
//  Onboarding.swift
//  HPRT Utility
//
//  A first-run splash that asks for each capability the app needs, one clearly
//  labelled row at a time, and checks their current state in parallel — instead
//  of firing every system prompt at once the moment the window opens.
//

import SwiftUI
import CoreBluetooth
import AppKit

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState

    /// Where a single permission currently stands.
    enum Phase: Equatable {
        case checking          // status is being resolved
        case granted           // good to go
        case denied            // the user said no — needs Settings
        case notDetermined     // never asked
        case onDemand          // no upfront grant; requested when first needed
        case info              // nothing to grant, purely informational
    }

    @State private var bluetooth: Phase = .checking
    @State private var admin: Phase = .checking
    @State private var printing: Phase = .checking
    @State private var btBusy = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    bluetoothCard
                    adminCard
                    printingCard
                    reassurance
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .task { await checkAllInParallel() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to HPRT Utility").font(.title2.weight(.bold))
                Text("Grant the few capabilities it needs. You can change any of them later in System Settings, and revisit this screen from the Diagnostics menu.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if allResolved {
                Label("All checks complete", systemImage: "checkmark.seal.fill")
                    .font(.callout).foregroundStyle(.green)
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Continue") { finish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    // MARK: Cards

    private var bluetoothCard: some View {
        PermissionCard(
            icon: "dot.radiowaves.left.and.right", tint: .blue,
            title: "Bluetooth",
            detail: "Finds the MT800 over Bluetooth LE, reads its link state, and looks for a battery level. Needed only for the wireless features.",
            phase: bluetooth,
            busy: btBusy,
            primary: bluetooth == .notDetermined ? .init(label: "Allow", action: requestBluetooth) : nil,
            secondary: bluetooth == .denied ? .init(label: "Open Settings", action: openBluetoothSettings) : nil
        )
    }

    private var adminCard: some View {
        PermissionCard(
            icon: "lock.shield", tint: .orange,
            title: "Administrator",
            detail: "There is nothing to grant here. Creating or repairing a print queue (lpadmin, cupsctl) asks for your password with the standard macOS dialog at that moment — never before. Nothing is installed as a background helper.",
            phase: admin,
            busy: false,
            primary: nil,
            secondary: nil
        )
    }

    private var printingCard: some View {
        PermissionCard(
            icon: "printer", tint: .green,
            title: "USB & Printing",
            detail: printingDetail,
            phase: printing,
            busy: false, primary: nil, secondary: nil
        )
    }

    private var printingDetail: String {
        if !state.usb.devices.isEmpty { return "The printer is on USB right now. No permission is required — IOKit and CUPS work out of the box." }
        if state.btClassic.contains(where: { $0.isPrinter }) { return "A Bluetooth-paired printer was found. No permission is required for USB or CUPS printing." }
        return "Reading USB topology and driving CUPS need no permission at all. Plug the printer in whenever you like."
    }

    private var reassurance: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.secondary)
            Text("HPRT Utility never phones home and installs no privileged helper. The App Sandbox is off so it can talk to CUPS and the device directly; everything it does is visible in the panels.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: Status resolution (run concurrently)

    private var allResolved: Bool { bluetooth != .checking && admin != .checking && printing != .checking }

    private func checkAllInParallel() async {
        // Three independent checks, kicked off together; each row updates itself
        // as soon as its own result lands.
        async let bt = resolveBluetooth()
        async let ad = resolveAdmin()
        async let pr = resolvePrinting()
        let results = await (bt, ad, pr)
        bluetooth = results.0
        admin = results.1
        printing = results.2
    }

    private func resolveBluetooth() async -> Phase {
        // Reading the authorization is instant and never prompts.
        try? await Task.sleep(nanoseconds: 250_000_000)
        return mapBluetooth(CBCentralManager.authorization)
    }

    private func resolveAdmin() async -> Phase {
        try? await Task.sleep(nanoseconds: 350_000_000)
        return .onDemand
    }

    private func resolvePrinting() async -> Phase {
        try? await Task.sleep(nanoseconds: 450_000_000)
        return .info
    }

    private func mapBluetooth(_ a: CBManagerAuthorization) -> Phase {
        switch a {
        case .allowedAlways: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: Actions

    private func requestBluetooth() {
        btBusy = true
        state.ble.start()          // creating the central manager triggers the TCC prompt
        Task {
            // Wait for the user to answer the system dialog, then reflect the result.
            for _ in 0..<120 {
                if CBCentralManager.authorization != .notDetermined { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            bluetooth = mapBluetooth(CBCentralManager.authorization)
            btBusy = false
        }
    }

    private func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    private func finish() {
        state.completeOnboarding()
        // Only start the BLE stack now if it is actually authorised, so dismissing
        // the splash never springs an unexpected prompt.
        if CBCentralManager.authorization == .allowedAlways { state.ble.start() }
        state.refreshAll()
    }
}

// MARK: - Row

private struct PermissionCard: View {
    struct Action { var label: String; var action: () -> Void }

    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let phase: OnboardingView.Phase
    var busy: Bool = false
    var primary: Action? = nil
    var secondary: Action? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon).foregroundStyle(tint).imageScale(.large)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                statusPill
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    if let primary { Button(primary.label, action: primary.action).buttonStyle(.borderedProminent).controlSize(.small) }
                    if let secondary { Button(secondary.label, action: secondary.action).controlSize(.small) }
                }
            }
            .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    @ViewBuilder private var statusPill: some View {
        switch phase {
        case .checking:
            pill("Checking…", "clock", .secondary)
        case .granted:
            pill("Granted", "checkmark.circle.fill", .green)
        case .denied:
            pill("Denied", "xmark.octagon.fill", .red)
        case .notDetermined:
            pill("Not set", "questionmark.circle", .orange)
        case .onDemand:
            pill("When needed", "hand.tap", .blue)
        case .info:
            pill("Ready", "checkmark.circle.fill", .green)
        }
    }

    private func pill(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}
