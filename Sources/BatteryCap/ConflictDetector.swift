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
        case obcDetectionUnknown  // "couldn't check via pmset, please verify manually"
        case systemChargeManagementApparent(maxSocToday: Int)  // ioreg-based fallback

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
            case .systemChargeManagementApparent(let maxSoc):
                return "System appears to be limiting charge (max SoC today: \(maxSoc)%)"
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
            case .systemChargeManagementApparent(let maxSoc):
                return """
                       BatteryCap detected that the battery's max state-of-charge \
                       today was \(maxSoc)% (from IORegistry BatteryData.DailyMaxSoc). \
                       This means the system held charge below 100% — either \
                       Optimized Battery Charging engaged, or a native charge \
                       limit is set.
                       Verify at: System Settings → Battery → Battery Health \
                       AND Charge Limit. Disable whichever is active if you \
                       want BatteryCap to manage the cap exclusively.
                       Note: this is an inferred signal, not a definitive flag. \
                       If you just unplugged before the battery reached 100%, \
                       DailyMaxSoc could be low for that reason alone.
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
            case .systemChargeManagementApparent:
                return .warning  // Strong inferred signal that cap is active
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

        // 1. macOS Optimized Battery Charging (tri-state via pmset)
        let obcDetection = detectOptimizedCharging()
        switch obcDetection {
        case .on:   conflicts.append(.optimizedBatteryCharging)
        case .off:  break  // Confirmed off — don't fall through to ioreg
        case .unknown:
            // pmset didn't expose it. Try ioreg DailyMaxSoc as fallback
            // (works on macOS 26+ where Apple moved OBC out of pmset).
            if let dailyMax = BatteryMonitor.readDailyMaxSoc() {
                if dailyMax < 100 {
                    // Strong signal that system held charge below max today.
                    conflicts.append(.systemChargeManagementApparent(maxSocToday: dailyMax))
                }
                // If dailyMax == 100, battery reached full today — no cap
                // active (or it was disabled). Don't append anything.
            } else {
                // Couldn't read ioreg either. Last-resort manual verify.
                conflicts.append(.obcDetectionUnknown)
            }
        }

        // 2-4. Other tools (binary file-existence checks)
        if isAldenteInstalled()    { conflicts.append(.aldenteInstalled) }
        if isBattInstalled()       { conflicts.append(.battInstalled) }
        if isBclmPersistInstalled(){ conflicts.append(.bclmPersistInstalled) }

        // 5. Native charge limit (macOS 26.4+) via pmset chlim
        if isNativeChargeLimitSet() { conflicts.append(.nativeChargeLimitSet) }

        return Result(conflicts: conflicts)
    }

    // MARK: Optimized Battery Charging

    private enum Detection { case on, off, unknown }

    /// OBC has moved across macOS versions:
    /// - macOS 13/14 (Intel target): exposed via `pmset -g` as `optimizedcharging`.
    /// - macOS 26+ (Apple Silicon): moved to private defaults, not userland-readable.
    ///
    /// Detection strategy (in priority order):
    ///   1. `pmset -g` for `optimizedcharging` line — definitive when present
    ///   2. IORegistry `BatteryData.DailyMaxSoc` — if < 100, system held charge
    ///      below max today (OBC or native limit engaged). Doesn't distinguish
    ///      which, but better than "unknown."
    ///   3. Give up → .unknown
    ///
    /// The ioreg fallback (strategy 2) lets us return useful signal on
    /// macOS 26+ where pmset stopped exposing the flag. Surfaced as the
    /// `.systemChargeManagementApparent(maxSocToday:)` conflict rather than
    /// as a definitive `.on` so the user knows it's inferred.
    private func detectOptimizedCharging() -> Detection {
        // Strategy 1: pmset -g
        if let output = runPmsetG() {
            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("optimizedcharging") {
                    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                    if let last = parts.last {
                        return last == "1" ? .on : .off
                    }
                }
            }
        }

        // Strategy 2: ioreg DailyMaxSoc (macOS 26+ fallback)
        // Returns .unknown if we can't read it; caller handles by surfacing
        // a different conflict (.systemChargeManagementApparent).
        return .unknown  // see detect() for the ioreg fallback wiring
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
