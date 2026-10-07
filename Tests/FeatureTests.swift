//
//  FeatureTests.swift
//  KwikBattery
//
//  Tests for the 1.11 logic: the health forecast, the charge-limit payoff
//  ledger, per-app energy alerts, scheduled Low Power Mode, and the
//  temperature trend. Compiled into the insights test program and run from
//  InsightsTests.main(), using its check helpers. Every expected number is
//  worked out in the comment beside it.
//

import Foundation

enum FeatureTests {
    static func run() {
        forecastTests()
        payoffTests()
        energyAlertTests()
        lowPowerWindowTests()
        lowPowerEngineTests()
        lowPowerConfigTests()
        temperatureTests()
    }

    static let t0 = InsightsTests.t0                     // 2026-09-21 14:13:20 UTC
    static func check(_ ok: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        InsightsTests.check(ok(), message, line: line)
    }
    static func near(_ value: Double?, _ expected: Double, _ message: String,
                     tolerance: Double = 1e-6, line: Int = #line) {
        InsightsTests.near(value, expected, message, tolerance: tolerance, line: line)
    }
    static func equal<T: Equatable>(_ value: T, _ expected: T, _ message: String, line: Int = #line) {
        InsightsTests.equal(value, expected, message, line: line)
    }

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - HealthForecast

    /// `days` daily readings ending at t0: health = start − perDay·i, cycles = 100 + cyclesPerDay·i.
    static func readings(days: Int, start: Double, perDay: Double, cyclesPerDay: Double = 1) -> [HealthForecast.Reading] {
        (0..<days).map { i in
            HealthForecast.Reading(date: t0.addingTimeInterval(-Double(days - 1 - i) * 86400),
                                   health: start - perDay * Double(i),
                                   cycles: 100 + Int((cyclesPerDay * Double(i)).rounded()))
        }
    }

    static func forecastTests() {
        // 60 readings, 59 days apart end to end: health 95 − 0.05·i, cycles 100 + i.
        // Slope −0.05 %/day = −1.5 %/month; fitted today = 95 − 0.05·59 = 92.05;
        // days to 80 = (92.05 − 80) / 0.05 = 241; cycles 1/day = 30/month;
        // health per 100 cycles = −0.05 / 1 · 100 = −5.
        let r = HealthForecast.forecast(readings(days: 60, start: 95, perDay: 0.05), now: t0)
        near(r?.percentPerMonth, -1.5, "falling 1.5%/month")
        near(r?.cyclesPerMonth, 30, "30 cycles a month")
        near(r?.percentPer100Cycles, -5, "5% lost per 100 cycles")
        near(r?.fittedHealth, 92.05, "fitted health today")
        equal(r?.daysToTarget, 241, "241 days to 80%")
        equal(r?.isSteady, false, "not steady")
        equal(r?.confidence, .fair, "59 days of clean data is fair")
        equal(r?.spanDays, 59, "span")
        if let r {
            equal(HealthForecast.monthYear(r.targetDate ?? t0, calendar: utc), "May 2027", "target date: 2026-09-21 + 241 days")
            let text = HealthForecast.summary(r, calendar: utc)
            check(text.contains("1.5% a month"), "summary names the rate: \(text)")
            check(text.contains("reaches 80% around May 2027"), "summary names the date: \(text)")
            check(!text.contains("Early estimate"), "fair confidence has no early-estimate note")
        }

        // 120 clean days is good confidence.
        equal(HealthForecast.forecast(readings(days: 120, start: 98, perDay: 0.03), now: t0)?.confidence,
              .good, "120 clean days is good")
        // 25 days: allowed, but low confidence, and the summary says so.
        let early = HealthForecast.forecast(readings(days: 25, start: 95, perDay: 0.05), now: t0)
        equal(early?.confidence, .low, "25 days is low confidence")
        if let early { check(HealthForecast.summary(early, calendar: utc).contains("Early estimate"), "early note") }

        // Not enough data.
        check(HealthForecast.forecast(readings(days: 4, start: 95, perDay: 0.5), now: t0) == nil, "4 readings: nil")
        check(HealthForecast.forecast(readings(days: 15, start: 95, perDay: 0.1), now: t0) == nil, "14-day span: nil")
        check(HealthForecast.forecast([], now: t0) == nil, "no readings: nil")

        // Flat: steady, no date.
        let flat = HealthForecast.forecast(readings(days: 60, start: 90, perDay: 0), now: t0)
        equal(flat?.isSteady, true, "flat is steady")
        check(flat?.daysToTarget == nil && flat?.targetDate == nil, "flat has no date")
        near(flat?.percentPerMonth, 0, "flat rate is 0")
        if let flat { check(HealthForecast.summary(flat, calendar: utc).contains("holding steady"), "steady summary") }

        // −0.0001 %/day (0.04%/year) is below the 0.1%/year steady line.
        equal(HealthForecast.forecast(readings(days: 60, start: 95, perDay: 0.0001), now: t0)?.isSteady,
              true, "tiny fall is steady")

        // Falling, but so slowly (−0.0005 %/day → ~38,000 days to 80%) the date is meaningless.
        let slow = HealthForecast.forecast(readings(days: 60, start: 99, perDay: 0.0005), now: t0)
        equal(slow?.isSteady, false, "slow fall isn't steady")
        check(slow?.daysToTarget == nil, "over 20 years: no date")
        if let slow { check(HealthForecast.summary(slow, calendar: utc).contains("more than 20 years"), "20-year summary") }

        // Already at or below the target.
        let below = HealthForecast.forecast(readings(days: 60, start: 79, perDay: 0.01), now: t0)
        equal(below?.daysToTarget, 0, "already under 80%")
        if let below { check(HealthForecast.summary(below, calendar: utc).contains("at or below 80%"), "below summary") }

        // Health that rises (a re-calibration) is never a "fall".
        let rising = HealthForecast.forecast(readings(days: 60, start: 90, perDay: -0.02), now: t0)
        equal(rising?.isSteady, true, "rising counts as steady")

        // Garbage readings are ignored.
        var dirty = readings(days: 60, start: 95, perDay: 0.05)
        dirty.append(HealthForecast.Reading(date: t0.addingTimeInterval(3600), health: .nan, cycles: 1))
        dirty.append(HealthForecast.Reading(date: t0.addingTimeInterval(7200), health: 0, cycles: 1))
        near(HealthForecast.forecast(dirty, now: t0)?.percentPerMonth, -1.5, "NaN and zero readings dropped")

        // Least squares: y = 2x + 1.
        let fit = HealthForecast.leastSquares([0, 1, 2, 3], [1, 3, 5, 7])
        near(fit?.slope, 2, "slope")
        near(fit?.intercept, 1, "intercept")
        near(fit?.r2, 1, "perfect fit")
        check(HealthForecast.leastSquares([1, 1, 1], [1, 2, 3]) == nil, "no x spread: nil")
    }

