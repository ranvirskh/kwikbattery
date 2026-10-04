//
//  BatteryInsights.swift
//  KwikBattery
//
//  Small, pure pieces of logic that sit on top of BatteryInfo: a smoothed
//  time-remaining estimate, the menu bar text, the charger check, the
//  hot-battery episode tracker and the `--status` JSON snapshot.
//
//  Foundation only, so it compiles into the test program with
//  Tests/InsightsTests.swift (bash build.sh --test).
//

import Foundation

// MARK: - Smoothed time remaining

/// Estimates minutes left on battery from how fast the percentage has been
/// falling, rather than from the draw at this instant (which is what macOS's
/// own "time remaining" extrapolates from, so it swings wildly with load).
///
/// It fits a least-squares line to percent-vs-time over the last 45 minutes of
/// on-battery readings. When there isn't enough evidence it returns nil and
/// the UI falls back to macOS's figure.
struct RunTimeEstimator {
    struct Sample: Equatable {
        let time: Date
        let percent: Double
    }

    /// Only the most recent stretch of use is relevant to "how long from now".
    var window: TimeInterval = 45 * 60
    /// Readings arrive every 2 s while the panel is open; one a minute is plenty
    /// unless the percentage actually moved.
    var thinning: TimeInterval = 60
    /// Longer than this between readings means sleep, or the app wasn't running:
    /// the slope across the gap says nothing about current use.
    var maxGap: TimeInterval = 20 * 60
    var minSpan: TimeInterval = 10 * 60
    /// Percentage is an integer: below a 2-point drop the slope is mostly rounding.
    var minDrop: Double = 2
    /// %/minute. Anything flatter (1% per 200 minutes) isn't a usable trend.
    var flattestSlope: Double = -0.005
    var maxMinutes: Double = 30 * 60

    private(set) var samples: [Sample] = []

    mutating func reset() {
        samples.removeAll()
    }

    /// Adds one reading. Plugging in, the clock going backwards, or a long gap
    /// all start the history again.
    mutating func add(percent: Double, at time: Date, onBattery: Bool) {
        guard onBattery, percent.isFinite else {
            reset()
            return
        }
        if let last = samples.last {
            let dt = time.timeIntervalSince(last.time)
            if dt < 0 || dt > maxGap {
                reset()
            } else if dt < thinning && percent == last.percent {
                return
            }
        }
        samples.append(Sample(time: time, percent: percent))

        let cutoff = time.addingTimeInterval(-window)
        if let firstKept = samples.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }

    /// Percent per minute from a least-squares fit, or nil with fewer than two
    /// distinct times.
    var slopePerMinute: Double? {
        guard samples.count >= 2, let first = samples.first else { return nil }
        let xs = samples.map { $0.time.timeIntervalSince(first.time) / 60.0 }
        let ys = samples.map { $0.percent }
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxy = 0.0
        var sxx = 0.0
        for i in xs.indices {
            let dx = xs[i] - meanX
            sxy += dx * (ys[i] - meanY)
            sxx += dx * dx
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        return slope.isFinite ? slope : nil
    }

    /// Minutes until empty at the fitted rate, or nil when the data can't support one.
    var minutesRemaining: Int? {
        guard let first = samples.first, let last = samples.last else { return nil }
        guard last.time.timeIntervalSince(first.time) >= minSpan else { return nil }
        guard first.percent - last.percent >= minDrop else { return nil }
        guard let slope = slopePerMinute, slope < flattestSlope else { return nil }
        let minutes = last.percent / -slope
        guard minutes.isFinite, minutes >= 0, minutes <= maxMinutes else { return nil }
        return Int(minutes.rounded())
    }
}

// MARK: - Menu bar text

enum MenuBarTextMode: String, CaseIterable, Identifiable {
    case none
    case percent
    case timeLeft
    case watts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:     return "None"
        case .percent:  return "Percent"
        case .timeLeft: return "Time left"
        case .watts:    return "Watts"
        }
    }
}

enum MenuBarText {
    /// The text shown next to the menu bar icon. Leading space so it doesn't
    /// touch the icon; empty when there's nothing honest to show.
    static func text(mode: MenuBarTextMode, percentage: Int, minutes: Int?, watts: Double?) -> String {
        switch mode {
        case .none:
            return ""
        case .percent:
            return " \(percentage)%"
        case .timeLeft:
            guard let minutes, minutes >= 0 else { return "" }
            return " " + Format.duration(minutes: minutes)
        case .watts:
            guard let watts, watts.isFinite else { return "" }
            // "%+.0f" turns -0.3 into "-0"; anything that rounds to zero is just 0.
            if abs(watts) < 0.5 { return " 0 W" }
            return String(format: " %+.0f W", watts)
        }
    }
}

