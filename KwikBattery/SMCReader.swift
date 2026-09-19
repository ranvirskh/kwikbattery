//
//  SMCReader.swift
//  KwikBattery
//
//  Live power readings straight from the System Management Controller (SMC).
//
//  Why: the AppleSmartBattery IORegistry values (voltage, amperage,
//  PowerTelemetryData) are only refreshed by macOS every ~10–60 seconds.
//  The SMC updates its sensor keys several times per second, which is what
//  makes the dropdown feel truly live.
//
//  How it works (read-only, no root needed):
//   1. Open a connection to the "AppleSMC" IOService.
//   2. Every request is one IOConnectCallStructMethod call (selector 2) that
//      passes an 80-byte SMCKeyData struct in and out.
//        data8 = 9  → "get key info" (size + type of a 4-char key)
//        data8 = 5  → "read key"     (the raw bytes)
//   3. Decode the bytes according to the key's type ("flt ", "ui16", …).
//
//  Apple silicon vs Intel:
//   • Apple silicon reports most sensors as little-endian 32-bit floats ("flt ").
//   • Intel Macs use big-endian fixed-point types ("sp78", "sp96", "fpe2", …)
//     where the last hex digit is the number of fraction bits, and big-endian
//     integers ("ui16", "si16").
//   Both are handled below; integer keys are cross-checked against the
//   IORegistry value to pick the right byte order.
//
//  Keys used:
//     PSTR  total system power (W)        PDTR  power coming in from the adapter (W)
//     PPBR  battery power (W)             VD0R  adapter input voltage (V)
//     ID0R  adapter input current (A)     B0AV  battery voltage (mV)
//     B0AC  battery current (mA, signed)
//  On Intel: PSTR is "sp78", PDTR is "sp96", B0AV "ui16", B0AC "si16" (big-endian).
//  PPBR / VD0R / ID0R may not exist there; the app then derives battery power
//  from voltage × current and falls back to the adapter's reported voltage.
//  Every value is range-checked; anything implausible is ignored and the
//  IORegistry value is used instead.
//

import Foundation
import IOKit

final class SMCReader {
    static let shared = SMCReader()

    // MARK: - C struct mirrors (must total exactly 80 bytes)

