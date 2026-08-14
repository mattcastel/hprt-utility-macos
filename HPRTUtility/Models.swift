//
//  Models.swift
//  HPRT Utility
//

import Foundation
import SwiftUI

// MARK: - Check results

enum CheckStatus: String, Codable {
    case ok, warning, failure, unknown, pending

    var symbol: String {
        switch self {
        case .ok:      return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        case .pending: return "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ok:      return .green
        case .warning: return .orange
        case .failure: return .red
        case .unknown: return .secondary
        case .pending: return .blue
        }
    }

    var label: String {
        switch self {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .failure: return "Failed"
        case .unknown: return "Unknown"
        case .pending: return "Checking"
        }
    }

    /// Used to roll several checks up into one headline status.
    var severity: Int {
        switch self {
        case .ok: return 0
        case .unknown: return 1
        case .pending: return 1
        case .warning: return 2
        case .failure: return 3
        }
    }
}

enum Remedy: Hashable {
    case installRosetta
    case installDriver
    case enableQueue(String)
    case acceptQueue(String)
    case clearJobs(String)
    case setDensity(queue: String, value: Int)
    case launchBluetoothBridge
    case createBluetoothQueue(queue: String, uri: String, model: String)
    case openPrintersPane

    var title: String {
        switch self {
        case .installRosetta:         return "Install Rosetta 2"
        case .installDriver:          return "Install / Repair Driver"
        case .enableQueue:            return "Enable Queue"
        case .acceptQueue:            return "Accept Jobs"
        case .clearJobs:              return "Clear Stuck Jobs"
        case .setDensity(_, let v):   return "Set Density to \(v)"
        case .launchBluetoothBridge:  return "Launch Driver BT Tool"
        case .createBluetoothQueue:   return "Create Bluetooth Queue"
        case .openPrintersPane:       return "Open Printers & Scanners"
        }
    }

    var needsAdmin: Bool {
        switch self {
        case .launchBluetoothBridge, .openPrintersPane: return false
        default: return true
        }
    }
}

struct Check: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var value: String = ""
    var detail: String? = nil
    var status: CheckStatus = .unknown
    var remedy: Remedy? = nil

    static func ok(_ t: String, _ v: String = "", _ d: String? = nil) -> Check {
        Check(title: t, value: v, detail: d, status: .ok)
    }
    static func warn(_ t: String, _ v: String = "", _ d: String? = nil, remedy: Remedy? = nil) -> Check {
        Check(title: t, value: v, detail: d, status: .warning, remedy: remedy)
    }
    static func fail(_ t: String, _ v: String = "", _ d: String? = nil, remedy: Remedy? = nil) -> Check {
        Check(title: t, value: v, detail: d, status: .failure, remedy: remedy)
    }
    static func info(_ t: String, _ v: String = "", _ d: String? = nil) -> Check {
        Check(title: t, value: v, detail: d, status: .unknown)
    }
}

// MARK: - Snapshots

struct SystemInfo {
    var productVersion = "—"
    var buildVersion = "—"
    var architecture = "—"
    var rosettaInstalled = false
    var rosettaNeeded = false
    var hostName = "—"
}

struct FilterInfo: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var architectures: [String]
    var signed: Bool
    var signedBy: String?
    var sizeBytes: Int

    var isUniversal: Bool { architectures.contains("arm64") }
}

struct DriverInfo {
    var ppdFiles: [String] = []
    var filters: [FilterInfo] = []
    var filterDirectory: String? = nil
    var sealedPathUsed = false      // filters found in /usr/libexec (impossible to install on macOS 11+)
    var installed: Bool { !filters.isEmpty && !ppdFiles.isEmpty }
}

struct USBDeviceInfo: Identifiable, Hashable {
    var id: String { "\(locationID)-\(serial ?? productName)" }
    var vendorName: String
    var productName: String
    var serial: String?
    var vendorID: Int
    var productID: Int
    var locationID: String
    var speed: String
    var interfaceClasses: [Int]
    var deviceInfo: HPRTDeviceInfo? = nil

    var isPrinterClass: Bool { interfaceClasses.contains(7) }
    var idPair: String { String(format: "0x%04X / 0x%04X", vendorID, productID) }

