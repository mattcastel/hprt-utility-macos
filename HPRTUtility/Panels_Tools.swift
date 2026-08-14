//
//  Panels_Tools.swift
//  HPRT Utility
//

import SwiftUI

// MARK: - ESC/POS console

struct ConsolePanel: View {
    @EnvironmentObject private var state: AppState

    @State private var selectedCommand: ESCPOSCommand = ESCPOS.library[0]
    @State private var parameter: Int = 0
    @State private var customHex = ""
    @State private var transcript: [String] = []
    @State private var sending = false

    private var payload: Data {
        if !customHex.trimmingCharacters(in: .whitespaces).isEmpty {
            return Self.parseHex(customHex)
        }
        return Data(selectedCommand.encoded(parameter: selectedCommand.parameterName == nil ? nil : parameter))
    }

    var body: some View {
        PanelScaffold(title: "ESC/POS Console",
                      subtitle: "Speak to the printer directly, with no rasteriser and no filter in the way.") {

            Card(title: "How these opcodes were obtained", systemImage: "doc.text.magnifyingglass") {
                Text("""
                Every command below was recovered by disassembling raster-mt800lzo, the filter inside HPRT's own \
                macOS driver, and reading the exact bytes each routine emits. They are therefore what this printer \
                family actually understands, not a guess from a generic ESC/POS table.

                One caveat worth keeping in mind: an A4 raster printer often has no built-in fonts. Text sent this \
                way may advance the paper and mark nothing — that is the printer having nothing to draw, not a fault. \
                Use the solid black band below for an honest darkness test.
                """)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Card(title: "Command library", systemImage: "list.bullet.rectangle.portrait") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ESCPOS.library) { command in
                        Button {
                            selectedCommand = command
                            parameter = command.parameterDefault
                            customHex = ""
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selectedCommand.id == command.id
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selectedCommand.id == command.id ? Color.accentColor : .secondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(command.name).font(.callout.weight(.medium))
                                        if command.expectsReply {
                                            StatusChip(status: .warning, text: "expects a reply")
                                        }
                                    }
                                    Text(command.summary)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("\(command.hex)   ·   \(command.origin)")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        if command.id != ESCPOS.library.last?.id { Divider().opacity(0.35) }
                    }
                }
            }

