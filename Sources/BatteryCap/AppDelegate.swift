//
//  AppDelegate.swift
//  BatteryCap
//
//  Owns the NSApplication lifecycle and the menu bar status item.
//

import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: UI launch entry point (used by CLI when no args + TTY)

    /// Sets up the NSApplication loop and runs it. Returns EXIT_SUCCESS on
    /// termination. Called from CLI.launchUI() — kept here so the CLI
    /// doesn't need to know about AppKit.
    static func launchApplication() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // No Dock icon.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        return EXIT_SUCCESS
    }

    // MARK: Instance state

    private var statusItem: NSStatusItem!
    private var monitor: BatteryMonitor!
    private var capController: CapController!
    private var persistence: PersistenceInstaller!

    // UI state. Refreshed by `refresh()`.
    private var currentCharge: Int = -1     // -1 = unknown
    private var currentCap: Int? = nil      // nil = unknown / not set
    private var pendingCap: Int? = nil      // while async write in flight
    private var isApplyingCap: Bool = false

    // Conflict detection state.
    private var detectedConflicts: [ConflictDetector.Conflict] = []
    private var conflictCheckComplete: Bool = false  // false until first scan returns

    // Sanity bounds. BCLM is documented 50..100; we cap UI at 80 because
    // above 80 makes no sense for the calendar-aging use case.
    private let capChoices: [Int] = [50, 60, 70, 80]

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = BatteryMonitor()
        capController = CapController()
        persistence = PersistenceInstaller()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()

        // Poll battery every 60s. SMC cap rarely changes, so cheap poll is fine.
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()

        // Run conflict detection asynchronously. pmset -g takes ~50ms; we
        // don't want to block the menu bar from appearing.
        runConflictDetection()
    }

    // MARK: Conflict detection

    private func runConflictDetection() {
        conflictCheckComplete = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ConflictDetector().detect()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.detectedConflicts = result.conflicts
                self.conflictCheckComplete = true
                self.refresh()
            }
        }
    }

    @objc private func rescanConflicts() {
        runConflictDetection()
    }

    @objc private func showConflictDialog() {
        let alert = NSAlert()
        alert.messageText = detectedConflicts.isEmpty
            ? "No conflicts detected"
            : "\(detectedConflicts.count) conflict(s) detected"
        alert.alertStyle = detectedConflicts.isEmpty ? .informational : .warning

        if detectedConflicts.isEmpty {
            alert.informativeText = """
                Checked for: macOS Optimized Battery Charging, AlDente, batt,
                bclm persistence, and macOS 26.4+ native charge limit.

                None found. Your BatteryCap cap should hold without interference.
                """
        } else {
            // One block per conflict: title + detail, separated by a divider.
            let body = detectedConflicts.map { conflict in
                "\(conflict.title)\n\n\(conflict.detail)"
            }.joined(separator: "\n\n————————————————\n\n")
            alert.informativeText = body
        }

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Re-scan")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            runConflictDetection()
        }
    }

    // MARK: Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false  // We manage enabled state ourselves.

        menu.addItem(withTitle: "BatteryCap",
                     action: nil, keyEquivalent: "").isEnabled = false

        // Conflict status row. Title is dynamically updated in refresh().
        // Clicking opens the detail dialog. Sits at the top so it's visible.
        let conflictItem = menu.addItem(withTitle: "Checking for conflicts…",
                                        action: #selector(showConflictDialog),
                                        keyEquivalent: "")
        conflictItem.target = self
        conflictItem.tag = 300

        menu.addItem(.separator())

        let chargeItem = menu.addItem(withTitle: "Current charge: …",
                                      action: nil, keyEquivalent: "")
        chargeItem.isEnabled = false
        chargeItem.tag = 100

        let capItem = menu.addItem(withTitle: "Charge cap: …",
                                   action: nil, keyEquivalent: "")
        capItem.isEnabled = false
        capItem.tag = 101

        menu.addItem(.separator())

        let targetHeader = menu.addItem(withTitle: "Set cap to:",
                                        action: nil, keyEquivalent: "")
        targetHeader.isEnabled = false

        for value in capChoices {
            let item = menu.addItem(withTitle: "\(value)%",
                                    action: #selector(setCap(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.tag = value
        }

        // Free-form entry. Pre-fills with current_charge + 3 (clamped) for
        // the fast proving test described in the README.
        let customItem = menu.addItem(withTitle: "Set custom cap…",
                                      action: #selector(setCustomCap),
                                      keyEquivalent: "")
        customItem.target = self
        customItem.tag = 200

        menu.addItem(.separator())

        let removeItem = menu.addItem(withTitle: "Remove cap (100%)",
                                      action: #selector(removeCap(_:)),
                                      keyEquivalent: "")
        removeItem.target = self

        menu.addItem(.separator())

        let persistItem = menu.addItem(withTitle: "Persist on boot: …",
                                       action: #selector(togglePersistence(_:)),
                                       keyEquivalent: "")
        persistItem.target = self
        persistItem.tag = 102

        menu.addItem(.separator())

        // Manual re-scan for conflicts. Useful after the user has resolved
        // a conflict (e.g., uninstalled AlDente) to confirm BatteryCap sees
        // a clean state.
        let rescanItem = menu.addItem(withTitle: "Re-scan for conflicts",
                                      action: #selector(rescanConflicts),
                                      keyEquivalent: "")
        rescanItem.target = self

        menu.addItem(.separator())

        let quitItem = menu.addItem(withTitle: "Quit BatteryCap",
                                    action: #selector(quit),
                                    keyEquivalent: "q")
        quitItem.target = self

        return menu
    }

    // MARK: Actions

    /// Shared apply path used by both the preset buttons and the custom
    /// dialog. Bounds check is the caller's responsibility.
    private func applyCapValue(_ value: Int) {
        guard !isApplyingCap else { return }
        guard (50...100).contains(value) else { return }
        isApplyingCap = true
        pendingCap = value
        refresh()

        capController.applyCap(value: UInt8(value)) { [weak self] result in
            guard let self = self else { return }
            self.isApplyingCap = false
            switch result {
            case .success:
                self.currentCap = value
                self.pendingCap = nil
            case .failure(let error):
                self.pendingCap = nil
                self.showError(error)
            }
            self.refresh()
        }
    }

    @objc private func setCap(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        applyCapValue(value)
    }

    /// Opens a modal dialog with a free-form cap entry. Pre-fills with the
    /// existing cap if set, otherwise `current charge + 3` clamped to 50..100
    /// (the "fast proving test" value).
    @objc private func setCustomCap() {
        guard !isApplyingCap else { return }

        // Compute suggested value.
        let suggested: Int
        if let cap = currentCap, cap < 100, cap >= 50 {
            suggested = cap
        } else if currentCharge >= 0 {
            suggested = min(max(currentCharge + 3, 50), 100)
        } else {
            suggested = 60
        }

        let alert = NSAlert()
        alert.messageText = "Set custom charge cap"
        let chargeStr = currentCharge >= 0 ? "\(currentCharge)%" : "unknown"
        let overshoot = min(suggested + 3, 100)
        alert.informativeText = """
            Enter an integer from 50 to 100.

            Current charge: \(chargeStr)
            Suggested: \(suggested)% → battery will charge to ~\(overshoot)% (Intel firmware overshoots ~3%)

            Tip: set cap to current charge + 3 for the fastest plateau test.
            """
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        textField.stringValue = "\(suggested)"
        textField.placeholderString = "50–100"
        alert.accessoryView = textField
        // Focus the text field on open so the user can type immediately.
        alert.window.initialFirstResponder = textField

        alert.addButton(withTitle: "Set cap")
        alert.addButton(withTitle: "Cancel")

        // runModal() blocks the main thread — fine here because menu bar
        // interactions are user-driven and the OS keeps the run loop alive.
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (50...100).contains(value) else {
            let errAlert = NSAlert()
            errAlert.alertStyle = .warning
            errAlert.messageText = "Invalid value"
            errAlert.informativeText = """
                "\(trimmed)" is not an integer between 50 and 100.

                BCLM is a UInt8 storing 0–100; values outside 50–100 are rejected \
                to avoid deep-discharge risk (below 50) or no-op writes (above 100).
                """
            errAlert.addButton(withTitle: "OK")
            errAlert.runModal()
            return
        }

        applyCapValue(value)
    }

    @objc private func removeCap(_ sender: NSMenuItem) {
        guard !isApplyingCap else { return }
        isApplyingCap = true
        pendingCap = 100
        refresh()

        // Remove cap = write BCLM = 100. Also clears persisted config.
        capController.applyCap(value: 100) { [weak self] result in
            guard let self = self else { return }
            self.isApplyingCap = false
            switch result {
            case .success:
                self.currentCap = 100
                self.pendingCap = nil
            case .failure(let error):
                self.pendingCap = nil
                self.showError(error)
            }
            self.refresh()
        }
    }

    @objc private func togglePersistence(_ sender: NSMenuItem) {
        let installed = persistence.isInstalled
        persistence.setPersisted(!installed) { [weak self] success in
            guard let self = self else { return }
            if !success {
                self.showError(NSError(
                    domain: "BatteryCap",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to toggle persistence."]
                ))
            }
            self.refresh()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Refresh

    /// Re-reads battery + cap state and updates the menu.
    /// Called on app launch, every 60s, and after each user action.
    private func refresh() {
        currentCharge = monitor.currentChargePercent()
        currentCap = capController.readCap()

        // Status item title
        let chargeText = currentCharge >= 0 ? "\(currentCharge)%" : "—"
        let capText: String
        if isApplyingCap, let pending = pendingCap {
            capText = "→ \(pending)%"
        } else if let cap = currentCap {
            capText = cap >= 100 ? "no cap" : "cap \(cap)%"
        } else {
            capText = "cap ?"
        }
        // Prefix with ⚠️ when conflicts are detected. The visual indicator
        // in the menu bar means the user doesn't need to open the menu to
        // know something needs attention.
        let warningPrefix = !detectedConflicts.isEmpty ? "⚠️ " : ""
        statusItem.button?.title = "\(warningPrefix)🔋 \(chargeText) · \(capText)"

        // Menu items
        if let menu = statusItem.menu {
            if let chargeItem = menu.item(withTag: 100) {
                chargeItem.title = "Current charge: \(chargeText)"
            }
            if let capItem = menu.item(withTag: 101) {
                capItem.title = "Charge cap: \(capText)"
            }
            for value in capChoices {
                if let item = menu.item(withTag: value) {
                    let active = (currentCap == value) || (pendingCap == value)
                    item.state = active ? .on : .off
                    item.isEnabled = !isApplyingCap
                }
            }
            if let customItem = menu.item(withTag: 200) {
                // Show a checkmark if the current cap is non-preset.
                let isPreset = capChoices.contains(currentCap ?? -1) || capChoices.contains(pendingCap ?? -1)
                customItem.state = (!isPreset && (currentCap ?? 0) < 100) ? .on : .off
                customItem.isEnabled = !isApplyingCap
            }
            if let persistItem = menu.item(withTag: 102) {
                persistItem.title = persistence.isInstalled
                    ? "Disable persistence on boot"
                    : "Persist cap on boot  ✓ to enable"
                persistItem.state = persistence.isInstalled ? .on : .off
            }
            if let conflictItem = menu.item(withTag: 300) {
                if !conflictCheckComplete {
                    conflictItem.title = "Checking for conflicts…"
                    conflictItem.isEnabled = false
                } else if detectedConflicts.isEmpty {
                    conflictItem.title = "✓ No conflicts detected"
                    conflictItem.isEnabled = true  // Still clickable for details
                } else {
                    conflictItem.title = "⚠️ \(detectedConflicts.count) conflict(s) — click for details"
                    conflictItem.isEnabled = true
                }
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "BatteryCap"
        alert.informativeText = "\(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
