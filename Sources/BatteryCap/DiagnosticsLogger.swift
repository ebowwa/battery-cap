//
//  DiagnosticsLogger.swift
//  BatteryCap
//
//  Append-only file logger for the periodic cap check. Lives at
//  /Library/Logs/BatteryCap.log (root-writable, world-readable so the
//  user can `tail -f` without sudo).
//
//  Purpose: gather evidence for OQ1 — "should we re-apply the cap
//  periodically as defense-in-depth against silent SMC resets?"
//  After ~30 days of logs, grep for `drift=true` to decide whether to
//  keep the periodic check, change the interval, or remove it.
//

import Foundation

enum DiagnosticsLogger {

    /// Log location. /Library/Logs is the macOS convention for system-wide
    /// app logs. World-readable so users can inspect without sudo.
    static let logPath = "/Library/Logs/BatteryCap.log"

    /// Rotate when the active log exceeds this size.
    private static let maxFileSize: UInt64 = 1_000_000  // 1 MB

    /// How many archived (.1, .2, .3) files to keep.
    private static let maxArchiveCount = 3

    /// Serialize appends. Multiple short-lived daemon invocations could
    /// race on the file (launchd may overlap a slow invocation with the
    /// next interval trigger). The queue isn't cross-process; for true
    /// cross-process safety we'd need a file lock — but launchd doesn't
    /// overlap invocations of the same label in practice.
    private static let queue = DispatchQueue(label: "com.ebowwa.battery-cap.logger")

    // MARK: Public API

    /// Append a single line to the log. Adds ISO8601 timestamp prefix.
    /// Safe to call from any thread.
    ///
    /// Uses `sync` (not `async`) because the LaunchDaemon process exits
    /// immediately after applying the cap — async writes might not flush
    /// before exit. The performance cost is negligible (file append ~1ms).
    static func log(_ message: String) {
        queue.sync {
            let timestamp = currentTimestamp()
            let line = "\(timestamp) \(message)\n"
            append(line: line)
            rotateIfNeeded()
        }
    }

    /// Read the tail of the log. Returns up to `maxLines` lines from the
    /// end of the file. Used by the (future) `--show-log` CLI mode.
    static func tail(_ maxLines: Int = 100) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)) else {
            return "(no log file yet)"
        }
        let full = String(data: data, encoding: .utf8) ?? ""
        let lines = full.split(separator: "\n", omittingEmptySubsequences: true)
        let tail = lines.suffix(maxLines)
        return tail.joined(separator: "\n")
    }

    // MARK: Internals

    private static func append(line: String) {
        let data = line.data(using: .utf8) ?? Data()

        // Create file with conservative perms if missing.
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(
                atPath: logPath,
                contents: data,
                attributes: [.posixPermissions: 0o644]  // rw-r--r--
            )
            return
        }

        // Append. FileHandle(forWritingAtPath) requires the file to exist.
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }

    private static func rotateIfNeeded() {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
            let size = attrs[.size] as? UInt64,
            size > maxFileSize
        else { return }

        // Drop the oldest archive, shift the rest up, move active to .1.
        // Pattern: BatteryCap.log.3 -> delete, .2 -> .3, .1 -> .2, log -> .1
        let oldest = "\(logPath).\(maxArchiveCount)"
        try? FileManager.default.removeItem(atPath: oldest)

        for i in stride(from: maxArchiveCount - 1, through: 1, by: -1) {
            let from = "\(logPath).\(i)"
            let to = "\(logPath).\(i + 1)"
            try? FileManager.default.moveItem(atPath: from, toPath: to)
        }

        try? FileManager.default.moveItem(atPath: logPath, toPath: "\(logPath).1")
    }

    private static func currentTimestamp() -> String {
        // ISO8601 with timezone offset. Sortable, grep-friendly.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
