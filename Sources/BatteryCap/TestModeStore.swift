//
//  TestModeStore.swift
//  BatteryCap
//
//  Non-persistent state for the "test mode" feature (PRD OQ3).
//
//  Test mode: auto-set cap to current+3 (or user-specified value) for a
//  bounded duration, then revert. Does NOT touch ConfigStore — the saved
//  cap is preserved untouched, so the LaunchDaemon's hourly drift check
//  would "correct" the test cap back to the saved value if we didn't gate
//  on test mode being active.
//
//  State file lives in /tmp (cleared on reboot = test mode is non-persistent
//  across reboots, by design).
//

import Foundation

enum TestModeStore {

    /// /tmp is cleared on reboot — that's the point. Test mode is a
    /// single-boot affair.
    static let statePath = "/tmp/batterycap-test-mode.json"

    struct State: Codable {
        /// The cap value applied during test mode (e.g., 54).
        let testValue: Int
        /// The cap value to restore when test mode ends (e.g., 100 or 60).
        let originalCap: Int
        /// When test mode started (ISO8601).
        let startedAt: Date
        /// When the auto-reverter should fire (ISO8601).
        let expiresAt: Date
        /// PID of the background reverter process (`nohup sleep N && test end`).
        /// Used by `test end` to kill the reverter if test mode is ended early.
        let reverterPid: Int

        /// Time remaining in seconds, clamped at 0.
        var remainingSeconds: Int {
            let remaining = expiresAt.timeIntervalSinceNow
            return remaining > 0 ? Int(remaining) : 0
        }

        var isExpired: Bool {
            return Date() >= expiresAt
        }
    }

    /// Returns the active state, or nil if no test mode is active.
    /// If the state exists but is expired, treats it as inactive (caller
    /// should clean up via clearExpired()).
    static func read() -> State? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    /// Writes the state file. Caller is responsible for having already
    /// written the test cap to SMC and spawned the reverter.
    static func write(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: URL(fileURLWithPath: statePath), options: [.atomic])
    }

    /// Removes the state file. Idempotent.
    static func clear() {
        try? FileManager.default.removeItem(atPath: statePath)
    }

    /// If state exists but is expired, remove it and return true (caller
    /// should treat this as "no active test mode"). Returns false otherwise.
    @discardableResult
    static func clearIfExpired() -> Bool {
        guard let state = read() else { return false }
        if state.isExpired {
            // Also try to kill the reverter if it's somehow still alive.
            killReverter(pid: state.reverterPid)
            clear()
            return true
        }
        return false
    }

    /// Sends SIGTERM to the reverter process if it still exists.
    static func killReverter(pid: Int) {
        guard pid > 0 else { return }
        // kill(pid, 0) returns 0 if process exists, -1 (errno=ESRCH) if not.
        if kill(Int32(pid), 0) == 0 {
            _ = kill(Int32(pid), SIGTERM)
        }
    }
}
