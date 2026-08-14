//
//  RasterInspector.swift
//  HPRT Utility
//
//  Runs a document through the macOS half of the print pipeline and looks at
//  what comes out, *before* the HPRT filter ever sees it.
//
//  This is the single most useful diagnostic for a page that ejects blank:
//  if the raster CUPS produces already has no ink, the vendor driver is
//  innocent and the fault lies in the macOS PDF/text rasteriser.
//

import Foundation
import CoreGraphics
import AppKit

enum RasterInspector {

    static func analyse(file: URL, ppdPath: String, renderPreview: Bool = true) -> RasterAnalysis {
        var analysis = RasterAnalysis()

        // A raster stream is binary; it must never travel through String.
        let (data, result) = Shell.runData("/usr/sbin/cupsfilter",
                                           ["-p", ppdPath,
                                            "-m", "application/vnd.cups-raster",
                                            "-e", file.path],
                                           timeout: 120)
        guard data.count > 16 else {
            analysis.note = result.err.isEmpty
                ? "cupsfilter produced no raster data."
                : "cupsfilter failed: \(result.err)"
            return analysis
        }
        return parse(data, renderPreview: renderPreview)
    }

    /// Same as `analyse`, but reads a raster file straight from disk.
    static func analyse(rasterFile: URL, renderPreview: Bool = true) -> RasterAnalysis {
        guard let data = try? Data(contentsOf: rasterFile) else {
            var a = RasterAnalysis(); a.note = "Could not read \(rasterFile.lastPathComponent)"; return a
        }
        return parse(data, renderPreview: renderPreview)
    }

    // MARK: Parsing

    static func parse(_ data: Data, renderPreview: Bool) -> RasterAnalysis {
        var analysis = RasterAnalysis()
        analysis.totalBytes = data.count
        analysis.inkBytes = data.reduce(into: 0) { partial, byte in if byte != 0 { partial += 1 } }

        guard data.count >= 4 else {
            analysis.note = "Too short to be a CUPS raster stream."
            return analysis
        }

        let magic = String(decoding: data.prefix(4), as: UTF8.self)
        let littleEndian: Bool
        let headerSize: Int

        switch magic {
        case "RaSt": littleEndian = false; headerSize = 420;  analysis.version = "v1"; analysis.compressed = false
        case "tSaR": littleEndian = true;  headerSize = 420;  analysis.version = "v1"; analysis.compressed = false
        case "RaS2": littleEndian = false; headerSize = 1796; analysis.version = "v2"; analysis.compressed = true
        case "2SaR": littleEndian = true;  headerSize = 1796; analysis.version = "v2"; analysis.compressed = true
        case "RaS3": littleEndian = false; headerSize = 1796; analysis.version = "v3"; analysis.compressed = false
        case "3SaR": littleEndian = true;  headerSize = 1796; analysis.version = "v3"; analysis.compressed = false
        default:
            analysis.note = "Unrecognised magic “\(magic)”. This is not a CUPS raster stream."
            return analysis
        }

        analysis.byteOrder = littleEndian ? "little-endian" : "big-endian"
        analysis.headerBytes = headerSize

        guard data.count >= 4 + headerSize else {
            analysis.note = "Header truncated — the filter chain stopped early."
            return analysis
        }

        func word(_ offsetInHeader: Int) -> Int {
            let base = 4 + offsetInHeader
            guard base + 4 <= data.count else { return 0 }
            let bytes = [UInt8](data[base..<(base + 4)])
            let value: UInt32 = littleEndian
                ? UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                : UInt32(bytes[3]) | UInt32(bytes[2]) << 8 | UInt32(bytes[1]) << 16 | UInt32(bytes[0]) << 24
            return Int(value)
        }

        analysis.resolution = (word(276), word(280))
        analysis.width = word(372)
        analysis.height = word(376)
        analysis.bitsPerColor = word(384)
        analysis.bitsPerPixel = word(388)
        analysis.bytesPerLine = word(392)
        analysis.colorSpace = word(400)
        analysis.colorSpaceName = colorSpaceName(analysis.colorSpace)
        analysis.pages = 1

        if renderPreview, analysis.width > 0, analysis.height > 0, analysis.bytesPerLine > 0 {
            let payload = data.subdata(in: (4 + headerSize)..<data.count)
            let lines = analysis.compressed
                ? decodeRLE(payload,
                            bytesPerLine: analysis.bytesPerLine,
                            height: analysis.height,
                            bitsPerPixel: max(1, analysis.bitsPerPixel))
                : rawLines(payload, bytesPerLine: analysis.bytesPerLine, height: analysis.height)

            if let lines {
                analysis.preview = image(from: lines, analysis: analysis)
            } else {
                analysis.note = "Raster decoded partially — preview unavailable."
            }
        }
        return analysis
    }

