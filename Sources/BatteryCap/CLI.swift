//
//  CLI.swift
//  BatteryCap
//
//  First-class CLI for Claude-driven remote management. Subcommand structure
//  rather than flag explosion. Supports --json output for parseable responses.
//
//  Existing --read/--write/--boot-apply modes are preserved for the
//  LaunchDaemon and backward compatibility — they live in main.swift.
//

import Foundation

enum CLI {

    // MARK: Entry point

    /// Dispatch a subcommand. Args is the FULL CommandLine.arguments
    /// (binary path at index 0, command at index 1, sub-args after).
    /// Returns exit code.
    static func dispatch(_ args: [String]) -> Int32 {
        // args.count <= 1: no command given.
        //   TTY present  → launch menu bar UI (preserves "double-click" UX).
        //   No TTY       → print status (for SSH scripts, pipes).
        if args.count <= 1 {
            if isatty(fileno(stdin)) != 0 {
                return launchUI()
            }
            return StatusCommand.run(args: [])
        }

        let command = args[1].lowercased()
        var commandArgs = Array(args.dropFirst(2))  // Skip binary + command.

        // Strip global --json / --help flags from the sub-args.
        var jsonMode = false
        var helpRequested = false
        var filtered: [String] = []
        for arg in commandArgs {
            switch arg {
            case "--json": jsonMode = true
            case "--help", "-h": helpRequested = true
            default: filtered.append(arg)
            }
        }
        commandArgs = filtered
        globalJSON = jsonMode

        if helpRequested {
            return HelpCommand.run(forCommand: command)
        }

        switch command {
        case "status":      return StatusCommand.run(args: commandArgs)
        case "get":         return GetCommand.run(args: commandArgs)
        case "set":         return SetCommand.run(args: commandArgs)
        case "clear", "off", "disable":
            return ClearCommand.run(args: commandArgs)
        case "test":        return TestCommand.run(args: commandArgs)
        case "persist":     return PersistCommand.run(args: commandArgs)
        case "log":         return LogCommand.run(args: commandArgs)
        case "conflicts":   return ConflictsCommand.run(args: commandArgs)
        case "ui", "menu", "tray":
            return launchUI()
        case "version", "--version", "-v":
            return VersionCommand.run(args: commandArgs)
        case "help", "--help", "-h":
            return HelpCommand.run(args: commandArgs)
        default:
            err("Unknown command: \(command)")
            err("Run 'batterycap help' for usage.")
            return EXIT_FAILURE
        }
    }

    // MARK: Shared helpers

    /// Set by --json global flag. When true, commands emit JSON instead of
    /// human-readable text.
    static var globalJSON: Bool = false

    /// Print to stdout.
    static func out(_ s: String) {
        print(s)
    }

