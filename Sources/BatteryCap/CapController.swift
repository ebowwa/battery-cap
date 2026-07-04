//
//  CapController.swift
//  BatteryCap
//
//  Reads/writes the SMC BCLM (Battery Charge Level Max) key on Intel Macs.
//  Also writes BFCL (Battery Final Charge Level) which controls the LED
//  indicator on Macs that have one — USB-C Macs lack BFCL, the keyNotFound
//  case is expected and ignored.
//
//  UI calls applyCap(), which re-execs this same binary as root via
//  osascript. Helper entrypoints: --read, --write, --boot-apply.
//

import Foundation

struct CapController {

    // MARK: Direct SMC operations (must run as root for write)

    /// Reads current cap value. Returns nil if SMC is unavailable or
    /// the platform's cap key (BCLM on Intel, CHWA on Apple Silicon) is
    /// missing.
    static func readCap() throws -> Int? {
        try SMCKit.open()
        defer { _ = SMCKit.close() }

        let platform = Platform.current
        let key = SMCKit.getKey(platform.capKeyName, type: DataTypes.UInt8)
        do {
            let bytes = try SMCKit.readData(key)
            return platform.cap(fromSmcByte: bytes.0)
        } catch SMCKit.SMCError.keyNotFound {
            return nil
        }
    }

    /// Writes cap = value (percentage). Must be called as root.
    /// Caller is responsible for validating value via Platform.isValid(cap:).
    static func writeCap(value: Int) throws {
        try SMCKit.open()
        defer { _ = SMCKit.close() }

        let platform = Platform.current
        let key = SMCKit.getKey(platform.capKeyName, type: DataTypes.UInt8)
        var bytes = emptySMCBytes()
        bytes.0 = platform.smcByte(forCap: value)
        try SMCKit.writeData(key, data: bytes)
    }

    /// Writes BFCL = value. Intel-only — Apple Silicon never has BFCL.
    /// Best-effort: ignored if the key doesn't exist (USB-C Macs without
    /// charging LEDs).
    static func writeBFCL(value: Int) throws {
        guard Platform.current.supportsBFCL else { return }
        try SMCKit.open()
        defer { _ = SMCKit.close() }

        let key = SMCKit.getKey("BFCL", type: DataTypes.UInt8)
        var bytes = emptySMCBytes()
        bytes.0 = UInt8(value)
        try SMCKit.writeData(key, data: bytes)
    }

    // MARK: UI-driven application (re-execs self as root via osascript)

    /// Sets the cap from the menu bar UI. Spawns a privileged subprocess
    /// via `osascript ... with administrator privileges`. The native macOS
    /// auth dialog appears; user enters password; binary writes BCLM as root.
    ///
    /// Completion is called on the main thread.
    func applyCap(value: UInt8, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let selfPath = CommandLine.arguments[0]
            // Single-quote the path; if it contains a single quote (rare for
            // .app bundle paths), escape with the standard '\'' trick.
            let escapedPath = selfPath.replacingOccurrences(of: "'", with: "'\\''")
            let shell = "'\(escapedPath)' --write \(value)"

            let script = "do shell script \"\(shell)\" with administrator privileges"

            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]

            let errPipe = Pipe()
            task.standardError = errPipe
            task.standardOutput = Pipe()  // Discard stdout.

