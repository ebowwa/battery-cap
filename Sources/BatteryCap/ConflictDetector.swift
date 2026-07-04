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
        case nativeChargeLimitSet(soc: Int, ownerPid: Int?)  // macOS 26.4+ via pmset -g battlimit
        case obcDetectionUnknown  // "couldn't check via pmset, please verify manually"
        case systemChargeManagementApparent(maxSocToday: Int)  // ioreg fallback when battlimit unavailable

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
            case .nativeChargeLimitSet(let soc, _):
                return "macOS native charge limit is set to \(soc)%"
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
            case .nativeChargeLimitSet(let soc, let ownerPid):
                let owner = ownerPid.map { pid in
                    processName(forPid: pid).map { " (held by \($0), pid \(pid))" } ?? " (held by pid \(pid))"
                } ?? ""
                return """
                       macOS has a manual charge limit set to \(soc)% via the \
                       native System Settings API\(owner). This will take \
                       precedence over BatteryCap on platforms where both apply.
                       Disable: System Settings → Battery → Charge Limit → Off \
                       (or set to 100%)
                       Detection source: `pmset -g battlimit` shows \
                       `chargeSocLimitReason = manualChargeLimit, \
                       chargeSocLimitSoc = \(soc)`.
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
                 .nativeChargeLimitSet, .systemChargeManagementApparent:
                return .warning  // Active conflict
            case .obcDetectionUnknown:
                return .info  // Might or might not be a conflict
            }
        }

        enum Severity { case warning, info }

        /// Resolve a PID to a process name (best-effort, for the conflict message).
        private func processName(forPid pid: Int) -> String? {
            // ps -p PID -o comm= returns just the basename of the executable.
            let task = Process()
            task.launchPath = "/bin/ps"
            task.arguments = ["-p", "\(pid)", "-o", "comm="]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return nil
            }
        }
    }

    // MARK: Detection

    struct Result {
        let conflicts: [Conflict]
    }

    /// Runs all detectors. Fast enough to call on app launch (~50-150ms total,
    /// dominated by the pmset subprocess).
    func detect() -> Result {
        var conflicts: [Conflict] = []

        // 1. Native charge limit (macOS 26.4+) via `pmset -g battlimit`.
        //    Most definitive signal — gives the actual cap value and the
        //    PID that set it. Available on Apple Silicon macOS 26+.
        if let nativeLimit = detectNativeChargeLimitViaBattlimit() {
            conflicts.append(.nativeChargeLimitSet(soc: nativeLimit.soc,
                                                    ownerPid: nativeLimit.ownerPid))
        }

        // 2. macOS Optimized Battery Charging (tri-state via pmset -g)
        let obcDetection = detectOptimizedCharging()
        switch obcDetection {
        case .on:   conflicts.append(.optimizedBatteryCharging)
        case .off:  break  // Confirmed off — don't fall through to ioreg
        case .unknown:
            // pmset didn't expose OBC. Try ioreg DailyMaxSoc as fallback
            // (works on macOS 26+ where Apple moved OBC out of pmset).
            // But only if we don't already have a definitive native limit
            // signal — otherwise we'd double-report.
            if !conflicts.contains(where: {
                if case .nativeChargeLimitSet = $0 { return true }
                return false
            }) {
                if let dailyMax = BatteryMonitor.readDailyMaxSoc() {
                    if dailyMax < 100 {
                        conflicts.append(.systemChargeManagementApparent(maxSocToday: dailyMax))
                    }
                    // If dailyMax == 100, battery reached full today — no cap
                    // active (or it was disabled). Don't append anything.
                } else {
                    // Couldn't read ioreg either. Last-resort manual verify.
                    conflicts.append(.obcDetectionUnknown)
                }
            }
        }

        // 3-5. Other tools (binary file-existence checks)
        if isAldenteInstalled()    { conflicts.append(.aldenteInstalled) }
        if isBattInstalled()       { conflicts.append(.battInstalled) }
        if isBclmPersistInstalled(){ conflicts.append(.bclmPersistInstalled) }

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

    /// Native charge limit on macOS 26.4+ Apple Silicon. Uses the hidden
    /// `pmset -g battlimit` subcommand which exposes:
    ///   chargeSocLimitReason = manualChargeLimit
    ///   chargeSocLimitSoc = 80
    ///   chargeSocLimitOwner = <PID>
    /// Returns nil if the command doesn't exist (older macOS) or no manual
    /// limit is currently set.
    ///
    /// The output may contain multiple entries (one per claim holder). We
    /// parse per-entry (delimited by `{` ... `}`) and pick the first manual
    /// entry with a non-zero owner PID — that's the actual claim holder
    /// (e.g., PowerUIAgent for System Settings, or our own PID if we set it).
    private func detectNativeChargeLimitViaBattlimit() -> (soc: Int, ownerPid: Int?)? {
        guard let output = runPmset(["-g", "battlimit"]) else { return nil }

        // Split into entries by `{`. The text before the first `{` is the
        // "Battery level limits:" header + opening `(`. Each subsequent
        // chunk is one entry's contents terminated by `}`.
        let entries = output.split(separator: "{")
        for entry in entries.dropFirst() {  // skip the header
            var isManual = false
            var soc: Int?
            var owner: Int?

            for line in entry.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("chargeSocLimitReason") &&
                   trimmed.contains("manualChargeLimit") {
                    isManual = true
                }
                if trimmed.hasPrefix("chargeSocLimitSoc") {
                    soc = extractIntValue(from: trimmed)
                }
                if trimmed.hasPrefix("chargeSocLimitOwner") {
                    owner = extractIntValue(from: trimmed)
                }
            }

            // Stop at the first manual entry with a non-zero owner PID.
            // owner=0 entries are system mirrors/echoes, not the actual claim.
            if isManual, let s = soc, let own = owner, own != 0 {
                return (s, own)
            }
        }

        // Fallback: if all manual entries have owner=0, take the first manual
        // one and report nil for the owner. Still useful — the user knows the
        // cap is set, just not by whom.
        for entry in entries.dropFirst() {
            var isManual = false
            var soc: Int?
            for line in entry.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("chargeSocLimitReason") &&
                   trimmed.contains("manualChargeLimit") {
                    isManual = true
                }
                if trimmed.hasPrefix("chargeSocLimitSoc") {
                    soc = extractIntValue(from: trimmed)
                }
            }
            if isManual, let s = soc {
                return (s, nil)
            }
        }

        return nil
    }

    /// Parses "key = value;" lines into Int.
    private func extractIntValue(from line: String) -> Int? {
        // Format: "chargeSocLimitSoc = 80;" or "chargeSocLimitOwner = 70699;"
        let parts = line.split(separator: "=")
        guard parts.count >= 2 else { return nil }
        let rawTail = parts[1].trimmingCharacters(in: .whitespaces)
        // Strip trailing ; and any whitespace
        let cleaned = rawTail.replacingOccurrences(of: ";", with: "")
                             .trimmingCharacters(in: .whitespaces)
        return Int(cleaned)
    }

    /// Native charge limit fallback (macOS 13-14, Intel target via pmset chlim).
    /// Not used on macOS 26+ where battlimit is the definitive source.
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
    private func runPmsetG() -> String? {
        return runPmset(["-g"])
    }

    /// Runs `pmset` with arbitrary args and returns stdout.
    private func runPmset(_ args: [String]) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = args
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
