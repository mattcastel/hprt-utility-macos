//
//  Panels_Hardware.swift
//  HPRT Utility
//

import SwiftUI
import AppKit
import CoreBluetooth

struct PrinterPanel: View {
    @EnvironmentObject private var state: AppState
    @State private var showAllUSB = false

    var body: some View {
        PanelScaffold(title: "Printer",
                      subtitle: "How this Mac reaches the machine — wired, wireless, or not at all.") {

            linkSummary

            hardwareInfoCard

            Card(title: "USB", systemImage: "cable.connector") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.usbChecks) { check in
                        CheckRow(check: check) { state.apply($0) }
                    }
                }
            }

            Card(title: "USB bus",
                 subtitle: showAllUSB ? "Every device currently enumerated" : "HPRT devices only",
                 systemImage: "list.bullet.indent",
                 accessory: AnyView(
                    Toggle("Show all", isOn: $showAllUSB)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                 )) {
                let devices = showAllUSB ? state.usb.allDevices : state.usb.devices
                if devices.isEmpty {
                    EmptyHint(symbol: "cable.connector.slash",
                              title: "Nothing on the bus",
                              message: "Check the cable carries data, not just power, and that the printer is awake.")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(devices) { device in
                            usbRow(device)
                            if device.id != devices.last?.id { Divider().opacity(0.4) }
                        }
                    }
                }
            }

            btClassicCard

            Card(title: "HPRT Bluetooth bridge",
                 subtitle: "HPRT's helper app is a TCP relay, not a real Bluetooth backend",
                 systemImage: "app.connected.to.app.below.fill") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.bridgeChecks) { check in
                        CheckRow(check: check) { state.apply($0) }
                    }
                    Divider().opacity(0.4)
                    Text("""
                    A Bluetooth queue created by HPRT's tool points at socket://127.0.0.1:\(state.bridge.port). \
                    CUPS therefore talks to the helper application, which relays to the printer over BLE. \
                    If the helper is not running, jobs are accepted and then silently lost.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            BluetoothExplorer()
        }
    }

    private var linkSummary: some View {
        HStack(spacing: 14) {
            linkTile(title: "USB",
                     symbol: "cable.connector",
                     active: !state.usb.devices.isEmpty,
                     detail: state.usb.devices.first.map { "\($0.displayName) · \($0.speed)" } ?? "Not connected")

            linkTile(title: "Bluetooth",
                     symbol: "dot.radiowaves.left.and.right",
                     active: state.btPrinterConnected || state.bridge.portOpen,
                     detail: btDetail)

            linkTile(title: "Active path",
                     symbol: "arrow.triangle.branch",
                     active: state.selectedQueue != nil,
                     detail: state.selectedQueue?.transport.rawValue ?? "No queue")
        }
    }

    private var btDetail: String {
        if let p = state.btClassic.first(where: { $0.isPrinter && $0.connected }) {
            return "\(p.name) · classic / SPP"
        }
        if state.bridge.portOpen { return "HPRT bridge · port \(state.bridge.port)" }
        if let p = state.btClassic.first(where: \.isPrinter) { return "\(p.name) · paired, link down" }
        return "Not connected"
    }

    private func linkTile(title: String, symbol: String, active: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(active ? Color.green : Color.secondary)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Circle()
                    .fill(active ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Color.green.opacity(0.35) : Color.primary.opacity(0.07))
        )
    }

    private func usbRow(_ device: USBDeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(device.displayName)
                    .font(.callout.weight(.medium))
                if device.isPrinterClass {
                    StatusChip(status: .ok, text: "Printer class")
                }
                Spacer()
                Text(device.idPair)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label(device.locationID, systemImage: "location")
                Label(device.speed, systemImage: "speedometer")
                if let serial = device.serial {
                    Label(serial, systemImage: "number")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Hardware & Battery Info

    private var hardwareInfoCard: some View {
        let info = state.deviceInfo.hasData ? state.deviceInfo : state.ble.deviceInfo
        let battery = info.batteryLevel
        let voltage = info.batteryVoltage
        let fw = info.firmwareVersion
        let serial = info.serialNumber ?? state.usb.devices.first?.serial
        let model = info.modelName ?? state.cupsDevices.first?.firstMatch("usb://[^/]+/([^?]+)") ?? "MT8003"

        return Card(
            title: "Hardware & Battery Status",
            subtitle: "Firmware parameters and battery level (queried via HPRT V2 & GATT)",
            systemImage: batterySymbol(level: battery),
            accessory: AnyView(
                Button {
                    state.queryDeviceInfoNow()
                } label: {
                    Label("Query Now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    metricTile(
                        title: "Battery Level",
                        value: battery.map { "\($0)%" } ?? "Not queried",
                        detail: voltage ?? "Connect via BT / USB to query",
                        color: batteryColor(level: battery),
                        icon: batterySymbol(level: battery)
                    )

                    metricTile(
                        title: "Firmware Version",
                        value: fw ?? "—",
                        detail: info.secondaryFirmwareVersion.map { "Secondary: \($0)" } ?? (fw != nil ? "Official HPRT firmware" : "Query device to read"),
                        color: fw != nil ? .green : .secondary,
                        icon: "cpu"
                    )

                    metricTile(
                        title: "Printer Model",
                        value: model,
                        detail: info.protocolVersion.map { "Protocol \($0)" } ?? "HPRT MT800 series",
                        color: .blue,
                        icon: "printer.fill"
                    )

                    metricTile(
                        title: "Serial Number",
                        value: serial ?? "—",
                        detail: "Hardware controller ID",
                        color: serial != nil ? .primary : .secondary,
                        icon: "barcode"
                    )
                }

                if let date = info.lastUpdated {
                    HStack {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Last queried: \(date.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func metricTile(title: String, value: String, detail: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(color == .secondary ? Color.secondary : Color.primary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private func batterySymbol(level: Int?) -> String {
        guard let level else { return "battery.0" }
        if level >= 90 { return "battery.100" }
        if level >= 70 { return "battery.75" }
        if level >= 40 { return "battery.50" }
        if level >= 15 { return "battery.25" }
        return "battery.0"
    }

    private func batteryColor(level: Int?) -> Color {
        guard let level else { return .secondary }
        if level > 50 { return .green }
        if level > 20 { return .orange }
        return .red
    }

    // MARK: Classic Bluetooth (SPP)

    private var btPrinters: [BTClassicDevice] { state.btClassic.filter(\.isPrinter) }

    private var connectedBTPrinter: BTClassicDevice? {
        state.btClassic.first { $0.isPrinter && $0.connected } ?? btPrinters.first
    }

    /// Model string used both to name the queue and to pick the PPD.
    private var btQueueModel: String {
        if let m = state.cupsDevices.first?.firstMatch("usb://[^/]+/([^?]+)") { return m }
        if let m = state.selectedQueue?.name { return m }
        return connectedBTPrinter?.name.firstMatch(Paths.modelPattern) ?? "MT8003"
    }

    @ViewBuilder
    private var btClassicCard: some View {
        Card(title: "Bluetooth (classic / SPP)",
             subtitle: "How the MT800 actually connects — RFCOMM serial, not BLE",
             systemImage: "printer.dotmatrix") {
            if btPrinters.isEmpty {
                EmptyHint(symbol: "dot.radiowaves.right",
                          title: "No classic-Bluetooth printer paired",
                          message: "Pair the MT800 in System Settings › Bluetooth. It appears as a printer and as a /dev/cu.* serial port, which this panel then picks up.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(btPrinters) { device in
                        btDeviceRow(device)
                        if device.id != btPrinters.last?.id { Divider().opacity(0.4) }
                    }
                    Divider().opacity(0.4)
                    Text("""
                    macOS ships a native bluetooth CUPS backend that speaks RFCOMM directly. HPRT ignores it \
                    and routes Bluetooth through a local TCP relay (Driver BT Tool) instead. Creating a queue on \
                    the bluetooth:// URI above prints over Bluetooth with no helper app to keep alive.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func btDeviceRow(_ device: BTClassicDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "printer.dotmatrix").foregroundStyle(.secondary)
                Text(device.name).font(.callout.weight(.medium))
                StatusChip(status: device.connected ? .ok : .warning,
                           text: device.connected ? "Connected" : "Paired")
                Spacer()
                if let rssi = device.rssi {
                    Text("\(rssi) dBm")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if !device.address.isEmpty { KeyValueRow(key: "Address", value: device.address) }
            if let port = device.primarySerialPort { KeyValueRow(key: "Serial port", value: port) }
            if !device.cupsBluetoothURI.isEmpty { KeyValueRow(key: "Native CUPS URI", value: device.cupsBluetoothURI) }

            if device.connected && !device.cupsBluetoothURI.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        let model = btQueueModel
                        let queue = "\(model)_BT".replacingOccurrences(of: " ", with: "_")
                        state.apply(.createBluetoothQueue(queue: queue,
                                                          uri: device.cupsBluetoothURI,
                                                          model: model))
                    } label: {
                        Label("Create Bluetooth queue", systemImage: "plus.rectangle.on.folder")
                    }
                    .buttonStyle(.borderedProminent)

                    if !state.driver.installed {
                        Text("Install the driver first so the queue gets the HPRT PPD; otherwise it is created raw.")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Bluetooth / GATT explorer

struct BluetoothExplorer: View {
    @EnvironmentObject private var state: AppState
    @State private var scanEverything = false

    var body: some View {
        Card(title: "Bluetooth LE explorer",
             subtitle: "Where a real battery percentage would have to come from",
             systemImage: "antenna.radiowaves.left.and.right") {

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.ble.checks) { check in
                        CheckRow(check: check)
                    }
                }

                Divider().opacity(0.4)

                HStack(spacing: 10) {
                    Button {
                        if state.ble.isScanning {
                            state.ble.stopScan()
                        } else {
                            state.ble.scan(includeEverything: scanEverything)
                        }
                    } label: {
                        Label(state.ble.isScanning ? "Stop scan" : "Scan",
                              systemImage: state.ble.isScanning ? "stop.circle" : "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)

                    Toggle("Include every peripheral", isOn: $scanEverything)
                        .toggleStyle(.checkbox)

                    Spacer()

                    if state.ble.connectedName != nil {
                        Button("Disconnect") { state.ble.disconnect() }
                    }
                }

                if state.ble.peripherals.isEmpty {
                    EmptyHint(symbol: "wave.3.right",
                              title: "No peripherals yet",
                              message: "A BLE device accepts one central at a time. If your phone is connected to the printer, disconnect it there first.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.ble.peripherals) { peripheral in
                            HStack(spacing: 10) {
                                Image(systemName: "printer.dotmatrix")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(peripheral.name).font(.callout.weight(.medium))
                                    Text(peripheral.advertisedServices.isEmpty
                                         ? peripheral.id.uuidString
                                         : peripheral.advertisedServices.joined(separator: ", "))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("\(peripheral.rssi) dBm")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Button("Connect") { state.ble.connect(peripheral) }
                                    .disabled(!peripheral.connectable)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                if !state.ble.characteristics.isEmpty {
                    Divider().opacity(0.4)
                    Text("GATT table — \(state.ble.connectedName ?? "connected device")")
                        .font(.subheadline.weight(.semibold))

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(state.ble.characteristics) { characteristic in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(characteristic.uuid)
                                        .font(.system(size: 11, design: .monospaced).weight(.medium))
                                    Text(characteristic.properties.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let interpretation = characteristic.interpretation {
                                        StatusChip(status: .ok, text: interpretation)
                                    }
                                    Spacer()
                                    Text(BLEProbe.describe(characteristic.serviceUUID))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let value = characteristic.value {
                                    Text(value)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !state.ble.activityLog.isEmpty {
                    DisclosureGroup("Bluetooth activity") {
                        MonoLog(lines: Array(state.ble.activityLog.prefix(60)), maxHeight: 160)
                    }
                    .font(.callout)
                }
            }
        }
        .onAppear { state.ble.start() }
    }
}
