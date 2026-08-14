//
//  Services.swift
//  HPRT Utility
//

import Foundation
import AppKit

// MARK: - Paths

enum Paths {
    static let systemPPDDirectory = "/Library/Printers/PPDs/Contents/Resources"
    static let sealedFilterDirectory = "/usr/libexec/cups/filter"        // read-only since macOS 11
    static let managedPrefix = "/Library/Printers/HPRT"
    static let managedFilterDirectory = "/Library/Printers/HPRT/filter"
    static let cupsErrorLog = "/var/log/cups/error_log"
    static let cupsPPDDirectory = "/etc/cups/ppd"
    static let bridgeAppName = "Driver BT Tool"
    static let bridgePort = 9101

    /// Matches MT800, MT8003, MT800Q, MT800Q3, MT866, MT8663 …
    static let modelPattern = "MT8[0-9]{2,3}Q?[0-9]?"
}

// MARK: - System

enum SystemProbe {
    static func snapshot() -> SystemInfo {
        var info = SystemInfo()
        info.productVersion = Shell.run("/usr/bin/sw_vers", ["-productVersion"]).out
        info.buildVersion = Shell.run("/usr/bin/sw_vers", ["-buildVersion"]).out
        info.hostName = ProcessInfo.processInfo.hostName

        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        info.architecture = machine

        if machine == "arm64" {
            info.rosettaNeeded = true
            let runtimeExists = FileManager.default.fileExists(
                atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
            let canTranslate = Shell.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"], timeout: 8).ok
            info.rosettaInstalled = runtimeExists || canTranslate
        } else {
            info.rosettaInstalled = true
        }
        return info
    }

    static func checks(_ info: SystemInfo) -> [Check] {
        var out: [Check] = [
            .info("macOS", "\(info.productVersion) (\(info.buildVersion))"),
            .info("Architecture", info.architecture)
        ]
        if info.rosettaNeeded {
            if info.rosettaInstalled {
                out.append(.warn("Rosetta 2", "Installed",
                                 "HPRT ships x86_64-only CUPS filters, so every job is translated. Apple has announced macOS 27 as the last release to carry Rosetta 2 in full."))
            } else {
                out.append(.fail("Rosetta 2", "Missing",
                                 "The HPRT filters are x86_64-only and cannot run without it. cupsd fails silently in this state.",
                                 remedy: .installRosetta))
            }
        }
        return out
    }
}

// MARK: - Driver

enum DriverInspector {

    static func snapshot() -> DriverInfo {
        var info = DriverInfo()
        let fm = FileManager.default

        if let entries = try? fm.contentsOfDirectory(atPath: Paths.systemPPDDirectory) {
            info.ppdFiles = entries
                .filter { $0.lowercased().hasPrefix("mt8") && $0.lowercased().contains(".ppd") }
                .sorted()
        }

        for directory in [Paths.managedFilterDirectory, Paths.sealedFilterDirectory] {
            let candidates = ["raster-mt800lzo", "raster-mt800"]
                .map { directory + "/" + $0 }
                .filter { fm.isExecutableFile(atPath: $0) }
            guard !candidates.isEmpty else { continue }
            info.filterDirectory = directory
            info.sealedPathUsed = (directory == Paths.sealedFilterDirectory)
            info.filters = candidates.map { describe(filterAt: $0) }
            break
        }
        return info
    }

    private static func describe(filterAt path: String) -> FilterInfo {
        let archs = Shell.run("/usr/bin/lipo", ["-archs", path], timeout: 8).out
            .split(separator: " ").map(String.init)
        let sign = Shell.run("/usr/bin/codesign", ["-dv", path], timeout: 10)
        let authority = sign.stderr.firstMatch("Authority=([^\\n]+)")
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return FilterInfo(path: path,
                          architectures: archs.isEmpty ? ["unknown"] : archs,
                          signed: sign.stderr.contains("Signature="),
                          signedBy: authority,
                          sizeBytes: size)
    }

