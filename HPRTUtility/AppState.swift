//
//  AppState.swift
//  HPRT Utility
//

import Foundation
import SwiftUI
import Combine

enum Panel: String, CaseIterable, Identifiable {
    case overview, printer, driver, queue, printing, raster, console, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .printer:  return "Printer"
        case .driver:   return "Driver"
        case .queue:    return "Print Queue"
        case .printing: return "Print"
        case .raster:   return "Raster Lab"
        case .console:  return "ESC/POS Console"
        case .logs:     return "CUPS Log"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.bottom.50percent"
        case .printer:  return "cable.connector"
        case .driver:   return "shippingbox"
        case .queue:    return "list.bullet.rectangle"
        case .printing: return "printer"
        case .raster:   return "square.grid.3x3.topleft.filled"
        case .console:  return "terminal"
        case .logs:     return "doc.text.magnifyingglass"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Health at a glance"
        case .printer:  return "USB & Bluetooth link"
        case .driver:   return "PPD, filters, Rosetta"
        case .queue:    return "CUPS state & options"
        case .printing: return "Send a document"
        case .raster:   return "What CUPS actually renders"
        case .console:  return "Raw commands"
        case .logs:     return "Live diagnostics"
        }
    }
}

@MainActor
final class AppState: ObservableObject {

    // Snapshots
    @Published var system = SystemInfo()
    @Published var driver = DriverInfo()
    @Published var queues: [QueueInfo] = []
    @Published var bridge = BridgeInfo()
    @Published var btClassic: [BTClassicDevice] = []
    @Published var cupsDevices: [String] = []

    // Live probes. They are ObservableObjects in their own right, so their
    // change notifications are forwarded here — otherwise SwiftUI would never
    // see a USB device appear or a GATT table fill in.
    let usb = USBProbe()
    let ble = BLEProbe()
    @Published var deviceInfo = HPRTDeviceInfo()
    private var forwarders: [AnyCancellable] = []

