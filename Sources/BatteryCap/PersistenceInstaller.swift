//
//  PersistenceInstaller.swift
//  BatteryCap
//
//  Installs / uninstalls a LaunchDaemon at
//  /Library/LaunchDaemons/com.ebowwa.battery-cap.plist that re-applies the
//  configured cap on every boot. Installation needs root, so we go through
//  the same osascript admin-privileges path as the SMC write.
//

import Foundation

struct PersistenceInstaller {

    static let plistPath = "/Library/LaunchDaemons/com.ebowwa.battery-cap.plist"
    static let label = "com.ebowwa.battery-cap"

    /// True if the LaunchDaemon plist currently exists at the expected path.
    var isInstalled: Bool {
        return FileManager.default.fileExists(atPath: Self.plistPath)
    }

    /// Installs or removes the LaunchDaemon. Async — calls completion on
    /// main thread with success=true if the operation succeeded.
    func setPersisted(_ enable: Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let selfPath = CommandLine.arguments[0]
            let escapedPath = selfPath.replacingOccurrences(of: "'", with: "'\\''")

            // Build the shell command. We write the plist inline via cat >,
            // then load it via launchctl. Disable = unload + rm.
            let shell: String
            if enable {
                let plist = Self.generatePlist(binaryPath: escapedPath)
                // Write plist, set perms, load it, run it once immediately.
                shell = """
                cat > \(Self.plistPath) <<'PLIST'
                \(plist)
                PLIST
                chown root:wheel \(Self.plistPath)
                chmod 644 \(Self.plistPath)
                launchctl bootstrap system/\(Self.label) \(Self.plistPath) 2>/dev/null || launchctl load -w \(Self.plistPath)
                \(escapedPath) --boot-apply
                """
            } else {
                shell = """
                launchctl bootout system/\(Self.label) 2>/dev/null || launchctl unload -w \(Self.plistPath) 2>/dev/null
                rm -f \(Self.plistPath)
                """
            }

            let script = "do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            let errPipe = Pipe()
            task.standardError = errPipe
            task.standardOutput = Pipe()

            do {
                try task.run()
                task.waitUntilExit()
                let success = (task.terminationStatus == 0)
                if !success {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? ""
                    FileHandle.standardError.write(
                        "persistence toggle failed: \(errMsg)\n".data(using: .utf8)!)
                }
                DispatchQueue.main.async { completion(success) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// One-shot uninstall. Exit code semantics for the --unpersist CLI mode.
    static func uninstall() -> Int32 {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        let script = """
        do shell script "launchctl bootout system/\(label) 2>/dev/null; launchctl unload -w \(plistPath) 2>/dev/null; rm -f \(plistPath)" with administrator privileges
        """
        task.arguments = ["-e", script]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return EXIT_FAILURE
        }
    }

    /// Generates the LaunchDaemon plist XML. The plist runs the binary with
    /// `--boot-apply` at load time, which reads the config file and applies
    /// the saved cap.
    private static func generatePlist(binaryPath: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>--boot-apply</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """
    }
}