    /// Print to stderr.
    static func err(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    /// Print a value as JSON. Uses JSONSerialization for proper escaping.
    static func printJSON(_ object: Any) {
        do {
            var opts: JSONSerialization.WritingOptions = [.sortedKeys]
            // Pretty-print for human readability; Claude parses either way.
            opts.insert(.prettyPrinted)
            let data = try JSONSerialization.data(withJSONObject: object, options: opts)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } catch {
            err("JSON serialization failed: \(error)")
        }
    }

    /// True if running as root.
    static var isRoot: Bool {
        return getuid() == 0
    }

    /// Print a "needs root" error and exit with EX_NOPERM.
    @discardableResult
    static func requireRoot() -> Bool {
        if isRoot { return true }
        err("This command modifies the SMC and must run as root.")
        err("Re-run with: sudo batterycap ...")
        return false
    }

    /// Launch the menu bar UI. Returns EXIT_SUCCESS on app termination.
    static func launchUI() -> Int32 {
        // We import AppKit lazily here so the CLI commands don't require
        // AppKit to be linked at startup. (Swift compiles them all into
        // the same binary anyway, but this signals intent.)
        return AppDelegate.launchApplication()
    }
}

// MARK: - status

enum StatusCommand {
    static func run(args: [String]) -> Int32 {
        let charge = BatteryMonitor().currentChargePercent()
        let cap = (try? CapController.readCap()) ?? nil
        let conflicts = ConflictDetector().detect().conflicts
        let testState = TestModeController.status()
        let persistenceInstalled = FileManager.default.fileExists(
            atPath: PersistenceInstaller.plistPath
        )

        if CLI.globalJSON {
            CLI.printJSON([
                "charge_percent": charge,
                "cap_percent": cap as Any,
                "persistence": [
                    "installed": persistenceInstalled,
                    "plist_path": PersistenceInstaller.plistPath
                ] as [String: Any],
                "test_mode": [
                    "active": testState != nil,
                    "test_value": testState?.testValue as Any,
                    "remaining_seconds": testState?.remainingSeconds as Any,
                    "expires_at": testState != nil
                        ? ISO8601DateFormatter().string(from: testState!.expiresAt)
                        : NSNull()
                ] as [String: Any],
                "conflicts": conflicts.map { $0.title }
            ])
            return EXIT_SUCCESS
        }

        // Human-readable
        CLI.out("BatteryCap status")
        CLI.out("─────────────────────────────────────")
        CLI.out("Platform:  \(Platform.current.shortLabel)")
        if !Platform.current.canControlChargeViaSMC {
            CLI.out("           \(Platform.current.statusTag) — SMC cap unavailable")
        }
        CLI.out("Charge:    \(charge >= 0 ? "\(charge)%" : "unknown")")
        if Platform.current.canControlChargeViaSMC {
            CLI.out("Cap:       \(cap.map { "\($0)%" } ?? "not set")")
            CLI.out("Persist:   \(persistenceInstalled ? "enabled (LaunchDaemon loaded)" : "disabled")")
            if let test = testState {
                let mins = test.remainingSeconds / 60
                let secs = test.remainingSeconds % 60
                CLI.out("Test mode: ACTIVE (value=\(test.testValue)%, \(mins)m\(secs)s remaining, reverts to \(test.originalCap)%)")
            } else {
                CLI.out("Test mode: inactive")
            }
        } else {
            // Surface the recommendation as a status hint.
            CLI.out("")
            CLI.out("Recommendation:")
            let sentences = Platform.current.recommendation
                .split(separator: ". ")
                .map { $0.hasSuffix(".") ? String($0) : String($0) + "." }
            for sentence in sentences {
                CLI.out("  \(sentence)")
            }
        }
        if conflicts.isEmpty {
            CLI.out("Conflicts: ✓ none detected")
        } else {
            CLI.out("Conflicts: ⚠️  \(conflicts.count) detected:")
            for c in conflicts {
                CLI.out("  - \(c.title)")
            }
            CLI.out("  Run 'batterycap conflicts' for details.")
        }
        return EXIT_SUCCESS
    }
}

// MARK: - get

enum GetCommand {
    static func run(args: [String]) -> Int32 {
        let what = args.first?.lowercased() ?? ""
        switch what {
        case "cap", "limit":
            let cap = (try? CapController.readCap()) ?? nil
            if CLI.globalJSON {
                CLI.printJSON(["cap_percent": cap as Any])
            } else {
                CLI.out(cap.map { "\($0)" } ?? "not set")
            }
            return EXIT_SUCCESS

        case "charge", "battery":
            let charge = BatteryMonitor().currentChargePercent()
            if CLI.globalJSON {
                CLI.printJSON(["charge_percent": charge])
            } else {
                CLI.out("\(charge)")
            }
            return EXIT_SUCCESS

        case "conflicts":
            return ConflictsCommand.run(args: Array(args.dropFirst()))

        case "test":
            let state = TestModeController.status()
            if CLI.globalJSON {
                CLI.printJSON([
                    "active": state != nil,
                    "test_value": state?.testValue as Any,
                    "remaining_seconds": state?.remainingSeconds as Any
                ])
            } else if let s = state {
                CLI.out("active value=\(s.testValue)% remaining=\(s.remainingSeconds)s reverts_to=\(s.originalCap)%")
            } else {
                CLI.out("inactive")
            }
            return EXIT_SUCCESS

        case "persist":
            let installed = FileManager.default.fileExists(atPath: PersistenceInstaller.plistPath)
            if CLI.globalJSON {
                CLI.printJSON([
                    "installed": installed,
                    "plist_path": PersistenceInstaller.plistPath
                ])
            } else {
                CLI.out(installed ? "enabled" : "disabled")
            }
            return EXIT_SUCCESS

        default:
            CLI.err("Usage: batterycap get <cap|charge|conflicts|test|persist>")
            return EXIT_FAILURE
        }
    }
}

// MARK: - set

enum SetCommand {
    static func run(args: [String]) -> Int32 {
        guard CLI.requireRoot() else { return Int32(EX_NOPERM) }
        guard let valueStr = args.first, let value = Int(valueStr) else {
            CLI.err("Usage: batterycap set <50-100>")
            return EXIT_FAILURE
        }
        guard (50...100).contains(value) else {
            CLI.err("Value must be 50..100, got \(value)")
            return EXIT_FAILURE
        }
        // Platform-specific validation: Apple Silicon only allows 80 or 100.
        guard Platform.current.isValid(cap: value) else {
            CLI.err("\(Platform.current.displayName) only supports: \(Platform.current.validCapValues.map { "\($0)%" }.joined(separator: ", "))")
            CLI.err("Got: \(value)%. CHWA is a binary 80%/100% toggle on Apple Silicon.")
            return EXIT_FAILURE
        }
        // Refuse if test mode is active — set would conflict with the test cap.
        if TestModeController.status() != nil {
            CLI.err("Test mode is active. Run 'batterycap test end' first.")
            return EXIT_FAILURE
        }
        do {
            try CapController.writeCap(value: value)
            try? CapController.writeBFCL(value: max(value - 5, 50))
            _ = try? ConfigStore.write(cap: value)
            DiagnosticsLogger.log("[cli] set: value=\(value)%")
            if CLI.globalJSON {
                CLI.printJSON(["ok": true, "cap_percent": value])
            } else {
                CLI.out("Cap set to \(value)%. Saved to config (will re-apply on boot if persistence is enabled).")
            }
            return EXIT_SUCCESS
        } catch {
            CLI.err("SMC write failed: \(error)")
            return EXIT_FAILURE
        }
    }
}

// MARK: - clear

enum ClearCommand {
    static func run(args: [String]) -> Int32 {
        guard CLI.requireRoot() else { return Int32(EX_NOPERM) }
        // End any active test mode first, then set cap to 100.
        if TestModeController.status() != nil {
            _ = try? TestModeController.end()
        }
        do {
            try CapController.writeCap(value: 100)
            try? CapController.writeBFCL(value: 95)  // BFCL internally no-ops on Apple Silicon
            _ = try? ConfigStore.write(cap: 100)
            DiagnosticsLogger.log("[cli] clear: cap removed (set to 100)")
            if CLI.globalJSON {
                CLI.printJSON(["ok": true, "cap_percent": 100])
            } else {
                CLI.out("Cap removed. Battery will charge to 100%.")
            }
            return EXIT_SUCCESS
        } catch {
            CLI.err("SMC write failed: \(error)")
            return EXIT_FAILURE
        }
    }
}

// MARK: - test

enum TestCommand {
    static func run(args: [String]) -> Int32 {
        let sub = args.first?.lowercased() ?? "status"

        switch sub {
        case "start":
            guard CLI.requireRoot() else { return Int32(EX_NOPERM) }
            var rest = Array(args.dropFirst())
            var explicitValue: Int? = nil
            var duration = TestModeController.defaultDurationSeconds

            // Parse --value N and --for N (minutes)
            while !rest.isEmpty {
                let flag = rest.removeFirst()
                switch flag {
                case "--value", "-v":
                    if let v = rest.first, let parsed = Int(v) {
                        explicitValue = parsed
                        rest.removeFirst()
                    } else {
                        CLI.err("--value requires an integer argument")
                        return EXIT_FAILURE
                    }
                case "--for":
                    if let v = rest.first, let minutes = Int(v) {
                        duration = minutes * 60
                        rest.removeFirst()
                    } else {
                        CLI.err("--for requires an integer (minutes) argument")
                        return EXIT_FAILURE
                    }
                default:
                    CLI.err("Unknown flag: \(flag)")
                    return EXIT_FAILURE
                }
            }

            do {
                let state = try TestModeController.start(
                    explicitValue: explicitValue,
                    durationSeconds: duration
                )
                if CLI.globalJSON {
                    let fmt = ISO8601DateFormatter()
                    CLI.printJSON([
                        "ok": true,
                        "test_value": state.testValue,
                        "original_cap": state.originalCap,
                        "expires_at": fmt.string(from: state.expiresAt),
                        "remaining_seconds": state.remainingSeconds
                    ])
                } else {
                    let fmt = ISO8601DateFormatter()
                    CLI.out("Test mode started.")
                    CLI.out("  Test value: \(state.testValue)%")
                    CLI.out("  Original cap: \(state.originalCap)% (will be restored)")
                    CLI.out("  Duration: \(duration / 60) minutes")
                    CLI.out("  Expires: \(fmt.string(from: state.expiresAt))")
                    CLI.out("  Reverter PID: \(state.reverterPid)")
                    CLI.out("")
                    CLI.out("Run 'batterycap test status' to check, 'batterycap test end' to revert early.")
                }
                return EXIT_SUCCESS
            } catch {
                CLI.err("\(error)")
                return EXIT_FAILURE
            }

        case "end", "stop", "cancel":
            guard CLI.requireRoot() else { return Int32(EX_NOPERM) }
            do {
                let restored = try TestModeController.end()
                if CLI.globalJSON {
                    CLI.printJSON(["ok": true, "restored_cap": restored])
                } else {
                    CLI.out("Test mode ended. Cap restored to \(restored)%.")
                }
                return EXIT_SUCCESS
            } catch {
                CLI.err("\(error)")
                return EXIT_FAILURE
            }

        case "status":
            let state = TestModeController.status()
            if CLI.globalJSON {
                CLI.printJSON([
                    "active": state != nil,
                    "test_value": state?.testValue as Any,
                    "remaining_seconds": state?.remainingSeconds as Any
                ])
            } else if let s = state {
                let mins = s.remainingSeconds / 60
                let secs = s.remainingSeconds % 60
                CLI.out("Test mode ACTIVE")
                CLI.out("  Test value: \(s.testValue)%")
                CLI.out("  Reverts to: \(s.originalCap)%")
                CLI.out("  Remaining:  \(mins)m\(secs)s")
            } else {
                CLI.out("Test mode inactive.")
            }
            return EXIT_SUCCESS

        default:
            CLI.err("Usage: batterycap test <start|end|status>")
            return EXIT_FAILURE
        }
    }
}

// MARK: - persist

enum PersistCommand {
    static func run(args: [String]) -> Int32 {
        let sub = args.first?.lowercased() ?? "status"

        switch sub {
        case "enable", "on":
            guard CLI.requireRoot() else { return Int32(EX_NOPERM) }
            // For CLI use, we don't go through osascript — caller is already root.
            // We write the plist directly + load via launchctl.
            let selfPath = CommandLine.arguments[0]
            do {
                try Self.writeAndLoadPlist(binaryPath: selfPath)
                CLI.out("Persistence enabled. LaunchDaemon installed at \(PersistenceInstaller.plistPath).")
                // Seed config if missing so boot-apply has a default.
                if (try? ConfigStore.read()) == nil {
                    _ = try? ConfigStore.write(cap: 60)
                    CLI.out("Config seeded with default 60% (edit via 'batterycap set N').")
                }
                return EXIT_SUCCESS
            } catch {
                CLI.err("Failed to enable persistence: \(error)")
                return EXIT_FAILURE
            }

        case "disable", "off":
            guard CLI.requireRoot() else { return Int32(EX_NOPERM) }
            let task = Process()
            task.launchPath = "/bin/launchctl"
            task.arguments = ["bootout", "system/\(PersistenceInstaller.label)"]
            try? task.run()
            task.waitUntilExit()
            try? FileManager.default.removeItem(atPath: PersistenceInstaller.plistPath)
            CLI.out("Persistence disabled. LaunchDaemon removed.")
            return EXIT_SUCCESS

        case "status":
            let installed = FileManager.default.fileExists(atPath: PersistenceInstaller.plistPath)
            if CLI.globalJSON {
                CLI.printJSON([
                    "installed": installed,
                    "plist_path": PersistenceInstaller.plistPath
                ])
            } else {
                CLI.out(installed ? "enabled" : "disabled")
            }
            return EXIT_SUCCESS

        default:
            CLI.err("Usage: batterycap persist <enable|disable|status>")
            return EXIT_FAILURE
        }
    }

