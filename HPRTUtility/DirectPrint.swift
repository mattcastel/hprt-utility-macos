//
//  DirectPrint.swift
//  HPRT Utility
//
//  A self-contained print path that does not need HPRT's CUPS filter at all.
//
//  It renders a PDF (or image) with CoreGraphics to a 1-bit raster at the
//  printer's dot width, then emits ESC/POS raster-graphics commands (GS v 0) and
//  ships them straight to the device — over the existing USB queue as a raw job,
//  or by writing to the classic-Bluetooth serial port. This is the plan's
//  "Phase 5" native rasteriser, applied to on-demand printing: no PPD, no
//  raster-mt800lzo, no Rosetta.
//

import Foundation
import CoreGraphics
import PDFKit
import AppKit

/// One page reduced to packed 1-bit pixels, MSB first, 1 = burn (black dot).
struct RasterPage: Identifiable {
    let id = UUID()
    let width: Int
    let height: Int
    let bytesPerLine: Int
    let bits: [UInt8]
}

enum DirectPrintService {

    /// The MT800 head is A4-wide at 300 dpi. 2320 dots ≈ 196 mm, a byte-aligned
    /// value just inside the 198 mm printable width the mt800 PPD declares.
    static let defaultWidthDots = 2320
    static let maxPagesDefault = 20

    // MARK: Rendering

    static func render(file url: URL, widthDots: Int, dither: Bool,
                       maxPages: Int = maxPagesDefault) -> (pages: [RasterPage], note: String?) {
        let width = max(8, (widthDots / 8) * 8)   // byte-align the head width
        let ext = url.pathExtension.lowercased()

        if ext == "pdf" || PDFDocument(url: url) != nil {
            return renderPDF(url, width: width, dither: dither, maxPages: maxPages)
        }
        if let page = renderImage(url, width: width, dither: dither) {
            return ([page], nil)
        }
        return ([], "Direct print takes a PDF or an image (PNG, JPEG…). \(url.lastPathComponent) is neither.")
    }

    private static func renderPDF(_ url: URL, width: Int, dither: Bool,
                                  maxPages: Int) -> ([RasterPage], String?) {
        guard let doc = PDFDocument(url: url) else { return ([], "Could not open the PDF.") }
        let total = doc.pageCount
        guard total > 0 else { return ([], "The PDF has no pages.") }

        var pages: [RasterPage] = []
        for index in 0..<min(total, maxPages) {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let scale = CGFloat(width) / bounds.width
            let height = max(1, Int((bounds.height * scale).rounded()))

            guard let ctx = grayContext(width: width, height: height) else { continue }
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            if let raster = pack(ctx, width: width, height: height, dither: dither) {
                pages.append(raster)
            }
        }
        let note = total > maxPages ? "Rendered the first \(maxPages) of \(total) pages." : nil
        return (pages, pages.isEmpty ? "Nothing could be rendered from the PDF." : note)
    }

    private static func renderImage(_ url: URL, width: Int, dither: Bool) -> RasterPage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let scale = CGFloat(width) / CGFloat(image.width)
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let ctx = grayContext(width: width, height: height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pack(ctx, width: width, height: height, dither: dither)
    }

