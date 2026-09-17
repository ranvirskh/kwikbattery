//
//  BatteryInfo.swift
//  KwikBattery
//
//  A clean, IOKit-free snapshot of everything KwikBattery knows about the battery.
//  BatteryMonitor builds one of these from the raw IOKit dictionaries.
//

import Foundation

enum ChargingState: Equatable {
    case charging        // plugged in, current flowing into the battery
    case discharging     // running on battery
    case full            // plugged in and fully charged
    case notCharging     // plugged in but charging is paused (limit, optimized charging, heat…)
    case noBattery       // desktop Mac or battery not detected
}

/// A device the Mac is powering over USB / USB-C.
struct PoweredAccessory: Identifiable, Equatable {
    let id: String
    let name: String
    let watts: Double
    /// true = derived from the USB power *allocation* (5 V × allotted mA), not measured.
    let isEstimate: Bool
    /// The Mac's USB-C port number, when known.
    var portIndex: Int? = nil
}

struct BatteryInfo: Equatable {
    var hasBattery: Bool = false

    // Charge
    var percentage: Int = 0
    var isPluggedIn: Bool = false
    var isCharging: Bool = false
    var isFullyCharged: Bool = false
    /// ChargerData.NotChargingReason from the battery driver (0 = no reason given).
    var notChargingReason: Int = 0

    // Health
    var cycleCount: Int?
    var designCapacity: Int?      // mAh (factory)
    var maxCapacity: Int?         // mAh (what the battery can hold today)
    var currentCapacity: Int?     // mAh (charge right now)
    var condition: String = "Unknown"

    // Time estimates (minutes); nil = unknown / still calculating
    var timeToEmptyMinutes: Int?
    var timeToFullMinutes: Int?

    // Electrical
    var voltage: Double?          // volts
    var amperage: Double?         // amps; positive = charging, negative = discharging
    var adapterWatts: Int?        // rated wattage reported by the power adapter
    var adapterName: String?

    /// Individual cell voltages (volts), when the battery reports them.
    var cellVoltages: [Double] = []

    // Thermal
    var temperatureCelsius: Double?

    // Live power telemetry (Apple silicon: AppleSmartBattery › PowerTelemetryData)
    var systemPowerIn: Double?    // watts flowing from the adapter into the Mac
    var systemVoltageIn: Double?  // volts at the Mac's power input
    var systemCurrentIn: Double?  // amps at the Mac's power input
    var systemLoad: Double?       // watts the whole system consumes (incl. USB output)
    var batteryPowerMeasured: Double? // magnitude of battery power from telemetry, watts

    // Adapter's negotiated USB-C PD contract
    var adapterVoltage: Double?   // volts
    var adapterCurrent: Double?   // amps (maximum offered)

    // Power the Mac is sending out to connected accessories (USB / USB-C)
    var poweredAccessories: [PoweredAccessory] = []

    var lastUpdated: Date = .distantPast

    static let empty = BatteryInfo()

    // MARK: Derived values

    /// Battery health = max capacity / design capacity × 100.
    /// New batteries can legitimately report slightly above 100%.
    var healthPercent: Double? {
        guard let design = designCapacity, let max = maxCapacity, design > 0, max > 0 else { return nil }
        return Double(max) / Double(design) * 100.0
    }

    /// Instantaneous battery power in watts (V × A). Positive while charging,
    /// negative while discharging.
    var batteryWatts: Double? {
        if let measured = batteryPowerMeasured {
            // Telemetry gives the magnitude; the sign comes from the current direction.
            let charging: Bool
            if let a = amperage { charging = a >= 0 } else { charging = isCharging }
            return charging ? measured : -measured
        }
        guard let v = voltage, let a = amperage else { return nil }
        return v * a
    }

    /// Watts being drawn by the Mac (CPU, display, …), from telemetry or derived.
    var systemLoadWatts: Double? {
        if let systemLoad { return systemLoad }
        guard let battery = batteryWatts else { return nil }
        if !isPluggedIn { return abs(battery) }
        if let input = systemPowerIn { return Swift.max(0, input - Swift.max(0, battery)) }
        return nil
    }

    /// Watts arriving from the charger right now.
    var inputWatts: Double? {
        guard isPluggedIn else { return nil }
        if let systemPowerIn { return systemPowerIn }
        if let load = systemLoad, let battery = batteryWatts { return load + Swift.max(0, battery) }
        return nil
    }

    /// Total watts going out to accessories.
    var accessoryWatts: Double {
        poweredAccessories.reduce(0) { $0 + $1.watts }
    }

    /// True when every accessory figure is an allocation estimate rather than a measurement.
    var accessoryWattsIsEstimate: Bool {
        !poweredAccessories.isEmpty && poweredAccessories.allSatisfy { $0.isEstimate }
    }

    /// Watts the MacBook itself uses (total system load minus accessory output).
    var macOwnWatts: Double? {
        guard let load = systemLoadWatts else { return nil }
        return Swift.max(0, load - accessoryWatts)
    }

    /// Plain-English explanation for "plugged in but not charging".
    var holdReason: String {
        if isFullyCharged || percentage >= 98 {
            return "Battery is full"
        }
        if percentage >= 75 {
            return "macOS is holding the charge at \(percentage)% (Optimized Charging or Charge Limit)"
        }
        if notChargingReason != 0 {
            return "macOS paused charging (e.g. temperature or adapter)"
        }
        return "Charger connected, battery not charging"
    }

    var state: ChargingState {
        guard hasBattery else { return .noBattery }
        if isCharging { return .charging }
        if isPluggedIn { return (isFullyCharged || percentage >= 100) ? .full : .notCharging }
        return .discharging
    }

    var stateDescription: String {
        switch state {
        case .charging:    return "Charging"
        case .discharging: return "On Battery"
        case .full:        return "Fully Charged"
        case .notCharging: return "Plugged In, Holding Charge"
        case .noBattery:   return "No Battery Detected"
        }
    }
}

// MARK: - Formatting helpers

enum Format {
    static func duration(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        return "\(h)h \(m)m"
    }

    static func temperature(celsius: Double, fahrenheit: Bool) -> String {
        if fahrenheit {
            return String(format: "%.1f °F", celsius * 9.0 / 5.0 + 32.0)
        }
        return String(format: "%.1f °C", celsius)
    }

    static func watts(_ w: Double) -> String {
        String(format: "%.1f W", w)
    }

    static func percent(_ p: Double) -> String {
        String(format: "%.1f%%", p)
    }
}