    static func checks(_ info: DriverInfo, system: SystemInfo) -> [Check] {
        var out: [Check] = []

        if info.ppdFiles.isEmpty {
            out.append(.fail("PPD files", "None found",
                             "No HPRT PPD in \(Paths.systemPPDDirectory).",
                             remedy: .installDriver))
        } else {
            out.append(.ok("PPD files", info.ppdFiles.joined(separator: ", ")))
        }

        if info.filters.isEmpty {
            out.append(.fail("CUPS filters", "None found",
                             "HPRT's installer targets \(Paths.sealedFilterDirectory), which lives on the sealed system volume and has been read-only since macOS 11. The package cannot succeed there. Install the filters under \(Paths.managedPrefix) instead.",
                             remedy: .installDriver))
        } else {
            for filter in info.filters {
                let name = (filter.path as NSString).lastPathComponent
                if filter.isUniversal {
                    out.append(.ok("Filter \(name)", filter.architectures.joined(separator: ", "), filter.path))
                } else if system.architecture == "arm64" {
                    out.append(.warn("Filter \(name)",
                                     filter.architectures.joined(separator: ", "),
                                     "x86_64 only — runs through Rosetta 2 under cupsd. \(filter.path)"))
                } else {
                    out.append(.ok("Filter \(name)", filter.architectures.joined(separator: ", "), filter.path))
                }
            }
            if info.sealedPathUsed {
                out.append(.warn("Filter location", Paths.sealedFilterDirectory,
                                 "These filters sit on the sealed system volume and will be wiped by the next macOS upgrade."))
            }
        }
        return out
    }
}

// MARK: - CUPS

enum CupsService {

    static func hprtQueues() -> [QueueInfo] {
        let names = Shell.lpstat(["-p"]).lines.compactMap { line -> String? in
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count > 1,
                  parts[0].lowercased().hasPrefix("printer") || parts[0].lowercased().hasPrefix("imprimante")
            else { return nil }
            return parts[1]
        }

        let uriLines = Shell.lpstat(["-v"]).lines
        var result: [QueueInfo] = []

        for name in names {
            let ppdPath = "\(Paths.cupsPPDDirectory)/\(name).ppd"
            guard let ppd = try? String(contentsOfFile: ppdPath, encoding: .isoLatin1) else { continue }
            let isHPRT = ppd.containsCI("Manufacturer: \"HPRT")
                || ppd.containsCI("raster-mt800")
                || ppd.firstMatch("ModelName: \"(\(Paths.modelPattern))") != nil
            guard isHPRT else { continue }

            let uri = uriLines.first { $0.contains("for \(name):") }?
                .split(separator: " ").last.map(String.init) ?? ""
            let statusLine = Shell.lpstat(["-p", name]).out
            let acceptLine = Shell.lpstat(["-a", name]).out
            let pending = Shell.lpstat(["-o", name]).lines.count

            result.append(QueueInfo(
                name: name,
                deviceURI: uri,
                enabled: !statusLine.containsCI("disabled") && !statusLine.containsCI("désactiv"),
                accepting: !acceptLine.containsCI("not accepting") && !acceptLine.containsCI("refuse"),
                stateMessage: statusLine,
                pendingJobs: pending,
                ppdPath: ppdPath,
                modelName: ppd.firstMatch("ModelName: \"([^\"]+)\"") ?? "Unknown",
                options: options(for: name)
            ))
        }
        return result
    }

    /// Parses `lpoptions -p <queue> -l`. The choice prefixed with `*` is the one
    /// CUPS will actually apply — `lpoptions -p <queue>` without `-l` only lists
    /// user-level overrides, and its silence does not mean "unset".
    static func options(for queue: String) -> [PPDOption] {
        Shell.lpoptions(["-p", queue, "-l"]).lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let head = String(line[line.startIndex..<colon])
            let tail = String(line[line.index(after: colon)...])
            let keyword = head.split(separator: "/").first.map(String.init) ?? head
            let display = head.split(separator: "/").dropFirst().joined(separator: "/")
            let tokens = tail.split(separator: " ").map(String.init)
            let current = tokens.first { $0.hasPrefix("*") }?.replacingOccurrences(of: "*", with: "") ?? ""
            return PPDOption(keyword: keyword,
                             displayName: display.isEmpty ? keyword : display,
                             choices: tokens.map { $0.replacingOccurrences(of: "*", with: "") },
                             current: current)
        }
    }

    static func discoveredDevices() -> [String] {
        Shell.lpinfo(["-v"]).lines.filter { $0.containsCI("hprt") || $0.containsCI("hanin") }
    }

    /// Best HPRT PPD to hand `lpadmin` for a new queue: the one the managed
    /// installer wrote for this model, then any installed HPRT PPD. Returns nil
    /// when nothing is installed — the caller falls back to a raw queue.
    static func bestPPDPath(model: String) -> String? {
        let fm = FileManager.default
        let managed = "\(Paths.systemPPDDirectory)/\(model.lowercased())-hprt.ppd"
        if fm.isReadableFile(atPath: managed) { return managed }
        if let entries = try? fm.contentsOfDirectory(atPath: Paths.systemPPDDirectory) {
            if let hit = entries.first(where: { $0.lowercased().hasPrefix(model.lowercased()) && $0.lowercased().contains(".ppd") })
                ?? entries.first(where: { $0.lowercased().hasPrefix("mt8") && $0.lowercased().hasSuffix("-hprt.ppd") })
                ?? entries.first(where: { $0.lowercased().hasPrefix("mt8") && $0.lowercased().contains(".ppd") }) {
                return "\(Paths.systemPPDDirectory)/\(hit)"
            }
        }
        return nil
    }

