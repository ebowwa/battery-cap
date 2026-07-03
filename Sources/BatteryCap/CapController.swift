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

    /// Reads current BCLM value. Returns nil if SMC is unavailable or
    /// the key is missing on this hardware.
    static func readCap() throws -> Int? {
        try SMCKit.open()
        defer { _ = SMCKit.close() }

        let key = SMCKit.getKey("BCLM", type: DataTypes.UInt8)
        do {
            let bytes = try SMCKit.readData(key)
            return Int(bytes.0)
        } catch SMCKit.SMCError.keyNotFound {
            return nil
        }
    }

    /// Writes BCLM = value. Must be called as root.
    static func writeCap(value: UInt8) throws {
        try SMCKit.open()
        defer { _ = SMCKit.close() }

        let key = SMCKit.getKey("BCLM", type: DataTypes.UInt8)
        var bytes = emptySMCBytes()
        bytes.0 = value
        try SMCKit.writeData(key, data: bytes)
    }

    /// Writes BFCL = value. Best-effort: ignored if the key doesn't exist
    /// (USB-C Macs without charging LEDs).
    static func writeBFCL(value: UInt8) throws {
        try SMCKit.open()
        defer { _ = SMCKit.close() }

        let key = SMCKit.getKey("BFCL", type: DataTypes.UInt8)
        var bytes = emptySMCBytes()
        bytes.0 = value
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

    /// Reads cap from ConfigStore and applies it. Used by the LaunchDaemon
    /// on boot. Returns the exit code (0 = success).
    static func bootApply() -> Int32 {
        guard let cap = try? ConfigStore.read(), (50...100).contains(cap) else {
            // No config or invalid → nothing to do. Don't fail; LaunchDaemon
            // would back off exponentially.
            return EXIT_SUCCESS
        }
        do {
            try writeCap(value: UInt8(cap))
            try? writeBFCL(value: UInt8(max(cap - 5, 50)))
            return EXIT_SUCCESS
        } catch {
            FileHandle.standardError.write(
                "boot-apply failed: \(error)\n".data(using: .utf8)!)
            return EXIT_FAILURE
        }
    }
}