    // UI state
    @Published var selection: Panel? = .overview
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?
    @Published var activity: [ActivityEntry] = []
    @Published var jobs: [PrintJobRecord] = []

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let date = Date()
        var message: String
        var status: CheckStatus
    }

    var selectedQueue: QueueInfo? { queues.first }

    init() {
        forwarders = [
            usb.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            ble.objectWillChange.sink { [weak self] _ in
                guard let self else { return }
                self.deviceInfo.merge(with: self.ble.deviceInfo)
                self.objectWillChange.send()
            }
        ]
    }

    // MARK: Aggregated checks

    var systemChecks: [Check] { SystemProbe.checks(system) }
    var driverChecks: [Check] { DriverInspector.checks(driver, system: system) }
    var hardwareChecks: [Check] {
        var out: [Check] = []
        let effective = deviceInfo.hasData ? deviceInfo : ble.deviceInfo

        if let bat = effective.batteryLevel {
            let volt = effective.batteryVoltage.map { " (\($0))" } ?? ""
            let status: CheckStatus = bat > 20 ? .ok : .warning
            out.append(Check(title: "Battery level",
                             value: "\(bat)%\(volt)",
                             detail: bat > 20 ? "Sufficient charge for portable operation." : "Battery is low (< 20%). Connect USB charger.",
                             status: status))
        }

        if let fw = effective.firmwareVersion {
            let sec = effective.secondaryFirmwareVersion.map { " · Sec: \($0)" } ?? ""
            let proto = effective.protocolVersion.map { " · Protocol \($0)" } ?? ""
            out.append(Check(title: "Firmware version",
                             value: "\(fw)\(sec)",
                             detail: "Printer firmware reported by device\(proto).",
                             status: .ok))
        }

        if let sn = effective.serialNumber {
            out.append(Check(title: "Serial number",
                             value: sn,
                             detail: "Hardware serial number from printer controller.",
                             status: .ok))
        }

        return out
    }
    var usbChecks: [Check] { USBProbe.checks(devices: usb.devices, cupsDevices: cupsDevices) }
    var queueChecks: [Check] { CupsService.checks(queues, usb: usb.devices, driverInstalled: driver.installed) }
    var bridgeChecks: [Check] { BridgeProbe.checks(bridge, queueTransport: selectedQueue?.transport) }
    var btClassicChecks: [Check] { BluetoothClassicProbe.checks(btClassic, queueTransport: selectedQueue?.transport) }
    var bleChecks: [Check] { ble.checks }

    /// A printer paired *and* linked over classic Bluetooth right now.
    var btPrinterConnected: Bool { btClassic.contains { $0.isPrinter && $0.connected } }

    var allChecks: [Check] {
        systemChecks + driverChecks + hardwareChecks + usbChecks + queueChecks + btClassicChecks + bridgeChecks
    }

    /// The single sentence shown at the top of the Overview panel.
    var headline: (CheckStatus, String, String) {
        let worst = allChecks.map(\.status).max(by: { $0.severity < $1.severity }) ?? .unknown

        if usb.devices.isEmpty && !bridge.portOpen && !btPrinterConnected {
            return (.failure, "Printer not reachable",
                    "Nothing on USB, no classic-Bluetooth link, and the HPRT bridge is closed.")
        }
        if !driver.installed {
            return (.failure, "Driver not installed",
                    "The printer is present but no HPRT driver is in place, so there is no print path.")
        }
        if queues.isEmpty {
            return (.failure, "No print queue",
                    "The driver is installed but nothing uses it yet.")
        }
        guard let queue = selectedQueue else {
            return (.warning, "Incomplete setup", "Review the checks below.")
        }
        if !queue.enabled || !queue.accepting {
            return (.failure, "Queue is halted", queue.stateMessage)
        }
        if queue.transport == .bluetoothBridge && !bridge.portOpen {
            return (.failure, "Bluetooth bridge is down",
                    "The queue points at 127.0.0.1:\(bridge.port) but nothing is listening there.")
        }
        if queue.transport == .usb && usb.devices.isEmpty && btPrinterConnected {
            return (.warning, "Printer on Bluetooth, queue on USB",
                    "\(queue.name) prints over USB, but the printer is linked over Bluetooth right now. Create a Bluetooth queue from the Printer panel.")
        }
        if worst == .warning {
            return (.warning, "Ready, with reservations",
                    "The print path is complete. The warnings below are worth knowing about.")
        }
        return (.ok, "Ready to print",
                "\(queue.name) over \(queue.transport.rawValue), density \(queue.option("PrintDensity")?.current ?? "—").")
    }

    // MARK: Refresh

    func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let system = SystemProbe.snapshot()
            let driver = DriverInspector.snapshot()
            let queues = CupsService.hprtQueues()
            let bridge = BridgeProbe.snapshot()
            let btClassic = BluetoothClassicProbe.snapshot()
            let devices = CupsService.discoveredDevices()
            let serialPorts = BluetoothClassicProbe.serialPorts()
            let queryInfo = DeviceQueryService.queryAll(
                serialPorts: serialPorts,
                bridgeOpen: bridge.portOpen,
                cupsURI: devices.first(where: { $0.contains("MT800") || $0.contains("HPRT") })
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.system = system
                self.driver = driver
                self.queues = queues
                self.bridge = bridge
                self.btClassic = btClassic
                self.cupsDevices = devices
                self.deviceInfo.merge(with: queryInfo)
                self.deviceInfo.merge(with: self.ble.deviceInfo)
                self.usb.refresh()
                self.lastRefresh = Date()
                self.isRefreshing = false
            }
        }
    }

    func queryDeviceInfoNow() {
        log("Querying printer parameters (battery, voltage, firmware)…", .pending)
        Task.detached(priority: .userInitiated) { [weak self] in
            let serialPorts = BluetoothClassicProbe.serialPorts()
            let bridge = BridgeProbe.snapshot()
            let devices = CupsService.discoveredDevices()
            let queryInfo = DeviceQueryService.queryAll(
                serialPorts: serialPorts,
                bridgeOpen: bridge.portOpen,
                cupsURI: devices.first(where: { $0.contains("MT800") || $0.contains("HPRT") })
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.deviceInfo.merge(with: queryInfo)
                self.deviceInfo.merge(with: self.ble.deviceInfo)
                if let b = self.deviceInfo.batteryLevel {
                    self.log("Device queried: Battery \(b)%, Firmware \(self.deviceInfo.firmwareVersion ?? "—")", .ok)
                } else if self.deviceInfo.firmwareVersion != nil || self.deviceInfo.serialNumber != nil {
                    self.log("Device queried: Firmware \(self.deviceInfo.firmwareVersion ?? "—"), Serial \(self.deviceInfo.serialNumber ?? "—")", .ok)
                } else {
                    self.log("Query sent. Make sure the printer is on and connected via Bluetooth or USB.", .unknown)
                }
            }
        }
    }

    func log(_ message: String, _ status: CheckStatus = .unknown) {
        activity.insert(ActivityEntry(message: message, status: status), at: 0)
        if activity.count > 300 { activity.removeLast() }
    }

    // MARK: Remedies

    func apply(_ remedy: Remedy) {
        log("Running: \(remedy.title)", .pending)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CupsService.apply(remedy)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if result.ok {
                    self.log("\(remedy.title) succeeded. \(result.out)", .ok)
                } else {
                    self.log("\(remedy.title) failed: \(result.err)", .failure)
                }
                self.refreshAll()
            }
        }
    }

    // MARK: Report

    func markdownReport() -> String {
        var out = "# HPRT Utility — diagnostic report\n\n"
        out += "Generated \(ISO8601DateFormatter().string(from: Date())) on \(system.hostName)\n\n"

        func section(_ title: String, _ checks: [Check]) {
            out += "## \(title)\n\n| Status | Check | Value |\n|---|---|---|\n"
            for c in checks {
                out += "| \(c.status.label) | \(c.title) | \(c.value) |\n"
            }
            out += "\n"
            for c in checks where c.detail != nil {
                out += "- **\(c.title)** — \(c.detail!)\n"
            }
            out += "\n"
        }

        let (status, title, detail) = headline
        out += "**\(status.label): \(title)** — \(detail)\n\n"

        section("System", systemChecks)
        section("Driver", driverChecks)
        section("USB", usbChecks)
        section("Print queue", queueChecks)
        section("Bluetooth bridge", bridgeChecks)

        if let queue = selectedQueue, !queue.options.isEmpty {
            out += "## PPD options\n\n| Keyword | Current | Choices |\n|---|---|---|\n"
            for option in queue.options {
                out += "| \(option.keyword) | \(option.current) | \(option.choices.joined(separator: " ")) |\n"
            }
            out += "\n"
        }

        if !usb.allDevices.isEmpty {
            out += "## USB bus\n\n"
            for device in usb.allDevices {
                out += "- \(device.vendorName) \(device.productName) — \(device.idPair) @ \(device.locationID)\n"
            }
            out += "\n"
        }
        return out
    }
}
