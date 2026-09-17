//
//  AppleDeviceNames.swift
//  KwikBattery
//
//  Turns iPhone / iPad model identifiers ("iPhone18,3") into marketing
//  names ("iPhone 17"), and keeps a small thread-safe cache that maps a USB
//  serial number to the friendly model name, so the power-flow code can label
//  a USB port "iPhone 17" instead of "USB-C Port 1".
//

import Foundation

enum AppleModelNames {
    static let table: [String: String] = [
        // iPhone 12 family
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        // iPhone 13 family / SE
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd gen)",
        // iPhone 14 family
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        // iPhone 15 family
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        // iPhone 16 family
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        // iPhone 17 family
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,5": "iPhone 17e",
        // Recent iPads
        "iPad16,1": "iPad mini (A17 Pro)", "iPad16,2": "iPad mini (A17 Pro)",
        "iPad16,3": "iPad Pro 11-inch (M4)", "iPad16,4": "iPad Pro 11-inch (M4)",
        "iPad16,5": "iPad Pro 13-inch (M4)", "iPad16,6": "iPad Pro 13-inch (M4)",
        "iPad16,8": "iPad Air 11-inch (M3)", "iPad16,9": "iPad Air 11-inch (M3)",
        "iPad16,10": "iPad Air 13-inch (M3)", "iPad16,11": "iPad Air 13-inch (M3)",
        "iPad17,1": "iPad Pro 11-inch (M5)", "iPad17,2": "iPad Pro 11-inch (M5)",
        "iPad17,3": "iPad Pro 13-inch (M5)", "iPad17,4": "iPad Pro 13-inch (M5)",
    ]

    /// "iPhone18,3" → "iPhone 17". Unknown identifiers fall back to a generic name.
    static func name(forProductType productType: String) -> String? {
        if let name = table[productType] { return name }
        if productType.hasPrefix("iPhone") { return "iPhone" }
        if productType.hasPrefix("iPad") { return "iPad" }
        return nil
    }

    /// USB serial numbers and UDIDs differ only by dashes / case.
    static func normalizeSerial(_ serial: String) -> String {
        serial.replacingOccurrences(of: "-", with: "").uppercased()
    }
}

/// Serial number → friendly model name, filled in by BluetoothDeviceMonitor
/// (which talks to libimobiledevice) and read by AccessoryPowerReader.
final class DeviceNameCache: @unchecked Sendable {
    static let shared = DeviceNameCache()

    private let lock = NSLock()
    private var names: [String: String] = [:]

    func set(_ name: String, forSerial serial: String) {
        lock.lock()
        names[AppleModelNames.normalizeSerial(serial)] = name
        lock.unlock()
    }

    func name(forSerial serial: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return names[AppleModelNames.normalizeSerial(serial)]
    }
}
