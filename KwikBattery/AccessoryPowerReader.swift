//
//  AccessoryPowerReader.swift
//  KwikBattery
//
//  Best-effort readout of power the Mac is sending OUT to accessories.
//
//  macOS has no public API for this, so we combine two IORegistry sources:
//
//   1. AppleSmartBattery › "PowerOutDetails" (Apple silicon). Lists power
//      delivered from the Mac's USB-C ports (e.g. charging an iPhone).
//      The format is undocumented, so we accept an array or a dictionary
//      and look for power (mW / W) or voltage × current values.
//
//   2. IOUSBHostDevice entries. Each connected USB device has a power
//      *allocation* from the port ("UsbPowerSinkAllocation", in mA at 5 V).
//      That is the budget the device was granted, not a live measurement,
//      so these entries are flagged `isEstimate`.
//

import Foundation
import IOKit

enum AccessoryPowerReader {

    static func read(smartBattery: [String: Any]?) -> [PoweredAccessory] {
        let usbDevices = readUSBDevices()
        // Prefer measured port power; fall back to USB allocations only if the
        // firmware doesn't report PowerOutDetails (e.g. Intel Macs).
        if let measured = readPowerOutDetails(smartBattery, usbDevices: usbDevices) {
            return measured.sorted { $0.watts > $1.watts }
        }
        return usbDevices
            .filter { $0.milliamps > 0 }
            .map { device in
                PoweredAccessory(id: "usb-\(device.locationID)",
                                 name: device.displayName,
                                 watts: Double(device.milliamps) * 5.0 / 1000.0,
                                 isEstimate: true)
            }
            .sorted { $0.watts > $1.watts }
    }

    // MARK: 1. PowerOutDetails (measured, per USB-C port)

    /// Example entry (values in mW / mV / mA):
    ///   { "PortIndex"=1, "Watts"=14157, "FilteredPower"=14055,
    ///     "AdapterVoltage"=5202, "Current"=2721, "PDPowermW"=15000, … }
    /// Note: despite its name, "Watts" is in milliwatts. "PDPowermW" is the
    /// port's *capability*, not live usage, so it is ignored.
    /// Returns nil when the Mac doesn't provide this data at all.
    static func readPowerOutDetails(_ sb: [String: Any]?, usbDevices: [USBDeviceInfo]) -> [PoweredAccessory]? {
        guard let raw = sb?["PowerOutDetails"] else { return nil }

        var entries: [[String: Any]] = []
        if let array = raw as? [[String: Any]] {
            entries = array
        } else if let dict = raw as? [String: Any] {
            entries = [dict]
        } else {
            return nil
        }

        struct Port {
            let index: Int
            let milliwatts: Int
        }

        var ports: [Port] = []
        for (position, entry) in entries.enumerated() {
            let index = number(entry["PortIndex"]) ?? (position + 1)
            var mw = number(entry["Watts"]) ?? number(entry["FilteredPower"])
            if mw == nil, let mv = number(entry["AdapterVoltage"]), let ma = number(entry["Current"]) {
                mw = mv * ma / 1000
            }
            guard let milliwatts = mw, milliwatts >= 100, milliwatts <= 250_000 else { continue }
            ports.append(Port(index: index, milliwatts: milliwatts))
        }

        // ---- Work out which device is on which port -----------------------
        // Strategy 1: USB topology. On Apple silicon each USB-C port has its own
        // USB controller, and the top byte of a device's locationID identifies
        // that controller. PortIndex is 1-based, the controller index 0-based,
        // but we test both offsets and keep whichever explains more ports.
        func devices(onPort index: Int, offset: Int) -> [USBDeviceInfo] {
            usbDevices.filter { $0.controllerIndex == index + offset }
        }
        func matchedPorts(offset: Int) -> Int {
            ports.filter { !devices(onPort: $0.index, offset: offset).isEmpty }.count
        }
        // Prefer the 1-based → 0-based mapping unless the other one explains more ports.
        let bestOffset = matchedPorts(offset: 0) > matchedPorts(offset: -1) ? 0 : -1

        // Strategy 2: pair by power rank when the counts line up.
        let sortedPorts = ports.sorted { $0.milliwatts > $1.milliwatts }
        let sortedDevices = usbDevices.sorted { $0.milliamps > $1.milliamps }
        let canPairByRank = !sortedDevices.isEmpty && sortedDevices.count == sortedPorts.count

        return sortedPorts.enumerated().map { rank, port in
            var name = "USB-C Port \(port.index)"
            let onPort = devices(onPort: port.index, offset: bestOffset)
                .sorted { $0.milliamps > $1.milliamps }
            if let primary = onPort.first {
                name = onPort.count > 1 ? "\(primary.displayName) + \(onPort.count - 1) more" : primary.displayName
            } else if canPairByRank {
                name = sortedDevices[rank].displayName
            }
            return PoweredAccessory(id: "port-\(port.index)",
                                    name: name,
                                    watts: Double(port.milliwatts) / 1000.0,
                                    isEstimate: false,
                                    portIndex: port.index)
        }
    }

    private static func number(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber else { return nil }
        return Int(truncatingIfNeeded: n.int64Value)
    }

    // MARK: 2. External USB devices

    struct USBDeviceInfo {
        let name: String
        let serial: String?
        let locationID: UInt32
        let milliamps: Int

        /// Top byte of locationID = which USB controller (≈ which port) it hangs off.
        var controllerIndex: Int { Int((locationID >> 24) & 0xFF) }

        /// "iPhone 17" when libimobiledevice told us the model, else the USB name.
        var displayName: String {
            if let serial, let friendly = DeviceNameCache.shared.name(forSerial: serial) {
                return friendly
            }
            return name
        }
    }

    static func readUSBDevices() -> [USBDeviceInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [USBDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any] else { continue }

            // Skip devices built into the Mac (internal hubs, camera, etc.).
            if (dict["Built-In"] as? Bool) == true { continue }

            var milliamps = 0
            for key in ["UsbPowerSinkAllocation", "kUSBCurrentRequired", "Current Required"] {
                if let n = dict[key] as? NSNumber, n.intValue > 0 {
                    milliamps = n.intValue
                    break
                }
            }

            let name = (dict["USB Product Name"] as? String)
                ?? (dict["kUSBProductString"] as? String)
                ?? (dict["Product"] as? String)
                ?? "USB Device"
            let serial = (dict["USB Serial Number"] as? String) ?? (dict["kUSBSerialNumberString"] as? String)
            let location = UInt32(truncatingIfNeeded: (dict["locationID"] as? NSNumber)?.int64Value ?? 0)

            result.append(USBDeviceInfo(name: name, serial: serial, locationID: location, milliamps: milliamps))
        }
        return result
    }
}