    // MARK: - LimitLedger

    static func payoffTests() {
        let today = "2026-09-26"
        var ledger = LimitLedger()
        ledger.record(day: today, percent: 80, minutes: 1)
        ledger.record(day: today, percent: 80, minutes: 1)
        ledger.record(day: today, percent: 100, minutes: 1)        // at 100% there's nothing held back
        ledger.record(day: today, percent: 80, minutes: 0)         // no time
        ledger.record(day: today, percent: 80, minutes: -3)        // clock went backwards
        ledger.record(day: today, percent: 80, minutes: .nan)
        near(ledger.days[today]?.minutes, 2, "two valid minutes")
        near(ledger.days[today]?.pointMinutes, 40, "20 points × 2 min")

        // A long gap (sleep) credits at most 2.5 minutes.
        ledger.record(day: today, percent: 70, minutes: 90)
        near(ledger.days[today]?.minutes, 4.5, "gap capped at 2.5 min")
        near(ledger.days[today]?.pointMinutes, 40 + 30 * 2.5, "30 points × 2.5 min added")

        // A caller whose readings are 5 minutes apart allows a longer gap.
        var slowReadings = LimitLedger()
        slowReadings.record(day: today, percent: 80, minutes: 5, maxMinutes: 7.5)
        slowReadings.record(day: today, percent: 80, minutes: 20, maxMinutes: 7.5)
        near(slowReadings.days[today]?.minutes, 12.5, "5 min credited in full, 20 min capped at 7.5")

        // 60 minutes at 80% six days ago (inside the 7-day window), 60 at 90% seven days ago (outside).
        var week = LimitLedger()
        for _ in 0..<24 { week.record(day: "2026-09-20", percent: 80, minutes: 2.5) }    // 60 min
        for _ in 0..<24 { week.record(day: "2026-09-19", percent: 90, minutes: 2.5) }    // 60 min
        let s7 = week.summary(lastDays: 7, today: today)
        near(s7?.hours, 1, "one hour in the last 7 days")
        near(s7?.averagePointsBelowFull, 20, "averaging 20 points under full")
        equal(s7?.activeDays, 1, "one active day")
        let all = week.lifetimeSummary()
        near(all?.hours, 2, "two hours lifetime")
        near(all?.averagePointsBelowFull, 15, "(20·60 + 10·60) / 120 = 15")
        equal(week.since, "2026-09-19", "since is the earliest day")
        check(LimitLedger().summary(lastDays: 7, today: today) == nil, "empty: nil")
        var tiny = LimitLedger()
        tiny.record(day: today, percent: 80, minutes: 0.5)
        check(tiny.summary(lastDays: 7, today: today) == nil, "under a minute: nil")

        // Pruning drops old days but keeps lifetime totals.
        var old = LimitLedger()
        old.record(day: "2025-01-01", percent: 80, minutes: 2)
        old.record(day: today, percent: 80, minutes: 2)
        old.prune(today: today)
        check(old.days["2025-01-01"] == nil, "day older than 400 days pruned")
        check(old.days[today] != nil, "recent day kept")
        near(old.lifetime.minutes, 4, "lifetime survives pruning")

        // Codable round trip.
        if let data = try? JSONEncoder().encode(week), let back = try? JSONDecoder().decode(LimitLedger.self, from: data) {
            equal(back, week, "ledger round-trips")
        } else {
            check(false, "ledger encodes")
        }

        // What counts as "held by the limit".
        func held(enabled: Bool = true, mode: ChargeMode = .hold, limit: Int = 80, topUp: Bool = false,
                  hot: Bool = false, plugged: Bool = true, percent: Int = 80) -> Bool {
            LimitPayoff.isHeldByLimit(helperEnabled: enabled, mode: mode, effectiveLimit: limit,
                                      topUpActive: topUp, hotPaused: hot, pluggedIn: plugged, percent: percent)
        }
        check(held(), "holding at the limit counts")
        check(held(mode: .discharge, percent: 85), "discharging toward the limit counts")
        check(!held(enabled: false), "charge control off doesn't count")
        check(!held(mode: .normal), "charging normally doesn't count")
        check(!held(limit: 100), "no limit doesn't count")
        check(!held(topUp: true), "a top-up doesn't count")
        check(!held(hot: true), "a heat pause isn't the limit")
        check(!held(plugged: false), "on battery doesn't count")
        check(!held(percent: 100), "at 100% nothing was held back")

        let line = LimitPayoff.line(LimitLedger.Summary(hours: 41.2, averagePointsBelowFull: 20.4, activeDays: 5), period: "this week")
        equal(line, "Held below full for 41 h this week, about 20 points under 100%.", "big-hours line")
        let small = LimitPayoff.line(LimitLedger.Summary(hours: 5.3, averagePointsBelowFull: 19.6, activeDays: 1), period: "this week")
        equal(small, "Held below full for 5.3 h this week, about 20 points under 100%.", "small-hours line")
    }

