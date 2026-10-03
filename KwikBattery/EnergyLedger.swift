//
//  EnergyLedger.swift
//  KwikBattery
//
//  Per-day record of how much energy each app used while the Mac was on
//  battery. Pure data + arithmetic (Foundation only), so it is unit tested
//  in Tests/InsightsTests.swift. EnergyHistory owns the live copy and the file.
//
//  Each sample says "for the last N seconds the Mac drew W watts, and app X
//  had P% of the Energy Impact". That credits X with P/100 × W × N/3600 Wh.
//  Energy Impact is Apple's score, not a meter, so the per-app figures are
//  approximate; the day's total is the measured system power.
//

import Foundation

struct EnergyLedger: Codable, Equatable {
    struct AppEntry: Codable, Equatable {
        var name: String
        var path: String?
        var wh: Double
    }

    struct Day: Codable, Equatable {
        var totalWh: Double = 0
        var seconds: Double = 0
        var apps: [String: AppEntry] = [:]
    }

    struct Ranking: Equatable, Identifiable {
        let id: String
        let name: String
        let path: String?
        let wh: Double
        /// This app's energy as a fraction (0–1) of everything the Mac used
        /// over the same days on battery.
        let shareOfTotal: Double
    }

    typealias AppShare = (id: String, name: String, appPath: String?, percentShare: Double)

    /// Days kept, counting today.
    static let retentionDays = 35

    /// "yyyy-MM-dd" → that day's totals.
    private(set) var days: [String: Day] = [:]

    var isEmpty: Bool { days.isEmpty }

    // MARK: Recording

    mutating func record(day: String, apps: [AppShare], systemLoadWatts: Double, seconds: Double) {
        guard Self.date(fromKey: day) != nil,
              systemLoadWatts.isFinite, systemLoadWatts > 0,
              seconds.isFinite, seconds > 0 else { return }

        let energy = systemLoadWatts * seconds / 3600.0
        var entry = days[day] ?? Day()
        entry.totalWh += energy
        entry.seconds += seconds
        for app in apps {
            guard app.percentShare.isFinite, app.percentShare > 0 else { continue }
            let share = Swift.min(app.percentShare, 100) / 100.0
            var row = entry.apps[app.id] ?? AppEntry(name: app.name, path: app.appPath, wh: 0)
            row.name = app.name
            row.path = app.appPath ?? row.path
            row.wh += share * energy
            entry.apps[app.id] = row
        }
        days[day] = entry
        prune(today: day)
    }

    /// Drops days more than `retentionDays - 1` days before `today`.
    mutating func prune(today: String) {
        guard let cutoff = Self.key(today, offsetBy: -(Self.retentionDays - 1)) else { return }
        days = days.filter { $0.key >= cutoff }
    }

    // MARK: Reading

    /// The day keys covered by "the last `count` days", ending on `today`.
    private func keys(forDays count: Int, endingOn today: String) -> [String] {
        guard count > 0, let first = Self.key(today, offsetBy: -(count - 1)) else { return [] }
        return days.keys.filter { $0 >= first && $0 <= today }
    }

    func totalWh(forDays count: Int, endingOn today: String) -> Double {
        keys(forDays: count, endingOn: today).reduce(0) { $0 + (days[$1]?.totalWh ?? 0) }
    }

    func trackedSeconds(forDays count: Int, endingOn today: String) -> Double {
        keys(forDays: count, endingOn: today).reduce(0) { $0 + (days[$1]?.seconds ?? 0) }
    }

    /// Apps ranked by energy over the period, most first.
    func rankings(forDays count: Int, endingOn today: String) -> [Ranking] {
        let included = keys(forDays: count, endingOn: today).sorted()
        var totals: [String: AppEntry] = [:]
        var grandTotal = 0.0
        for key in included {   // oldest first, so the newest name/path wins
            guard let day = days[key] else { continue }
            grandTotal += day.totalWh
            for (id, app) in day.apps {
                var row = totals[id] ?? AppEntry(name: app.name, path: app.path, wh: 0)
                row.name = app.name
                row.path = app.path ?? row.path
                row.wh += app.wh
                totals[id] = row
            }
        }
        guard grandTotal > 0 else { return [] }
        return totals
            .map { Ranking(id: $0.key, name: $0.value.name, path: $0.value.path,
                           wh: $0.value.wh, shareOfTotal: $0.value.wh / grandTotal) }
            .sorted { $0.wh != $1.wh ? $0.wh > $1.wh : $0.name < $1.name }
    }

    // MARK: Day keys

    /// Day keys are calendar dates. Arithmetic on them is done in UTC so a
    /// daylight-saving change can't produce a 23- or 25-hour "day".
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? c.timeZone
        return c
    }

    static func date(fromKey key: String) -> Date? {
        guard let date = keyFormatter.date(from: key), keyFormatter.string(from: date) == key else { return nil }
        return date
    }

    static func key(_ key: String, offsetBy days: Int) -> String? {
        guard let date = date(fromKey: key),
              let moved = utcCalendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return keyFormatter.string(from: moved)
    }

    /// Today's key in the user's own time zone.
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
