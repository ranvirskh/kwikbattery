//
//  InsightsTests.swift
//  KwikBattery
//
//  Tests for the 1.8 logic: the smoothed run-time estimator, menu bar text,
//  the per-app energy ledger, the charger check, the hot-battery episode
//  tracker and the --status JSON. Run with:
//      bash build.sh --test
//
//  Compiled with BatteryInfo.swift, BatteryInsights.swift and EnergyLedger.swift
//  into its own small program (separate from PowerTests) that exits non-zero if
//  any check fails. Every expected number is worked out in the comment beside it.
//

import Foundation

@main
struct InsightsTests {
    static var checks = 0
    static var failures = 0

    static func check(_ ok: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !ok() {
            failures += 1
            print("  FAIL (line \(line)): \(message)")
        }
    }

    static func near(_ value: Double?, _ expected: Double, _ message: String,
                     tolerance: Double = 1e-9, line: Int = #line) {
        checks += 1
        guard let value else {
            failures += 1
            print("  FAIL (line \(line)): \(message) -- got nil, expected \(expected)")
            return
        }
        if abs(value - expected) > tolerance {
            failures += 1
            print("  FAIL (line \(line)): \(message) -- got \(value), expected \(expected)")
        }
    }

    static func equal<T: Equatable>(_ value: T, _ expected: T, _ message: String, line: Int = #line) {
        checks += 1
        if value != expected {
            failures += 1
            print("  FAIL (line \(line)): \(message) -- got \(value), expected \(expected)")
        }
    }

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func at(minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    static func main() {
        estimatorTests()
        menuTextTests()
        ledgerTests()
        chargerTests()
        hotGuardTests()
        statusTests()

        print("Insights tests: \(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - RunTimeEstimator

    /// One reading a minute, k = 0...`last`, percent = f(k).
    static func feed(_ estimator: inout RunTimeEstimator, through last: Int, _ percent: (Int) -> Double) {
        for k in 0...last {
            estimator.add(percent: percent(k), at: at(minutes: Double(k)), onBattery: true)
        }
    }

    static func estimatorTests() {
        // Steady drain: 1% every 2 minutes for 30 minutes, 80% → 65%.
        // The least-squares slope of 80 - floor(k/2) over k = 0...30 is exactly
        // -0.5 %/min (the staircase is symmetric about the line), so time left is
        // 65 / 0.5 = 130 minutes.
        var steady = RunTimeEstimator()
        feed(&steady, through: 30) { 80 - Double($0 / 2) }
        equal(steady.samples.count, 31, "one sample a minute kept")
        near(steady.slopePerMinute, -0.5, "steady slope", tolerance: 1e-9)
        if let minutes = steady.minutesRemaining {
            check(abs(Double(minutes) - 130) <= 13, "steady drain within 10% of 130 min (got \(minutes))")
            equal(minutes, 130, "steady drain exact")
        } else {
            check(false, "steady drain gave nil")
        }

        // Short span: 9 minutes, 80% → 76% (a 4-point drop, but < 10 min) → nil.
        var short = RunTimeEstimator()
        feed(&short, through: 9) { 80 - Double($0 / 2) }
        check(short.minutesRemaining == nil, "under 10 minutes of data gives nil")
        // ...and the same at exactly 10 minutes (80 → 75) gives a figure.
        short.add(percent: 75, at: at(minutes: 10), onBattery: true)
        check(short.minutesRemaining != nil, "10 minutes and a 5-point drop gives a figure")

        // Small drop: 30 minutes but only 80 → 79 → nil.
        var small = RunTimeEstimator()
        feed(&small, through: 30) { $0 < 15 ? 80 : 79 }
        check(small.minutesRemaining == nil, "a 1-point drop gives nil")

        // Plugging in clears everything.
        var plug = steady
        plug.add(percent: 65, at: at(minutes: 31), onBattery: false)
        equal(plug.samples.count, 0, "plug-in clears samples")
        check(plug.minutesRemaining == nil, "plug-in gives nil")

        // A gap over 20 minutes (sleep) starts again; 19 minutes doesn't.
        var gap = steady
        gap.add(percent: 60, at: at(minutes: 30 + 21), onBattery: true)
        equal(gap.samples.count, 1, "21-minute gap resets to the new sample")
        check(gap.minutesRemaining == nil, "after a reset there's no estimate")
        // At 49 min the 45-minute window starts at 4 min, so minutes 4...30
        // (27 samples) survive, plus the new one: 28.
        var noGap = steady
        noGap.add(percent: 60, at: at(minutes: 30 + 19), onBattery: true)
        equal(noGap.samples.count, 28, "19-minute gap keeps (windowed) history")

        // Clock going backwards resets.
        var clock = steady
        clock.add(percent: 65, at: at(minutes: 30).addingTimeInterval(-10), onBattery: true)
        equal(clock.samples.count, 1, "clock backwards resets")

        // Dedupe: same percent within 60 s is skipped; a change is kept.
        var dedupe = RunTimeEstimator()
        dedupe.add(percent: 80, at: t0, onBattery: true)
        dedupe.add(percent: 80, at: t0.addingTimeInterval(10), onBattery: true)
        equal(dedupe.samples.count, 1, "same percent 10 s later is skipped")
        dedupe.add(percent: 79, at: t0.addingTimeInterval(20), onBattery: true)
        equal(dedupe.samples.count, 2, "changed percent 20 s later is kept")
        dedupe.add(percent: 79, at: t0.addingTimeInterval(30), onBattery: true)
        equal(dedupe.samples.count, 2, "unchanged again within 60 s is skipped")
        dedupe.add(percent: 79, at: t0.addingTimeInterval(80), onBattery: true)
        equal(dedupe.samples.count, 3, "unchanged after 60 s is kept")

        // Window trim: 60 minutes of 1% every 3 minutes (90% → 70%). Only
        // k = 15...60 lie within 45 minutes of the last reading: 46 samples.
        // Over that stretch the fitted rate is ~1/3 %/min (-0.33302), so time
        // left ≈ 70 / 0.33302 ≈ 210 minutes.
        var window = RunTimeEstimator()
        feed(&window, through: 60) { 90 - Double($0 / 3) }
        equal(window.samples.count, 46, "window keeps the last 45 minutes")
        equal(window.samples.first?.time, at(minutes: 15), "oldest kept sample is at 15 min")
        near(window.slopePerMinute, -0.3330249768732655, "window slope", tolerance: 1e-9)
        equal(window.minutesRemaining, 210, "window estimate")

        // Over 30 hours → nil. One reading a minute for 44 minutes (a two-reading
        // version would trip the 20-minute gap rule): 92% for k = 0...21, 91% for
        // 22...43, 90% at 44. Fitted slope -0.0362319 %/min, so 90 / 0.0362319 =
        // 2484 minutes (41 h): too flat to be a believable prediction.
        var long = RunTimeEstimator()
        feed(&long, through: 44) { 92 - Double($0 / 22) }
        near(long.slopePerMinute, -0.036231884057971016, "slow-drain slope", tolerance: 1e-9)
        check(long.minutesRemaining == nil, "over 30 hours gives nil")

        // A trend that isn't falling (slope +0.141 %/min) → nil, even though the
        // last reading is 2 points below the first (50 → 48).
        var rising = RunTimeEstimator()
        feed(&rising, through: 45) { k in
            if k == 0 { return 50 }
            if k == 45 { return 48 }
            return k <= 10 ? 45 : 52
        }
        near(rising.slopePerMinute, 0.14122725871106998, "rising slope", tolerance: 1e-9)
        check(rising.minutesRemaining == nil, "slope flatter than -0.005 %/min gives nil")

        // NaN is treated like losing the trend.
        var bad = steady
        bad.add(percent: .nan, at: at(minutes: 31), onBattery: true)
        equal(bad.samples.count, 0, "NaN percent resets")
    }

    // MARK: - Menu bar text

    static func menuTextTests() {
        equal(MenuBarText.text(mode: .none, percentage: 83, minutes: 150, watts: -18), "", "none")
        equal(MenuBarText.text(mode: .percent, percentage: 83, minutes: nil, watts: nil), " 83%", "percent")
        equal(MenuBarText.text(mode: .percent, percentage: 100, minutes: nil, watts: nil), " 100%", "percent 100")
        equal(MenuBarText.text(mode: .timeLeft, percentage: 83, minutes: 150, watts: nil), " 2h 30m", "time 150 min")
        equal(MenuBarText.text(mode: .timeLeft, percentage: 83, minutes: 45, watts: nil), " 45m", "time 45 min")
        equal(MenuBarText.text(mode: .timeLeft, percentage: 83, minutes: nil, watts: nil), "", "time unknown")
        equal(MenuBarText.text(mode: .watts, percentage: 83, minutes: nil, watts: -18.2), " -18 W", "watts discharging")
        equal(MenuBarText.text(mode: .watts, percentage: 83, minutes: nil, watts: 41.6), " +42 W", "watts charging")
        equal(MenuBarText.text(mode: .watts, percentage: 83, minutes: nil, watts: -0.3), " 0 W", "watts ~0")
        equal(MenuBarText.text(mode: .watts, percentage: 83, minutes: nil, watts: .nan), "", "watts NaN")
        equal(MenuBarText.text(mode: .watts, percentage: 83, minutes: nil, watts: nil), "", "watts unknown")
        equal(MenuBarTextMode(rawValue: "timeLeft"), .timeLeft, "raw value round trip")
        equal(MenuBarTextMode(rawValue: "bogus"), nil, "unknown raw value")
    }

    // MARK: - EnergyLedger

    static func ledgerTests() {
        var ledger = EnergyLedger()

        // 12 W for 300 s = 12 × 300 / 3600 = 1.0 Wh. A had 50% → 0.5 Wh, B 25% → 0.25 Wh.
        ledger.record(day: "2026-10-01",
                      apps: [(id: "a", name: "Alpha", appPath: "/Applications/Alpha.app", percentShare: 50),
                             (id: "b", name: "Beta", appPath: nil, percentShare: 25)],
                      systemLoadWatts: 12, seconds: 300)
        near(ledger.days["2026-10-01"]?.totalWh, 1.0, "day total after one sample")
        near(ledger.days["2026-10-01"]?.apps["a"]?.wh, 0.5, "A after one sample")
        near(ledger.days["2026-10-01"]?.apps["b"]?.wh, 0.25, "B after one sample")

        // 24 W for 150 s = 1.0 Wh more; A had 20% → +0.2 → 0.7 Wh. Day = 2.0 Wh.
        ledger.record(day: "2026-10-01",
                      apps: [(id: "a", name: "Alpha", appPath: "/Applications/Alpha.app", percentShare: 20)],
                      systemLoadWatts: 24, seconds: 150)
        near(ledger.days["2026-10-01"]?.totalWh, 2.0, "day total after two samples")
        near(ledger.days["2026-10-01"]?.apps["a"]?.wh, 0.7, "A after two samples")
        near(ledger.days["2026-10-01"]?.seconds, 450, "seconds tracked")

        // Today only: A 0.7 / 2.0 = 0.35, B 0.25 / 2.0 = 0.125.
        let today = ledger.rankings(forDays: 1, endingOn: "2026-10-01")
        equal(today.map { $0.id }, ["a", "b"], "today ranking order")
        near(today.first?.wh, 0.7, "today A Wh")
        near(today.first?.shareOfTotal, 0.35, "today A share")
        near(today.last?.shareOfTotal, 0.125, "today B share")
        near(today.reduce(0) { $0 + $1.shareOfTotal }, 0.475, "today shares sum")
        check(today.reduce(0) { $0 + $1.shareOfTotal } <= 1.0, "shares never exceed the total")

        // Six days earlier: C 100% at 10 W for 360 s = 1.0 Wh.
        ledger.record(day: "2026-09-25",
                      apps: [(id: "c", name: "Gamma", appPath: nil, percentShare: 100)],
                      systemLoadWatts: 10, seconds: 360)
        // 7 days ending 10-01 = 09-25...10-01, so C is in: total 3.0 Wh.
        // C 1.0/3 = 0.3333, A 0.7/3 = 0.2333, B 0.25/3 = 0.0833; sum 1.95/3 = 0.65.
        near(ledger.totalWh(forDays: 7, endingOn: "2026-10-01"), 3.0, "week total")
        let week = ledger.rankings(forDays: 7, endingOn: "2026-10-01")
        equal(week.map { $0.id }, ["c", "a", "b"], "week ranking order")
        near(week.first?.shareOfTotal, 1.0 / 3.0, "week C share")
        near(week[1].shareOfTotal, 0.7 / 3.0, "week A share")
        near(week.reduce(0) { $0 + $1.shareOfTotal }, 0.65, "week shares sum")
        // 6 days ending 10-01 = 09-26...10-01: C is out again.
        equal(ledger.rankings(forDays: 6, endingOn: "2026-10-01").map { $0.id }, ["a", "b"], "6-day window excludes 09-25")
        near(ledger.totalWh(forDays: 1, endingOn: "2026-10-01"), 2.0, "today total unchanged")

        // Invalid samples change nothing.
        let before = ledger
        ledger.record(day: "2026-10-01", apps: [(id: "a", name: "Alpha", appPath: nil, percentShare: 50)],
                      systemLoadWatts: 0, seconds: 300)
        ledger.record(day: "2026-10-01", apps: [(id: "a", name: "Alpha", appPath: nil, percentShare: 50)],
                      systemLoadWatts: .nan, seconds: 300)
        ledger.record(day: "2026-10-01", apps: [(id: "a", name: "Alpha", appPath: nil, percentShare: 50)],
                      systemLoadWatts: 10, seconds: -5)
        ledger.record(day: "2026-13-01", apps: [(id: "a", name: "Alpha", appPath: nil, percentShare: 50)],
                      systemLoadWatts: 10, seconds: 300)
        check(ledger == before, "zero/NaN watts, negative seconds and a bad day key are ignored")

        // A share over 100% is clamped: 10 W × 360 s = 1.0 Wh, all of it.
        var clamp = EnergyLedger()
        clamp.record(day: "2026-10-01", apps: [(id: "x", name: "X", appPath: nil, percentShare: 150)],
                     systemLoadWatts: 10, seconds: 360)
        near(clamp.days["2026-10-01"]?.apps["x"]?.wh, 1.0, "share clamped to 100%")

        // Prune: 35 days are kept, counting today. 10-01 minus 34 days is 08-28
        // (Aug 28–31 = 4 days, Sep = 30, Oct 1 = 1: 35), so 08-27 goes.
        var prune = EnergyLedger()
        for day in ["2026-08-27", "2026-08-28"] {
            prune.record(day: day, apps: [], systemLoadWatts: 10, seconds: 360)
        }
        equal(prune.days.count, 2, "both old days present before today's record")
        prune.record(day: "2026-10-01", apps: [], systemLoadWatts: 10, seconds: 360)
        check(prune.days["2026-08-27"] == nil, "day 36 pruned")
        check(prune.days["2026-08-28"] != nil, "day 35 kept")
        equal(prune.days.count, 2, "08-28 and 10-01 remain")

        // Day-key arithmetic across month and year ends.
        equal(EnergyLedger.key("2026-03-01", offsetBy: -1), "2026-02-28", "back across February")
        equal(EnergyLedger.key("2027-01-01", offsetBy: -1), "2026-12-31", "back across a year")
        equal(EnergyLedger.key(for: t0, calendar: utcCalendar), "2026-09-21", "key for a date")

        // Codable round trip.
        if let data = try? JSONEncoder().encode(ledger),
           let decoded = try? JSONDecoder().decode(EnergyLedger.self, from: data) {
            check(decoded == ledger, "ledger survives JSON round trip")
        } else {
            check(false, "ledger JSON round trip failed")
        }
    }

    static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: - Charger check

    static func pluggedInfo(volts: Double, amps: Double, load: Double?, input: Double?,
                            adapter: Int? = 30, percentage: Int = 50) -> BatteryInfo {
        var info = BatteryInfo()
        info.hasBattery = true
        info.isPluggedIn = true
        info.percentage = percentage
        info.adapterWatts = adapter
        info.systemLoad = load
        info.systemPowerIn = input
        info.applyLiveBattery(volts: volts, amps: amps)
        return info
    }

    static func chargerTests() {
        // Draining on AC: 12 V × -0.5 A = -6 W, load 36 W > 30 W in → weak adapter.
        let weak = pluggedInfo(volts: 12, amps: -0.5, load: 36, input: 30)
        check(ChargerCheck.adapterCannotKeepUp(weak), "draining 6 W on a 30 W supply with a 36 W load")
        equal(ChargerCheck.evaluate(weak, slowThreshold: 10), .weakAdapter, "panel says weak adapter")

        // No measured input: input is derived as load + battery = 36 - 6 = 30 W < 36 W.
        let derived = pluggedInfo(volts: 12, amps: -0.5, load: 36, input: nil)
        check(ChargerCheck.adapterCannotKeepUp(derived), "derived input when it isn't measured")
        // Only V × I is known (no load, no input, no rating): nothing to compare.
        let bare = pluggedInfo(volts: 12, amps: -0.5, load: nil, input: nil, adapter: nil)
        check(!ChargerCheck.adapterCannotKeepUp(bare), "no load figure: can't claim the charger is short")

        // 12 V × -0.02 A = -0.24 W: inside the 0.5 W tolerance, so not draining.
        let noise = pluggedInfo(volts: 12, amps: -0.02, load: 20, input: 20)
        check(!ChargerCheck.adapterCannotKeepUp(noise), "-0.24 W is noise")
        equal(ChargerCheck.evaluate(noise, slowThreshold: 10), .ok, "noise is OK")

        // Charging at 12 V × 0.4 A = 4.8 W at 50% with a 10 W threshold → slow.
        let slow = pluggedInfo(volts: 12, amps: 0.4, load: 10, input: 14.8)
        equal(ChargerCheck.evaluate(slow, slowThreshold: 10), .chargingSlowly, "4.8 W below 10 W at 50%")
        // The same 4.8 W at 95% is normal tapering.
        let taper = pluggedInfo(volts: 12, amps: 0.4, load: 10, input: 14.8, percentage: 95)
        equal(ChargerCheck.evaluate(taper, slowThreshold: 10), .ok, "taper near full is OK")
        // Charging at 12.55 V × 4.625 A = 58.04 W → OK.
        let fast = pluggedInfo(volts: 12.55, amps: 4.625, load: 28, input: 86.04, adapter: 87)
        equal(ChargerCheck.evaluate(fast, slowThreshold: 10), .ok, "58 W charging is OK")

        var unplugged = BatteryInfo()
        unplugged.hasBattery = true
        unplugged.isPluggedIn = false
        unplugged.applyLiveBattery(volts: 12, amps: -1.5)
        equal(ChargerCheck.evaluate(unplugged, slowThreshold: 10), nil, "no line when unplugged")
        check(!ChargerCheck.adapterCannotKeepUp(unplugged), "unplugged is never 'can't keep up'")
    }

    // MARK: - Hot battery

    static func hotGuardTests() {
        var guardState = HotBatteryGuard()
        equal(guardState.update(celsius: 39.9, threshold: 40), nil, "39.9 °C is below 40")
        equal(guardState.update(celsius: 40.0, threshold: 40), .becameHot, "40.0 °C starts an episode")
        equal(guardState.update(celsius: 42.0, threshold: 40), nil, "still hot: no repeat")
        equal(guardState.update(celsius: 37.5, threshold: 40), nil, "37.5 °C hasn't cooled 3 °C yet")
        equal(guardState.update(celsius: nil, threshold: 40), nil, "missing reading changes nothing")
        check(guardState.isHot, "still in the episode")
        equal(guardState.update(celsius: 37.0, threshold: 40), .cooledDown, "37.0 °C re-arms")
        equal(guardState.update(celsius: 40.5, threshold: 40), .becameHot, "a new episode alerts again")
    }

    // MARK: - --status JSON

    static func statusTests() {
        var info = pluggedInfo(volts: 12.55, amps: 4.625, load: 28, input: 86.04, adapter: 87, percentage: 68)
        info.temperatureCelsius = .nan
        info.cycleCount = 120
        info.designCapacity = 5000
        info.maxCapacity = 4500        // health 90.0%

        let text = BatteryStatus.json(for: info)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            check(false, "--status output isn't a JSON object: \(text)")
            return
        }
        let keys = ["percent", "state", "pluggedIn", "charging", "timeToEmptyMinutes", "timeToFullMinutes",
                    "healthPercent", "cycles", "temperatureC", "batteryWatts", "systemLoadWatts",
                    "inputWatts", "adapterWatts", "voltage"]
        equal(Set(object.keys), Set(keys), "every documented key, and only those")
        equal(object["percent"] as? Int, 68, "percent")
        equal(object["state"] as? String, "charging", "state")
        equal(object["pluggedIn"] as? Bool, true, "pluggedIn")
        equal(object["charging"] as? Bool, true, "charging")
        check(object["temperatureC"] is NSNull, "NaN temperature becomes null")
        check(object["timeToFullMinutes"] is NSNull, "unknown time becomes null")
        // 12.55 × 4.625 = 58.04375 → 58.04 at two decimals.
        near(object["batteryWatts"] as? Double, 58.04, "batteryWatts rounded", tolerance: 1e-9)
        near(object["inputWatts"] as? Double, 86.04, "inputWatts", tolerance: 1e-9)
        near(object["systemLoadWatts"] as? Double, 28, "systemLoadWatts", tolerance: 1e-9)
        near(object["voltage"] as? Double, 12.55, "voltage", tolerance: 1e-9)
        near(object["healthPercent"] as? Double, 90.0, "health", tolerance: 1e-9)
        equal(object["cycles"] as? Int, 120, "cycles")
        equal(object["adapterWatts"] as? Int, 87, "adapterWatts")

        // A completely unknown battery still produces valid JSON.
        let empty = BatteryStatus.json(for: BatteryInfo())
        check(empty != "{}" && empty.contains("\"state\" : \"noBattery\""), "empty info is valid JSON")
    }
}