    // MARK: - AppEnergyAlertEngine

    static func energyAlertTests() {
        func sample(_ id: String, _ watts: Double) -> AppEnergyAlertEngine.Sample {
            AppEnergyAlertEngine.Sample(id: id, name: id.uppercased(), watts: watts)
        }
        func sample(_ watts: Double) -> AppEnergyAlertEngine.Sample { sample("a", watts) }
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
        func step(_ e: inout AppEnergyAlertEngine, _ samples: [AppEnergyAlertEngine.Sample], _ minutes: Double,
                  interval: TimeInterval = 300, ignoring: Set<String> = []) -> [AppEnergyAlertEngine.Alert] {
            e.update(samples, at: at(minutes), interval: interval, thresholdWatts: 8, sustainMinutes: 10, ignoring: ignoring)
        }

        // Sustained 10 minutes at 5-minute samples: alert on the third sample, once.
        var e = AppEnergyAlertEngine()
        check(step(&e, [sample(9)], 0).isEmpty, "first hot sample: no alert")
        check(step(&e, [sample(9)], 5).isEmpty, "5 minutes: not yet")
        let alerts = step(&e, [sample(9.5)], 10)
        equal(alerts.count, 1, "alert at 10 minutes")
        equal(alerts.first?.id, "a", "alert is for app a")
        equal(alerts.first?.minutes, 10, "after 10 minutes")
        check(step(&e, [sample(9)], 15).isEmpty, "no repeat in the same episode")

        // Re-arms after 10 quiet minutes, then needs a fresh 10 minutes.
        check(step(&e, [sample(2)], 20).isEmpty, "drops below")
        check(step(&e, [], 25).isEmpty, "absent counts as quiet")
        check(step(&e, [sample(2)], 30).isEmpty, "10 minutes quiet: re-armed")
        check(step(&e, [sample(9)], 35).isEmpty, "new streak starts")
        check(step(&e, [sample(9)], 40).isEmpty, "5 minutes in")
        equal(step(&e, [sample(9)], 45).count, 1, "second episode alerts again")

        // A brief dip inside the quiet period doesn't re-arm: still the same episode.
        var dip = AppEnergyAlertEngine()
        _ = step(&dip, [sample(9)], 0); _ = step(&dip, [sample(9)], 5)
        equal(step(&dip, [sample(9)], 10).count, 1, "alert")
        _ = step(&dip, [sample(2)], 15)
        check(step(&dip, [sample(9)], 20).isEmpty, "a 5-minute dip hasn't re-armed")
        check(step(&dip, [sample(9)], 25).isEmpty, "still the same episode")

        // Samples are stamped when their measurement finishes, so 10 minutes can arrive a little early.
        var early = AppEnergyAlertEngine()
        _ = step(&early, [sample(9)], 0); _ = step(&early, [sample(9)], 5)
        equal(step(&early, [sample(9)], 9.5).count, 1, "9.5 minutes counts as 10")
        var tooEarly = AppEnergyAlertEngine()
        _ = step(&tooEarly, [sample(9)], 0); _ = step(&tooEarly, [sample(9)], 5)
        check(step(&tooEarly, [sample(9)], 8.5).isEmpty, "8.5 minutes is too soon")

        // A gap (sleep) over 2.5 intervals breaks the streak.
        var gap = AppEnergyAlertEngine()
        _ = step(&gap, [sample(9)], 0); _ = step(&gap, [sample(9)], 5)
        check(step(&gap, [sample(9)], 30).isEmpty, "after a 25-minute gap the streak restarts")
        check(step(&gap, [sample(9)], 35).isEmpty, "5 minutes into the new streak")
        equal(step(&gap, [sample(9)], 40).count, 1, "10 minutes into the new streak")

        // Low Power Mode samples every 15 minutes: the streak needs at least two intervals (30 min).
        var slow = AppEnergyAlertEngine()
        check(step(&slow, [sample(9)], 0, interval: 900).isEmpty, "slow: first")
        check(step(&slow, [sample(9)], 15, interval: 900).isEmpty, "slow: 15 min isn't enough")
        equal(step(&slow, [sample(9)], 30, interval: 900).count, 1, "slow: alerts at 30 min")

        // Below the threshold, NaN, and ignored apps never alert.
        var quiet = AppEnergyAlertEngine()
        for m in stride(from: 0.0, through: 60.0, by: 5.0) {
            check(step(&quiet, [sample(7.9), sample("b", .nan)], m).isEmpty, "below threshold at \(m)")
        }
        var ignored = AppEnergyAlertEngine()
        for m in stride(from: 0.0, through: 30.0, by: 5.0) {
            check(step(&ignored, [sample(20)], m, ignoring: ["a"]).isEmpty, "ignored app at \(m)")
        }

        // Two apps are tracked separately.
        var two = AppEnergyAlertEngine()
        _ = step(&two, [sample("a", 9), sample("b", 9)], 0)
        _ = step(&two, [sample("a", 9), sample("b", 2)], 5)
        let both = step(&two, [sample("a", 9), sample("b", 9)], 10)
        equal(both.map(\.id), ["a"], "a is at 10 minutes, b restarted")

        // reset() forgets streaks and alerts.
        var forget = AppEnergyAlertEngine()
        _ = step(&forget, [sample(9)], 0); _ = step(&forget, [sample(9)], 5)
        forget.reset()
        check(step(&forget, [sample(9)], 10).isEmpty, "after reset a streak starts over")

        // extraMinutes: 120 min at 10 W = 20 Wh; at 6 W that lasts 200 min → +80.
        equal(AppEnergyAlertEngine.extraMinutes(timeLeftMinutes: 120, systemWatts: 10, appWatts: 4), 80, "+80 minutes")
        check(AppEnergyAlertEngine.extraMinutes(timeLeftMinutes: 0, systemWatts: 10, appWatts: 4) == nil, "no time left: nil")
        check(AppEnergyAlertEngine.extraMinutes(timeLeftMinutes: 60, systemWatts: 10, appWatts: 9.8) == nil, "app is the whole load: nil")
        check(AppEnergyAlertEngine.extraMinutes(timeLeftMinutes: 60, systemWatts: 10, appWatts: 0) == nil, "no app power: nil")
        check(AppEnergyAlertEngine.extraMinutes(timeLeftMinutes: 60, systemWatts: .nan, appWatts: 4) == nil, "NaN: nil")
    }

