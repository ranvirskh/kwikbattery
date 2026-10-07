//
//  LimitPayoff.swift
//  KwikBattery
//
//  What the charge limit actually did. A battery ages faster the longer it sits
//  near 100%, so the honest measure of a limit is how long it kept the battery
//  below full while the Mac was plugged in: that is time the cells didn't spend
//  at high charge. This keeps a small per-day tally of exactly that. It does not
//  claim a capacity figure, because nobody can measure one from outside.
//
//  Foundation only (compiled into the insights tests).
//

import Foundation

struct LimitLedger: Codable, Equatable {
    struct Day: Codable, Equatable {
        /// Minutes spent plugged in and held below 100% by the limit.
        var minutes = 0.0
        /// Sum of (100 − charge) × minutes, so the average gap to full can be worked out.
        var pointMinutes = 0.0
    }

    struct Summary: Equatable {
        let hours: Double
        /// Average points below 100% over the held time.
        let averagePointsBelowFull: Double
        let activeDays: Int
    }

    static let retentionDays = 400
    /// One reading may credit at most this long, so a sleep gap isn't counted.
    /// Callers pass a longer cap when readings arrive less often (the app takes
    /// one every 5 minutes while its panel is closed).
    static let maxCreditMinutes = 2.5

    private(set) var days: [String: Day] = [:]
    /// Lifetime totals; they survive pruning of old days.
    private(set) var lifetime = Day()
    private(set) var since: String?

    /// Credits `minutes` held at `percent` to `day` (a yyyy-MM-dd key).
    mutating func record(day: String, percent: Int, minutes: Double,
                         maxMinutes: Double = LimitLedger.maxCreditMinutes) {
        guard minutes.isFinite, minutes > 0, percent < 100 else { return }
        let m = Swift.min(minutes, Swift.max(maxMinutes, 0))
        let gap = Double(Swift.max(0, 100 - Swift.max(percent, 0)))
        var entry = days[day] ?? Day()
        entry.minutes += m
        entry.pointMinutes += gap * m
        days[day] = entry
        lifetime.minutes += m
        lifetime.pointMinutes += gap * m
        if since == nil || day < (since ?? day) { since = day }
    }

    mutating func prune(today: String) {
        guard let cutoff = EnergyLedger.key(today, offsetBy: -(Self.retentionDays - 1)) else { return }
        days = days.filter { $0.key >= cutoff }
    }

    /// The last `count` days including `today`.
    func summary(lastDays count: Int, today: String) -> Summary? {
        guard count > 0, let cutoff = EnergyLedger.key(today, offsetBy: -(count - 1)) else { return nil }
        let window = days.filter { $0.key >= cutoff && $0.key <= today }
        return Self.summarize(window.values.reduce(Day()) { Day(minutes: $0.minutes + $1.minutes,
                                                                pointMinutes: $0.pointMinutes + $1.pointMinutes) },
                              activeDays: window.count)
    }

    func lifetimeSummary() -> Summary? {
        Self.summarize(lifetime, activeDays: days.count)
    }

    private static func summarize(_ total: Day, activeDays: Int) -> Summary? {
        guard total.minutes >= 1 else { return nil }
        return Summary(hours: total.minutes / 60,
                       averagePointsBelowFull: total.pointMinutes / total.minutes,
                       activeDays: activeDays)
    }
}

enum LimitPayoff {
    /// True while the limit (not a top-up, a heat pause or macOS itself) is the
    /// reason the Mac is plugged in but not filling to 100%.
    static func isHeldByLimit(helperEnabled: Bool,
                              mode: ChargeMode,
                              effectiveLimit: Int,
                              topUpActive: Bool,
                              hotPaused: Bool,
                              pluggedIn: Bool,
                              percent: Int) -> Bool {
        helperEnabled && pluggedIn && mode != .normal && !topUpActive && !hotPaused
            && effectiveLimit < 100 && percent < 100
    }

    static func line(_ s: LimitLedger.Summary, period: String) -> String {
        let hours = s.hours >= 10 ? String(format: "%.0f", s.hours) : String(format: "%.1f", s.hours)
        let gap = String(format: "%.0f", s.averagePointsBelowFull)
        return "Held below full for \(hours) h \(period), about \(gap) points under 100%."
    }
}