            do {
                try task.run()
                task.waitUntilExit()

                if task.terminationStatus == 0 {
                    DispatchQueue.main.async {
                        // Persist the chosen cap to the config file so the
                        // LaunchDaemon can re-apply it on boot.
                        _ = try? ConfigStore.write(cap: Int(value))
                        completion(.success(()))
                    }
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                    DispatchQueue.main.async {
                        completion(.failure(NSError(
                            domain: "BatteryCap",
                            code: Int(task.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: errMsg]
                        )))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Reads current cap for UI display. Returns nil if the SMC is
    /// unavailable (e.g. running on a Mac without BCLM, like Apple Silicon).
    func readCap() -> Int? {
        return (try? CapController.readCap()) ?? nil
    }

    // MARK: LaunchDaemon entry point (--boot-apply)

    /// Reads saved cap from ConfigStore, reads current BCLM, logs the
    /// comparison, writes corrective value if drifted, verifies.
    ///
    /// Invoked by LaunchDaemon at boot (RunAtLoad=true) and every hour
    /// (StartInterval=3600). The same code path handles both — log line
    /// includes system uptime so you can tell which is which in the log:
    /// boot invocations have small uptimes, periodic ones large.
    ///
    /// **Test mode interaction**: if test mode is active (state file at
    /// /tmp/batterycap-test-mode.json exists and not expired), skip the
    /// drift correction — the test cap should not be "corrected" back to
    /// the saved value mid-test. If state exists but is expired, clean it
    /// up before proceeding.
    ///
    /// Returns exit code (0 = success). Failures don't crash; launchd
    /// would back off exponentially.
    static func bootApply() -> Int32 {
        let uptime = Int(ProcessInfo.processInfo.systemUptime)

        // 0. Test mode gate — takes precedence over saved cap.
        TestModeStore.clearIfExpired()
        if let testState = TestModeStore.read() {
            DiagnosticsLogger.log(
                "[up \(uptime)s] scheduled-apply: test mode active (value=\(testState.testValue)%, \(testState.remainingSeconds)s remaining), skipping drift correction"
            )
            return EXIT_SUCCESS
        }

        // 1. Read the saved target cap.
        guard let target = try? ConfigStore.read(), (50...100).contains(target) else {
            DiagnosticsLogger.log(
                "[up \(uptime)s] scheduled-apply: no config or invalid, skipping"
            )
            return EXIT_SUCCESS
        }

        // 2. Read current BCLM to detect drift.
        let actual: Int?
        do {
            actual = try readCap()
        } catch {
            DiagnosticsLogger.log(
                "[up \(uptime)s] scheduled-apply: target=\(target) read_error=\(error)"
            )
            return EXIT_FAILURE
        }

        // 3. Happy path — cap already correct, no write needed. This is
        // the most common case for periodic invocations.
        if actual == target {
            DiagnosticsLogger.log(
                "[up \(uptime)s] scheduled-apply: target=\(target) actual=\(actual ?? -1) drift=false"
            )
            return EXIT_SUCCESS
        }

        // Validate target is acceptable on this platform before writing.
        // (User could have set 60 on Intel, then config file ended up on
        // an Apple Silicon Mac via migration. Don't write a wrong value.)
        guard Platform.current.isValid(cap: target) else {
            DiagnosticsLogger.log(
                "[up \(uptime)s] scheduled-apply: target=\(target) invalid on \(Platform.current.displayName) (valid: \(Platform.current.validCapValues)), skipping"
            )
            return EXIT_SUCCESS
        }

        // 4. Drift detected (cap missing, wrong value, or SMC reset).
        //    Write the corrective value + BFCL.
        DiagnosticsLogger.log(
            "[up \(uptime)s] scheduled-apply: target=\(target) actual=\(actual ?? -1) drift=true correcting"
        )

        do {
            try writeCap(value: target)
            try? writeBFCL(value: max(target - 5, 50))
        } catch {
            DiagnosticsLogger.log(
                "[up \(uptime)s] scheduled-apply: target=\(target) correct_error=\(error)"
            )
            return EXIT_FAILURE
        }

        // 5. Verify the correction took effect by re-reading.
        let verify = (try? readCap()) ?? -1
        let effective = verify == target ? "yes" : "no"
        DiagnosticsLogger.log(
            "[up \(uptime)s] scheduled-apply: target=\(target) corrected verify=\(verify) effective=\(effective)"
        )

        return verify == target ? EXIT_SUCCESS : EXIT_FAILURE
    }
}