    // MARK: - LowPowerWindow

    static func lowPowerWindowTests() {
        // 2026-10-05 is a Monday (weekday 2), 06 Tuesday (3), 07 Wednesday (4), 08 Thursday (5).
        equal(utc.component(.weekday, from: date(2026, 10, 7)), 4, "Oct 7 2026 is a Wednesday")

        var overnight = LowPowerWindow()                       // every day 22:00 to 07:00
        check(overnight.contains(date(2026, 10, 6, 23, 0), calendar: utc), "23:00 inside")
        check(overnight.contains(date(2026, 10, 7, 3, 0), calendar: utc), "03:00 inside")
        check(overnight.contains(date(2026, 10, 6, 22, 0), calendar: utc), "start is inclusive")
        check(!overnight.contains(date(2026, 10, 7, 7, 0), calendar: utc), "end is exclusive")
        check(!overnight.contains(date(2026, 10, 7, 8, 0), calendar: utc), "08:00 outside")
        check(!overnight.contains(date(2026, 10, 7, 21, 59), calendar: utc), "21:59 outside")

        // Only Tuesday nights: Tue 22:00 → Wed 07:00.
        overnight.weekdays = [3]
        check(overnight.contains(date(2026, 10, 6, 23, 0), calendar: utc), "Tuesday 23:00 inside")
        check(overnight.contains(date(2026, 10, 7, 3, 0), calendar: utc), "Wednesday 03:00 belongs to Tuesday's window")
        check(!overnight.contains(date(2026, 10, 7, 23, 0), calendar: utc), "Wednesday 23:00 outside")
        check(!overnight.contains(date(2026, 10, 8, 3, 0), calendar: utc), "Thursday 03:00 outside")

        // Sunday night into Monday: weekday wrap (Sunday = 1, yesterday of Sunday is Saturday = 7).
        var sunday = LowPowerWindow(); sunday.weekdays = [7]       // Saturday night
        check(sunday.contains(date(2026, 10, 11, 2, 0), calendar: utc), "Sunday 02:00 belongs to Saturday's window")
        check(!sunday.contains(date(2026, 10, 12, 2, 0), calendar: utc), "Monday 02:00 doesn't")

        // Same-day window.
        var work = LowPowerWindow(); work.weekdays = [2, 3, 4, 5, 6]; work.startMinute = 9 * 60; work.endMinute = 17 * 60
        check(work.contains(date(2026, 10, 7, 12, 0), calendar: utc), "Wednesday noon inside")
        check(!work.contains(date(2026, 10, 7, 17, 0), calendar: utc), "17:00 is the end")
        check(!work.contains(date(2026, 10, 10, 12, 0), calendar: utc), "Saturday outside")
        check(!work.contains(date(2026, 10, 7, 8, 59), calendar: utc), "08:59 outside")

        var empty = LowPowerWindow(); empty.startMinute = 600; empty.endMinute = 600
        check(!empty.contains(date(2026, 10, 7, 10, 0), calendar: utc), "start == end is never")
        var off = LowPowerWindow(); off.enabled = false
        check(!off.contains(date(2026, 10, 6, 23, 0), calendar: utc), "disabled never")
    }