    /// The USB vendor id HPRT ships the MT800 family under (0x20D1). The device
    /// presents no vendor string, so this is one of the few stable signals.
    static let hprtVendorID = 0x20D1

    /// True when this device is (or is almost certainly) the HPRT printer.
    ///
    /// Matching by name is the happy path, but the MT800 ships **no**
    /// iManufacturer / iProduct string descriptors — on USB it enumerates
    /// nameless, with only a serial like `MT80021071201…`. Relying on the name
    /// alone is exactly why the printer went unrecognised while plugged in. So we
    /// also accept a serial that matches the model family, and vendor id 0x20D1
    /// when the device presents the USB printer class.
    var looksLikeHPRT: Bool {
        if vendorName.localizedCaseInsensitiveContains("HPRT")
            || vendorName.localizedCaseInsensitiveContains("Hanin") { return true }
        if productName.range(of: Paths.modelPattern, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if let serial, serial.range(of: Paths.modelPattern, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if vendorID == Self.hprtVendorID && isPrinterClass { return true }
        return false
    }

    /// A usable name even when the descriptor carries no product/vendor string.
    var displayName: String {
        let v = vendorName.hasPrefix("Unknown") ? "" : vendorName
        let p = productName.hasPrefix("Unknown") ? "" : productName
        let named = "\(v) \(p)".trimmingCharacters(in: .whitespaces)
        if !named.isEmpty { return named }
        if looksLikeHPRT { return serial.map { "HPRT printer · \($0)" } ?? "HPRT printer" }
        return "USB device \(idPair)"
    }
}

struct PPDOption: Identifiable, Hashable {
    var id: String { keyword }
    var keyword: String
    var displayName: String
    var choices: [String]
    var current: String
}

struct QueueInfo: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var deviceURI: String
    var enabled: Bool
    var accepting: Bool
    var stateMessage: String
    var pendingJobs: Int
    var ppdPath: String
    var modelName: String
    var options: [PPDOption] = []

    var transport: Transport {
        if deviceURI.hasPrefix("usb://") { return .usb }
        if deviceURI.hasPrefix("bluetooth://") { return .bluetoothClassic }
        if deviceURI.contains("127.0.0.1:9101") || deviceURI.contains("localhost:9101") { return .bluetoothBridge }
        if deviceURI.hasPrefix("socket://") || deviceURI.hasPrefix("ipp") || deviceURI.hasPrefix("dnssd") { return .network }
        return .unknown
    }

    enum Transport: String {
        case usb = "USB"
        case bluetoothClassic = "Bluetooth (native backend)"
        case bluetoothBridge = "Bluetooth (HPRT TCP bridge)"
        case network = "Network"
        case unknown = "Unknown"
    }

    func option(_ keyword: String) -> PPDOption? { options.first { $0.keyword == keyword } }
}

struct BridgeInfo {
    var helperRunning = false
    var helperPID: Int32? = nil
    var portOpen = false
    var port = 9101
}

/// A printer paired over *classic* Bluetooth (RFCOMM / SPP), which is how the
/// MT800 actually connects. This is neither BLE nor HPRT's TCP bridge, so the
/// original probes never saw it: the device shows up as a `/dev/cu.*` serial
/// port and, to macOS, as a connected Bluetooth device of minor type "Printer".
struct BTClassicDevice: Identifiable, Hashable {
    var id: String { address.isEmpty ? name : address }
    var name: String
    var address: String          // "00:15:82:94:09:5C", empty if only the serial port is known
    var minorType: String = ""
    var rssi: Int? = nil
    var connected: Bool = false
    var serialPorts: [String] = []   // ["/dev/cu.MT800-095C"]
    var deviceInfo: HPRTDeviceInfo? = nil

    var isPrinter: Bool { minorType.localizedCaseInsensitiveContains("print") || name.range(of: Paths.modelPattern, options: [.regularExpression, .caseInsensitive]) != nil }

    /// The URI macOS's own `bluetooth` CUPS backend expects: `bluetooth://` plus
    /// the address as 12 uppercase hex digits, no separators. Recovered from the
    /// backend binary, whose only URI template is the literal `bluetooth://%@`.
    var cupsBluetoothURI: String {
        let hex = address.replacingOccurrences(of: ":", with: "")
                         .replacingOccurrences(of: "-", with: "")
                         .uppercased()
        return hex.isEmpty ? "" : "bluetooth://\(hex)"
    }