    private static func colorSpaceName(_ raw: Int) -> String {
        switch raw {
        case 0: return "W (luminance, 0 = black)"
        case 1: return "RGB"
        case 3: return "K (black, 0 = white)"
        case 6: return "CMYK"
        default: return "code \(raw)"
        }
    }

    // MARK: Line decoding

    private static func rawLines(_ payload: Data, bytesPerLine: Int, height: Int) -> [[UInt8]]? {
        guard bytesPerLine > 0 else { return nil }
        var lines: [[UInt8]] = []
        lines.reserveCapacity(min(height, 5000))
        var offset = 0
        while offset + bytesPerLine <= payload.count && lines.count < height {
            let start = payload.startIndex + offset
            lines.append([UInt8](payload[start..<(start + bytesPerLine)]))
            offset += bytesPerLine
        }
        return lines.isEmpty ? nil : lines
    }

    /// CUPS raster v2 run-length encoding.
    /// Per line: a repeat count byte, then runs until bytesPerLine is filled.
    /// A run byte < 128 repeats the next pixel (count+1) times; a run byte
    /// >= 128 introduces (257 - byte) literal pixels.
    private static func decodeRLE(_ payload: Data, bytesPerLine: Int, height: Int,
                                  bitsPerPixel: Int) -> [[UInt8]]? {
        let pixelBytes = max(1, bitsPerPixel / 8)
        var lines: [[UInt8]] = []
        var index = payload.startIndex

        func byte() -> UInt8? {
            guard index < payload.endIndex else { return nil }
            defer { index = payload.index(after: index) }
            return payload[index]
        }

        while lines.count < height {
            guard let repeatByte = byte() else { break }
            let repeats = Int(repeatByte) + 1

            var line = [UInt8]()
            line.reserveCapacity(bytesPerLine)
            var guardCounter = 0

            while line.count < bytesPerLine {
                guardCounter += 1
                if guardCounter > bytesPerLine + 16 { return lines.isEmpty ? nil : pad(lines, height: height, bytesPerLine: bytesPerLine) }
                guard let control = byte() else {
                    return lines.isEmpty ? nil : pad(lines, height: height, bytesPerLine: bytesPerLine)
                }
                if control < 128 {
                    var pixel = [UInt8]()
                    for _ in 0..<pixelBytes { pixel.append(byte() ?? 0) }
                    for _ in 0...Int(control) where line.count < bytesPerLine {
                        line.append(contentsOf: pixel.prefix(min(pixelBytes, bytesPerLine - line.count)))
                    }
                } else {
                    let literalPixels = 257 - Int(control)
                    for _ in 0..<literalPixels where line.count < bytesPerLine {
                        for _ in 0..<pixelBytes where line.count < bytesPerLine {
                            line.append(byte() ?? 0)
                        }
                    }
                }
            }
            if line.count < bytesPerLine {
                line.append(contentsOf: [UInt8](repeating: 0, count: bytesPerLine - line.count))
            }
            for _ in 0..<repeats where lines.count < height { lines.append(line) }
        }
        return lines.isEmpty ? nil : lines
    }

    private static func pad(_ lines: [[UInt8]], height: Int, bytesPerLine: Int) -> [[UInt8]] {
        var out = lines
        while out.count < height { out.append([UInt8](repeating: 0, count: bytesPerLine)) }
        return out
    }

    // MARK: Preview rendering

    private static func image(from lines: [[UInt8]], analysis: RasterAnalysis) -> CGImage? {
        let width = analysis.width
        let height = min(analysis.height, lines.count)
        guard width > 0, height > 0 else { return nil }

        // Keep the preview manageable: an A4 page at 300 dpi is 2480 px wide.
        let step = max(1, width / 900)
        let outWidth = width / step
        let outHeight = height / step
        guard outWidth > 0, outHeight > 0 else { return nil }

        var pixels = [UInt8](repeating: 255, count: outWidth * outHeight)
        let inverted = (analysis.colorSpace == 3 || analysis.colorSpace == 6)   // K: 0 = white

        for y in 0..<outHeight {
            let line = lines[min(y * step, lines.count - 1)]
            for x in 0..<outWidth {
                let sourceX = x * step
                var level: UInt8 = 255
                if analysis.bitsPerColor == 1 {
                    let byteIndex = sourceX / 8
                    guard byteIndex < line.count else { continue }
                    let bit = (line[byteIndex] >> (7 - UInt8(sourceX % 8))) & 1
                    level = bit == 1 ? (inverted ? 0 : 255) : (inverted ? 255 : 0)
                } else {
                    guard sourceX < line.count else { continue }
                    let raw = line[sourceX]
                    level = inverted ? 255 &- raw : raw
                }
                pixels[y * outWidth + x] = level
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: outWidth,
                       height: outHeight,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: outWidth,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // MARK: Filter chain

    static func filterChain(for file: URL, ppdPath: String) -> [String] {
        Shell.cupsfilter(["--list-filters", "-p", ppdPath,
                          "-m", "application/vnd.cups-raster", file.path], timeout: 30).lines
    }
}