    // MARK: - LowPowerEngine

    static func lowPowerEngineTests() {
        func engine(below: Int = 20, windows: [LowPowerWindow] = [], batteryOnly: Bool = true,
                    enabled: Bool = true) -> LowPowerEngine {
            var c = LowPowerConfig()
            c.enabled = enabled; c.belowPercent = below; c.windows = windows; c.windowsOnBatteryOnly = batteryOnly
            return LowPowerEngine(config: c, calendar: utc)
        }
        let noon = date(2026, 10, 7, 12, 0)
        var reads = 0
        func decide(_ e: inout LowPowerEngine, percent: Int, plugged: Bool = false, now: Date = noon,
                    system: Bool?) -> LowPowerEngine.Action {
            e.decide(percent: percent, pluggedIn: plugged, now: now) { reads += 1; return system }
        }

        // Charge level rule.
        var e = engine()
        equal(decide(&e, percent: 50, system: false), .none, "50%: nothing")
        equal(decide(&e, percent: 21, system: false), .none, "21%: nothing")
        equal(decide(&e, percent: 20, system: false), .enable, "20%: enable")
        check(e.state.weTurnedOn, "we own it")
        reads = 0
        equal(decide(&e, percent: 19, system: true), .none, "19%: no change")
        equal(decide(&e, percent: 15, system: true), .none, "15%: no change")
        equal(reads, 0, "pmset isn't read unless the wish changes")
        equal(decide(&e, percent: 15, plugged: true, system: true), .disable, "plugged in: give it back")
        check(!e.state.weTurnedOn, "no longer owned")
        equal(decide(&e, percent: 15, plugged: true, system: false), .none, "stays off")

        // Already on when the wish starts: not ours to switch off.
        var mine = engine()
        equal(decide(&mine, percent: 20, system: true), .none, "already on: leave it")
        check(!mine.state.weTurnedOn, "not owned")
        equal(decide(&mine, percent: 20, plugged: true, system: true), .none, "and left on afterwards")

        // The user switched it off mid-episode: no fighting, nothing to undo.
        var user = engine()
        equal(decide(&user, percent: 20, system: false), .enable, "enabled")
        equal(decide(&user, percent: 18, system: false), .none, "user turned it off: not forced back on")
        equal(decide(&user, percent: 18, plugged: true, system: false), .none, "nothing to disable")
        check(!user.state.weTurnedOn, "ownership cleared")

        // Unreadable state: act anyway.
        var unknown = engine()
        equal(decide(&unknown, percent: 20, system: nil), .enable, "unreadable: enable")
        equal(decide(&unknown, percent: 20, plugged: true, system: nil), .disable, "unreadable: disable what we enabled")

        // Hours rule.
        let overnight = LowPowerWindow()
        var night = engine(below: 0, windows: [overnight])
        equal(decide(&night, percent: 90, now: date(2026, 10, 6, 21, 0), system: false), .none, "before the window")
        equal(decide(&night, percent: 90, now: date(2026, 10, 6, 22, 0), system: false), .enable, "window starts")
        equal(decide(&night, percent: 90, now: date(2026, 10, 7, 3, 0), system: true), .none, "inside the window")
        equal(decide(&night, percent: 90, now: date(2026, 10, 7, 7, 0), system: true), .disable, "window ends")

        // Windows apply on battery only by default; plugged-in nights can opt in.
        var pluggedNight = engine(below: 0, windows: [overnight])
        equal(decide(&pluggedNight, percent: 90, plugged: true, now: date(2026, 10, 6, 23, 0), system: false),
              .none, "plugged in: window ignored")
        var anyNight = engine(below: 0, windows: [overnight], batteryOnly: false)
        equal(decide(&anyNight, percent: 90, plugged: true, now: date(2026, 10, 6, 23, 0), system: false),
              .enable, "plugged in allowed")

        // Charge level and window together are one wish, not two.
        var both = engine(windows: [overnight])
        equal(decide(&both, percent: 50, now: date(2026, 10, 6, 23, 0), system: false), .enable, "window starts")
        equal(decide(&both, percent: 15, now: date(2026, 10, 6, 23, 5), system: true), .none, "level joins: no second enable")
        equal(decide(&both, percent: 15, now: date(2026, 10, 7, 8, 0), system: true), .none, "window over but still low: stay on")
        equal(decide(&both, percent: 15, plugged: true, now: date(2026, 10, 7, 8, 5), system: true), .disable, "plugged in: off")

        // Turning the feature off hands it back.
        var off = engine()
        equal(decide(&off, percent: 10, system: false), .enable, "enabled")
        off.config.enabled = false
        equal(decide(&off, percent: 10, system: true), .disable, "feature switched off: disable")
        var neverOn = engine(enabled: false)
        equal(decide(&neverOn, percent: 5, system: false), .none, "disabled feature does nothing")

        // release() / userChangedSystemState().
        var rel = engine()
        _ = decide(&rel, percent: 20, system: false)
        check(rel.release(), "release says we owned it")
        check(!rel.release(), "second release: nothing owned")
        var changed = engine()
        _ = decide(&changed, percent: 20, system: false)
        changed.userChangedSystemState()
        check(!changed.state.weTurnedOn, "manual change drops ownership")
        check(changed.state.wasWanted, "but the wish is remembered, so it isn't re-applied")
        equal(decide(&changed, percent: 10, system: false), .none, "no re-enable after a manual change")

        // A failed pmset call is retried, not forgotten.
        var failEnable = engine()
        equal(decide(&failEnable, percent: 20, system: false), .enable, "wants to enable")
        failEnable.confirm(.enable, ok: false)
        check(!failEnable.state.weTurnedOn && !failEnable.state.wasWanted, "failed enable: nothing claimed")
        equal(decide(&failEnable, percent: 20, system: false), .enable, "failed enable is tried again")
        failEnable.confirm(.enable, ok: true)
        check(failEnable.state.weTurnedOn && failEnable.state.wasWanted, "a successful call changes nothing")

        var failDisable = engine()
        _ = decide(&failDisable, percent: 20, system: false)
        equal(decide(&failDisable, percent: 20, plugged: true, system: true), .disable, "wants to disable")
        failDisable.confirm(.disable, ok: false)
        check(failDisable.state.weTurnedOn && failDisable.state.wasWanted, "failed disable: still ours")
        equal(decide(&failDisable, percent: 20, plugged: true, system: true), .disable, "failed disable is tried again")
        let snapshot = failDisable.state
        failDisable.confirm(.none, ok: false)
        equal(failDisable.state, snapshot, "confirming no action changes nothing")

        // State survives a restart.
        if let data = try? JSONEncoder().encode(e.state),
           let back = try? JSONDecoder().decode(LowPowerEngine.State.self, from: data) {
            equal(back, e.state, "state round-trips")
            var restarted = LowPowerEngine(config: e.config, calendar: utc, state: LowPowerEngine.State(wasWanted: true, weTurnedOn: true))
            equal(decide(&restarted, percent: 15, plugged: true, system: true), .disable, "a restarted helper still gives it back")
        } else {
            check(false, "state encodes")
        }

        // pmset -g custom: the per-source values the helper puts back.
        let custom = "Battery Power:\n lowpowermode         1\n sleep                1\nAC Power:\n lowpowermode         0\n sleep                0\n"
        let perSource = LowPowerEngine.parsePmsetCustom(custom)
        equal(perSource.battery, true, "battery value read")
        equal(perSource.ac, false, "charger value read")
        let batteryOnly = LowPowerEngine.parsePmsetCustom("Battery Power:\n lowpowermode 1\nAC Power:\n sleep 0\n")
        equal(batteryOnly.battery, true, "battery only: battery read")
        check(batteryOnly.ac == nil, "battery only: no charger value")
        let emptyCustom = LowPowerEngine.parsePmsetCustom("")
        check(emptyCustom.battery == nil && emptyCustom.ac == nil, "empty output: no values")
        let outside = LowPowerEngine.parsePmsetCustom(" lowpowermode 1\nBattery Power:\n sleep 1\n")
        check(outside.battery == nil && outside.ac == nil, "a value outside any power source is ignored")

        // pmset parsing.
        let on = "System-wide power settings:\nCurrently in use:\n standby              1\n lowpowermode         1\n powermode            1\n"
        equal(LowPowerEngine.parsePmset(on), true, "lowpowermode 1")
        equal(LowPowerEngine.parsePmset(on.replacingOccurrences(of: "lowpowermode         1", with: "lowpowermode         0")),
              false, "lowpowermode 0")
        check(LowPowerEngine.parsePmset("standby 1\nsleep 1\n") == nil, "no line: nil")
        check(LowPowerEngine.parsePmset("lowpowermode x\n") == nil, "garbage value: nil")
        check(LowPowerEngine.parsePmset("") == nil, "empty output: nil")
        equal(LowPowerEngine.parsePmset(" sleep 7\n powermode            0\n"), false, "newer macOS: powermode 0")
        equal(LowPowerEngine.parsePmset(" powermode            1\n"), true, "newer macOS: powermode 1")
        equal(LowPowerEngine.parsePmset(" powermode            2\n"), false, "High Power Mode isn't Low Power Mode")
        equal(LowPowerEngine.parsePmset(" powermode 0\n lowpowermode 1\n"), true, "lowpowermode wins when both are printed")
        near(EnergyLedger.batteryFraction(wh: 5, fullChargeWh: 50) ?? -1, 0.1, "5 Wh of a 50 Wh battery")
        check(EnergyLedger.batteryFraction(wh: 5, fullChargeWh: nil) == nil, "unknown capacity: nil")
        check(EnergyLedger.batteryFraction(wh: 5, fullChargeWh: 0) == nil, "zero capacity: nil")
        equal(EnergyLedger.batteryText(wh: 19, fullChargeWh: 50), "38% of battery", "38% text")
        equal(EnergyLedger.batteryText(wh: 0.2, fullChargeWh: 50), "<1% of battery", "<1% text")
        equal(EnergyLedger.batteryText(wh: 120, fullChargeWh: 50), "2.4 charges", "more than one charge")
        let newCustom = LowPowerEngine.parsePmsetCustom("Battery Power:\n powermode 1\nAC Power:\n powermode 0\n")
        check(newCustom.battery == true && newCustom.ac == false, "per-source powermode")
    }