    var primarySerialPort: String? { serialPorts.first }
}

struct PrintJobRecord: Identifiable, Hashable {
    let id = UUID()
    var jobID: String
    var file: String
    var queue: String
    var submitted: Date
    var density: String
    var finished: Bool = false
    var note: String = ""
}

// MARK: - Raster

struct RasterAnalysis {
    var version: String = "—"
    var byteOrder: String = "—"
    var headerBytes: Int = 0
    var width: Int = 0
    var height: Int = 0
    var bitsPerColor: Int = 0
    var bitsPerPixel: Int = 0
    var bytesPerLine: Int = 0
    var colorSpace: Int = 0
    var colorSpaceName: String = "—"
    var compressed: Bool = false
    var resolution: (Int, Int) = (0, 0)
    var totalBytes: Int = 0
    var inkBytes: Int = 0
    var pages: Int = 0
    var preview: CGImage? = nil
    var note: String? = nil

    var inkRatio: Double { totalBytes > 0 ? Double(inkBytes) / Double(totalBytes) : 0 }
    var looksBlank: Bool { inkBytes < 2_000 }

    var verdict: (CheckStatus, String) {
        if totalBytes < 2_000 {
            return (.failure, "No raster produced. The macOS filter chain failed before the driver was reached.")
        }
        if looksBlank {
            return (.failure, "Raster contains no ink. The page is already blank before it reaches the HPRT filter — the fault is upstream, in the macOS PDF/text rasteriser.")
        }
        return (.ok, String(format: "Raster carries ink (%.2f%% non-zero bytes). If the paper still comes out blank, the fault is in the HPRT filter or later.", inkRatio * 100))
    }
}

// MARK: - ESC/POS

/// Opcodes recovered by disassembling `raster-mt800lzo`, the filter shipped in
/// HPRT's own macOS driver. Each entry lists the exact bytes that filter emits.
struct ESCPOSCommand: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var summary: String
    var bytes: [UInt8]
    var parameterName: String? = nil
    var parameterRange: ClosedRange<Int>? = nil
    var parameterDefault: Int = 0
    var expectsReply: Bool = false
    var origin: String

    func encoded(parameter: Int?) -> [UInt8] {
        guard parameterName != nil, let p = parameter else { return bytes }
        return bytes + [UInt8(clamping: p)]
    }