    private struct KeyDataVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        // Explicit padding: C pads this struct to 12 bytes, Swift would not.
        var padding0: UInt8 = 0
        var padding1: UInt8 = 0
        var padding2: UInt8 = 0
    }

    private typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    private struct KeyData {
        var key: UInt32 = 0
        var version = KeyDataVersion()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let selectorHandleYPCEvent: UInt32 = 2
    private static let commandReadKeyInfo: UInt8 = 9
    private static let commandReadBytes: UInt8 = 5

    // MARK: - State

    private var connection: io_connect_t = 0
    private var isOpen = false
    private var infoCache: [UInt32: KeyInfo] = [:]
    private let lock = NSLock()

    private init() {
        // Safety net: if Swift ever lays these structs out differently from C,
        // don't talk to the SMC at all.
        guard MemoryLayout<KeyData>.stride == 80 else {
            NSLog("KwikBattery: SMC struct size mismatch (\(MemoryLayout<KeyData>.stride)); SMC disabled.")
            return
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        isOpen = IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
    }

    deinit {
        if isOpen { IOServiceClose(connection) }
    }

    var isAvailable: Bool { isOpen }

    // MARK: - Public readings

    struct Snapshot {
        var systemPower: Double?     // W
        var adapterPower: Double?    // W
        var batteryPower: Double?    // W (magnitude)
        var adapterVoltage: Double?  // V
        var adapterCurrent: Double?  // A
        var batteryTemperature: Double?  // °C
        var batteryVoltage: Double?  // V
        var batteryCurrent: Double?  // A (signed, + = charging) – only when unambiguous
    }

    /// Reads all live keys. `referenceAmps` (from the IORegistry) is used to
    /// pick the right byte order / sign for integer keys.
    func snapshot(referenceAmps: Double?, referenceVolts: Double?) -> Snapshot {
        var s = Snapshot()
        guard isOpen else { return s }

        s.systemPower   = readDouble("PSTR").flatMap { plausible($0, 0.05...400) }
        s.adapterPower  = readDouble("PDTR").flatMap { plausible($0, 0.05...400) }
        s.batteryPower  = readDouble("PPBR").map { abs($0) }.flatMap { plausible($0, 0...300) }
        s.adapterVoltage = readDouble("VD0R").flatMap { plausible($0, 4.5...49) }
        s.adapterCurrent = readDouble("ID0R").flatMap { plausible($0, 0.01...10) }
        // macOS 27 no longer publishes the battery temperature in IORegistry,
        // so the SMC sensor is the only source there.
        s.batteryTemperature = (readDouble("TB0T") ?? readDouble("TB1T"))
            .flatMap { plausible($0, 1...80) }

        let voltageCandidates = readIntegerCandidates("B0AV")
            .map { Double($0) / 1000.0 }
            .filter { (5.5...20.0).contains($0) }
        if let reference = referenceVolts {
            // Pick the decoding that agrees with the (slower) registry voltage.
            s.batteryVoltage = voltageCandidates
                .filter { abs($0 - reference) <= 1.5 }
                .min { abs($0 - reference) < abs($1 - reference) }
        } else {
            s.batteryVoltage = voltageCandidates.first
        }

        if let reference = referenceAmps {
            let currentCandidates = readIntegerCandidates("B0AC").map { Double($0) / 1000.0 }
                .filter { abs($0) <= 12 }
            // Choose the decoding closest to the (slower) registry reading.
            s.batteryCurrent = currentCandidates.min { abs($0 - reference) < abs($1 - reference) }
            if let chosen = s.batteryCurrent, abs(chosen - reference) > 3 {
                s.batteryCurrent = nil   // too far off to trust
            }
        }
        return s
    }

    // MARK: - Key reading

    private func plausible(_ value: Double, _ range: ClosedRange<Double>) -> Double? {
        guard value.isFinite, range.contains(value) else { return nil }
        return value
    }

    private static func fourCC(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func string(from fourCC: UInt32) -> String {
        let bytes = [UInt8((fourCC >> 24) & 0xFF), UInt8((fourCC >> 16) & 0xFF),
                     UInt8((fourCC >> 8) & 0xFF), UInt8(fourCC & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        let inputSize = MemoryLayout<KeyData>.stride
        var outputSize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection,
                                               Self.selectorHandleYPCEvent,
                                               &input, inputSize,
                                               &output, &outputSize)
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    /// Returns (type, raw bytes) for a key, or nil if the key doesn't exist.
    private func readRaw(_ key: String) -> (type: String, bytes: [UInt8])? {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return nil }

        let code = Self.fourCC(key)
        var info = infoCache[code]
        if info == nil {
            var request = KeyData()
            request.key = code
            request.data8 = Self.commandReadKeyInfo
            guard let response = call(&request) else { return nil }
            info = response.keyInfo
            infoCache[code] = response.keyInfo
        }
        guard let keyInfo = info, keyInfo.dataSize > 0, keyInfo.dataSize <= 32 else { return nil }

        var request = KeyData()
        request.key = code
        request.keyInfo.dataSize = keyInfo.dataSize
        request.data8 = Self.commandReadBytes
        guard let response = call(&request) else { return nil }

        let all: [UInt8] = withUnsafeBytes(of: response.bytes) { Array($0) }
        return (Self.string(from: keyInfo.dataType), Array(all.prefix(Int(keyInfo.dataSize))))
    }

    /// Floating-point style keys ("flt " on Apple silicon; fixed-point on Intel).
    private func readDouble(_ key: String) -> Double? {
        guard let raw = readRaw(key) else { return nil }
        let bytes = raw.bytes
        switch raw.type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case let t where t.count == 4 && (t.hasPrefix("fp") || t.hasPrefix("sp")):
            // Fixed point, big-endian: "spXY"/"fpXY" → Y (hex) fraction bits.
            guard bytes.count >= 2,
                  let fractionBits = Int(String(t.suffix(1)), radix: 16) else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let scale = Double(1 << fractionBits)
            if t.hasPrefix("sp") {
                return Double(Int16(bitPattern: raw)) / scale
            }
            return Double(raw) / scale
        default:
            return nil
        }
    }

    /// Integer keys can be little- or big-endian depending on the Mac, and
    /// signed or unsigned, so return every sensible decoding.
    private func readIntegerCandidates(_ key: String) -> [Int] {
        guard let raw = readRaw(key), raw.bytes.count >= 2 else { return [] }
        let bytes = raw.bytes
        let le = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        let be = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        // Native order first: big-endian on Intel SMCs, little-endian on Apple silicon.
        #if arch(x86_64)
        let ordered = [be, le]
        #else
        let ordered = [le, be]
        #endif
        switch raw.type {
        case "ui16":
            return ordered.map { Int($0) }
        case "si16":
            return ordered.map { Int(Int16(bitPattern: $0)) }
        case "ui32", "si32":
            guard bytes.count >= 4 else { return [] }
            let le32 = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let be32 = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            #if arch(x86_64)
            return [Int(Int32(bitPattern: be32)), Int(Int32(bitPattern: le32))]
            #else
            return [Int(Int32(bitPattern: le32)), Int(Int32(bitPattern: be32))]
            #endif
        default:
            return []
        }
    }

    // MARK: - Diagnostics

    /// Prints raw SMC readings; used by `KwikBattery --smc-diag` (see build.sh).
    func diagnosticReport() -> String {
        var lines = ["SMC available: \(isOpen)  struct size: \(MemoryLayout<KeyData>.stride)"]
        #if arch(x86_64)
        lines.insert("Architecture: Intel (x86_64)", at: 0)
        #else
        lines.insert("Architecture: Apple silicon (arm64)", at: 0)
        #endif
        for key in ["PSTR", "PDTR", "PPBR", "VD0R", "ID0R", "B0AV", "B0AC", "PC0C", "B0FC", "B0RM", "TB0T"] {
            if let raw = readRaw(key) {
                let hex = raw.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                let value = readDouble(key).map { String(format: "%.3f", $0) }
                    ?? readIntegerCandidates(key).map { String($0) }.joined(separator: " / ")
                lines.append("\(key) [\(raw.type)] \(hex)  →  \(value)")
            } else {
                lines.append("\(key) — not available")
            }
        }
        return lines.joined(separator: "\n")
    }
}
