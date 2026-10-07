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

    /// Energy a full battery holds today, in Wh: max capacity × voltage.
    var fullChargeWh: Double? {
        guard let mah = maxCapacity, mah > 0, let v = voltage, v.isFinite, v > 0 else { return nil }
        return Double(mah) / 1000.0 * v
    }

    /// Power at the battery's terminals in watts: voltage × current, signed
    /// (+ charging, − discharging). Both factors come from the same instant
    /// (see `applyLiveBattery`).
    ///
    /// This is deliberately NOT taken from a "battery power" sensor. The SMC's
    /// PPBR key reads ~0.7 W while the battery is charging at 40+ W (it measures
    /// what the system draws FROM the battery, which is ~0 on the adapter), and
    /// the two registry fields called BatteryPower disagree with each other while
    /// discharging. V × I is the one quantity that is always the power actually
    /// flowing through the battery, and it balances: adapter in = system load +
    /// battery power.
    var batteryWatts: Double? {
        guard let v = voltage, let a = amperage, v.isFinite, a.isFinite else { return nil }
        return v * a
    }

    /// True when `systemLoad` came from a sensor, false when `systemLoadWatts`
    /// has to be derived from the battery's V × I (so the UI can mark it "~").
    var systemLoadIsMeasured: Bool { systemLoad != nil }

    /// Watts being drawn by the Mac (CPU, display, …), from telemetry or derived.
    var systemLoadWatts: Double? {
        if let systemLoad { return systemLoad }
        guard let battery = batteryWatts else { return nil }
        if !isPluggedIn { return abs(battery) }
        // `battery` is signed: negative while discharging. Clamping it at 0
        // deleted the battery's contribution exactly when the adapter can't keep
        // up, under-reporting system load by the discharge wattage.
        if let input = systemPowerIn { return Swift.max(0, input - battery) }
        return nil
    }

    /// Watts arriving from the charger right now.
    var inputWatts: Double? {
        guard isPluggedIn else { return nil }
        if let systemPowerIn { return systemPowerIn }
        if let load = systemLoad, let battery = batteryWatts { return Swift.max(0, load + battery) }
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

    /// Folds one live SMC voltage/current reading into this snapshot.
    ///
    /// Voltage and current are applied TOGETHER or not at all. Under load the
    /// pack voltage moves with the current (a charging Mac was seen going
    /// 12.06 V → 12.59 V in four seconds as the charge rate ramped), so a live
    /// voltage multiplied by a registry current that is 10–60 s old yields a power
    /// that was never true at any instant. Without a matched live pair, the
    /// registry's own pair is kept.
    ///
    /// The live current is also the ground truth for direction, in both
    /// directions: the IsCharging flags lag, and a stale "charging" flag with a
    /// negative current would otherwise read "Charging at -14 W".
    mutating func applyLiveBattery(volts: Double?, amps: Double?) {
        guard let volts, let amps, volts.isFinite, amps.isFinite else { return }
        voltage = volts
        amperage = amps
        if isPluggedIn {
            if amps > 0.05 { isCharging = true }
            else if amps < -0.05 { isCharging = false }
        }
    }

    /// Plain-English explanation for "plugged in but not charging".
    var holdReason: String {
        if isFullyCharged || percentage >= 98 {
            return "Battery is full"
        }
        // Check the reported reason BEFORE the percentage band: a charge paused
        // at 80% because the pack is hot is not the same as a charge limit, and
        // blaming the setting sends the user to the wrong place.
        if notChargingReason != 0 {
            return "macOS paused charging (e.g. temperature or adapter)"
        }
        if percentage >= 75 {
            return "macOS is holding the charge at \(percentage)% (Optimized Charging or Charge Limit)"
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
