//
//  BatteryMonitor.swift
//  BatteryCap
//
//  Reads current battery charge via IOKit's IOPowerSources API.
//  No privileges required — this is the same path `pmset -g batt` uses.
//
//  Also exposes readDailyMaxSoc() which reads BatteryData.DailyMaxSoc from
//  the AppleSmartBattery IORegistry node. Used by ConflictDetector to infer
//  OBC / native-charge-limit state on macOS 26+ where pmset no longer
//  exposes the optimizedcharging flag.
//

import Foundation
import IOKit
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

    /// Reads BatteryData.DailyMaxSoc from the AppleSmartBattery IORegistry
    /// node. DailyMaxSoc is the highest state-of-charge the battery reached
    /// today (resets daily). If < 100, the system held charge below max —
    /// either OBC engaged or a native charge limit is set.
    ///
    /// Returns nil if the IORegistry node or key is unavailable.
    static func readDailyMaxSoc() -> Int? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(
            service, &propsUnmanaged, kCFAllocatorDefault, 0
        )
        guard kr == kIOReturnSuccess,
              let dict = propsUnmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        // BatteryData is a nested dictionary containing fuel-gauge telemetry.
        // The DailyMaxSoc/DailyMinSoc keys live inside it.
        guard let batteryData = dict["BatteryData"] as? [String: Any] else {
            return nil
        }
        return batteryData["DailyMaxSoc"] as? Int
    }

    /// Convenience: reads IsCharging + ExternalConnected + CurrentCapacity
    /// for a "is the system currently holding charge below max?" check.
    /// Returns (isCharging, externalConnected, currentCapacity) or nil.
    static func readChargeState() -> (isCharging: Bool, externalConnected: Bool, currentCapacity: Int)? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(
            service, &propsUnmanaged, kCFAllocatorDefault, 0
        )
        guard kr == kIOReturnSuccess,
              let dict = propsUnmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        guard let isCharging = dict["IsCharging"] as? Bool,
              let external = dict["ExternalConnected"] as? Bool,
              let current = dict["CurrentCapacity"] as? Int else {
            return nil
        }
        return (isCharging, external, current)
    }
}

