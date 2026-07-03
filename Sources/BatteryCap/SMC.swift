//
//  SMC.swift
//  BatteryCap
//
//  The MIT License
//
//  Copyright (C) 2014-2017 beltex <https://beltex.github.io>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//
//  Trimmed from the original beltex/SMCKit to only what BatteryCap needs:
//  open / close / readData / writeData / getKey. Temperature and fan code
//  dropped. Original at https://github.com/beltex/SMCKit
//

import Foundation
import IOKit

// MARK: Type Aliases

/// 32-byte SMC data buffer. Bridged as a tuple because Swift can't express
/// a fixed-size C array directly.
public typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8)

/// Zero-initialized SMCBytes (matches the bytes layout used by SMCKit).
public func emptySMCBytes() -> SMCBytes {
    return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

// MARK: FourCharCode

public extension FourCharCode {

    init(fromString str: String) {
        precondition(str.count == 4)
        self = str.utf8.reduce(0) { sum, character in
            sum << 8 | UInt32(character)
        }
    }

    init(fromStaticString str: StaticString) {
        precondition(str.utf8CodeUnitCount == 4)
        self = str.withUTF8Buffer { buffer in
            let byte0 = UInt32(buffer[0]) << 24
            let byte1 = UInt32(buffer[1]) << 16
            let byte2 = UInt32(buffer[2]) << 8
            let byte3 = UInt32(buffer[3])
            return byte0 | byte1 | byte2 | byte3
        }
    }

    func toString() -> String {
        return String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 8  & 0xff)!) +
               String(describing: UnicodeScalar(self       & 0xff)!)
    }
}

// MARK: SMC Param Struct (defined by AppleSMC.kext)

/// The struct passed across the IOKit user-client boundary to AppleSMC.
///
/// Size MUST be 80 bytes. The assertion in `callDriver` will fire at runtime
/// if Swift's layout ever drifts.
public struct SMCParamStruct {

    public enum Selector: UInt8 {
        case kSMCHandleYPCEvent  = 2
        case kSMCReadKey         = 5
        case kSMCWriteKey        = 6
        case kSMCGetKeyFromIndex = 8
        case kSMCGetKeyInfo      = 9
    }

    public enum Result: UInt8 {
        case kSMCSuccess     = 0
        case kSMCError       = 1
        case kSMCKeyNotFound = 132
    }

    public struct SMCVersion {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    public struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    public struct SMCKeyInfoData {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()  // Required: padding brings struct to 80 bytes.
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = emptySMCBytes()
}

// MARK: Data Types

public struct DataTypes {
    public static let Flag  = DataType(type: FourCharCode(fromStaticString: "flag"), size: 1)
    public static let UInt8 = DataType(type: FourCharCode(fromStaticString: "ui8 "), size: 1)
}

public struct DataType: Equatable {
    let type: FourCharCode
    let size: UInt32
}

public func ==(lhs: DataType, rhs: DataType) -> Bool {
    return lhs.type == rhs.type && lhs.size == rhs.size
}

public struct SMCKey {
    let code: FourCharCode
    let info: DataType
}

// MARK: SMC Client

/// Apple System Management Controller (SMC) user-space client.
///
/// Talks to AppleSMC.kext (closed source) via its IOKit user client. All
/// writes require root. Reads do not.
public struct SMCKit {

    public enum SMCError: Error {
        case driverNotFound
        case failedToOpen
        case keyNotFound(code: String)
        case notPrivileged
        case unknown(kIOReturn: kern_return_t, SMCResult: UInt8)
    }

    fileprivate static var connection: io_connect_t = 0

    public static func open() throws {
        // kIOMasterPortDefault was renamed to kIOMainPortDefault in macOS 12.
        // Use the new symbol; fall back to the old one if targeting older SDKs.
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        let service = IOServiceGetMatchingService(
            mainPort,
            IOServiceMatching("AppleSMC")
        )
        if service == 0 { throw SMCError.driverNotFound }

        let result = IOServiceOpen(service, mach_task_self_, 0, &SMCKit.connection)
        IOObjectRelease(service)

        if result != kIOReturnSuccess { throw SMCError.failedToOpen }
    }

    @discardableResult
    public static func close() -> Bool {
        let result = IOServiceClose(SMCKit.connection)
        return result == kIOReturnSuccess
    }

    public static func getKey(_ code: String, type: DataType) -> SMCKey {
        return SMCKey(code: FourCharCode(fromString: code), info: type)
    }

    public static func readData(_ key: SMCKey) throws -> SMCBytes {
        var inputStruct = SMCParamStruct()
        inputStruct.key = key.code
        inputStruct.keyInfo.dataSize = UInt32(key.info.size)
        inputStruct.data8 = SMCParamStruct.Selector.kSMCReadKey.rawValue

        let outputStruct = try callDriver(&inputStruct)
        return outputStruct.bytes
    }

    public static func writeData(_ key: SMCKey, data: SMCBytes) throws {
        var inputStruct = SMCParamStruct()
        inputStruct.key = key.code
        inputStruct.bytes = data
        inputStruct.keyInfo.dataSize = UInt32(key.info.size)
        inputStruct.data8 = SMCParamStruct.Selector.kSMCWriteKey.rawValue

        _ = try callDriver(&inputStruct)
    }

    /// Calls the SMC driver via the IOKit user-client struct-method API.
    ///
    /// Selector comes from `inputStruct.data8`. The default selector arg here
    /// mirrors the upstream API; we always set `data8` explicitly above.
    public static func callDriver(
        _ inputStruct: inout SMCParamStruct,
        selector: SMCParamStruct.Selector = .kSMCHandleYPCEvent
    ) throws -> SMCParamStruct {

        assert(MemoryLayout<SMCParamStruct>.stride == 80,
               "SMCParamStruct size is != 80 — driver call would corrupt memory")

        var outputStruct = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            SMCKit.connection,
            UInt32(selector.rawValue),
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        switch (result, outputStruct.result) {
        case (kIOReturnSuccess, SMCParamStruct.Result.kSMCSuccess.rawValue):
            return outputStruct
        case (kIOReturnSuccess, SMCParamStruct.Result.kSMCKeyNotFound.rawValue):
            throw SMCError.keyNotFound(code: inputStruct.key.toString())
        case (kIOReturnNotPrivileged, _):
            throw SMCError.notPrivileged
        default:
            throw SMCError.unknown(kIOReturn: result, SMCResult: outputStruct.result)
        }
    }
}