    // MARK: - Config

    static func lowPowerConfigTests() {
        var c = LowPowerConfig()
        c.belowPercent = 3
        equal(c.sanitized.belowPercent, 5, "3% raised to 5")
        c.belowPercent = 95
        equal(c.sanitized.belowPercent, 80, "95% lowered to 80")
        c.belowPercent = 0
        equal(c.sanitized.belowPercent, 0, "0 means never by level")
        c.belowPercent = -4
        equal(c.sanitized.belowPercent, 0, "negative means never")

        var w = LowPowerWindow()
        w.startMinute = -5; w.endMinute = 5000; w.weekdays = [0, 3, 3, 9, 1]
        c.windows = Array(repeating: w, count: 12)
        let clean = c.sanitized
        equal(clean.windows.count, 8, "at most 8 windows")
        equal(clean.windows.first?.startMinute, 0, "start clamped")
        equal(clean.windows.first?.endMinute, 1439, "end clamped")
        equal(clean.windows.first?.weekdays, [1, 3], "weekdays deduplicated and limited to 1...7")

        // Settings saved by 1.10 (no lowPower key) still load, with Low Power Mode off.
        let old = #"{"enabled":true,"limit":80,"sailingRange":3}"#
        if let decoded = try? JSONDecoder().decode(ChargePolicyConfig.self, from: Data(old.utf8)) {
            equal(decoded.lowPower, LowPowerConfig(), "older settings get the default (off)")
            equal(decoded.limit, 80, "other settings kept")
        } else {
            check(false, "1.10 settings decode")
        }

        // Round trip, and sanitizing the whole policy sanitizes Low Power Mode too.
        var policy = ChargePolicyConfig()
        policy.lowPower.enabled = true
        policy.lowPower.belowPercent = 30
        policy.lowPower.windows = [LowPowerWindow()]
        if let data = try? JSONEncoder().encode(policy),
           let back = try? JSONDecoder().decode(ChargePolicyConfig.self, from: data) {
            equal(back, policy, "policy with Low Power round-trips")
        } else {
            check(false, "policy encodes")
        }
        policy.lowPower.belowPercent = 2
        equal(policy.sanitized.lowPower.belowPercent, 5, "policy.sanitized sanitizes Low Power")

        // A 1.10-era helper's status (no Low Power fields) still decodes in a newer app.
        let status = #"{"version":2,"pluggedIn":true,"lidClosed":false,"mode":"normal","reason":"x","effectiveLimit":80,"topUpActive":false,"policy":{}}"#
        if let decoded = try? JSONDecoder().decode(HelperStatus.self, from: Data(status.utf8)) {
            equal(decoded.version, 2, "old helper version read")
            check(decoded.lowPowerManaged == nil, "no Low Power field from an old helper")
        } else {
            check(false, "old helper status decodes")
        }
        equal(HelperStatus.currentVersion, 3, "helper version 3 adds Low Power Mode")
    }