    static func checks(_ queues: [QueueInfo], usb: [USBDeviceInfo], driverInstalled: Bool) -> [Check] {
        guard let queue = queues.first else {
            if !usb.isEmpty && !driverInstalled {
                return [.fail("Print queue", "None",
                              "The printer answers on USB but no driver is installed, so no queue can exist yet.",
                              remedy: .installDriver)]
            }
            return [.fail("Print queue", "None",
                          "No CUPS queue uses an HPRT driver.",
                          remedy: .installDriver)]
        }

        var out: [Check] = [
            .ok("Queue", queue.name, queue.modelName),
            .info("Device URI", queue.deviceURI),
            .info("Transport", queue.transport.rawValue)
        ]

        out.append(queue.enabled
                   ? .ok("Queue enabled", "Yes", queue.stateMessage)
                   : .fail("Queue enabled", "No", queue.stateMessage, remedy: .enableQueue(queue.name)))

        out.append(queue.accepting
                   ? .ok("Accepting jobs", "Yes")
                   : .fail("Accepting jobs", "No", nil, remedy: .acceptQueue(queue.name)))

        if queue.pendingJobs > 0 {
            out.append(.warn("Pending jobs", "\(queue.pendingJobs)",
                             "Jobs sitting in the queue usually mean the backend never got an answer.",
                             remedy: .clearJobs(queue.name)))
        } else {
            out.append(.ok("Pending jobs", "0"))
        }

        if let density = queue.option("PrintDensity") {
            switch density.current {
            case "3":
                out.append(.ok("Print density", "3 (maximum)", "Choices: " + density.choices.joined(separator: " ")))
            case "None", "":
                out.append(.warn("Print density", density.current.isEmpty ? "unset" : "None",
                                 "The printer keeps its internal setting, which is usually pale.",
                                 remedy: .setDensity(queue: queue.name, value: 3)))
            default:
                out.append(.warn("Print density", density.current, "Maximum is 3.",
                                 remedy: .setDensity(queue: queue.name, value: 3)))
            }
        } else {
            out.append(.warn("Print density", "Not exposed",
                             "The stock mt8003 PPD ships no PrintDensity block at all. The filter still honours the option, so it has to be injected into the PPD or passed per job.",
                             remedy: .installDriver))
        }
        return out
    }

    // MARK: Actions

    static func apply(_ remedy: Remedy) -> CommandResult {
        switch remedy {
        case .installRosetta:
            return Shell.runPrivileged("/usr/sbin/softwareupdate --install-rosetta --agree-to-license")
        case .enableQueue(let q):
            return Shell.runPrivileged("/usr/sbin/cupsenable '\(q)'")
        case .acceptQueue(let q):
            return Shell.runPrivileged("/usr/sbin/cupsaccept '\(q)'")
        case .clearJobs(let q):
            return Shell.run("/usr/bin/cancel", ["-a", q])
        case .setDensity(let q, let v):
            return Shell.runPrivileged("/usr/sbin/lpadmin -p '\(q)' -o PrintDensity=\(v) -o PaperType=1")
        case .launchBluetoothBridge:
            let r = Shell.run("/usr/bin/open", ["-a", Paths.bridgeAppName])
            return r
        case .createBluetoothQueue(let queue, let uri, let model):
            let ppdArg = bestPPDPath(model: model).map { "-P '\($0)'" } ?? "-m raw"
            let script = """
            /usr/sbin/lpadmin -x '\(queue)' 2>/dev/null || true
            /usr/sbin/lpadmin -p '\(queue)' -E -v '\(uri)' \(ppdArg) \
              -o printer-is-shared=false -o PrintDensity=3 -o PaperType=1 \
              -D 'HPRT \(model) over Bluetooth'
            /usr/sbin/cupsenable '\(queue)'
            /usr/sbin/cupsaccept '\(queue)'
            /usr/bin/lpstat -v '\(queue)'
            """
            return Shell.runPrivileged(script)
        case .openPrintersPane:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension")!)
            return CommandResult(command: "open printers pane", status: 0, stdout: "", stderr: "")
        case .installDriver:
            return .failed("installDriver", "Handled by DriverInstaller.")
        }
    }
}