    var hex: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

enum ESCPOS {
    static let library: [ESCPOSCommand] = [
        ESCPOSCommand(name: "Initialise printer",
                      summary: "Clears the buffer and resets every mode. Always send this first.",
                      bytes: [0x1B, 0x40],
                      origin: "ESC @ — standard ESC/POS"),

        ESCPOSCommand(name: "Set print density",
                      summary: "The darkness control. 3 is the maximum the HPRT PPD exposes.",
                      bytes: [0x1D, 0x28, 0x4B, 0x02, 0x00, 0x31],
                      parameterName: "Density",
                      parameterRange: 0...3,
                      parameterDefault: 3,
                      origin: "GS ( K fn=49 — from _hprt_cmd_select_the_print_density"),

        ESCPOSCommand(name: "Real-time status",
                      summary: "Asks for printer, offline, error or paper status. Needs a bidirectional channel to read the answer.",
                      bytes: [0x10, 0x04],
                      parameterName: "n (1=printer 2=offline 3=error 4=paper)",
                      parameterRange: 1...4,
                      parameterDefault: 1,
                      expectsReply: true,
                      origin: "DLE EOT n — from _hprt_cmd_transmit_real_time_status"),

        ESCPOSCommand(name: "Transmit printer ID",
                      summary: "Returns model / type / firmware identifiers.",
                      bytes: [0x1D, 0x49],
                      parameterName: "n (1=model 2=type 3=firmware)",
                      parameterRange: 1...67,
                      parameterDefault: 1,
                      expectsReply: true,
                      origin: "GS I n — from _hprt_cmd_transmit_printer_id"),

        ESCPOSCommand(name: "Transmit status",
                      summary: "Paper sensor and peripheral status. Worth probing for a battery byte.",
                      bytes: [0x1D, 0x72],
                      parameterName: "n",
                      parameterRange: 1...4,
                      parameterDefault: 1,
                      expectsReply: true,
                      origin: "GS r n — from _hprt_cmd_transmit_status"),

        ESCPOSCommand(name: "Enable / disable ASB",
                      summary: "Automatic Status Back: the printer pushes status bytes on change.",
                      bytes: [0x1D, 0x61],
                      parameterName: "Mask (0 = off, 255 = everything)",
                      parameterRange: 0...255,
                      parameterDefault: 255,
                      expectsReply: true,
                      origin: "GS a n — from _hprt_cmd_enable_disable_ASB"),

        ESCPOSCommand(name: "Feed n lines",
                      summary: "Advances the paper without printing. Useful to prove the motor obeys.",
                      bytes: [0x1B, 0x64],
                      parameterName: "Lines",
                      parameterRange: 0...255,
                      parameterDefault: 3,
                      origin: "ESC d n — from _hprt_cmd_print_and_feed_n_line"),

        ESCPOSCommand(name: "Form feed / eject page",
                      summary: "Ends the page and ejects it.",
                      bytes: [0x0C],
                      origin: "FF — standard"),

        ESCPOSCommand(name: "HPRT V2: Query battery level",
                      summary: "Queries the battery percentage (0–100%) using HPRT V2 protocol 'getval bat_ratio'.",
                      bytes: [UInt8](HPRTProtocol.queryBatteryPacket()),
                      expectsReply: true,
                      origin: "HPRT V2 Framing — getval bat_ratio"),

        ESCPOSCommand(name: "HPRT V2: Query battery voltage",
                      summary: "Queries the battery millivolts using HPRT V2 protocol 'getval power_voltage'.",
                      bytes: [UInt8](HPRTProtocol.queryVoltagePacket()),
                      expectsReply: true,
                      origin: "HPRT V2 Framing — getval power_voltage"),

        ESCPOSCommand(name: "HPRT V2: Query firmware version",
                      summary: "Queries firmware revision using HPRT V2 protocol 'getval printer_version'.",
                      bytes: [UInt8](HPRTProtocol.queryFirmwareVersionPacket()),
                      expectsReply: true,
                      origin: "HPRT V2 Framing — getval printer_version"),

        ESCPOSCommand(name: "HPRT V2: Query serial number",
                      summary: "Queries hardware serial number using HPRT V2 protocol 'getval serial_no'.",
                      bytes: [UInt8](HPRTProtocol.querySerialNumberPacket()),
                      expectsReply: true,
                      origin: "HPRT V2 Framing — getval serial_no"),

        ESCPOSCommand(name: "ESC/POS: Query firmware version",
                      summary: "Queries printer firmware version using HPRT proprietary string command.",
                      bytes: [UInt8](HPRTProtocol.escposGetVersion),
                      expectsReply: true,
                      origin: "ZZZGETVERSION — from _hprt_cmd_transmit_printer_version"),
    ]

    /// A page of solid black bands drawn with the raster graphics command.
    /// On an A4 raster printer this is the honest darkness test: text mode is
    /// often unimplemented, but the graphics path is the one CUPS uses.
    static func solidBlackBand(widthDots: Int = 1584, heightDots: Int = 240, density: Int = 3) -> Data {
        var out = Data([0x1B, 0x40])
        out.append(contentsOf: [0x1D, 0x28, 0x4B, 0x02, 0x00, 0x31, UInt8(clamping: density)])

        let bytesPerLine = (widthDots + 7) / 8
        // GS v 0 m xL xH yL yH  — raster bit image, m = 0 (normal)
        out.append(contentsOf: [0x1D, 0x76, 0x30, 0x00])
        out.append(contentsOf: [UInt8(bytesPerLine & 0xFF), UInt8((bytesPerLine >> 8) & 0xFF)])
        out.append(contentsOf: [UInt8(heightDots & 0xFF), UInt8((heightDots >> 8) & 0xFF)])
        out.append(Data(repeating: 0xFF, count: bytesPerLine * heightDots))

        out.append(contentsOf: [0x1B, 0x64, 0x02])
        out.append(0x0C)
        return out
    }
}