    // MARK: - Temperature trend

    static func temperatureTests() {
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

        // A temperature move of 2 °C gets its own point; 1 °C inside the heartbeat doesn't.
        var log = ChargeLog()
        check(log.record(percent: 50, pluggedIn: false, celsius: 30, at: at(0)), "first point")
        check(!log.record(percent: 50, pluggedIn: false, celsius: 31, at: at(1)), "+1 °C: skipped")
        check(log.record(percent: 50, pluggedIn: false, celsius: 32, at: at(2)), "+2 °C from the last stored: stored")
        check(!log.record(percent: 50, pluggedIn: false, celsius: nil, at: at(3)), "no reading: skipped")
        check(!log.record(percent: 50, pluggedIn: false, at: at(4)), "old call style still works")
        check(log.record(percent: 50, pluggedIn: false, celsius: 33, at: at(12)), "heartbeat stores anyway")
        near(log.points.last?.celsius, 33, "temperature kept on the point")
        check(log.record(percent: 49, pluggedIn: false, celsius: .nan, at: at(13)), "percent change stored")
        check(log.points.last?.celsius == nil, "NaN temperature dropped")

        // Files from 1.9/1.10 have no temperature at all.
        let oldJSON = #"{"points":[{"time":"2026-09-21T14:13:20Z","percent":50,"pluggedIn":false}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let old = try? decoder.decode(ChargeLog.self, from: Data(oldJSON.utf8)) {
            equal(old.points.count, 1, "old history loads")
            check(old.points.first?.celsius == nil, "with no temperature")
        } else {
            check(false, "old charge history decodes")
        }

