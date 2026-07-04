//
//  TestModeController.swift
//  BatteryCap
//
//  Orchestrates the test mode lifecycle:
//    start → write test cap to SMC (NOT ConfigStore), spawn background
//            reverter, write state file.
//    end   → kill reverter, restore original cap, clear state file.
//    status→ read state file, format for display.
//
//  Background reverter uses `nohup sh -c 'sleep N && batterycap test end' &`
//  so it survives parent process exit. Inherits root EUID when test start
//  was run via sudo (which is required for SMC writes).
//

import Foundation

enum TestModeController {

    // MARK: Errors

    enum Error: Swift.Error, CustomStringConvertible {
        case alreadyActive(state: TestModeStore.State)
        case noActiveTest
        case invalidValue(Int)
        case needsRoot
        case spawnFailed(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case .alreadyActive(let state):
                return "Test mode already active (value=\(state.testValue)%, \(state.remainingSeconds)s remaining). Run 'test end' first."
            case .noActiveTest:
                return "No active test mode."
            case .invalidValue(let v):
                return "Value \(v) is not in 50..100."
            case .needsRoot:
                return "This command modifies the SMC and must run as root (sudo)."
            case .spawnFailed(let msg):
                return "Failed to spawn background reverter: \(msg)"
            case .writeFailed(let msg):
                return "SMC write failed: \(msg)"
            }
        }
    }

    // MARK: Start

    /// Default test duration: 30 minutes. Long enough to observe plateau in
    /// the fast-proving-test scenario, short enough to not annoy.
    static let defaultDurationSeconds = 30 * 60

    /// Starts test mode.
    ///
    /// - Parameters:
    ///   - explicitValue: user-specified cap value, or nil to auto-compute
    ///     `min(currentCharge + 3, 100)` clamped to 50..100.
    ///   - durationSeconds: test duration. Defaults to 30 min.
    /// - Returns: the resulting State on success.
    static func start(
        explicitValue: Int? = nil,
        durationSeconds: Int = defaultDurationSeconds
    ) throws -> TestModeStore.State {

        // Must be root to write SMC.
        guard getuid() == 0 else { throw Error.needsRoot }

        // Refuse if test mode already active. Caller should run `end` first.
        TestModeStore.clearIfExpired()
        if let existing = TestModeStore.read() {
            throw Error.alreadyActive(state: existing)
        }

        // Compute test value.
        let testValue: Int
        if let v = explicitValue {
            guard (50...100).contains(v) else { throw Error.invalidValue(v) }
            testValue = v
        } else {
            // Default: current charge + 3, clamped to 50..100.
            let charge = BatteryMonitor().currentChargePercent()
            let target = charge >= 0 ? charge + 3 : 60
            testValue = min(max(target, 50), 100)
        }

        // Capture original cap (what we'll restore to).
        let originalCap = (try? CapController.readCap()) ?? 100

        // Write test cap to SMC. ConfigStore is NOT touched — that's the
        // whole point of "non-persistent."
        do {
            try CapController.writeCap(value: UInt8(testValue))
            try? CapController.writeBFCL(value: UInt8(max(testValue - 5, 50)))
        } catch {
            throw Error.writeFailed("\(error)")
        }

        // Spawn background reverter. nohup so it survives our exit.
        let reverterPid = spawnReverter(durationSeconds: durationSeconds)

        // Write state file.
        let now = Date()
        let state = TestModeStore.State(
            testValue: testValue,
            originalCap: originalCap,
            startedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(durationSeconds)),
            reverterPid: reverterPid
        )
        try TestModeStore.write(state)

        DiagnosticsLogger.log(
            "[test] start: value=\(testValue)% original=\(originalCap)% duration=\(durationSeconds)s reverterPid=\(reverterPid)"
        )

        return state
    }

    /// Ends test mode: kills reverter, restores original cap, clears state.
    /// Safe to call manually or from the background reverter.
    static func end() throws -> Int {
        // Must be root to write SMC.
        guard getuid() == 0 else { throw Error.needsRoot }

        guard let state = TestModeStore.read() else {
            throw Error.noActiveTest
        }

        // Kill the reverter first (in case we're being called manually and
        // the reverter is still sleeping).
        TestModeStore.killReverter(pid: state.reverterPid)

        // Restore original cap to SMC.
        do {
            try CapController.writeCap(value: UInt8(state.originalCap))
            try? CapController.writeBFCL(value: UInt8(max(state.originalCap - 5, 50)))
        } catch {
            throw Error.writeFailed("\(error)")
        }

        TestModeStore.clear()

        DiagnosticsLogger.log(
            "[test] end: restored cap to \(state.originalCap)%"
        )

        return state.originalCap
    }

    // MARK: Status (no root needed)

    /// Returns the current state, or nil if test mode is inactive.
    /// Also cleans up expired state as a side effect.
    static func status() -> TestModeStore.State? {
        TestModeStore.clearIfExpired()
        return TestModeStore.read()
    }

    // MARK: Internal

    /// Spawns `nohup /bin/sh -c 'sleep N && <self> test end' &` detached.
    /// Returns the nohup process PID (which becomes sh's PID via exec).
    static func spawnReverter(durationSeconds: Int) -> Int {
        let selfPath = CommandLine.arguments[0]
        let escapedPath = selfPath.replacingOccurrences(of: "'", with: "'\\''")
        let innerCmd = "'\(escapedPath)' test end"
        let script = "sleep \(durationSeconds) && \(innerCmd)"

        let task = Process()
        task.launchPath = "/usr/bin/nohup"
        task.arguments = ["/bin/sh", "-c", script]

        // Redirect to /dev/null so output doesn't leak anywhere.
        let devNull = FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle()
        task.standardOutput = devNull
        task.standardError = devNull
        task.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        do {
            try task.run()
            // Detach: don't waitUntilExit. The process continues after we exit.
            return Int(task.processIdentifier)
        } catch {
            DiagnosticsLogger.log("[test] spawn-failed: \(error)")
            return -1
        }
    }
}
