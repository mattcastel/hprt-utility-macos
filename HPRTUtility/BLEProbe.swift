//
//  BLEProbe.swift
//  HPRT Utility
//
//  CoreBluetooth scanner and GATT explorer with bidirectional HPRT protocol support.
//

import Foundation
import CoreBluetooth

struct DiscoveredPeripheral: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var advertisedServices: [String]
    var connectable: Bool
    var lastSeen: Date
}

struct GATTCharacteristic: Identifiable, Hashable {
    var id: String { serviceUUID + "/" + uuid }
    var serviceUUID: String
    var uuid: String
    var properties: [String]
    var value: String?
    var interpretation: String?
}

final class BLEProbe: NSObject, ObservableObject {

    static let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "FFE0"),
        CBUUID(string: "FF00"),
        CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"),
        CBUUID(string: "779856e9-52cd-11ef-975a-043f72a0b6f2"),
        CBUUID(string: "180F"),  // standard Battery Service
        CBUUID(string: "180A")   // standard Device Information
    ]

    static let serviceDescriptions: [String: String] = [
        "FFE0": "Generic BLE UART (HM-10 style)",
        "FF00": "Vendor serial service",
        "180F": "Battery Service (standard)",
        "180A": "Device Information (standard)",
        "49535343-FE7D-4AE5-8FA9-9FAFD205E455": "Microchip / ISSC transparent UART",
        "779856E9-52CD-11EF-975A-043F72A0B6F2": "HPRT proprietary job protocol"
    ]

    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var peripherals: [DiscoveredPeripheral] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var characteristics: [GATTCharacteristic] = []
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var deviceInfo = HPRTDeviceInfo()
    @Published private(set) var lastError: String?
    @Published private(set) var activityLog: [String] = []

    private var central: CBCentralManager?
    private var connected: CBPeripheral?
    private var handles: [UUID: CBPeripheral] = [:]
    private var writeCharacteristic: CBCharacteristic?

    var stateDescription: String {
        switch state {
        case .poweredOn: return "Powered on"
        case .poweredOff: return "Powered off"
        case .unauthorized: return "Not authorised — grant Bluetooth access in System Settings › Privacy & Security"
        case .unsupported: return "Unsupported on this Mac"
        case .resetting: return "Resetting"
        default: return "Unknown"
        }
    }

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func scan(includeEverything: Bool = false) {
        guard let central, central.state == .poweredOn else {
            lastError = "Bluetooth is not ready (\(stateDescription))."
            return
        }
        peripherals.removeAll()
        note("Scanning\(includeEverything ? " (all peripherals)" : " for known HPRT services")…")
        central.scanForPeripherals(
            withServices: includeEverything ? nil : Self.knownServiceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }

    func stopScan() {
        central?.stopScan()
        isScanning = false
        note("Scan stopped.")
    }

    func connect(_ item: DiscoveredPeripheral) {
        guard let central, let peripheral = handles[item.id] else { return }
        characteristics.removeAll()
        batteryLevel = nil
        deviceInfo = HPRTDeviceInfo()
        writeCharacteristic = nil
        note("Connecting to \(item.name)…")
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let central, let connected else { return }
        central.cancelPeripheralConnection(connected)
    }

    /// Sends query packets over the active BLE write pipe
    func sendQueryPackets() {
        guard let connected, let writeCharacteristic else { return }
        note("Sending HPRT V2 info and battery query packets…")
        let queries = [
            HPRTProtocol.probeProtocolVersion,
            HPRTProtocol.queryBatteryPacket(pkgId: 1),
            HPRTProtocol.queryFirmwareVersionPacket(pkgId: 2),
            HPRTProtocol.queryVoltagePacket(pkgId: 3),
            HPRTProtocol.querySerialNumberPacket(pkgId: 4),
            HPRTProtocol.queryModelNamePacket(pkgId: 5),
            HPRTProtocol.escposGetVersion
        ]

        for (idx, query) in queries.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.15) { [weak self] in
                let type: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
                connected.writeValue(query, for: writeCharacteristic, type: type)
                self?.note("Sent query #\(idx + 1) (\(query.count) bytes)")
            }
        }
    }

    private func note(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        activityLog.insert("[\(stamp)] \(message)", at: 0)
        if activityLog.count > 200 { activityLog.removeLast() }
    }

    static func describe(_ uuidString: String) -> String {
        serviceDescriptions[uuidString.uppercased()] ?? "Unknown service"
    }

    var checks: [Check] {
        var out: [Check] = []
        switch state {
        case .poweredOn: out.append(.ok("Bluetooth", "Powered on"))
        case .unauthorized:
            out.append(.fail("Bluetooth", "Not authorised",
                             "Allow HPRT Utility to use Bluetooth in System Settings › Privacy & Security › Bluetooth."))
        case .poweredOff: out.append(.warn("Bluetooth", "Powered off"))
        default: out.append(.info("Bluetooth", stateDescription))
        }

        if peripherals.isEmpty {
            out.append(.info("HPRT peripherals", "None seen",
                             "Normal if the printer is off, already connected to a phone, or only used over USB. A BLE peripheral accepts one central at a time."))
        } else {
            out.append(.ok("HPRT peripherals", "\(peripherals.count) found"))
        }

        let effectiveBattery = deviceInfo.batteryLevel ?? batteryLevel
        if let effectiveBattery {
            let voltStr = deviceInfo.batteryVoltage.map { " (\($0))" } ?? ""
            let status: CheckStatus = effectiveBattery > 20 ? .ok : .warning
            out.append(Check(title: "Battery level",
                             value: "\(effectiveBattery)%\(voltStr)",
                             detail: effectiveBattery > 20 ? "Battery charge is sufficient for mobile printing." : "Battery is low. Connect USB power.",
                             status: status))
        } else {
            out.append(.info("Battery level", "Not queried yet",
                             "Connect over BLE or USB to read the battery level and voltage from the firmware."))
        }

        if let fw = deviceInfo.firmwareVersion {
            out.append(.ok("Printer firmware", fw, deviceInfo.secondaryFirmwareVersion.map { "Sec: \($0)" }))
        }

        return out
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEProbe: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        note("Bluetooth state: \(stateDescription)")
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {

        handles[peripheral.identifier] = peripheral
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString } ?? []
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unnamed"

        let entry = DiscoveredPeripheral(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            advertisedServices: advertised,
            connectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true,
            lastSeen: Date())

        if let index = peripherals.firstIndex(where: { $0.id == entry.id }) {
            peripherals[index] = entry
        } else {
            peripherals.append(entry)
            note("Found \(name) (RSSI \(RSSI.intValue))")
        }
        peripherals.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = peripheral
        connectedName = peripheral.name ?? "Unnamed"
        peripheral.delegate = self
        note("Connected. Discovering services…")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastError = error?.localizedDescription ?? "Connection failed"
        note("Connection failed: \(lastError ?? "")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = nil
        connectedName = nil
        writeCharacteristic = nil
        note("Disconnected.")
    }
}

