//
//  UsageInsightsTests.swift
//  KwikBattery
//
//  Tests for UsageInsights.swift (1.9): the charge timeline, sleep drain,
//  since-unplugged summary, Bluetooth device alerts, CSV export and the
//  shortcut choices. Compiled into the insights test program and run from
//  InsightsTests.main(), using its check helpers.
//

import Foundation

enum UsageInsightsTests {
    static func run() {
        chargeLogTests()
        sleepDrainTests()
        dischargeSessionTests()
        deviceAlertTests()
        csvTests()
        hotKeyTests()
    }

    static let t0 = InsightsTests.t0
    static func at(minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    static func at(hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    static func check(_ ok: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        InsightsTests.check(ok(), message, line: line)
    }
    static func near(_ value: Double?, _ expected: Double, _ message: String,
                     tolerance: Double = 1e-9, line: Int = #line) {
        InsightsTests.near(value, expected, message, tolerance: tolerance, line: line)
    }
    static func equal<T: Equatable>(_ value: T, _ expected: T, _ message: String, line: Int = #line) {
        InsightsTests.equal(value, expected, message, line: line)
    }

    // MARK: - ChargeLog

    static func chargeLogTests() {
        var log = ChargeLog()
        check(log.record(percent: 50, pluggedIn: false, at: t0), "first point stored")
        check(!log.record(percent: 50, pluggedIn: false, at: at(minutes: 5)), "unchanged within 10 min skipped")
        check(log.record(percent: 50, pluggedIn: false, at: at(minutes: 10)), "unchanged at 10 min stored (heartbeat)")
        check(log.record(percent: 49, pluggedIn: false, at: at(minutes: 11)), "percent change stored")
        check(log.record(percent: 49, pluggedIn: true, at: at(minutes: 12)), "plug change stored")
        equal(log.points.count, 4, "four points")

        // Clock backwards to 5 min: the 10, 11 and 12 min points go; 48% is new.
        var back = log
        back.record(percent: 48, pluggedIn: false, at: at(minutes: 5))
        equal(back.points.map(\.percent), [50, 48], "points after the new time dropped")

        // 49 hours later everything before hour 1 is gone: only the new point.
        var old = log
        old.record(percent: 30, pluggedIn: false, at: at(hours: 49))
        equal(old.points.count, 1, "48-hour retention")

        // Spans: unplugged at 0 h, plugged 1 h, unplugged 3 h, plugged 5 h.
        var spans = ChargeLog()
        spans.record(percent: 50, pluggedIn: false, at: t0)
        spans.record(percent: 45, pluggedIn: true, at: at(hours: 1))
        spans.record(percent: 80, pluggedIn: false, at: at(hours: 3))
        spans.record(percent: 70, pluggedIn: true, at: at(hours: 5))
        let all = spans.pluggedSpans(from: t0, to: at(hours: 6))
        equal(all, [DateInterval(start: at(hours: 1), end: at(hours: 3)),
                    DateInterval(start: at(hours: 5), end: at(hours: 6))], "two spans, the last still open")
        let clipped = spans.pluggedSpans(from: at(hours: 2), to: at(hours: 6))
        equal(clipped.first, DateInterval(start: at(hours: 2), end: at(hours: 3)), "span clipped to window start")
        equal(spans.pluggedSpans(from: at(hours: 2), to: at(hours: 4)).count, 1, "later span outside window")
        equal(spans.pluggedSpans(from: at(hours: 5.5), to: at(hours: 6)),
              [DateInterval(start: at(hours: 5.5), end: at(hours: 6))], "window starting inside a span")
        equal(spans.points(from: at(hours: 1), to: at(hours: 3)).count, 2, "points in range, inclusive")
    }

    // MARK: - Sleep drain

    static func sleepDrainTests() {
        func mark(_ time: Date, _ percent: Int, plugged: Bool = false) -> SleepDrain.Mark {
            SleepDrain.Mark(time: time, percent: percent, pluggedIn: plugged)
        }

        // 7 h, 80 → 77: 3 points, 3/7 = 0.4286 %/h. Normal.
        if let night = SleepDrain.report(sleep: mark(t0, 80), wake: mark(at(hours: 7), 77)) {
            equal(night.drop, 3, "overnight drop")
            near(night.percentPerHour, 3.0 / 7.0, "overnight rate")
            check(!SleepDrain.isHeavy(night, thresholdPerHour: 1.5), "0.43 %/h is normal")
            equal(SleepDrain.summary(night), "Lost 3% while asleep for 7h 0m (0.4%/h)", "summary text")
        } else {
            check(false, "overnight report missing")
        }

        // 2 h, 80 → 72: 8 points, 4 %/h. Heavy.
        if let heavy = SleepDrain.report(sleep: mark(t0, 80), wake: mark(at(hours: 2), 72)) {
            near(heavy.percentPerHour, 4.0, "heavy rate")
            check(SleepDrain.isHeavy(heavy, thresholdPerHour: 1.5), "4 %/h is heavy")
        } else {
            check(false, "heavy report missing")
        }

        // 40 min, 80 → 78: 3 %/h but only 2 points: rounding, not heavy.
        if let small = SleepDrain.report(sleep: mark(t0, 80), wake: mark(at(minutes: 40), 78)) {
            near(small.percentPerHour, 3.0, "small-drop rate")
            check(!SleepDrain.isHeavy(small, thresholdPerHour: 1.5), "a 2-point drop is never heavy")
        } else {
            check(false, "40-minute report missing")
        }

        if let none = SleepDrain.report(sleep: mark(t0, 80), wake: mark(at(hours: 8), 80)) {
            equal(SleepDrain.summary(none), "Lost nothing while asleep for 8h 0m", "no-loss summary")
        } else {
            check(false, "no-loss report missing")
        }

        check(SleepDrain.report(sleep: mark(t0, 80), wake: mark(at(minutes: 20), 79)) == nil, "under 30 min: nil")
        check(SleepDrain.report(sleep: mark(t0, 80, plugged: true), wake: mark(at(hours: 7), 77)) == nil,
              "plugged in at sleep: nil")
        check(SleepDrain.report(sleep: mark(t0, 80), wake: mark(at(hours: 7), 77, plugged: true)) == nil,
              "plugged in at wake: nil")
        check(SleepDrain.report(sleep: mark(t0, 70), wake: mark(at(hours: 7), 75)) == nil, "charge rose: nil")
        check(SleepDrain.report(sleep: mark(at(hours: 7), 80), wake: mark(t0, 77)) == nil, "wake before sleep: nil")
    }

    // MARK: - Since unplugged

    static func dischargeSessionTests() {
        let start = DischargeSession.update(nil, pluggedIn: false, percent: 90, capacity: 5000, at: t0)
        equal(start, DischargeSession(start: t0, startPercent: 90, startCapacity: 5000), "unplug starts a session")
        equal(DischargeSession.update(start, pluggedIn: false, percent: 85, capacity: 4700, at: at(minutes: 30)),
              start, "draining keeps the session")
        equal(DischargeSession.update(start, pluggedIn: false, percent: 91, capacity: 5050, at: at(minutes: 30)),
              start, "+1 point is rounding: same session")
        equal(DischargeSession.update(start, pluggedIn: false, percent: 92, capacity: 5100, at: at(minutes: 30))?.startPercent,
              92, "+2 points: charged unseen, new session")
        equal(DischargeSession.update(start, pluggedIn: true, percent: 85, capacity: 4700, at: at(minutes: 30)),
              nil, "plugging in ends it")

        // 2 h later at 70%, 4000 mAh, 12 V: 1000 mAh × 12 V = 12 Wh; 12 Wh / 2 h = 6 W.
        guard let session = start else { return }
        let summary = session.summary(percent: 70, capacity: 4000, voltage: 12, at: at(hours: 2))
        near(summary.elapsed, 7200, "elapsed")
        equal(summary.percentUsed, 20, "percent used")
        near(summary.wattHours, 12.0, "watt-hours")
        near(summary.averageWatts, 6.0, "average watts")
        equal(DischargeSession.text(summary), "Since unplugged: 2h 0m · 20% used · avg 6.0 W", "summary text")

        let early = session.summary(percent: 90, capacity: 4990, voltage: 12, at: at(minutes: 4))
        check(early.averageWatts == nil, "no average in the first 5 minutes")
        let noCapacity = session.summary(percent: 80, capacity: nil, voltage: 12, at: at(hours: 1))
        check(noCapacity.wattHours == nil && noCapacity.averageWatts == nil, "no capacity, no watts")
        equal(DischargeSession.text(noCapacity), "Since unplugged: 1h 0m · 10% used", "text without watts")
    }

    // MARK: - Device alerts

    static func deviceAlertTests() {
        typealias Reading = DeviceBatteryAlerts.Reading
        var alerts = DeviceBatteryAlerts()
        let first = alerts.update([Reading(id: "a", name: "Mouse", level: 25, isCharging: false),
                                   Reading(id: "b", name: "AirPods", level: 15, isCharging: false),
                                   Reading(id: "c", name: "Speaker", level: nil, isCharging: false)],
                                  threshold: 20)
        equal(first.map(\.id), ["b"], "only the device at or below 20% alerts")
        equal(alerts.update([Reading(id: "b", name: "AirPods", level: 14, isCharging: false)], threshold: 20).count,
              0, "no repeat while still low")
        equal(alerts.update([Reading(id: "b", name: "AirPods", level: 24, isCharging: false)], threshold: 20).count,
              0, "24% isn't enough to re-arm (needs > 25)")
        check(alerts.alerted.contains("b"), "still armed-off at 24%")
        _ = alerts.update([Reading(id: "b", name: "AirPods", level: 26, isCharging: false)], threshold: 20)
        check(!alerts.alerted.contains("b"), "26% re-arms")
        equal(alerts.update([Reading(id: "b", name: "AirPods", level: 18, isCharging: false)], threshold: 20).map(\.id),
              ["b"], "alerts again after re-arming")
        _ = alerts.update([Reading(id: "b", name: "AirPods", level: 18, isCharging: true)], threshold: 20)
        check(!alerts.alerted.contains("b"), "charging re-arms")
        equal(alerts.update([Reading(id: "d", name: "Keyboard", level: 5, isCharging: true)], threshold: 20).count,
              0, "a charging device never alerts")
        equal(alerts.update([Reading(id: "e", name: "Trackpad", level: 20, isCharging: false)], threshold: 20).count,
              1, "exactly at the threshold alerts")
    }

    // MARK: - CSV

    static func csvTests() {
        equal(CSV.field("plain"), "plain", "plain field")
        equal(CSV.field("a,b"), "\"a,b\"", "comma quoted")
        equal(CSV.field("say \"hi\""), "\"say \"\"hi\"\"\"", "quotes doubled")
        equal(CSV.field("two\nlines"), "\"two\nlines\"", "newline quoted")
        equal(CSV.field(" lead"), "\" lead\"", "leading space quoted")
        equal(CSV.field("=SUM(A1)"), "'=SUM(A1)", "formula neutralised")
        equal(CSV.field("-x,y"), "\"'-x,y\"", "formula prefix then quoted")
        equal(CSV.make(header: ["a", "b"], rows: [["1", "x,y"]]), "a,b\n1,\"x,y\"\n", "table")
        equal(CSV.number(nil), "", "nil number")
        equal(CSV.number(.nan), "", "NaN number")
        equal(CSV.number(1.23456, places: 2), "1.23", "rounded number")

        // 12 W × 300 s = 1.0 Wh: Alpha 50% → 0.5 Wh, Beta 25% → 0.25 Wh.
        var ledger = EnergyLedger()
        ledger.record(day: "2026-10-01",
                      apps: [(id: "b", name: "Beta", appPath: nil, percentShare: 25),
                             (id: "a", name: "Alpha", appPath: nil, percentShare: 50)],
                      systemLoadWatts: 12, seconds: 300)
        equal(CSV.energy(ledger),
              "date,app,wh,share_of_day_percent,day_total_wh\n"
              + "2026-10-01,Alpha,0.500,50.0,1.000\n"
              + "2026-10-01,Beta,0.250,25.0,1.000\n",
              "energy CSV, most first")

        var log = ChargeLog()
        log.record(percent: 50, pluggedIn: false, at: t0)          // 2026-09-21 14:13:20 UTC
        log.record(percent: 51, pluggedIn: true, at: at(minutes: 1))
        equal(CSV.charge(log),
              "time,percent,plugged_in,temperature_c\n2026-09-21T14:13:20Z,50,no,\n2026-09-21T14:14:20Z,51,yes,\n",
              "charge CSV")
    }

    // MARK: - Shortcut

    static func hotKeyTests() {
        equal(HotKeyChoice.off.carbonModifiers, nil, "off registers nothing")
        equal(HotKeyChoice.controlOptionB.carbonModifiers, 4096 + 2048, "⌃⌥ = controlKey | optionKey")
        equal(HotKeyChoice.optionCommandB.carbonModifiers, 2048 + 256, "⌥⌘ = optionKey | cmdKey")
        equal(HotKeyChoice.controlOptionCommandB.carbonModifiers, 4096 + 2048 + 256, "⌃⌥⌘")
        equal(HotKeyChoice.keyCodeB, 11, "kVK_ANSI_B")
        equal(HotKeyChoice(rawValue: "optionCommandB"), .optionCommandB, "raw value round trip")
        equal(HotKeyChoice(rawValue: "nope"), nil, "unknown raw value")
    }
}