    private static func grayContext(width: Int, height: Int) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)          // white paper
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    /// Threshold or Floyd–Steinberg the grayscale buffer down to packed 1-bit.
    /// A CGBitmapContext stores row 0 at the top of the image, which is the first
    /// line the printer lays down — so no vertical flip is needed.
    private static func pack(_ ctx: CGContext, width: Int, height: Int, dither: Bool) -> RasterPage? {
        guard let base = ctx.data else { return nil }
        let gray = base.bindMemory(to: UInt8.self, capacity: width * height)
        let bytesPerLine = (width + 7) / 8
        var packed = [UInt8](repeating: 0, count: bytesPerLine * height)

        if dither {
            var buf = [Int16](repeating: 0, count: width * height)
            for i in 0..<width * height { buf[i] = Int16(gray[i]) }
            for y in 0..<height {
                let row = y * width
                for x in 0..<width {
                    let i = row + x
                    let old = Int(buf[i])
                    let new = old < 128 ? 0 : 255
                    let err = old - new
                    if new == 0 { packed[y * bytesPerLine + x / 8] |= UInt8(0x80) >> UInt8(x % 8) }
                    if x + 1 < width { buf[i + 1] = clamp(Int(buf[i + 1]) + err * 7 / 16) }
                    if y + 1 < height {
                        if x > 0 { buf[i + width - 1] = clamp(Int(buf[i + width - 1]) + err * 3 / 16) }
                        buf[i + width] = clamp(Int(buf[i + width]) + err * 5 / 16)
                        if x + 1 < width { buf[i + width + 1] = clamp(Int(buf[i + width + 1]) + err / 16) }
                    }
                }
            }
        } else {
            for y in 0..<height {
                let row = y * width
                for x in 0..<width where gray[row + x] < 128 {
                    packed[y * bytesPerLine + x / 8] |= UInt8(0x80) >> UInt8(x % 8)
                }
            }
        }
        return RasterPage(width: width, height: height, bytesPerLine: bytesPerLine, bits: packed)
    }

    private static func clamp(_ v: Int) -> Int16 { Int16(min(255, max(0, v))) }

    // MARK: Preview

    /// A downsampled grayscale image of exactly what will be printed.
    static func preview(_ page: RasterPage, maxWidth: Int = 460) -> CGImage? {
        let step = max(1, page.width / maxWidth)
        let outW = page.width / step, outH = page.height / step
        guard outW > 0, outH > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: outW * outH)
        for y in 0..<outH {
            let srcRow = min(y * step, page.height - 1) * page.bytesPerLine
            for x in 0..<outW {
                let sx = x * step
                let bit = (page.bits[srcRow + sx / 8] >> (7 - UInt8(sx % 8))) & 1
                if bit == 1 { pixels[y * outW + x] = 0 }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: outW, height: outH, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: outW, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: ESC/POS assembly

    /// Builds the byte stream: initialise, set density, then each page as a run
    /// of `GS v 0` raster bands, a small feed between pages, and a final form
    /// feed. Banding keeps every `GS v 0` well inside the firmware's image buffer.
    static func escpos(pages: [RasterPage], density: Int, feedLines: Int = 3,
                       bandHeight: Int = 128) -> Data {
        var out = Data([0x1B, 0x40])                                   // ESC @  initialise
        out.append(contentsOf: [0x1D, 0x28, 0x4B, 0x02, 0x00, 0x31,    // GS ( K fn=49 density
                                UInt8(clamping: density)])
        for (index, page) in pages.enumerated() {
            let bpl = page.bytesPerLine
            var row = 0
            while row < page.height {
                let band = min(bandHeight, page.height - row)
                out.append(contentsOf: [0x1D, 0x76, 0x30, 0x00])       // GS v 0, m = 0
                out.append(contentsOf: [UInt8(bpl & 0xFF), UInt8((bpl >> 8) & 0xFF)])
                out.append(contentsOf: [UInt8(band & 0xFF), UInt8((band >> 8) & 0xFF)])
                out.append(contentsOf: page.bits[(row * bpl)..<((row + band) * bpl)])
                row += band
            }
            if index < pages.count - 1 {
                out.append(contentsOf: [0x1B, 0x64, UInt8(clamping: feedLines)])  // ESC d  feed
            }
        }
        out.append(contentsOf: [0x1B, 0x64, UInt8(clamping: feedLines)])
        out.append(0x0C)                                               // FF  eject page
        return out
    }

    // MARK: Sending

    enum Channel: Equatable {
        case rawQueue(String)        // existing CUPS queue, printed with -o raw (USB, no admin)
        case serial(String)          // /dev/cu.* Bluetooth SPP port (no admin)

        var label: String {
            switch self {
            case .rawQueue(let q): return "USB · queue “\(q)” (raw)"
            case .serial(let p):   return "Bluetooth · \(p)"
            }
        }
    }

    static func send(_ data: Data, over channel: Channel) -> CommandResult {
        switch channel {
        case .rawQueue(let queue): return PrintService.printRaw(queue: queue, data: data)
        case .serial(let path):    return PrintService.writeSerial(path: path, data: data)
        }
    }
}