        // Summary: 30, 41, 42, 35 at 0/10/20/30 minutes; limit 40; now 40 minutes.
        // Hot: 41 °C from 10 → 20 (10 min) and 42 °C from 20 → 30 (10 min) = 20 min.
        let points = [(0.0, 30.0), (10, 41), (20, 42), (30, 35)].map {
            ChargePoint(time: at($0.0), percent: 50, pluggedIn: false, celsius: $0.1)
        }
        let s = TemperatureTrend.summary(points, hotLimit: 40, until: at(40))
        near(s?.lowest, 30, "coolest")
        near(s?.highest, 42, "warmest")
        equal(s?.highestAt, at(20), "warmest at 20 minutes")
        equal(s?.minutesHot, 20, "20 minutes at or above 40 °C")

        // A reading with a long gap after it counts at most 15 minutes (1.5 × the heartbeat).
        let gap = [ChargePoint(time: at(0), percent: 50, pluggedIn: false, celsius: 45),
                   ChargePoint(time: at(60), percent: 50, pluggedIn: false, celsius: 30)]
        equal(TemperatureTrend.summary(gap, hotLimit: 40, until: at(70))?.minutesHot, 15, "sleep gap is capped at 15 minutes")
        // The last reading runs until `end`.
        let last = [ChargePoint(time: at(0), percent: 50, pluggedIn: false, celsius: 30),
                    ChargePoint(time: at(5), percent: 50, pluggedIn: false, celsius: 44)]
        equal(TemperatureTrend.summary(last, hotLimit: 40, until: at(12))?.minutesHot, 7, "last reading counts until now")

        check(TemperatureTrend.summary([], hotLimit: 40, until: at(1)) == nil, "empty: nil")
        let one = [ChargePoint(time: at(0), percent: 50, pluggedIn: false, celsius: 30),
                   ChargePoint(time: at(5), percent: 50, pluggedIn: false)]
        check(TemperatureTrend.summary(one, hotLimit: 40, until: at(6)) == nil, "one temperature reading: nil")

        // CSV: a temperature column, blank when unknown.
        var csvLog = ChargeLog()
        csvLog.record(percent: 50, pluggedIn: false, celsius: 33.456, at: t0)
        csvLog.record(percent: 51, pluggedIn: true, at: t0.addingTimeInterval(60))
        equal(CSV.charge(csvLog),
              "time,percent,plugged_in,temperature_c\n2026-09-21T14:13:20Z,50,no,33.5\n2026-09-21T14:14:20Z,51,yes,\n",
              "charge CSV with temperature")
    }
}