// MARK: - Bluetooth bridge (HPRT's own helper)

enum BridgeProbe {
    static func snapshot() -> BridgeInfo {
        var info = BridgeInfo()
        let pgrep = Shell.run("/usr/bin/pgrep", ["-f", Paths.bridgeAppName], timeout: 6)
        if pgrep.ok, let first = pgrep.lines.first, let pid = Int32(first) {
            info.helperRunning = true
            info.helperPID = pid
        }
        info.portOpen = isPortOpen(host: "127.0.0.1", port: Paths.bridgePort)
        return info
    }

    static func isPortOpen(host: String, port: Int, timeout: TimeInterval = 1.0) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    static func checks(_ info: BridgeInfo, queueTransport: QueueInfo.Transport?) -> [Check] {
        let usesBridge = queueTransport == .bluetoothBridge
        var out: [Check] = []

        if info.helperRunning {
            out.append(.ok("Driver BT Tool", "Running (pid \(info.helperPID ?? 0))"))
        } else {
            out.append(Check(title: "Driver BT Tool",
                             value: "Not running",
                             detail: "HPRT's helper opens a TCP server on 127.0.0.1:\(info.port) and relays to the printer over BLE. A Bluetooth queue points at that socket, not at the printer — without the helper, jobs vanish silently.",
                             status: usesBridge ? .failure : .unknown,
                             remedy: usesBridge ? .launchBluetoothBridge : nil))
        }

        if info.portOpen {
            out.append(.ok("Bridge port \(info.port)", "Open"))
        } else {
            out.append(Check(title: "Bridge port \(info.port)",
                             value: "Closed",
                             detail: usesBridge ? "The queue relies on this socket. Printing cannot work."
                                                : "Expected when printing over USB.",
                             status: usesBridge ? .failure : .ok))
        }
        return out
    }
}

// MARK: - Bluetooth (classic / SPP)

/// Detects the printer when it is paired over *classic* Bluetooth — the way the
/// MT800 actually connects. Two independent signals are combined:
///
///  1. `/dev/cu.*` serial ports, which appear instantly for any paired RFCOMM
///     device. This alone proves an MT8xx is paired, even if `system_profiler`
///     is slow or unavailable.
///  2. `system_profiler SPBluetoothDataType -json`, which adds the address, the
///     RSSI, whether the link is currently up, and the device's minor type.
///
/// Neither the BLE scanner nor the TCP-bridge probe could ever see this: over
/// classic Bluetooth the printer is an RFCOMM/SPP endpoint, reachable through
/// macOS's own `bluetooth` CUPS backend (`bluetooth://<addr>`), which is what
/// HPRT's tool sidesteps with its `socket://127.0.0.1:9101` relay.
enum BluetoothClassicProbe {

    static func snapshot() -> [BTClassicDevice] {
        let ports = serialPorts()
        var devices = systemProfilerDevices()

        // Attach serial ports to the device they belong to; keep leftovers as
        // serial-only entries so a paired printer is never dropped.
        var claimed = Set<String>()
        for index in devices.indices {
            let sanitized = sanitize(devices[index].name)
            let tail = addressTail(devices[index].address)
            let matches = ports.filter { port in
                let base = (port as NSString).lastPathComponent
                    .replacingOccurrences(of: "cu.", with: "")
                    .replacingOccurrences(of: "tty.", with: "")
                return base.caseInsensitiveCompare(sanitized) == .orderedSame
                    || base.localizedCaseInsensitiveContains(sanitized)
                    || (!tail.isEmpty && base.uppercased().hasSuffix(tail))
            }
            devices[index].serialPorts = matches
            claimed.formUnion(matches)
        }
        for port in ports where !claimed.contains(port) {
            let base = (port as NSString).lastPathComponent
                .replacingOccurrences(of: "cu.", with: "")
                .replacingOccurrences(of: "tty.", with: "")
            devices.append(BTClassicDevice(name: base, address: "",
                                           minorType: "Printer", connected: false,
                                           serialPorts: [port]))
        }

        // Printers first, then connected before merely paired.
        return devices.sorted {
            if $0.isPrinter != $1.isPrinter { return $0.isPrinter }
            return ($0.connected ? 0 : 1) < ($1.connected ? 0 : 1)
        }
    }

