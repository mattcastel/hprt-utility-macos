//
//  Core.swift
//  HPRT Utility
//
//  Process execution helpers. Everything this app knows about the system is
//  gathered either through IOKit / CoreBluetooth or through these commands.
//

import Foundation

struct CommandResult {
    let command: String
    let status: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { status == 0 }
    var out: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    var err: String { stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
    var lines: [String] { out.components(separatedBy: .newlines).filter { !$0.isEmpty } }

    static func failed(_ command: String, _ message: String) -> CommandResult {
        CommandResult(command: command, status: -1, stdout: "", stderr: message)
    }
}

enum Shell {

    /// Runs a command and captures both streams. Reads concurrently so large
    /// outputs (ioreg, system_profiler) cannot deadlock the pipe buffer.
    @discardableResult
    static func run(_ path: String,
                    _ arguments: [String] = [],
                    stdin input: Data? = nil,
                    timeout: TimeInterval = 30) -> CommandResult {

        let display = ([path] + arguments).joined(separator: " ")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .failed(display, "not executable: \(path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if input != nil { process.standardInput = inPipe }

        var outData = Data(), errData = Data()
        let lock = NSLock()
        let group = DispatchGroup()

        func drain(_ pipe: Pipe, into sink: @escaping (Data) -> Void) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); sink(d); lock.unlock()
                group.leave()
            }
        }

        do {
            try process.run()
        } catch {
            return .failed(display, error.localizedDescription)
        }

        drain(outPipe) { outData = $0 }
        drain(errPipe) { errData = $0 }

        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            return .failed(display, "timed out after \(Int(timeout))s")
        }

        _ = group.wait(timeout: .now() + 5)

        return CommandResult(command: display,
                             status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Runs a command and returns stdout as raw bytes. Required for anything
    /// binary — a CUPS raster stream does not survive a round trip through String.
    static func runData(_ path: String, _ arguments: [String], timeout: TimeInterval = 90) -> (Data, CommandResult) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hprt-out-\(UUID().uuidString.prefix(8)).bin")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let quoted = ([path] + arguments)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let result = run("/bin/sh", ["-c", "\(quoted) > '\(scratch.path)'"], timeout: timeout)
        let data = (try? Data(contentsOf: scratch)) ?? Data()
        return (data, result)
    }

    /// Runs a shell script as root through the standard authorisation dialog.
    ///
    /// The script is written to a temporary file first: AppleScript string
    /// literals cannot contain raw newlines, so passing a multi-line script
    /// inline to `do shell script` would break as soon as it stops being a
    /// one-liner.
    @discardableResult
    static func runPrivileged(_ script: String) -> CommandResult {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hprt-priv-\(UUID().uuidString.prefix(8)).sh")
        do {
            try ("#!/bin/bash\n" + script + "\n").write(to: scratch, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
        } catch {
            return .failed(script, "Could not stage the script: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let apple = "do shell script \"/bin/bash \(scratch.path)\" with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", apple], timeout: 600)
        if !result.ok, result.stderr.contains("-128") {
            return .failed(script, "Cancelled by the user.")
        }
        return result
    }

    /// Convenience wrappers for the binaries this app relies on.
    static func lpstat(_ args: [String]) -> CommandResult { run("/usr/bin/lpstat", args) }
    static func lpoptions(_ args: [String]) -> CommandResult { run("/usr/bin/lpoptions", args) }
    static func lp(_ args: [String]) -> CommandResult { run("/usr/bin/lp", args) }
    static func lpinfo(_ args: [String]) -> CommandResult { run("/usr/sbin/lpinfo", args) }
    static func cupsfilter(_ args: [String], timeout: TimeInterval = 90) -> CommandResult {
        run("/usr/sbin/cupsfilter", args, timeout: timeout)
    }
}

extension String {
    /// First capture group of the first match, or nil.
    func firstMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let m = re.firstMatch(in: self, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }

    func containsCI(_ needle: String) -> Bool {
        range(of: needle, options: .caseInsensitive) != nil
    }
}

extension Data {
    var hexPreview: String {
        prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
        + (count > 64 ? " … (\(count) bytes)" : "")
    }
}
