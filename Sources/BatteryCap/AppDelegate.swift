//
//  AppDelegate.swift
//  BatteryCap
//
//  Owns the NSApplication lifecycle and the menu bar status item.
//

import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var monitor: BatteryMonitor!
    private var capController: CapController!
    private var persistence: PersistenceInstaller!

    // UI state. Refreshed by `refresh()`.
    private var currentCharge: Int = -1     // -1 = unknown
    private var currentCap: Int? = nil      // nil = unknown / not set
    private var pendingCap: Int? = nil      // while async write in flight
    private var isApplyingCap: Bool = false

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
    }

    // MARK: Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false  // We manage enabled state ourselves.

        menu.addItem(withTitle: "BatteryCap",
                     action: nil, keyEquivalent: "").isEnabled = false

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

        let quitItem = menu.addItem(withTitle: "Quit BatteryCap",
                                    action: #selector(quit),
                                    keyEquivalent: "q")
        quitItem.target = self

        return menu
    }

    // MARK: Actions

    @objc private func setCap(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        guard !isApplyingCap else { return }
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
        statusItem.button?.title = "🔋 \(chargeText) · \(capText)"

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
            if let persistItem = menu.item(withTag: 102) {
                persistItem.title = persistence.isInstalled
                    ? "Disable persistence on boot"
                    : "Persist cap on boot  ✓ to enable"
                persistItem.state = persistence.isInstalled ? .on : .off
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