    /// The `/dev/cu.*` nodes whose name looks like an MT8xx printer.
    static func serialPorts() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return all
            .filter { $0.hasPrefix("cu.") }
            .filter { $0.range(of: Paths.modelPattern, options: [.regularExpression, .caseInsensitive]) != nil
                   || $0.localizedCaseInsensitiveContains("hprt") }
            .map { "/dev/\($0)" }
            .sorted()
    }

    private static func systemProfilerDevices() -> [BTClassicDevice] {
        // -json can take a few seconds; bounded so a refresh never stalls.
        let result = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 25)
        guard let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var out: [BTClassicDevice] = []
        for section in sections {
            parse(section["device_connected"], connected: true, into: &out)
            parse(section["device_not_connected"], connected: false, into: &out)
        }
        return out
    }

    private static func parse(_ raw: Any?, connected: Bool, into out: inout [BTClassicDevice]) {
        guard let list = raw as? [[String: Any]] else { return }
        for entry in list {
            for (name, value) in entry {
                let props = value as? [String: Any] ?? [:]
                let minor = props["device_minorType"] as? String ?? ""
                let addr = props["device_address"] as? String ?? ""
                // Keep printers and anything whose name matches the model family;
                // skip the phones, watches and headphones cluttering the list.
                let looksLikePrinter = minor.localizedCaseInsensitiveContains("print")
                    || name.range(of: Paths.modelPattern, options: [.regularExpression, .caseInsensitive]) != nil
                guard looksLikePrinter else { continue }
                let rssi = (props["device_rssi"] as? String).flatMap { Int($0) }
                out.append(BTClassicDevice(name: name, address: addr, minorType: minor,
                                           rssi: rssi, connected: connected))
            }
        }
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }

    private static func addressTail(_ address: String) -> String {
        let hex = address.replacingOccurrences(of: ":", with: "").uppercased()
        return hex.count >= 4 ? String(hex.suffix(4)) : ""
    }

    static func checks(_ devices: [BTClassicDevice], queueTransport: QueueInfo.Transport?) -> [Check] {
        guard let printer = devices.first(where: \.isPrinter) ?? devices.first else { return [] }
        var out: [Check] = []

        let where_ = printer.primarySerialPort.map { " · \($0)" } ?? ""
        let rssi = printer.rssi.map { " · RSSI \($0) dBm" } ?? ""
        if printer.connected {
            out.append(.ok("Bluetooth printer", "\(printer.name) — connected",
                           "Classic Bluetooth (RFCOMM/SPP)\(printer.address.isEmpty ? "" : " · \(printer.address)")\(rssi)\(where_). macOS can print to it through its native bluetooth backend — no HPRT bridge required."))
        } else {
            out.append(.warn("Bluetooth printer", "\(printer.name) — paired, link down",
                             "Paired over classic Bluetooth\(where_) but not currently connected. Wake the printer, or open it once from System Settings, then refresh."))
        }

        // If a queue exists but points somewhere other than this printer, say so.
        if let t = queueTransport, t != .bluetoothClassic, printer.connected {
            out.append(.warn("Bluetooth print path", "No native queue",
                             "The printer is on Bluetooth, but the current CUPS queue uses \(t.rawValue). Create a queue on \(printer.cupsBluetoothURI) to print over Bluetooth without HPRT's TCP bridge."))
        }
        return out
    }
}

// MARK: - Printing

enum PrintService {

    static func submit(file: URL, queue: String, density: Int?, paperType: String?,
                       postPrintAction: Bool, extraOptions: [String: String] = [:]) -> (CommandResult, String?) {
        var args = ["-d", queue]
        if let density { args += ["-o", "PrintDensity=\(density)"] }
        if let paperType { args += ["-o", "PaperType=\(paperType)"] }
        if postPrintAction { args += ["-o", "PostPrintAction=1"] }
        for (k, v) in extraOptions.sorted(by: { $0.key < $1.key }) { args += ["-o", "\(k)=\(v)"] }
        args.append(file.path)

        let result = Shell.lp(args)
        let jobID = result.out.firstMatch("request id is \\S+-(\\d+)")
        return (result, jobID)
    }

