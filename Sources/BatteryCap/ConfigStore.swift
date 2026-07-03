//
//  ConfigStore.swift
//  BatteryCap
//
//  Persists the chosen cap value so the LaunchDaemon can re-apply it on boot
//  without UI. The file lives at /usr/local/etc/battery-cap.conf and contains
//  a single integer (the cap value, 50..100). Written from the privileged
//  helper context (the same osascript call that writes BCLM), so root-owned.
//

import Foundation

enum ConfigStore {
    /// Path is fixed. The LaunchDaemon also reads this exact path.
    static let path = "/usr/local/etc/battery-cap.conf"

    static func read() throws -> Int? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let str = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(str) else {
            return nil
        }
        return value
    }

    /// Writes the cap value. Caller is expected to be root (the privileged
    /// helper). Creates the parent dir if missing.
    static func write(cap: Int) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let data = "\(cap)\n".data(using: .utf8)!
        if FileManager.default.fileExists(atPath: path) {
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            FileManager.default.createFile(atPath: path, contents: data,
                                           attributes: [.posixPermissions: 0o644])
        }
    }
}