    /// Direct plist write + launchctl load (no osascript — assumes root).
    static func writeAndLoadPlist(binaryPath: String) throws {
        // XML plist doesn't need shell-style escaping. Paths with `<` or `&`
        // are essentially impossible for app bundle paths; if you care, add
        // proper XML escaping here.
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(PersistenceInstaller.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>--boot-apply</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StartInterval</key>
            <integer>3600</integer>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """

        // bootout first if loaded (upgrade-safe).
        let bootout = Process()
        bootout.launchPath = "/bin/launchctl"
        bootout.arguments = ["bootout", "system/\(PersistenceInstaller.label)"]
        try? bootout.run()
        bootout.waitUntilExit()

        try plistContent.write(toFile: PersistenceInstaller.plistPath,
                               atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644, .ownerAccountName: "root", .groupOwnerAccountName: "wheel"],
            ofItemAtPath: PersistenceInstaller.plistPath
        )

        let bootstrap = Process()
        bootstrap.launchPath = "/bin/launchctl"
        bootstrap.arguments = ["bootstrap", "system/\(PersistenceInstaller.label)",
                               PersistenceInstaller.plistPath]
        try bootstrap.run()
        bootstrap.waitUntilExit()
    }
}

// MARK: - log

enum LogCommand {
    static func run(args: [String]) -> Int32 {
        let sub = args.first?.lowercased() ?? "show"
        let rest = Array(args.dropFirst())

        switch sub {
        case "show", "tail":
            let lines = DiagnosticsLogger.tail(extractLineCount(rest, default: 100))
            if CLI.globalJSON {
                CLI.printJSON(["lines": lines.split(separator: "\n").map(String.init)])
            } else {
                CLI.out(lines)
            }
            return EXIT_SUCCESS

        case "grep":
            guard let pattern = rest.first else {
                CLI.err("Usage: batterycap log grep <pattern>")
                return EXIT_FAILURE
            }
            let all = DiagnosticsLogger.tail(Int.max)
            let matched = all.split(separator: "\n")
                .filter { $0.contains(pattern) }
                .joined(separator: "\n")
            if CLI.globalJSON {
                CLI.printJSON(["matches": matched.split(separator: "\n").map(String.init)])
            } else {
                CLI.out(matched)
            }
            return EXIT_SUCCESS

        default:
            CLI.err("Usage: batterycap log <show|grep>")
            return EXIT_FAILURE
        }
    }

    private static func extractLineCount(_ args: [String], default def: Int) -> Int {
        // Look for -n N or --lines N
        var iter = args.makeIterator()
        while let arg = iter.next() {
            if arg == "-n" || arg == "--lines" {
                if let v = iter.next(), let n = Int(v) { return n }
            }
        }
        return def
    }
}

// MARK: - conflicts

enum ConflictsCommand {
    static func run(args: [String]) -> Int32 {
        let result = ConflictDetector().detect()
        if CLI.globalJSON {
            CLI.printJSON([
                "count": result.conflicts.count,
                "conflicts": result.conflicts.map { c in
                    ["title": c.title, "detail": c.detail]
                }
            ])
        } else if result.conflicts.isEmpty {
            CLI.out("✓ No conflicts detected.")
        } else {
            CLI.out("\(result.conflicts.count) conflict(s) detected:")
            CLI.out("")
            for c in result.conflicts {
                CLI.out("• \(c.title)")
                // Indent the detail block
                for line in c.detail.split(separator: "\n") {
                    CLI.out("  \(line)")
                }
                CLI.out("")
            }
        }
        return result.conflicts.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE
    }
}

// MARK: - version / help

enum VersionCommand {
    static func run(args: [String]) -> Int32 {
        if CLI.globalJSON {
            CLI.printJSON(["version": "0.3.0", "target": "Intel MacBook (A1706)"])
        } else {
            CLI.out("BatteryCap v0.3.0")
        }
        return EXIT_SUCCESS
    }
}

enum HelpCommand {
    static func run(args: [String]) -> Int32 {
        return run(forCommand: args.first)
    }

    static func run(forCommand command: String?) -> Int32 {
        if let command = command, !command.isEmpty, command != "help" {
            return printCommandHelp(command)
        }
        printFullHelp()
        return EXIT_SUCCESS
    }

    private static func printFullHelp() {
        CLI.out("""
        BatteryCap — cap Intel MacBook charge via SMC BCLM

        USAGE
          batterycap <command> [subcommand] [flags]
          batterycap                  # TTY: launch UI. Pipe/SSH: print status

        COMMANDS
          status                      # Full state: charge, cap, test, persist, conflicts
          get <cap|charge|test|persist|conflicts>
                                      # Single value (script-friendly)
          set <50-100>                # Persistent cap (writes SMC + config)
          clear                       # Remove cap (sets to 100%)
          test <start|end|status>     # Non-persistent test mode
          persist <enable|disable|status>
                                      # Manage LaunchDaemon
          log <show|grep>             # Inspect drift log
          conflicts                   # List conflicts with remediation hints
          ui                          # Launch menu bar UI
          version, help

        GLOBAL FLAGS
          --json                      # Machine-readable output (for Claude/scripts)
          --help, -h                  # Per-command help

        EXAMPLES
          batterycap status                      # See everything
          batterycap status --json               # Same, parseable
          sudo batterycap set 60                 # Persistent cap at 60%
          sudo batterycap test start             # Test cap at current+3 for 30min
          sudo batterycap test start --for 60    # 60-minute test
          sudo batterycap test start --value 55  # Specific value (skips auto-calc)
          batterycap test status                 # Check test state
          sudo batterycap test end               # End test, restore previous cap
          batterycap log grep drift=true         # Find drift events
          sudo batterycap persist enable          # Install LaunchDaemon

        EXIT CODES
          0   Success
          1   Generic failure (SMC write error, etc.)
          64  Usage error (EX_USAGE)
          77  Permission denied — re-run with sudo (EX_NOPERM)

        DOCUMENTATION
          README.md         — install + troubleshooting
          docs/PRD.md       — full product requirements doc
        """)
    }

    private static func printCommandHelp(_ command: String) -> Int32 {
        switch command.lowercased() {
        case "status":
            CLI.out("batterycap status [--json]  —  full state snapshot")
        case "get":
            CLI.out("batterycap get <cap|charge|test|persist|conflicts> [--json]")
        case "set":
            CLI.out("batterycap set <50-100>  —  persistent cap (requires sudo)")
        case "clear":
            CLI.out("batterycap clear  —  remove cap, set to 100% (requires sudo)")
        case "test":
            CLI.out("""
            batterycap test <start|end|status>

              start [--value V] [--for MINUTES]   (default value=current+3, duration=30min)
              end                                  (restore previous cap)
              status                               (show remaining time)
            """)
        case "persist":
            CLI.out("batterycap persist <enable|disable|status>")
        case "log":
            CLI.out("batterycap log <show [-n N]|grep PATTERN>")
        case "conflicts":
            CLI.out("batterycap conflicts [--json]  —  list detected conflicts")
        default:
            CLI.err("No help for unknown command: \(command)")
            return EXIT_FAILURE
        }
        return EXIT_SUCCESS
    }
}