    /// Sends raw bytes straight to the device, bypassing every filter, by way of
    /// a temporary queue created without a PPD (CUPS treats those as raw).
    static func sendRaw(_ bytes: Data, deviceURI: String, queueName: String = "HPRT_Utility_Raw") -> CommandResult {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hprt-raw-\(UUID().uuidString.prefix(8)).bin")
        do { try bytes.write(to: tmp) } catch {
            return .failed("write payload", error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let script = """
        /usr/sbin/lpadmin -p '\(queueName)' -E -v '\(deviceURI)' -D 'HPRT Utility raw passthrough' 2>/dev/null; \
        /usr/bin/lp -d '\(queueName)' -o raw '\(tmp.path)'
        """
        let result = Shell.runPrivileged(script)

        // Wait for the spool to drain, then remove the scratch queue.
        for _ in 0..<25 {
            if Shell.lpstat(["-o", queueName]).lines.isEmpty { break }
            Thread.sleep(forTimeInterval: 1)
        }
        _ = Shell.runPrivileged("/usr/sbin/lpadmin -x '\(queueName)' 2>/dev/null || true")
        return result
    }

    static func pendingJobs(queue: String) -> [String] {
        Shell.lpstat(["-o", queue]).lines
    }

    /// Prints a prebuilt byte stream through an existing queue as a raw job:
    /// `lp -d <queue> -o raw`. CUPS skips the PPD filter chain entirely and hands
    /// the bytes to the backend, so this works over the USB queue even with no
    /// HPRT driver installed — and needs no administrator rights.
    static func printRaw(queue: String, data: Data) -> CommandResult {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hprt-direct-\(UUID().uuidString.prefix(8)).bin")
        do { try data.write(to: tmp) } catch {
            return .failed("write payload", error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return Shell.lp(["-d", queue, "-o", "raw", tmp.path])
    }

    /// Writes bytes straight to a classic-Bluetooth (RFCOMM/SPP) serial port —
    /// no CUPS, no administrator prompt. Honours back-pressure so a full A4 page
    /// streams over the slow link without dropping data.
    static func writeSerial(path: String, data: Data) -> CommandResult {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return .failed("open \(path)", String(cString: strerror(errno))) }
        defer { close(fd) }

        var tio = termios()
        if tcgetattr(fd, &tio) == 0 {
            cfmakeraw(&tio)
            tio.c_cflag |= tcflag_t(CREAD | CLOCAL | CS8)
            cfsetispeed(&tio, speed_t(B115200))
            cfsetospeed(&tio, speed_t(B115200))
            tcsetattr(fd, TCSANOW, &tio)
        }

        let bytes = [UInt8](data)
        var sent = 0
        bytesLoop: while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: sent), min(4096, bytes.count - sent))
            }
            if n < 0 {
                if errno == EAGAIN {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 8000) <= 0 {
                        return .failed("serial write", "timed out writing to \(path)")
                    }
                    continue bytesLoop
                }
                return .failed("serial write", String(cString: strerror(errno)))
            }
            sent += n
        }
        tcdrain(fd)   // wait for the RFCOMM buffer to flush before closing
        return CommandResult(command: "serial write \(path)", status: 0,
                             stdout: "wrote \(sent) bytes", stderr: "")
    }
}

// MARK: - Device Query (Battery & Firmware)

enum DeviceQueryService {

    /// Sends a query sequence to a serial port and parses the returned info.
    static func querySerial(path: String, timeout: TimeInterval = 0.8) -> HPRTDeviceInfo? {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tio = termios()
        if tcgetattr(fd, &tio) == 0 {
            cfmakeraw(&tio)
            tio.c_cflag |= tcflag_t(CREAD | CLOCAL | CS8)
            cfsetispeed(&tio, speed_t(B115200))
            cfsetospeed(&tio, speed_t(B115200))
            tcsetattr(fd, TCSANOW, &tio)
        }

        var info = HPRTDeviceInfo()
        let queries: [Data] = [
            HPRTProtocol.probeProtocolVersion,
            HPRTProtocol.queryBatteryPacket(pkgId: 1),
            HPRTProtocol.queryVoltagePacket(pkgId: 2),
            HPRTProtocol.queryFirmwareVersionPacket(pkgId: 3),
            HPRTProtocol.querySerialNumberPacket(pkgId: 4),
            HPRTProtocol.queryModelNamePacket(pkgId: 5),
            HPRTProtocol.escposGetVersion
        ]

        var buffer = [UInt8](repeating: 0, count: 2048)

        for query in queries {
            _ = query.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!, query.count)
            }
            usleep(60_000)

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollRes = poll(&pfd, 1, Int32(timeout * 1000 / Double(queries.count)))
            if pollRes > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    let chunk = Data(buffer[0..<n])
                    HPRTProtocol.parseIncomingData(chunk, into: &info)
                }
            }
        }

        return info.hasData ? info : nil
    }

    /// Sends a query sequence to HPRT TCP bridge on 127.0.0.1:9101
    static func queryTCPBridge(host: String = "127.0.0.1", port: Int = Paths.bridgePort, timeout: TimeInterval = 1.0) -> HPRTDeviceInfo? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(host)

        let res = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard res == 0 else { return nil }

        var info = HPRTDeviceInfo()
        let queries: [Data] = [
            HPRTProtocol.probeProtocolVersion,
            HPRTProtocol.queryBatteryPacket(pkgId: 1),
            HPRTProtocol.queryVoltagePacket(pkgId: 2),
            HPRTProtocol.queryFirmwareVersionPacket(pkgId: 3),
            HPRTProtocol.querySerialNumberPacket(pkgId: 4),
            HPRTProtocol.queryModelNamePacket(pkgId: 5),
            HPRTProtocol.escposGetVersion
        ]

        var buffer = [UInt8](repeating: 0, count: 2048)
        for query in queries {
            _ = query.withUnsafeBytes { raw in
                send(sock, raw.baseAddress!, query.count, 0)
            }
            usleep(80_000)
            let n = recv(sock, &buffer, buffer.count, 0)
            if n > 0 {
                let chunk = Data(buffer[0..<n])
                HPRTProtocol.parseIncomingData(chunk, into: &info)
            }
        }

        return info.hasData ? info : nil
    }

    /// Queries all channels (Serial ports, TCP Bridge) and extracts model from CUPS URI
    static func queryAll(serialPorts: [String], bridgeOpen: Bool, cupsURI: String?) -> HPRTDeviceInfo {
        var info = HPRTDeviceInfo()

        // Extract serial and model from CUPS URI if available
        if let uri = cupsURI {
            if let model = uri.firstMatch("usb://[^/]+/([^?]+)") {
                info.modelName = model
            }
            if let serial = uri.firstMatch("serial=([^&]+)") {
                info.serialNumber = serial
            }
        }

        // Query TCP bridge if port is open
        if bridgeOpen, let bridgeInfo = queryTCPBridge() {
            info.merge(with: bridgeInfo)
        }

        // Query serial ports
        for port in serialPorts {
            if let sInfo = querySerial(path: port, timeout: 0.6) {
                info.merge(with: sInfo)
            }
        }

        return info
    }
}