// MARK: - Charger check

enum ChargerCheck: Equatable {
    case ok
    case weakAdapter
    case chargingSlowly

    /// Battery power below this while plugged in counts as draining, not noise.
    static let drainTolerance = 0.5   // watts

    var label: String {
        switch self {
        case .ok:             return "OK"
        case .weakAdapter:    return "Weak adapter"
        case .chargingSlowly: return "Charging slowly"
        }
    }

    /// Plugged in, yet the battery is supplying power: the Mac is drawing more
    /// than the charger delivers.
    static func adapterCannotKeepUp(_ info: BatteryInfo) -> Bool {
        guard info.hasBattery, info.isPluggedIn,
              let battery = info.batteryWatts, battery < -drainTolerance,
              let load = info.systemLoadWatts else { return false }
        guard let supply = info.inputWatts ?? info.adapterWatts.map(Double.init) else {
            // Draining on AC with no supply figure is evidence enough.
            return true
        }
        return load > supply
    }

    /// The panel's one-line status; nil when unplugged.
    static func evaluate(_ info: BatteryInfo, slowThreshold: Double) -> ChargerCheck? {
        guard info.hasBattery, info.isPluggedIn else { return nil }
        if adapterCannotKeepUp(info) { return .weakAdapter }
        if info.isCharging, info.percentage < 90,
           let watts = info.batteryWatts, watts > 0, watts < slowThreshold {
            return .chargingSlowly
        }
        return .ok
    }
}

// MARK: - Hot battery

/// Tracks one "battery is hot" episode: it starts at the threshold and only
/// ends once the battery has cooled `rearmMargin` degrees below it, so a pack
/// hovering at the threshold doesn't alert every reading.
struct HotBatteryGuard {
    enum Transition: Equatable {
        case becameHot
        case cooledDown
    }

    static let rearmMargin = 3.0   // °C

    private(set) var isHot = false

    mutating func update(celsius: Double?, threshold: Double) -> Transition? {
        guard let celsius, celsius.isFinite, threshold.isFinite else { return nil }
        if !isHot, celsius >= threshold {
            isHot = true
            return .becameHot
        }
        if isHot, celsius <= threshold - Self.rearmMargin {
            isHot = false
            return .cooledDown
        }
        return nil
    }
}

// MARK: - `--status` snapshot

enum BatteryStatus {
    static func stateName(_ state: ChargingState) -> String {
        switch state {
        case .charging:    return "charging"
        case .discharging: return "discharging"
        case .full:        return "full"
        case .notCharging: return "notCharging"
        case .noBattery:   return "noBattery"
        }
    }

    /// Every key is always present; unknown (or NaN / infinite) values are
    /// JSON null. JSONSerialization throws on NaN, so they never reach it.
    static func dictionary(for info: BatteryInfo) -> [String: Any] {
        func number(_ value: Double?, places: Double = 100) -> Any {
            guard let value, value.isFinite else { return NSNull() }
            return (value * places).rounded() / places
        }
        func integer(_ value: Int?) -> Any {
            value.map { $0 as Any } ?? NSNull()
        }
        return [
            "percent":            info.percentage,
            "state":              stateName(info.state),
            "pluggedIn":          info.isPluggedIn,
            "charging":           info.state == .charging,
            "timeToEmptyMinutes": integer(info.timeToEmptyMinutes),
            "timeToFullMinutes":  integer(info.timeToFullMinutes),
            "healthPercent":      number(info.healthPercent, places: 10),
            "cycles":             integer(info.cycleCount),
            "temperatureC":       number(info.temperatureCelsius, places: 10),
            "batteryWatts":       number(info.batteryWatts),
            "systemLoadWatts":    number(info.systemLoadWatts),
            "inputWatts":         number(info.inputWatts),
            "adapterWatts":       integer(info.adapterWatts),
            "voltage":            number(info.voltage, places: 1000),
        ]
    }

    static func json(for info: BatteryInfo) -> String {
        let object = dictionary(for: info)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
