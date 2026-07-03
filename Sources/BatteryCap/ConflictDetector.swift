//
//  ConflictDetector.swift
//  BatteryCap
//
//  Detects other tools / settings that could fight BatteryCap's BCLM writes.
//  R7 in the PRD: "battery at 100% even though cap is 60" is the most likely
//  user complaint, and conflicts are the most likely cause.
//
//  Tri-state detection: .on (conflict confirmed), .off (confirmed absent),
//  .unknown (cannot determine on this macOS version — don't cry wolf,
//  don't stay silent; surface as a manual-verify hint).
//

import Foundation

struct ConflictDetector {

    // MARK: Conflict types

    enum Conflict {
        case optimizedBatteryCharging
        case aldenteInstalled
        case battInstalled
        case bclmPersistInstalled
        case nativeChargeLimitSet
        case obcDetectionUnknown  // "couldn't check, please verify manually"

        var title: String {
            switch self {
            case .optimizedBatteryCharging:
                return "macOS Optimized Battery Charging is ON"
            case .aldenteInstalled:
                return "AlDente is installed"
            case .battInstalled:
                return "batt is installed"
            case .bclmPersistInstalled:
                return "bclm persistence is installed"
            case .nativeChargeLimitSet:
                return "macOS native charge limit is set"
            case .obcDetectionUnknown:
                return "macOS Optimized Battery Charging status unknown"
            }
        }

        var detail: String {
            switch self {
            case .optimizedBatteryCharging:
                return """
                       macOS is delaying charging past 80% based on usage \
                       patterns. This will fight BatteryCap's cap.
                       Disable: System Settings → Battery → Battery Health → \
                       (i) → Optimized Battery Charging → Off
                       """
            case .aldenteInstalled:
                return """
                       AlDente writes the same BCLM key. Two tools writing \
                       BCLM will overwrite each other on every polling cycle.
                       Quit AlDente, or remove its LaunchDaemon: \
                       /Library/LaunchDaemons/com.apphouseknight.aldente.*.plist
                       """
            case .battInstalled:
                return """
                       batt (charlie0129) writes SMC charge keys. Same \
                       overwriting conflict as AlDente.
                       Quit batt.app or remove its LaunchDaemon.
                       """
            case .bclmPersistInstalled:
                return """
                       bclm's LaunchDaemon is at \
                       /Library/LaunchDaemons/com.zackelia.bclm.plist. \
                       It re-writes BCLM on every boot, overwriting \
                       BatteryCap's value.
                       Uninstall with: sudo bclm unpersist
                       """
            case .nativeChargeLimitSet:
                return """
                       macOS 26.4+ native charge limit (chlim) is enabled. \
                       On supported hardware this takes precedence over \
                       BCLM writes.
                       Disable: System Settings → Battery → Charge Limit → Off
                       """
            case .obcDetectionUnknown:
                return """
                       BatteryCap could not auto-detect whether Optimized \
                       Battery Charging is enabled on this macOS version.
                       Manually verify: System Settings → Battery → \
                       Battery Health → (i). If Optimized Battery Charging \
                       is on, disable it — it will fight the cap.
                       """
            }
        }

        var severity: Severity {
            switch self {
            case .optimizedBatteryCharging, .aldenteInstalled,
                 .battInstalled, .bclmPersistInstalled,
                 .nativeChargeLimitSet:
                return .warning  // Active conflict
            case .obcDetectionUnknown:
                return .info  // Might or might not be a conflict
            }
        }

        enum Severity { case warning, info }
    }

    // MARK: Detection

    struct Result {
        let conflicts: [Conflict]
    }

    /// Runs all detectors. Fast enough to call on app launch (~50-150ms total,
    /// dominated by the pmset subprocess).
    func detect() -> Result {
        var conflicts: [Conflict] = []

        // 1. macOS Optimized Battery Charging (tri-state)
        switch detectOptimizedCharging() {
        case .on:   conflicts.append(.optimizedBatteryCharging)
        case .unknown: conflicts.append(.obcDetectionUnknown)
        case .off: break
        }

        // 2-4. Other tools (binary file-existence checks)
        if isAldenteInstalled()    { conflicts.append(.aldenteInstalled) }
        if isBattInstalled()       { conflicts.append(.battInstalled) }
        if isBclmPersistInstalled(){ conflicts.append(.bclmPersistInstalled) }

        // 5. Native charge limit (macOS 26.4+)
        if isNativeChargeLimitSet() { conflicts.append(.nativeChargeLimitSet) }

        return Result(conflicts: conflicts)
    }

    // MARK: Optimized Battery Charging

    private enum Detection { case on, off, unknown }

    /// OBC has moved across macOS versions:
    /// - macOS 13/14 (Intel target): exposed via `pmset -g` as `optimizedcharging`.
    /// - macOS 26+ (Apple Silicon): moved to private defaults, not userland-readable.
    /// We try pmset first; if the line isn't there, we return .unknown rather
    /// than risk a false negative.
    private func detectOptimizedCharging() -> Detection {
        guard let output = runPmsetG() else { return .unknown }

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Format: "optimizedcharging    1" or "optimizedcharging    0"
            if trimmed.hasPrefix("optimizedcharging") {
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if let last = parts.last {
                    return last == "1" ? .on : .off
                }
            }
        }
        return .unknown
    }

    // MARK: Other tools (file existence checks)

    private func isAldenteInstalled() -> Bool {
        // Check the most likely install paths. The LaunchDaemon is more
        // reliable than the .app bundle (user might have moved the app).
        let appPaths = [
            "/Applications/AlDente.app",
            "/Applications/AlDente Pro.app",
            "/Applications/AlDente Free.app"
        ]
        let daemonPaths = [
            "/Library/LaunchDaemons/com.apphouseknight.aldente.pro.helper.plist",
            "/Library/LaunchAgents/com.apphouseknight.aldente.plist",
            "/Library/LaunchAgents/com.apphouseknight.aldente.free.plist"
        ]
        return (appPaths + daemonPaths).contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private func isBattInstalled() -> Bool {
        // batt's actual LaunchDaemon label is com.charlieitzbatt.daemon
        // per the source at github.com/charlie0129/batt. Check several
        // variants to be safe.
        let paths = [
            "/Library/LaunchDaemons/com.charlieitzbatt.daemon.plist",
            "/Library/LaunchDaemons/me.charlieitzbatt.plist",
            "/Applications/batt.app"
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private func isBclmPersistInstalled() -> Bool {
        return FileManager.default.fileExists(
            atPath: "/Library/LaunchDaemons/com.zackelia.bclm.plist"
        )
    }

    /// Native charge limit on macOS 26.4+ Apple Silicon. Won't be present
    /// on the A1706 Intel target, but check anyway for forward-compatibility.
    private func isNativeChargeLimitSet() -> Bool {
        guard let output = runPmsetG() else { return false }

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("chlim") {
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if let last = parts.last, let value = Int(last) {
                    // chlim is the cap value; 100 means "no limit"
                    return value < 100
                }
            }
        }
        return false
    }

    // MARK: Subprocess helper

    /// Runs `pmset -g` and returns stdout. Returns nil on any error.
    /// Cached per-instance: callers should construct a fresh ConflictDetector
    /// rather than reusing across detections (we want fresh data each time).
    private func runPmsetG() -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["-g"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()  // Discard stderr.

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