// MARK: - CUPS log

enum LogService {

    static func logLevel() -> String {
        Shell.run("/usr/sbin/cupsctl").lines
            .first { $0.hasPrefix("LogLevel=") }?
            .replacingOccurrences(of: "LogLevel=", with: "") ?? "unknown"
    }

    static func setDebugLogging(_ enabled: Bool) -> CommandResult {
        Shell.runPrivileged("/usr/sbin/cupsctl \(enabled ? "--debug-logging" : "--no-debug-logging")")
    }

    static func tail(lines: Int = 400, filter: String? = nil) -> [String] {
        var script = "/usr/bin/tail -n \(lines) \(Paths.cupsErrorLog)"
        if let filter, !filter.isEmpty {
            let safe = filter.replacingOccurrences(of: "'", with: "")
            script += " | /usr/bin/grep -i '\(safe)'"
        }
        // The log is root:_lp 0640, so an ordinary read fails.
        if FileManager.default.isReadableFile(atPath: Paths.cupsErrorLog) {
            return Shell.run("/bin/sh", ["-c", script]).lines
        }
        return Shell.runPrivileged(script).lines
    }

    static func jobLines(jobID: String) -> [String] {
        Shell.runPrivileged("/usr/bin/grep '\\[Job \(jobID)\\]' \(Paths.cupsErrorLog) | /usr/bin/tail -n 300").lines
    }

    /// Highlights the traces `raster-mt800lzo` emits about itself.
    static func classify(_ line: String) -> CheckStatus {
        let l = line.lowercased()
        if l.hasPrefix("e ") || l.contains("filter failed") || l.contains("unable to")
            || l.contains("denied") || l.contains("bad exit") { return .failure }
        if l.hasPrefix("w ") || l.contains("libusb") || l.contains("retry") { return .warning }
        if l.contains("density") || l.contains("papertype") || l.contains("hprt")
            || l.contains("raster-mt800") { return .ok }
        return .unknown
    }
}

// MARK: - Driver installer

enum DriverInstaller {

    struct Plan {
        var dmg: URL
        var model: String
        var queueName: String
        var deviceURI: String
        var density: Int
    }

