//
//  BatteryMonitor.swift
//  BatteryCap
//
//  Reads current battery charge via IOKit's IOPowerSources API.
//  No privileges required — this is the same path `pmset -g batt` uses.
//

import Foundation
import IOKit.ps

struct BatteryMonitor {

    /// Returns current charge as 0..100, or -1 if no battery is found.
    func currentChargePercent() -> Int {
        // IOPSCopyPowerSourcesInfo returns an Unmanaged<CFTypeRef> blob.
        // IOPSCopyPowerSourcesList returns an Unmanaged<CFArray> of source IDs.
        // IOPSGetPowerSourceDescription returns the per-source dictionary.
        guard let infoUnmanaged = IOPSCopyPowerSourcesInfo() else { return -1 }
        let info = infoUnmanaged.takeRetainedValue()

        guard let listUnmanaged = IOPSCopyPowerSourcesList(info) else { return -1 }
        let list = listUnmanaged.takeRetainedValue() as NSArray

        for case let source as CFTypeRef in list {
            guard let descUnmanaged = IOPSGetPowerSourceDescription(info, source) else {
                continue
            }
            // takeUnretainedValue because IOPSGetPowerSourceDescription returns
            // a +0 reference (not +1, unlike the Copy functions above).
            let desc = descUnmanaged.takeUnretainedValue() as? [String: Any] ?? [:]

            // A battery source has both Current and Max capacity. Pure AC
            // sources (UPS without battery, etc.) won't have these.
            guard let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int,
                  max > 0 else {
                continue
            }
            return Int((Double(current) / Double(max)) * 100.0)
        }
        return -1
    }
}