            Card(title: "Payload", systemImage: "chevron.left.forwardslash.chevron.right") {
                VStack(alignment: .leading, spacing: 14) {
                    if let name = selectedCommand.parameterName, let range = selectedCommand.parameterRange {
                        HStack(spacing: 12) {
                            Text(name).foregroundStyle(.secondary).frame(width: 240, alignment: .leading)
                            Stepper(value: $parameter, in: range) {
                                Text("\(parameter)")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 44, alignment: .leading)
                            }
                            Spacer()
                        }
                    }

                    HStack(spacing: 12) {
                        Text("Custom hex").foregroundStyle(.secondary).frame(width: 240, alignment: .leading)
                        TextField("1B 40 1D 28 4B 02 00 31 03", text: $customHex)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("Anything typed here overrides the selection above.")
                        .font(.caption).foregroundStyle(.secondary)

                    Divider().opacity(0.4)

                    HStack(alignment: .top) {
                        Text("Bytes to send").foregroundStyle(.secondary).frame(width: 240, alignment: .leading)
                        Text(payload.isEmpty ? "—" : payload.hexPreview)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 10) {
                        Button {
                            send(payload)
                        } label: {
                            if sending {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…") }
                            } else {
                                Label("Send raw", systemImage: "paperplane.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(payload.isEmpty || deviceURI == nil || sending)

                        Button {
                            send(ESCPOS.solidBlackBand(density: 3), label: "solid black band")
                        } label: {
                            Label("Solid black band", systemImage: "square.fill")
                        }
                        .disabled(deviceURI == nil || sending)
                        .help("Fills a strip with every dot on, at maximum density. The honest darkness test.")

                        Button {
                            var data = Data([0x1B, 0x40])
                            data.append(contentsOf: [0x1D, 0x28, 0x4B, 0x02, 0x00, 0x31, 0x03])
                            data.append(contentsOf: [0x1B, 0x64, 0x03])
                            data.append(0x0C)
                            send(data, label: "reset + density 3 + eject")
                        } label: {
                            Label("Reset & eject", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(deviceURI == nil || sending)

                        Spacer()
                    }

                    if deviceURI == nil {
                        Text("No device URI available — connect the printer and refresh.")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Sent through a temporary raw CUPS queue on \(deviceURI!). Administrator rights required.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if selectedCommand.expectsReply {
                Card(title: "About replies", systemImage: "arrow.uturn.left") {
                    Text("""
                    This command asks the printer to answer. A raw CUPS queue is write-only, so the reply cannot be \
                    read here. Reading it needs a bidirectional channel — libusb over USB, or a notify characteristic \
                    over BLE. That is the route to a real battery reading, and it is the next thing worth building.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !transcript.isEmpty {
                Card(title: "Transcript", systemImage: "text.alignleft") {
                    MonoLog(lines: transcript, maxHeight: 200)
                }
            }
        }
    }

    private var deviceURI: String? {
        state.selectedQueue?.deviceURI
            ?? state.cupsDevices.first?.split(separator: " ").last.map(String.init)
    }

    private func send(_ data: Data, label: String? = nil) {
        guard let uri = deviceURI, !data.isEmpty else { return }
        sending = true
        let stamp = Date().formatted(date: .omitted, time: .standard)
        transcript.insert("[\(stamp)] → \(label ?? data.hexPreview)", at: 0)

        Task.detached(priority: .userInitiated) {
            let result = PrintService.sendRaw(data, deviceURI: uri)
            await MainActor.run {
                sending = false
                let line = result.ok ? "queued (\(data.count) bytes)"
                                     : "failed: \(result.err.isEmpty ? "unknown error" : result.err)"
                transcript.insert("[\(Date().formatted(date: .omitted, time: .standard))] ← \(line)", at: 0)
                state.log("Raw send: \(line)", result.ok ? .ok : .failure)
            }
        }
    }

    static func parseHex(_ text: String) -> Data {
        let cleaned = text
            .replacingOccurrences(of: "0x", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: " ")
        var bytes: [UInt8] = []
        for token in cleaned.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if let value = UInt8(token, radix: 16) { bytes.append(value) }
        }
        return Data(bytes)
    }
}

// MARK: - CUPS log

struct LogPanel: View {
    @EnvironmentObject private var state: AppState

    @State private var lines: [String] = []
    @State private var filter = ""
    @State private var level = "unknown"
    @State private var loading = false
    @State private var autoRefresh = false
    @State private var timer: Timer?

    private let presets = ["", "hprt", "density", "raster-mt800", "libusb", "Filter failed", "E ["]

    var body: some View {
        PanelScaffold(title: "CUPS Log",
                      subtitle: "The only place that says what really happened to a job.") {

            Card(title: "Logging level", systemImage: "dial.medium") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Text("Current").foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        Text(level).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Enable debug logging") { setLevel(true) }
                            .disabled(level == "debug")
                        Button("Back to normal") { setLevel(false) }
                            .disabled(level != "debug")
                    }
                    Text("""
                    The HPRT filter writes its own traces — “papertype = …”, “density = …”, \
                    “+printer_set_density(...) start.” — but only at debug level. If those lines never appear while \
                    debug logging is on, the filter was never executed at all.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card(title: "Filter", systemImage: "line.3.horizontal.decrease.circle") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        TextField("Search the log…", text: $filter)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            reload()
                        } label: {
                            if loading {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Read log", systemImage: "arrow.clockwise")
                            }
                        }
                        Toggle("Auto", isOn: $autoRefresh)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: autoRefresh) { _, on in
                                if on { startTimer() } else { stopTimer() }
                            }
                    }
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { preset in
                            Button(preset.isEmpty ? "All" : preset) {
                                filter = preset
                                reload()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Spacer()
                    }
                }
            }

            Card(title: "\(Paths.cupsErrorLog)",
                 subtitle: lines.isEmpty ? "Nothing loaded yet" : "\(lines.count) lines",
                 systemImage: "doc.plaintext") {
                if lines.isEmpty {
                    EmptyHint(symbol: "doc.text.magnifyingglass",
                              title: "Log not loaded",
                              message: "The CUPS log is readable by root only, so the first read asks for your password.")
                } else {
                    MonoLog(lines: lines, colorise: LogService.classify, maxHeight: 460)
                }
            }
        }
        .onAppear { level = LogService.logLevel() }
        .onDisappear { stopTimer() }
    }

    private func setLevel(_ debug: Bool) {
        Task.detached(priority: .userInitiated) {
            _ = LogService.setDebugLogging(debug)
            let current = LogService.logLevel()
            await MainActor.run {
                level = current
                state.log("CUPS log level is now \(current).", .ok)
            }
        }
    }

    private func reload() {
        loading = true
        let needle = filter
        Task.detached(priority: .userInitiated) {
            let result = LogService.tail(lines: 600, filter: needle.isEmpty ? nil : needle)
            await MainActor.run {
                lines = result.reversed()
                loading = false
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in reload() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