    /// Builds the same recipe as hprt-install.sh: filters into a writable
    /// directory, PPD rewritten to reference them absolutely, PrintDensity
    /// injected, queue created on the URI CUPS already discovered.
    static func script(for plan: Plan) -> String {
        let base = plan.model.lowercased()
        let ppdOut = "\(Paths.systemPPDDirectory)/\(base)-hprt.ppd"
        return """
        set -e
        TMP=$(mktemp -d -t hprtutil)
        MNT="$TMP/mnt"; mkdir -p "$MNT"
        /usr/bin/hdiutil attach '\(plan.dmg.path)' -nobrowse -readonly -mountpoint "$MNT" -quiet
        PKG=$(/usr/bin/find "$MNT" -name driver.pkg -maxdepth 3 | head -1)
        [ -n "$PKG" ] || { echo "driver.pkg not found in the disk image" >&2; exit 1; }
        /usr/sbin/pkgutil --expand-full "$PKG" "$TMP/pkg" >/dev/null
        FILTER=$(/usr/bin/find "$TMP/pkg" -type f -name 'raster-mt800lzo' | head -1)
        FILTER2=$(/usr/bin/find "$TMP/pkg" -type f -name 'raster-mt800' | head -1)
        PPDSRC=$(/usr/bin/find "$TMP/pkg" -type f -name '\(base).ppd.gz' | head -1)
        [ -n "$PPDSRC" ] || PPDSRC=$(/usr/bin/find "$TMP/pkg" -type f -name 'mt800.ppd.gz' | head -1)
        [ -n "$FILTER" ] && [ -n "$PPDSRC" ] || { echo "filter or PPD missing from the package" >&2; exit 1; }

        /bin/mkdir -p '\(Paths.managedFilterDirectory)'
        /bin/cp "$FILTER" '\(Paths.managedFilterDirectory)/'
        [ -n "$FILTER2" ] && /bin/cp "$FILTER2" '\(Paths.managedFilterDirectory)/'
        /usr/bin/xattr -cr '\(Paths.managedPrefix)'
        /usr/sbin/chown -R root:wheel '\(Paths.managedPrefix)'
        /bin/chmod 755 '\(Paths.managedFilterDirectory)'/raster-mt800*

        /bin/mkdir -p '\(Paths.systemPPDDirectory)'
        /usr/bin/gunzip -c "$PPDSRC" > "$TMP/base.ppd"
        /usr/bin/awk -v filt='\(Paths.managedFilterDirectory)/raster-mt800lzo' -v dens=\(plan.density) '
          BEGIN { injected = 0 }
          /^\\*cupsFilter:/ { print "*cupsFilter: \\"application/vnd.cups-raster 100 " filt "\\""; next }
          /^\\*DefaultPrintDarkness:/ { next }
          /^\\*OpenUI \\*PrintDensity/ { skip = 1 }
          skip == 1 { if ($0 ~ /^\\*CloseUI: \\*PrintDensity/) skip = 0; next }
          /^\\*CloseGroup: General/ && !injected {
            print "*OpenUI *PrintDensity/Print Density: PickOne"
            print "*OrderDependency: 320 AnySetup *PrintDensity"
            print "*DefaultPrintDensity: " dens
            print "*PrintDensity None/Use current printer setting: \\"\\""
            print "*PrintDensity 1/1 - Light: \\"\\""
            print "*PrintDensity 2/2 - Normal: \\"\\""
            print "*PrintDensity 3/3 - Maximum: \\"\\""
            print "*CloseUI: *PrintDensity"
            injected = 1
          }
          { print }
        ' "$TMP/base.ppd" > "$TMP/patched.ppd"
        /usr/bin/grep -q '^\\*DefaultPrintDensity: \(plan.density)' "$TMP/patched.ppd"
        /bin/cp "$TMP/patched.ppd" '\(ppdOut)'
        /usr/sbin/chown root:wheel '\(ppdOut)'; /bin/chmod 644 '\(ppdOut)'

        /usr/sbin/lpadmin -x '\(plan.queueName)' 2>/dev/null || true
        /usr/sbin/lpadmin -p '\(plan.queueName)' -E -v '\(plan.deviceURI)' -P '\(ppdOut)' \
          -o printer-is-shared=false -o PrintDensity=\(plan.density) -o PaperType=1 \
          -D 'HPRT \(plan.model) (managed by HPRT Utility)'
        /usr/sbin/cupsenable '\(plan.queueName)'
        /usr/sbin/cupsaccept '\(plan.queueName)'
        /usr/bin/hdiutil detach "$MNT" -quiet || true
        /bin/rm -rf "$TMP"
        echo "Installed \(plan.model) as queue \(plan.queueName)"
        """
    }

    static func install(_ plan: Plan) -> CommandResult {
        Shell.runPrivileged(script(for: plan))
    }

    static func uninstall(queueName: String?) -> CommandResult {
        var script = "/bin/rm -rf '\(Paths.managedPrefix)'; /bin/rm -f \(Paths.systemPPDDirectory)/mt8*-hprt.ppd"
        if let queueName { script = "/usr/sbin/lpadmin -x '\(queueName)' 2>/dev/null; " + script }
        return Shell.runPrivileged(script)
    }
}
