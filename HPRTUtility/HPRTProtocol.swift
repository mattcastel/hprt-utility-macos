//
//  HPRTProtocol.swift
//  HPRT Utility
//
//  Encapsulation of the HPRT V2 Framing Protocol and ESC/POS queries
//  extracted from HPRT macOS binaries and firmware SDK.
//

import Foundation

public struct HPRTDeviceInfo: Hashable, Codable {
    public var batteryLevel: Int?               // 0 - 100 % (from bat_ratio)
    public var batteryVoltage: String?          // e.g. "7.4 V" or "7400 mV" (from power_voltage)
    public var firmwareVersion: String?         // e.g. "1.0.6" (from printer_version)
    public var secondaryFirmwareVersion: String?// e.g. "1.0.1" (from printer_second_version)
    public var modelName: String?               // e.g. "MT8003" (from printer_model)
    public var serialNumber: String?            // e.g. "MT80021071201..." (from serial_no)
    public var protocolVersion: String?         // e.g. "V2" (from hp_protocol_version)
    public var statusDescription: String?       // e.g. "Ready" / "Normal" (from device_status / work_status)
    public var lastUpdated: Date?

    public init(
        batteryLevel: Int? = nil,
        batteryVoltage: String? = nil,
        firmwareVersion: String? = nil,
        secondaryFirmwareVersion: String? = nil,
        modelName: String? = nil,
        serialNumber: String? = nil,
        protocolVersion: String? = nil,
        statusDescription: String? = nil,
        lastUpdated: Date? = nil
    ) {
        self.batteryLevel = batteryLevel
        self.batteryVoltage = batteryVoltage
        self.firmwareVersion = firmwareVersion
        self.secondaryFirmwareVersion = secondaryFirmwareVersion
        self.modelName = modelName
        self.serialNumber = serialNumber
        self.protocolVersion = protocolVersion
        self.statusDescription = statusDescription
        self.lastUpdated = lastUpdated
    }

    public var hasData: Bool {
        batteryLevel != nil || firmwareVersion != nil || serialNumber != nil || modelName != nil || batteryVoltage != nil
    }

    public mutating func merge(with other: HPRTDeviceInfo) {
        if let b = other.batteryLevel { self.batteryLevel = b }
        if let v = other.batteryVoltage { self.batteryVoltage = v }
        if let f = other.firmwareVersion { self.firmwareVersion = f }
        if let sf = other.secondaryFirmwareVersion { self.secondaryFirmwareVersion = sf }
        if let m = other.modelName { self.modelName = m }
        if let s = other.serialNumber { self.serialNumber = s }
        if let p = other.protocolVersion { self.protocolVersion = p }
        if let st = other.statusDescription { self.statusDescription = st }
        if other.lastUpdated != nil { self.lastUpdated = other.lastUpdated }
    }
}

public enum HPRTProtocol {

    // MARK: - Constants & Magic bytes

    /// Magic prefix for HPRT V2 Protocol packets: 0x1B 0x1C 0x26 0x20 0x56 0x32 ("\x1b\x1c& V2")
    public static let v2Magic = Data([0x1B, 0x1C, 0x26, 0x20, 0x56, 0x32])
    
    /// Probe protocol version command: "\x1b\x1c& V?\r\n"
    public static let probeProtocolVersion = Data([0x1B, 0x1C, 0x26, 0x20, 0x56, 0x3F, 0x0D, 0x0A])

    /// Standard and Extended ESC/POS version queries
    public static let escposGetVersion = "ZZZGETVERSION\r\n".data(using: .utf8)!
    public static let escposTransmitPrinterIdFirmware = Data([0x1D, 0x49, 0x43]) // GS I 67 ('C')
    public static let escposTransmitPrinterIdModel = Data([0x1D, 0x49, 0x41])    // GS I 65 ('A')
    public static let escposRealtimeStatus = Data([0x10, 0x04, 0x01])            // DLE EOT 1
    public static let escposPaperStatus = Data([0x10, 0x04, 0x04])               // DLE EOT 4

