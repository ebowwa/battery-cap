//
//  main.swift
//  BatteryCap
//
//  Entry point + argv dispatch.
//
//  The same binary serves as both the menu bar app and its own privileged
//  helper. Dispatch is by argv: --write/--read/--boot-apply run as a root
//  subprocess (spawned via osascript) and exit. No argv → menu bar UI.
//

import AppKit
import Foundation

let args = CommandLine.arguments

// MARK: Helper modes (run as root via osascript)

if args.count >= 2 {
    switch args[1] {

    case "--read":
        // Prints current BCLM value (0..100) to stdout. Exit 0 on success.
        do {
            let cap = try CapController.readCap() ?? -1
            print(cap)
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                "read failed: \(error)\n".data(using: .utf8)!)
            exit(EXIT_FAILURE)
        }

    case "--write":
        // usage: BatteryCap --write <50-100>
        guard args.count == 3,
              let value = UInt8(args[2]),
              (50...100).contains(Int(value)) else {
            FileHandle.standardError.write(
                "usage: BatteryCap --write <50-100>\n".data(using: .utf8)!)
            exit(EXIT_FAILURE)
        }
        do {
            try CapController.writeCap(value: value)
            // Mirror bclm's pattern: also write BFCL = value - 5 if present.
            // USB-C Macs lack BFCL; the keyNotFound case is expected and OK.
            let bfcl: UInt8 = max(value - 5, 50)
            try? CapController.writeBFCL(value: bfcl)
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                "write failed: \(error)\n".data(using: .utf8)!)
            exit(EXIT_FAILURE)
        }

    case "--boot-apply":
        // Reads cap from config file and applies it. Used by LaunchDaemon.
        let exitCode = CapController.bootApply()
        exit(exitCode)

    case "--unpersist":
        let exitCode = PersistenceInstaller.uninstall()
        exit(exitCode)

    case "--helper-version":
        print("BatteryCap helper v1.0")
        exit(EXIT_SUCCESS)

    case "--detect-conflicts":
        // Diagnostic mode for the conflict detector. Prints what would be
        // surfaced in the menu UI. Useful for debugging on dev machines
        // where the menu bar isn't visible (headless, SSH, etc.).
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

    default:
        // Fall through to UI mode for unknown args (let the app show its menu).
        break
    }
}

// MARK: Menu bar UI mode

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // No Dock icon, just menu bar.
let delegate = AppDelegate()
app.delegate = delegate
app.run()
