//
//  Panels_Printing.swift
//  HPRT Utility
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Print

struct PrintPanel: View {
    @EnvironmentObject private var state: AppState

    @State private var document: URL?
    @State private var density = 3
    @State private var paperType = "1"
    @State private var autoFeed = true
    @State private var isDropTarget = false
    @State private var submitting = false
    @State private var message: (CheckStatus, String)?

    // Direct raster print (native rasteriser, no HPRT driver needed)
    @State private var directWidth = DirectPrintService.defaultWidthDots
    @State private var directDither = true
    @State private var directAllPages = false
    @State private var directPreview: CGImage?
    @State private var directBusy = false
    @State private var directResult: (CheckStatus, String)?

    var body: some View {
        PanelScaffold(title: "Print",
                      subtitle: "Send a document at full ink, and watch what the queue does with it.") {

            dropZone

            Card(title: "Options", systemImage: "slider.horizontal.3") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        Text("Ink density").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: $density) {
                                Text("1 — Light").tag(1)
                                Text("2 — Normal").tag(2)
                                Text("3 — Maximum").tag(3)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 340)
                            Text("Passed as -o PrintDensity=\(density). The filter turns this into GS ( K fn=49.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Paper type").foregroundStyle(.secondary)
                        Picker("", selection: $paperType) {
                            Text("A4 sheet").tag("1")
                            Text("Continuous").tag("0")
                            Text("Black marks").tag("2")
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    GridRow {
                        Text("After printing").foregroundStyle(.secondary)
                        Toggle("Feed the page out automatically", isOn: $autoFeed)
                            .toggleStyle(.checkbox)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    if let document { submit(document) }
                } label: {
                    if submitting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…") }
                    } else {
                        Label("Print", systemImage: "printer.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(document == nil || state.selectedQueue == nil || submitting)

                Button {
                    printTestPage()
                } label: {
                    Label("Print built-in test page", systemImage: "doc.text.image")
                }
                .controlSize(.large)
                .disabled(state.selectedQueue == nil || submitting)

                Spacer()

                if let queue = state.selectedQueue {
                    Text("→ \(queue.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let message {
                HStack(spacing: 8) {
                    StatusChip(status: message.0, compact: true)
                    Text(message.1).font(.callout).textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(message.0.tint.opacity(0.10)))
            }

            directPrintCard

            if !state.jobs.isEmpty {
                Card(title: "Recent jobs", systemImage: "clock") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.jobs.prefix(10)) { job in
                            HStack(spacing: 10) {
                                StatusChip(status: job.finished ? .ok : .pending, compact: true)
                                Text("#\(job.jobID)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 54, alignment: .leading)
                                Text(job.file).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("density \(job.density)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(job.submitted.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Card(title: "If the page comes out blank",
                 subtitle: "Read this before blaming the driver",
                 systemImage: "lightbulb") {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Open the Raster Lab and analyse the same file. If the raster carries no ink, the page was already blank before the HPRT filter ever saw it — the fault is in the macOS rasteriser, not the driver.")
                    bullet("Plain text files are the weakest path on modern macOS. A PDF goes through a far better maintained chain. Always compare with a PDF before drawing conclusions.")
                    bullet("Check the CUPS Log panel for lines containing “density” or “papertype”. The HPRT filter prints those itself, so their absence means the filter never ran.")
                    bullet("On Apple Silicon the filter is x86_64 and runs under Rosetta. If Rosetta is missing, cupsd fails silently and the page ejects blank.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: document == nil ? "arrow.down.doc" : "doc.fill")
                .font(.system(size: 32))
                .foregroundStyle(document == nil ? Color.secondary : Color.accentColor)
            if let document {
                Text(document.lastPathComponent).font(.headline)
                Text(document.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("Drop a document here").font(.headline)
                Text("PDF, PNG, JPEG or plain text").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Choose file…") { pickFile() }
                if document != nil {
                    Button("Clear") { document = nil; message = nil }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor : Color.primary.opacity(0.12),
                              style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1, dash: [7, 5]))
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                if let url {
                    DispatchQueue.main.async { document = url; message = nil }
                }
            }
            return true
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .plainText, .rtf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { document = panel.url; message = nil }
    }

    private func submit(_ document: URL) {
        guard let queue = state.selectedQueue else { return }
        submitting = true
        message = nil
        // Read the main-actor UI state once, here, so the detached task captures
        // plain values instead of reaching back onto the main actor for them.
        let density = density
        let paperType = paperType
        let autoFeed = autoFeed
        Task.detached(priority: .userInitiated) {
            let (result, jobID) = PrintService.submit(file: document, queue: queue.name,
                                                      density: density, paperType: paperType,
                                                      postPrintAction: autoFeed)
            await MainActor.run {
                submitting = false
                if result.ok {
                    message = (.ok, "Submitted as job \(jobID ?? "?"). \(result.out)")
                    state.jobs.insert(PrintJobRecord(jobID: jobID ?? "?",
                                                     file: document.lastPathComponent,
                                                     queue: queue.name,
                                                     submitted: Date(),
                                                     density: "\(density)"), at: 0)
                    state.log("Printed \(document.lastPathComponent) at density \(density).", .ok)
                } else {
                    message = (.failure, result.err.isEmpty ? "lp refused the job." : result.err)
                    state.log("Print failed: \(result.err)", .failure)
                }
                state.refreshAll()
            }
        }
    }

    private func printTestPage() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hprt-test-page.txt")
        let body = """
        HPRT Utility — test page
        Generated \(Date().formatted())
        Queue     : \(state.selectedQueue?.name ?? "?")
        Transport : \(state.selectedQueue?.transport.rawValue ?? "?")
        Density   : \(density) of 3

        Darkness ramp
        ################################################
        ################################################
        ||||||||||||||||||||||||||||||||||||||||||||||||
        abcdefghijklmnopqrstuvwxyz 0123456789
        """
        try? body.write(to: url, atomically: true, encoding: .utf8)
        document = url
        submit(url)
    }

    // MARK: Direct raster print (no driver required)

    /// Which channel a direct print would use, given what is connected right now.
    private var directChannel: DirectPrintService.Channel? {
        if !state.usb.devices.isEmpty, let q = state.selectedQueue?.name { return .rawQueue(q) }
        if let port = state.btClassic.first(where: { $0.isPrinter })?.primarySerialPort { return .serial(port) }
        if let q = state.selectedQueue?.name { return .rawQueue(q) }
        return nil
    }

    @ViewBuilder
    private var directPrintCard: some View {
        Card(title: "Direct raster print",
             subtitle: "Renders the page here and sends it as ESC/POS — bypasses the HPRT filter and Rosetta entirely",
             systemImage: "bolt.badge.automatic") {
            VStack(alignment: .leading, spacing: 14) {
                Text("""
                This path does not use the CUPS driver. The PDF is rasterised to 1-bit at the printer's dot width \
                and shipped straight to the device, so it works even with no HPRT filter installed. Use it when a \
                normal print comes out blank or fails.
                """)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Text("Head width").foregroundStyle(.secondary)
                        Picker("", selection: $directWidth) {
                            Text("A4 full — 2320 dots (196 mm)").tag(2320)
                            Text("Narrow — 1728 dots (146 mm)").tag(1728)
                            Text("Receipt — 576 dots (48 mm)").tag(576)
                        }
                        .labelsHidden().frame(width: 300)
                    }
                    GridRow {
                        Text("Rendering").foregroundStyle(.secondary)
                        HStack(spacing: 18) {
                            Toggle("Dither (grayscale & photos)", isOn: $directDither).toggleStyle(.checkbox)
                            Toggle("All pages", isOn: $directAllPages).toggleStyle(.checkbox)
                        }
                    }
                    GridRow {
                        Text("Sends over").foregroundStyle(.secondary)
                        Text(directChannel?.label ?? "No reachable channel — connect USB or pair over Bluetooth")
                            .font(.callout)
                            .foregroundStyle(directChannel == nil ? .orange : .secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        directPreviewRender()
                    } label: { Label("Preview", systemImage: "eye") }
                        .disabled(document == nil || directBusy)

                    Button {
                        directPrint()
                    } label: {
                        if directBusy {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working…") }
                        } else {
                            Label("Print directly", systemImage: "bolt.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(document == nil || directChannel == nil || directBusy)

                    Spacer()
                    Text("Density \(density) · from the picker above")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let directResult {
                    HStack(spacing: 8) {
                        StatusChip(status: directResult.0, compact: true)
                        Text(directResult.1).font(.callout).textSelection(.enabled)
                    }
                }

                if let directPreview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Exactly what the printer receives")
                            .font(.caption).foregroundStyle(.secondary)
                        Image(decorative: directPreview, scale: 1.0)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 300, maxHeight: 420)
                            .background(Color.white)
                            .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.15)))
                    }
                }
            }
        }
    }

    private func directPreviewRender() {
        guard let document else { return }
        directBusy = true; directResult = nil
        let width = directWidth, dither = directDither
        Task.detached(priority: .userInitiated) {
            let (pages, note) = DirectPrintService.render(file: document, widthDots: width,
                                                          dither: dither, maxPages: 1)
            let image = pages.first.flatMap { DirectPrintService.preview($0) }
            await MainActor.run {
                directBusy = false
                directPreview = image
                if pages.isEmpty { directResult = (.failure, note ?? "Nothing could be rendered.") }
                else { directResult = (.ok, note ?? "Preview of page 1 at \(width) dots wide.") }
            }
        }
    }

    private func directPrint() {
        guard let document, let channel = directChannel else { return }
        directBusy = true; directResult = nil
        let width = directWidth, dither = directDither, density = density
        let limit = directAllPages ? DirectPrintService.maxPagesDefault : 1
        let name = document.lastPathComponent
        Task.detached(priority: .userInitiated) {
            let (pages, note) = DirectPrintService.render(file: document, widthDots: width,
                                                          dither: dither, maxPages: limit)
            guard !pages.isEmpty else {
                await MainActor.run { directBusy = false; directResult = (.failure, note ?? "Render produced no pages.") }
                return
            }
            let data = DirectPrintService.escpos(pages: pages, density: density)
            let result = DirectPrintService.send(data, over: channel)
            let firstPreview = DirectPrintService.preview(pages[0])
            await MainActor.run {
                directBusy = false
                directPreview = firstPreview
                if result.ok {
                    let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                    directResult = (.ok, "Sent \(pages.count) page(s), \(size) over \(channel.label).")
                    state.jobs.insert(PrintJobRecord(jobID: "direct", file: name, queue: channel.label,
                                                     submitted: Date(), density: "\(density)"), at: 0)
                    state.log("Direct raster print: \(name) → \(channel.label).", .ok)
                } else {
                    directResult = (.failure, result.err.isEmpty ? "Send failed." : result.err)
                    state.log("Direct print failed: \(result.err)", .failure)
                }
            }
        }
    }
}

// MARK: - Raster Lab

struct RasterLabPanel: View {
    @EnvironmentObject private var state: AppState

    @State private var document: URL?
    @State private var analysis: RasterAnalysis?
    @State private var chain: [String] = []
    @State private var working = false

    var body: some View {
        PanelScaffold(title: "Raster Lab",
                      subtitle: "See exactly what macOS hands to the HPRT filter — before any paper moves.") {

            Card(title: "Why this matters", systemImage: "questionmark.circle") {
                Text("""
                A page that ejects blank has two very different explanations. Either the raster CUPS produced was \
                already empty — a macOS rasteriser problem, nothing to do with HPRT — or the raster was fine and \
                something after it went wrong. This panel runs the document through the real PPD, counts the ink, \
                and draws the page as the driver will receive it.
                """)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button {
                    pickFile()
                } label: {
                    Label(document == nil ? "Choose a document…" : "Change document…", systemImage: "doc")
                }
                if let document {
                    Text(document.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button {
                    analyse()
                } label: {
                    if working {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Rendering…") }
                    } else {
                        Label("Analyse", systemImage: "wand.and.rays")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(document == nil || state.selectedQueue == nil || working)
            }

            if let analysis {
                let (status, verdict) = analysis.verdict
                HeadlineBanner(status: status,
                               title: analysis.looksBlank ? "Blank raster" : "Raster carries ink",
                               detail: verdict)

                HStack(alignment: .top, spacing: 18) {
                    Card(title: "Raster header", systemImage: "tablecells") {
                        VStack(alignment: .leading, spacing: 7) {
                            KeyValueRow(key: "Format", value: "CUPS Raster \(analysis.version), \(analysis.byteOrder)")
                            KeyValueRow(key: "Compression", value: analysis.compressed ? "RLE (v2)" : "none")
                            KeyValueRow(key: "Page size", value: "\(analysis.width) × \(analysis.height) px")
                            KeyValueRow(key: "Resolution", value: "\(analysis.resolution.0) × \(analysis.resolution.1) dpi")
                            KeyValueRow(key: "Bits per colour", value: "\(analysis.bitsPerColor)")
                            KeyValueRow(key: "Bits per pixel", value: "\(analysis.bitsPerPixel)")
                            KeyValueRow(key: "Bytes per line", value: "\(analysis.bytesPerLine)")
                            KeyValueRow(key: "Colour space", value: analysis.colorSpaceName)
                            Divider().opacity(0.4)
                            KeyValueRow(key: "Stream size",
                                        value: ByteCountFormatter.string(fromByteCount: Int64(analysis.totalBytes), countStyle: .file))
                            KeyValueRow(key: "Non-zero bytes",
                                        value: String(format: "%d  (%.3f%%)", analysis.inkBytes, analysis.inkRatio * 100))
                        }
                    }

                    Card(title: "Page preview",
                         subtitle: "Rendered from the raster itself, not from the source file",
                         systemImage: "eye") {
                        if let preview = analysis.preview {
                            Image(decorative: preview, scale: 1.0)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 300, maxHeight: 420)
                                .background(Color.white)
                                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.15)))
                        } else {
                            EmptyHint(symbol: "photo",
                                      title: "No preview",
                                      message: analysis.note ?? "The raster could not be decoded into an image.")
                        }
                    }
                    .frame(width: 340)
                }

                if analysis.bitsPerColor == 1 {
                    Card(title: "Note on the MT8003 PPD", systemImage: "exclamationmark.bubble") {
                        Text("""
                        This PPD asks for 1 bit per pixel, while the MT800 PPD in the same package asks for 8. \
                        If the page is blank but this preview is not, that mismatch is the first thing to test: \
                        try the mt800 PPD on the same hardware and compare.
                        """)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !chain.isEmpty {
                Card(title: "Filter chain", subtitle: "The programs macOS runs, in order", systemImage: "arrow.right.circle") {
                    MonoLog(lines: chain, maxHeight: 120)
                }
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { document = panel.url; analysis = nil; chain = [] }
    }

    private func analyse() {
        guard let document, let queue = state.selectedQueue else { return }
        working = true
        Task.detached(priority: .userInitiated) {
            let result = RasterInspector.analyse(file: document, ppdPath: queue.ppdPath)
            let filters = RasterInspector.filterChain(for: document, ppdPath: queue.ppdPath)
            await MainActor.run {
                analysis = result
                chain = filters
                working = false
                state.log("Raster analysed: \(result.inkBytes) non-zero bytes of \(result.totalBytes).",
                          result.looksBlank ? .failure : .ok)
            }
        }
    }
}
