//
//  Platform.swift
//  BatteryCap
//
//  4-way platform classification that drives all UI / CLI gating:
//
//    intelFull                 — Intel Mac, full BCLM/BFCL support
//    appleSiliconPre15         — AS macOS <15, CHWA may work (bclm-era)
//    appleSiliconBlocked       — AS macOS 15–26.3, entitlement blocks SMC
//    appleSiliconNativeAPI     — AS macOS 26.4+, use native charge limit
//
//  Arch alone (Intel/AS) is insufficient — AS itself splits three ways by
//  macOS version. UI hides/shows controls based on `canControlChargeViaSMC`.
//

import Foundation

enum Platform {

    #if arch(x86_64)
    static let current: Platform = detectIntelVariant()
    #elseif arch(arm64)
    static let current: Platform = detectAppleSiliconVariant()
    #else
    static let current: Platform = .intelFull
    #endif

    case intelFull
    case appleSiliconPre15
    case appleSiliconBlocked
    case appleSiliconNativeAPI

    // MARK: Detection helpers

    private static func detectIntelVariant() -> Platform {
        // Intel is Intel as far as SMC charge keys go; macOS version doesn't
        // change much (BCLM broken on macOS 15+ per bclm, but we surface that
        // via the ConflictDetector and the entitlement-blocked message).
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion >= 15 {
            // Same entitlement lockdown as AS macOS 15+ — BCLM writes blocked.
            // We don't have a separate enum case for Intel-blocked because the
            // user's A1706 target caps at macOS 13/14 anyway. Log it.
            return .intelFull  // Falls through to runtime probe via canControlChargeViaSMC
        }
        return .intelFull
    }

    private static func detectAppleSiliconVariant() -> Platform {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        // macOS 26.4+ has native charge limit
        if v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 4) {
            return .appleSiliconNativeAPI
        }
        // macOS 15+ blocks SMC via entitlement
        if v.majorVersion >= 15 {
            return .appleSiliconBlocked
        }
        // macOS 13–14 (and older) — CHWA may work
        return .appleSiliconPre15
    }

    // MARK: Capability properties

    /// True if SMC writes for the charge cap can work on this platform.
    /// UI uses this to hide/show cap controls.
    var canControlChargeViaSMC: Bool {
        switch self {
        case .intelFull, .appleSiliconPre15:
            return true
        case .appleSiliconBlocked, .appleSiliconNativeAPI:
            return false
        }
    }

    /// True if persistence (LaunchDaemon) makes sense. Pointless if SMC
    /// writes can't happen.
    var persistenceMakesSense: Bool {
        return canControlChargeViaSMC
    }

    /// True if test mode makes sense. Same logic as persistence.
    var testModeMakesSense: Bool {
        return canControlChargeViaSMC
    }

    /// SMC key name for the cap, or nil if SMC isn't the right path.
    var capKeyName: String? {
        switch self {
        case .intelFull:           return "BCLM"
        case .appleSiliconPre15:   return "CHWA"
        case .appleSiliconBlocked: return "CHWA"  // Key name still nominally CHWA, just blocked
        case .appleSiliconNativeAPI: return nil   // Use native, not SMC
        }
    }

    /// Whether BFCL companion key could exist on this platform.
    var supportsBFCL: Bool {
        return self == .intelFull
    }

    /// Valid cap values for UI/CLI validation.
    var validCapValues: [Int] {
        switch self {
        case .intelFull:           return Array(50...100)
        case .appleSiliconPre15,
             .appleSiliconBlocked,
             .appleSiliconNativeAPI: return [80, 100]
        }
    }

    /// True if the given cap is acceptable on this platform.
    func isValid(cap value: Int) -> Bool {
        return validCapValues.contains(value)
    }

    /// Convert percentage → SMC byte. CHWA is binary (1=80%, 0=100%).
    func smcByte(forCap cap: Int) -> UInt8 {
        switch self {
        case .intelFull:
            return UInt8(cap)
        case .appleSiliconPre15, .appleSiliconBlocked, .appleSiliconNativeAPI:
            return cap == 80 ? 1 : 0
        }
    }

    /// Convert SMC byte → percentage for display.
    func cap(fromSmcByte byte: UInt8) -> Int {
        switch self {
        case .intelFull:
            return Int(byte)
        case .appleSiliconPre15, .appleSiliconBlocked, .appleSiliconNativeAPI:
            return byte == 1 ? 80 : 100
        }
    }

    // MARK: Display

    var archName: String {
        switch self {
        case .intelFull: return "Intel"
        case .appleSiliconPre15,
             .appleSiliconBlocked,
             .appleSiliconNativeAPI: return "Apple Silicon"
        }
    }

    /// Legacy alias for archName. Many call sites still use displayName.
    var displayName: String { return archName }

    /// Short label for the menu / status item (e.g., "Intel · macOS 14",
    /// "Apple Silicon · macOS 26.5").
    var shortLabel: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(archName) · macOS \(v.majorVersion).\(v.minorVersion)"
    }

    /// What the user should do on this platform when SMC cap isn't possible.
    /// Empty for platforms where it IS possible.
    var recommendation: String {
        switch self {
        case .intelFull, .appleSiliconPre15:
            return ""
        case .appleSiliconBlocked:
            return """
                   Charge limiting is blocked on Apple Silicon macOS 15–26.3 by \
                   kernel entitlement enforcement. No userland tool can write \
                   SMC charge keys. Update to macOS 26.4+ for native charge limit.
                   """
        case .appleSiliconNativeAPI:
            return """
                   Use the native macOS charge limit: System Settings → Battery → \
                   Charge Limit (80–100%). BatteryCap does not manage the cap on \
                   this platform — the native API is more capable.
                   """
        }
    }

    /// Short tag for the status item title when SMC cap is unavailable.
    /// Examples: "⚠️ use System Settings", "⚠️ blocked by macOS".
    var statusTag: String {
        switch self {
        case .intelFull, .appleSiliconPre15:
            return ""
        case .appleSiliconBlocked:
            return "⚠️ blocked"
        case .appleSiliconNativeAPI:
            return "⚠️ native"
        }
    }
}
