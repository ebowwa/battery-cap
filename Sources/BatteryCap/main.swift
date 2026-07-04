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
        guard args.count == 3,
              let value = UInt8(args[2]),
              (50...100).contains(Int(value)) else {
            FileHandle.standardError.write("usage: BatteryCap --write <50-100>\n".data(using: .utf8)!)
            exit(EXIT_FAILURE)
        }
        do {
            try CapController.writeCap(value: value)
            let bfcl: UInt8 = max(value - 5, 50)
            try? CapController.writeBFCL(value: bfcl)
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