    // MARK: - V2 Packet Framing

    /// Builds a full 18-byte header HPRT V2 packet with checksum
    ///
    /// Header layout (18 bytes):
    /// - 0..5   (6 bytes): Magic "\x1b\x1c& V2"
    /// - 6      (1 byte) : CmdType (1 = getval, 2 = setval, 3 = handshake, etc.)
    /// - 7      (1 byte) : HandshakeId (high nibble) | SubId (low nibble)
    /// - 8      (1 byte) : PackageId (sequence counter)
    /// - 9..10  (2 bytes): Data Length (little-endian UInt16)
    /// - 11     (1 byte) : CheckType (0 = none, 2 = CRC32)
    /// - 12     (1 byte) : CompressType (0 = none, 1 = LZO)
    /// - 13..16 (4 bytes): Data Check Value (UInt32 little-endian, default 0xFFFFFFFF)
    /// - 17     (1 byte) : Header checksum = sum of bytes 0..16 modulo 256
    public static func buildV2Packet(
        cmdType: UInt8,
        payload: String,
        packageId: UInt8 = 1,
        handshakeId: UInt8 = 0
    ) -> Data {
        let payloadData = payload.data(using: .utf8) ?? Data()
        var header = Data()
        header.append(v2Magic)
        header.append(cmdType)
        header.append((handshakeId << 4) & 0xF0)
        header.append(packageId)

        let len = UInt16(payloadData.count)
        header.append(UInt8(len & 0xFF))
        header.append(UInt8((len >> 8) & 0xFF))

        header.append(0x00) // checkType = 0 (none)
        header.append(0x00) // compressType = 0 (none)
        header.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // dataCheckValue

        // Header checksum (sum of bytes 0..16 & 0xFF)
        let checksum = header.reduce(0 as UInt32) { $0 + UInt32($1) } & 0xFF
        header.append(UInt8(checksum))

        return header + payloadData
    }

    /// Convenience packet builders for standard queries
    public static func queryBatteryPacket(pkgId: UInt8 = 1) -> Data {
        buildV2Packet(cmdType: 0x01, payload: "getval bat_ratio\r\n", packageId: pkgId)
    }

    public static func queryVoltagePacket(pkgId: UInt8 = 2) -> Data {
        buildV2Packet(cmdType: 0x01, payload: "getval power_voltage\r\n", packageId: pkgId)
    }

    public static func queryFirmwareVersionPacket(pkgId: UInt8 = 3) -> Data {
        buildV2Packet(cmdType: 0x01, payload: "getval printer_version\r\n", packageId: pkgId)
    }

    public static func querySecondaryFirmwarePacket(pkgId: UInt8 = 4) -> Data {
        buildV2Packet(cmdType: 0x01, payload: "getval printer_second_version\r\n", packageId: pkgId)
    }

    public static func querySerialNumberPacket(pkgId: UInt8 = 5) -> Data {
        buildV2Packet(cmdType: 0x01, payload: "getval serial_no\r\n", packageId: pkgId)
    }

    public static func queryModelNamePacket(pkgId: UInt8 = 6) -> Data {
        buildV2Packet(cmdType: 0x01, payload: "getval printer_model\r\n", packageId: pkgId)
    }

    public static func queryDeviceStatusPacket(pkgId: UInt8 = 7) -> Data {
        buildV2Packet(cmdType: 0x01, payload: "getval device_status\r\n", packageId: pkgId)
    }

    public static func handshakePacket(pkgId: UInt8 = 1) -> Data {
        buildV2Packet(
            cmdType: 0x03,
            payload: "user_port:1;print_relative_calib:1;print_compress:2;compress_type:1\r\n",
            packageId: pkgId
        )
    }

    // MARK: - Parsing & Decoding

