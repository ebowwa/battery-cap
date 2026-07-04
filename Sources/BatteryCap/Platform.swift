//
//  Platform.swift
//  BatteryCap
//
//  Architecture abstraction for the Intel ↔ Apple Silicon split.
//
//  - Intel: `BCLM` key, percentage 50–100 (continuous).
//  - Apple Silicon: `CHWA` key, binary (1 = 80% cap, 0 = no cap).
//
//  The hardware constraint is real — Apple Silicon's SMC firmware physically
//  cannot hold any value other than 80% or 100%. The UI and CLI must reflect
//  this; "set 65%" is impossible on Apple Silicon, not just unsupported.
//
//  Compiled with #if arch(arm64) / arch(x86_64) so the platform check is
//  zero-cost. A universal binary contains both code paths; at runtime only
//  one is reached.
//

import Foundation

enum Platform {

    #if arch(x86_64)
    static let current: Platform = .intel
    #elseif arch(arm64)
    static let current: Platform = .appleSilicon
    #else
    // Unknown arch — fall back to Intel assumptions (BCLM probe will fail
    // gracefully on AS hardware if we're wrong).
    static let current: Platform = .intel
    #endif

    case intel
    case appleSilicon

    /// SMC key name to read/write for the cap value.
    var capKeyName: String {
        switch self {
        case .intel:         return "BCLM"
        case .appleSilicon:  return "CHWA"
        }
    }

    /// Whether the BFCL companion key exists on this platform.
    /// Intel Macs with MagSafe have it (controls LED).
    /// Apple Silicon never has it (no MagSafe LED on USB-C).
    var supportsBFCL: Bool {
        return self == .intel
    }

    /// Valid cap values for this platform's UI/CLI validation.
    /// Intel: continuous 50–100.
    /// Apple Silicon: only 80 or 100 (CHWA is a binary 1/0 toggle).
    var validCapValues: [Int] {
        switch self {
        case .intel:         return Array(50...100)
        case .appleSilicon:  return [80, 100]
        }
    }

    /// True if the given cap is acceptable on this platform.
    func isValid(cap value: Int) -> Bool {
        return validCapValues.contains(value)
    }

    /// Convert a percentage cap to the UInt8 byte value the SMC key expects.
    func smcByte(forCap cap: Int) -> UInt8 {
        switch self {
        case .intel:
            return UInt8(cap)
        case .appleSilicon:
            // CHWA: 1 means "cap at 80%", 0 means "no cap (100%)".
            // Any value other than 80 is treated as "no cap".
            return cap == 80 ? 1 : 0
        }
    }

    /// Convert an SMC byte back to a percentage for display.
    func cap(fromSmcByte byte: UInt8) -> Int {
        switch self {
        case .intel:
            return Int(byte)
        case .appleSilicon:
            return byte == 1 ? 80 : 100
        }
    }

    /// Human-readable name for log messages and UI hints.
    var displayName: String {
        switch self {
        case .intel:         return "Intel"
        case .appleSilicon:  return "Apple Silicon"
        }
    }
}
