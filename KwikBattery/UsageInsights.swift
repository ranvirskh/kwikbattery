//
//  UsageInsights.swift
//  KwikBattery
//
//  Pure logic for the 1.9 features: the 48-hour charge timeline, the
//  sleep-drain report, the "since unplugged" summary, low-battery alerts for
//  Bluetooth devices, and CSV export. Foundation only, so it compiles into the
//  insights test program (Tests/UsageInsightsTests.swift).
//

import Foundation

// MARK: - Charge timeline

struct ChargePoint: Codable, Equatable {
    let time: Date
    let percent: Int
    let pluggedIn: Bool
}

/// The battery percentage over the last two days. A point is stored whenever
/// the percentage or the power source changes, plus one every 10 minutes so a
/// flat line still has points to draw.
struct ChargeLog: Codable, Equatable {
    static let keep: TimeInterval = 48 * 60 * 60
    static let heartbeat: TimeInterval = 10 * 60

    private(set) var points: [ChargePoint] = []

    /// Returns true when a point was stored.
    @discardableResult
    mutating func record(percent: Int, pluggedIn: Bool, at time: Date) -> Bool {
        // The clock went backwards: anything "after" now can't be trusted.
        points.removeAll { $0.time > time }
        if let last = points.last,
           last.percent == percent, last.pluggedIn == pluggedIn,
           time.timeIntervalSince(last.time) < Self.heartbeat {
            return false
        }
        points.append(ChargePoint(time: time, percent: percent, pluggedIn: pluggedIn))
        let cutoff = time.addingTimeInterval(-Self.keep)
        points.removeAll { $0.time < cutoff }
        return true
    }

    func points(from start: Date, to end: Date) -> [ChargePoint] {
        points.filter { $0.time >= start && $0.time <= end }
    }

    /// Stretches of time spent plugged in, clipped to `start...end`. A stretch
    /// runs from a plugged-in point to the next unplugged one (or `end`).
    func pluggedSpans(from start: Date, to end: Date) -> [DateInterval] {
        guard end > start else { return [] }
        var spans: [DateInterval] = []
        var openedAt: Date?
        for point in points where point.time <= end {
            if point.pluggedIn {
                if openedAt == nil { openedAt = Swift.max(point.time, start) }
            } else if let opened = openedAt {
                let close = Swift.max(point.time, start)
                if close > opened { spans.append(DateInterval(start: opened, end: close)) }
                openedAt = nil
            }
        }
        if let opened = openedAt, end > opened {
            spans.append(DateInterval(start: opened, end: end))
        }
        return spans
    }
}

// MARK: - Sleep drain

enum SleepDrain {
    struct Mark: Codable, Equatable {
        let time: Date
        let percent: Int
        let pluggedIn: Bool
    }

    struct Report: Codable, Equatable {
        let sleptAt: Date
        let wokeAt: Date
        let startPercent: Int
        let endPercent: Int

        var duration: TimeInterval { wokeAt.timeIntervalSince(sleptAt) }
        var drop: Int { startPercent - endPercent }
        var percentPerHour: Double { Double(drop) / (duration / 3600) }
    }

    /// Shorter naps say nothing useful: a single percentage point of rounding
    /// over 10 minutes would read as 6%/hour.
    static let minimumSleep: TimeInterval = 30 * 60
    /// Below this many points lost, even a high rate is just rounding.
    static let minimumDrop = 3

    /// A report for one sleep, or nil when it doesn't measure the battery alone:
    /// plugged in at either end, too short, or the clock/charge went the wrong way.
    static func report(sleep: Mark, wake: Mark) -> Report? {
        guard !sleep.pluggedIn, !wake.pluggedIn,
              wake.time.timeIntervalSince(sleep.time) >= minimumSleep,
              wake.percent <= sleep.percent else { return nil }
        return Report(sleptAt: sleep.time, wokeAt: wake.time,
                      startPercent: sleep.percent, endPercent: wake.percent)
    }

    static func isHeavy(_ report: Report, thresholdPerHour: Double) -> Bool {
        report.drop >= minimumDrop && report.percentPerHour > thresholdPerHour
    }

    static func summary(_ report: Report) -> String {
        let minutes = Int((report.duration / 60).rounded())
        let rate = String(format: "%.1f%%/h", report.percentPerHour)
        if report.drop == 0 {
            return "Lost nothing while asleep for \(Format.duration(minutes: minutes))"
        }
        return "Lost \(report.drop)% while asleep for \(Format.duration(minutes: minutes)) (\(rate))"
    }
}

// MARK: - Since unplugged

/// One stretch on battery, from unplugging to now.
struct DischargeSession: Codable, Equatable {
    let start: Date
    let startPercent: Int
    /// mAh stored at unplug, when the battery reports it.
    let startCapacity: Int?

    struct Summary: Equatable {
        let elapsed: TimeInterval
        let percentUsed: Int
        let wattHours: Double?
        /// nil for the first 5 minutes: too little to average.
        let averageWatts: Double?
    }