// MARK: - CBPeripheralDelegate

extension BLEProbe: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        note("\(services.count) service(s) found.")
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let list = service.characteristics else { return }
        for characteristic in list {
            characteristics.append(GATTCharacteristic(
                serviceUUID: service.uuid.uuidString,
                uuid: characteristic.uuid.uuidString,
                properties: Self.propertyNames(characteristic.properties),
                value: nil,
                interpretation: Self.interpretation(for: characteristic)))

            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }

            // Enable notifications on UART / HPRT data characteristics
            let uuid = characteristic.uuid.uuidString.uppercased()
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
                note("Subscribed to notifications on \(uuid).")
            }

            // Check for potential write pipe
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                if uuid.contains("7798") || uuid == "FFE1" || uuid == "FF01" || uuid.contains("4953") {
                    writeCharacteristic = characteristic
                    note("Selected \(uuid) as active query pipe.")
                } else if writeCharacteristic == nil {
                    writeCharacteristic = characteristic
                }
            }
        }
        characteristics.sort { $0.id < $1.id }

        // If a write pipe is ready, trigger query sequence after discovery
        if writeCharacteristic != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.sendQueryPackets()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ascii = String(decoding: data.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
        let rendered = ascii.count >= 3 ? "\(hex)   “\(ascii)”" : hex

        if let index = characteristics.firstIndex(where: {
            $0.serviceUUID == characteristic.service?.uuid.uuidString
                && $0.uuid == characteristic.uuid.uuidString }) {
            characteristics[index].value = rendered
        }

        // Standard Battery Service (0x2A19)
        if characteristic.uuid == CBUUID(string: "2A19"), let first = data.first {
            batteryLevel = Int(first)
            deviceInfo.batteryLevel = Int(first)
            deviceInfo.lastUpdated = Date()
            note("Standard Battery Service reports \(first)%.")
        }

        // Standard Firmware Revision (0x2A26)
        if characteristic.uuid == CBUUID(string: "2A26") {
            let str = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
            if !str.isEmpty {
                deviceInfo.firmwareVersion = str
                deviceInfo.lastUpdated = Date()
                note("Standard Device Info reports Firmware: \(str)")
            }
        }

        // Standard Model Number (0x2A24)
        if characteristic.uuid == CBUUID(string: "2A24") {
            let str = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
            if !str.isEmpty {
                deviceInfo.modelName = str
                deviceInfo.lastUpdated = Date()
                note("Standard Device Info reports Model: \(str)")
            }
        }

        // Standard Serial Number (0x2A25)
        if characteristic.uuid == CBUUID(string: "2A25") {
            let str = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
            if !str.isEmpty {
                deviceInfo.serialNumber = str
                deviceInfo.lastUpdated = Date()
                note("Standard Device Info reports Serial: \(str)")
            }
        }

        // Software Revision (0x2A28)
        if characteristic.uuid == CBUUID(string: "2A28") {
            let str = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
            if !str.isEmpty {
                deviceInfo.secondaryFirmwareVersion = str
                deviceInfo.lastUpdated = Date()
            }
        }

        // HPRT V2 & text response parsing from UART / Custom characteristics
        HPRTProtocol.parseIncomingData(data, into: &deviceInfo)
        if let b = deviceInfo.batteryLevel {
            batteryLevel = b
        }
    }

    private static func propertyNames(_ properties: CBCharacteristicProperties) -> [String] {
        var names: [String] = []
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.writeWithoutResponse) { names.append("writeNR") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        return names
    }

    private static func interpretation(for characteristic: CBCharacteristic) -> String? {
        switch characteristic.uuid.uuidString.uppercased() {
        case "2A19": return "Battery level (0–100%)"
        case "2A24": return "Model number"
        case "2A26": return "Firmware revision"
        case "2A25": return "Serial number"
        case "2A28": return "Software revision"
        case "2A27": return "Hardware revision"
        case "FFE1": return "UART data pipe"
        case "7798BF36-52CD-11EF-975A-043F72A0B6F2": return "HPRT V2 data pipe"
        default: return nil
        }
    }
}