    /// Decodes a raw incoming buffer (which may contain V2 packets, ESC/POS replies, or raw text)
    public static func parseIncomingData(_ data: Data, into info: inout HPRTDeviceInfo) {
        guard !data.isEmpty else { return }

        // 1. Try decoding as V2 Packet
        if data.count >= 18 && data.prefix(6) == v2Magic {
            let lenLow = UInt16(data[9])
            let lenHigh = UInt16(data[10])
            let payloadLen = Int(lenLow | (lenHigh << 8))
            let start = 18
            let end = min(data.count, start + payloadLen)
            if start < end {
                let payloadData = data.subdata(in: start..<end)
                if let str = String(data: payloadData, encoding: .utf8) ?? String(data: payloadData, encoding: .isoLatin1) {
                    parseKeyValueString(str, into: &info)
                }
            }
            info.protocolVersion = "V2"
        }

        // 2. Try decoding as plain text (key:value or JSON or ESC/POS ASCII)
        if let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            parseKeyValueString(str, into: &info)
        }

        // 3. Check for specific binary ESC/POS responses
        parseESCPOSStatusBytes(data, into: &info)

        if info.hasData {
            info.lastUpdated = Date()
        }
    }

    /// Parses key-value pairs in HPRT formats: "key:value;key2:val2" or "key=val" or "getval key\nval"
    public static func parseKeyValueString(_ text: String, into info: inout HPRTDeviceInfo) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // Format 1: semicolon-separated or newline-separated key:value
        let tokens = clean.components(separatedBy: CharacterSet(charactersIn: ";\r\n"))
        for token in tokens {
            let pair = token.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                let k = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                let v = pair[1].trimmingCharacters(in: .whitespaces)
                applyKeyValue(k: k, v: v, into: &info)
            } else {
                let eqPair = token.split(separator: "=", maxSplits: 1).map(String.init)
                if eqPair.count == 2 {
                    let k = eqPair[0].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = eqPair[1].trimmingCharacters(in: .whitespaces)
                    applyKeyValue(k: k, v: v, into: &info)
                }
            }
        }

        // Format 2: Direct numeric reply to battery or firmware query
        if let intVal = Int(clean), intVal >= 0 && intVal <= 100, info.batteryLevel == nil {
            // Might be a pure battery percentage number reply
            info.batteryLevel = intVal
        } else if clean.hasPrefix("V") || clean.hasPrefix("v") || clean.contains(".") {
            if clean.range(of: "^v?[0-9]+\\.[0-9]+", options: [.regularExpression, .caseInsensitive]) != nil {
                if info.firmwareVersion == nil {
                    info.firmwareVersion = clean
                }
            }
        }
    }

    private static func applyKeyValue(k: String, v: String, into info: inout HPRTDeviceInfo) {
        switch k {
        case "bat_ratio", "battery", "bat", "batterylevel":
            if let num = Int(v.filter({ $0.isNumber })) {
                info.batteryLevel = min(100, max(0, num))
            }
        case "power_voltage", "voltage", "vol":
            if let mv = Int(v.filter({ $0.isNumber })) {
                if mv > 100 {
                    info.batteryVoltage = String(format: "%.2f V (%d mV)", Double(mv) / 1000.0, mv)
                } else {
                    info.batteryVoltage = "\(v) V"
                }
            } else {
                info.batteryVoltage = v
            }
        case "printer_version", "firmware", "fw_ver", "version", "firmwareversion":
            info.firmwareVersion = v
        case "printer_second_version", "fw_sec_ver":
            info.secondaryFirmwareVersion = v
        case "serial_no", "serial", "sn", "serialnumber":
            info.serialNumber = v
        case "printer_model", "model", "modelname":
            info.modelName = v
        case "device_status", "work_status", "status":
            info.statusDescription = v
        case "hp_protocol_version":
            info.protocolVersion = v
        default:
            break
        }
    }

    private static func parseESCPOSStatusBytes(_ data: Data, into info: inout HPRTDeviceInfo) {
        // DLE EOT status byte 1
        if data.count == 1 {
            let b = data[0]
            // If bit 5 or 6 is low power indication
            if (b & 0x40) != 0 && info.batteryLevel == nil {
                info.statusDescription = "Low battery warning (ESC/POS)"
            }
        }
    }
}
