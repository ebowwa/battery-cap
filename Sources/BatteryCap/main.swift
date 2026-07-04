//
//  main.swift
//  BatteryCap
//
//  Entry point + argv dispatch.
//
//  The same binary serves as menu bar app, CLI, and its own privileged
//  helper. Dispatch:
//    --read/--write/--boot-apply/...  → helper modes (preserved for daemon + backward compat)
//    <subcommand>                     → CLI dispatch (status, set, test, etc.)
//    (no args, TTY)                   → menu bar UI
//    (no args, piped)                 → status (for scripts/SSH)
//

import AppKit
import Foundation

let args = CommandLine.arguments

// MARK: Helper modes (preserved for LaunchDaemon + osascript callers)

if args.count >= 2 {
    switch args[1] {

    case "--read":
        do {
            let cap = try CapController.readCap() ?? -1
            print(cap)
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write("read failed: \(error)\n".data(using: .utf8)!)
            exit(EXIT_FAILURE)
        }

    case "--write":
        // usage: BatteryCap --write <50-100>
        // Value range is platform-dependent (Apple Silicon: 80 or 100 only).
        guard args.count == 3, let value = Int(args[2]) else {
            FileHandle.standardError.write("usage: BatteryCap --write <50-100>\n".data(using: .utf8)!)
            exit(EXIT_FAILURE)
        }
        guard Platform.current.isValid(cap: value) else {
            FileHandle.standardError.write(
                "value \(value) not valid on \(Platform.current.displayName); valid: \(Platform.current.validCapValues)\n".data(using: .utf8)!)
            exit(EXIT_FAILURE)
        }
        do {
            try CapController.writeCap(value: value)
            try? CapController.writeBFCL(value: max(value - 5, 50))
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
            exit(EXIT_FAILURE)
        }

    case "--boot-apply":
        // LaunchDaemon entry point. Reads config, checks test mode,
        // applies saved cap if not in test mode.
        exit(CapController.bootApply())

    case "--unpersist":
        exit(PersistenceInstaller.uninstall())

    case "--probe-smc":
        // Diagnostic: probe SMC for known charge-related keys, print status.
        // Useful for figuring out which keys exist on a given Mac / macOS
        // version (especially when entitlement enforcement blocks access).
        do {
            try SMCKit.open()
        } catch {
            print("SMC open failed: \(error)")
            exit(EXIT_FAILURE)
        }
        defer { _ = SMCKit.close() }

        let probeKeys: [(String, String)] = [
            ("BCLM", "Battery Charge Level Max (Intel percentage)"),
            ("CHWA", "Charge Wall? (Apple Silicon 80/100 toggle)"),
            ("BFCL", "Battery Final Charge Level (Intel MagSafe LED)"),
            ("CH0B", "Charging Control (PowerLimit-style enable/disable)"),
            ("BRSC", "Battery Relative State of Charge"),
            ("TB0T", "Battery Temperature")
        ]
        print("Platform: \(Platform.current.displayName)")
        print("SMC key probe:")
        for (name, desc) in probeKeys {
            let key = SMCKit.getKey(name, type: DataTypes.UInt8)
            do {
                let bytes = try SMCKit.readData(key)
                print("  ✅ \(name) = \(bytes.0)  (\(desc))")
            } catch SMCKit.SMCError.keyNotFound {
                print("  ❌ \(name) not found  (\(desc))")
            } catch SMCKit.SMCError.notPrivileged {
                print("  🚫 \(name) entitlement-blocked  (\(desc))")
            } catch {
                print("  ⚠️  \(name) error: \(error)  (\(desc))")
            }
        }
        exit(EXIT_SUCCESS)

    case "--helper-version":
        print("BatteryCap helper v1.0")
        exit(EXIT_SUCCESS)

    case "--detect-conflicts":
        // Kept for backward compat. New code uses `batterycap conflicts`.
        let result = ConflictDetector().detect()
        if result.conflicts.isEmpty {
            print("No conflicts detected.")
            exit(EXIT_SUCCESS)
        }
        print("\(result.conflicts.count) conflict(s) detected:")
        for conflict in result.conflicts {
            print("- \(conflict.title)")
            print("  \(conflict.detail.replacingOccurrences(of: "\n", with: "\n  "))")
        }
        exit(EXIT_SUCCESS)

    case "--log-test":
        DiagnosticsLogger.log("[manual] log-test: synthetic entry for verification")
        print("Wrote test entry to: \(DiagnosticsLogger.logPath)")
        print("Tail with: sudo tail -f \(DiagnosticsLogger.logPath)")
        exit(EXIT_SUCCESS)

    default:
        // Not a helper mode — fall through to CLI dispatch.
        break
    }
}

// MARK: CLI dispatch (subcommands + no-arg UI/status)

exit(CLI.dispatch(args))