    /// The session to keep after a new reading: none on AC, a fresh one at
    /// unplug, and a fresh one if the charge rose (it was charged while the
    /// app wasn't watching).
    static func update(_ current: DischargeSession?, pluggedIn: Bool, percent: Int,
                       capacity: Int?, at time: Date) -> DischargeSession? {
        if pluggedIn { return nil }
        if let current, percent <= current.startPercent + 1, time >= current.start {
            return current
        }
        return DischargeSession(start: time, startPercent: percent, startCapacity: capacity)
    }

    func summary(percent: Int, capacity: Int?, voltage: Double?, at time: Date) -> Summary {
        let elapsed = Swift.max(0, time.timeIntervalSince(start))
        var wattHours: Double?
        if let startCapacity, let capacity, let voltage, voltage.isFinite, voltage > 0,
           startCapacity >= capacity {
            wattHours = Double(startCapacity - capacity) * voltage / 1000.0
        }
        var averageWatts: Double?
        if let wattHours, elapsed >= 5 * 60 {
            averageWatts = wattHours / (elapsed / 3600)
        }
        return Summary(elapsed: elapsed,
                       percentUsed: Swift.max(0, startPercent - percent),
                       wattHours: wattHours,
                       averageWatts: averageWatts)
    }

    static func text(_ summary: Summary) -> String {
        var parts = ["Since unplugged: \(Format.duration(minutes: Int(summary.elapsed / 60)))",
                     "\(summary.percentUsed)% used"]
        if let watts = summary.averageWatts {
            parts.append(String(format: "avg %.1f W", watts))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Bluetooth device alerts

/// Fires once when a device drops to the threshold, and re-arms when it is
/// charging or back `rearmMargin` points above it.
struct DeviceBatteryAlerts {
    struct Reading: Equatable {
        let id: String
        let name: String
        let level: Int?
        let isCharging: Bool
    }

    static let rearmMargin = 5

    private(set) var alerted: Set<String> = []

    mutating func update(_ readings: [Reading], threshold: Int) -> [Reading] {
        var newlyLow: [Reading] = []
        for reading in readings {
            guard let level = reading.level else { continue }
            if alerted.contains(reading.id) {
                if reading.isCharging || level > threshold + Self.rearmMargin {
                    alerted.remove(reading.id)
                }
            } else if !reading.isCharging, level <= threshold {
                alerted.insert(reading.id)
                newlyLow.append(reading)
            }
        }
        return newlyLow
    }
}

// MARK: - CSV

enum CSV {
    /// RFC 4180 quoting, plus a leading apostrophe on anything a spreadsheet
    /// would run as a formula (an app called "=HYPERLINK(...)" stays text).
    static func field(_ value: String) -> String {
        var text = value
        if let first = text.first, "=+-@".contains(first) {
            text = "'" + text
        }
        let needsQuotes = text.contains(",") || text.contains("\"") || text.contains("\n")
            || text.contains("\r") || text.hasPrefix(" ") || text.hasSuffix(" ")
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func make(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func number(_ value: Double?, places: Int = 3) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(places)f", value)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func energy(_ ledger: EnergyLedger) -> String {
        var rows: [[String]] = []
        for day in ledger.days.keys.sorted() {
            guard let entry = ledger.days[day] else { continue }
            let apps = entry.apps.sorted { $0.value.wh != $1.value.wh ? $0.value.wh > $1.value.wh : $0.key < $1.key }
            for (_, app) in apps {
                let share = entry.totalWh > 0 ? app.wh / entry.totalWh * 100 : nil
                rows.append([day, app.name, number(app.wh), number(share, places: 1), number(entry.totalWh)])
            }
        }
        return make(header: ["date", "app", "wh", "share_of_day_percent", "day_total_wh"], rows: rows)
    }

    static func charge(_ log: ChargeLog) -> String {
        make(header: ["time", "percent", "plugged_in"],
             rows: log.points.map { [isoFormatter.string(from: $0.time), "\($0.percent)", $0.pluggedIn ? "yes" : "no"] })
    }
}

// MARK: - Global shortcut

/// The keyboard shortcut that opens the panel from anywhere. A fixed short
/// list rather than a recorder: every option uses B ("battery") with modifiers
/// that common apps don't already claim.
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case off
    case controlOptionB
    case optionCommandB
    case controlOptionCommandB

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:                   return "Off"
        case .controlOptionB:        return "⌃⌥B"
        case .optionCommandB:        return "⌥⌘B"
        case .controlOptionCommandB: return "⌃⌥⌘B"
        }
    }

    // Carbon's modifier masks (Events.h): cmdKey 1 << 8, optionKey 1 << 11,
    // controlKey 1 << 12. Spelled out so this file needs only Foundation.
    static let commandMask: UInt32 = 1 << 8
    static let optionMask: UInt32 = 1 << 11
    static let controlMask: UInt32 = 1 << 12
    /// kVK_ANSI_B.
    static let keyCodeB: UInt32 = 11

    /// nil when the shortcut is off.
    var carbonModifiers: UInt32? {
        switch self {
        case .off:                   return nil
        case .controlOptionB:        return Self.controlMask | Self.optionMask
        case .optionCommandB:        return Self.optionMask | Self.commandMask
        case .controlOptionCommandB: return Self.controlMask | Self.optionMask | Self.commandMask
        }
    }
}
