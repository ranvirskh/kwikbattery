//
//  ChargePolicyTests.swift
//  KwikBattery
//
//  Tests for the charge-control decision logic. Run with:
//      bash build.sh --test
//

import Foundation

@main
struct ChargePolicyTests {
    static var checks = 0
    static var failures = 0

    static func check(_ ok: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !ok() { failures += 1; print("  FAIL (line \(line)): \(message)") }
    }

    static var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-10-05 is a Monday.
    static func date(day: Int = 5, hour: Int, minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    static func engine(_ edit: (inout ChargePolicyConfig) -> Void = { _ in }) -> PolicyEngine {
        var c = ChargePolicyConfig()
        c.enabled = true
        edit(&c)
        return PolicyEngine(config: c, calendar: utc)
    }

    static func input(_ pct: Int, plugged: Bool = true, lid: Bool = false, at: Date = date(hour: 12),
                      temp: Double? = nil) -> PolicyInput {
        PolicyInput(percent: pct, pluggedIn: plugged, lidClosed: lid, now: at, temperatureC: temp)
    }

    static func main() {
        print("off / unplugged")
        var e = engine { $0.enabled = false }
        check(e.decide(input(95)).mode == .normal, "disabled control never intervenes")
        e = engine()
        check(e.decide(input(95, plugged: false)).mode == .normal, "on battery: nothing to control")

        print("limit and sailing range")
        e = engine { $0.limit = 80; $0.sailingRange = 3 }
        check(e.decide(input(60)).mode == .normal, "below limit charges")
        check(e.decide(input(79)).mode == .normal, "79% still charges")
        check(e.decide(input(80)).mode == .hold, "reaching the limit holds")
        check(e.decide(input(79)).mode == .hold, "inside the sailing range stays held (no flapping)")
        check(e.decide(input(78)).mode == .hold, "78% still held")
        check(e.decide(input(77)).mode == .normal, "77% = limit - 3, charging resumes")
        check(e.decide(input(78)).mode == .normal, "and keeps charging up to the limit")
        e = engine { $0.limit = 100 }
        check(e.decide(input(100)).mode == .normal, "limit 100 means no limit")

        print("automatic discharge")
        e = engine { $0.limit = 80; $0.autoDischarge = true; $0.dischargeTolerance = 2 }
        check(e.decide(input(82)).mode == .hold, "within tolerance: hold, don't discharge")
        check(e.decide(input(83)).mode == .discharge, "above limit + tolerance: discharge")
        check(e.decide(input(81)).mode == .discharge, "keeps discharging down to the limit")
        check(e.decide(input(80)).mode == .hold, "at the limit it stops and holds")
        check(e.decide(input(82)).mode == .hold, "does not restart inside the tolerance band")
        e = engine { $0.limit = 80; $0.autoDischarge = false }
        check(e.decide(input(95)).mode == .hold, "discharge off: only holds")

        print("discharge when the adapter is off (reported as unplugged by macOS)")
        e = engine { $0.limit = 80; $0.autoDischarge = true }
        _ = e.decide(input(90))
        check(e.decide(input(89, plugged: true)).mode == .discharge, "helper reports plugged-in while it holds the adapter off")
        check(e.decide(input(88, plugged: false)).mode == .normal, "a real unplug releases control")
        check(e.decide(input(88, plugged: true)).mode == .discharge, "replugging resumes discharge when still above")

        print("clamshell")
        e = engine { $0.limit = 80; $0.autoDischarge = true; $0.dischargeWithLidClosed = false }
        check(e.decide(input(90, lid: true)).mode == .hold, "lid closed, not allowed: hold instead of discharging")
        check(e.decide(input(90, lid: false)).mode == .discharge, "lid opened: discharge resumes")
        e = engine { $0.limit = 80; $0.autoDischarge = true; $0.dischargeWithLidClosed = true }
        check(e.decide(input(90, lid: true)).mode == .discharge, "lid closed, allowed: discharges")

        print("top-up now")
        e = engine { $0.limit = 80 }
        _ = e.decide(input(80))
        e.startTopUp(target: 100, now: date(hour: 12))
        var d = e.decide(input(80))
        check(d.mode == .normal && d.topUpActive, "manual top-up charges past the limit")
        check(d.effectiveLimit == 100, "target shown as the effective limit")
        d = e.decide(input(99))
        check(d.mode == .normal && d.topUpActive, "still topping up at 99%")
        d = e.decide(input(100))
        check(!d.topUpActive && d.mode == .hold, "target reached: top-up ends, limit holds again")
        e.startTopUp(target: 100, now: date(hour: 12), duration: 3600)
        d = e.decide(input(90, at: date(hour: 14)))
        check(!d.topUpActive, "expired manual top-up is dropped")
        e.startTopUp(target: 100, now: date(hour: 12))
        e.cancelTopUp(now: date(hour: 12))
        check(!e.decide(input(85)).topUpActive, "cancel stops it")
        e = engine { $0.limit = 80; $0.autoDischarge = true }
        e.startTopUp(target: 100, now: date(hour: 12))
        check(e.decide(input(90)).mode == .normal, "top-up beats automatic discharge")

        print("top-up schedules")
        var sched = TopUpSchedule()
        sched.weekdays = [2]            // Monday
        sched.minuteOfDay = 7 * 60
        sched.targetPercent = 100
        e = engine { $0.limit = 80; $0.schedules = [sched]; $0.topUpWindowMinutes = 360 }
        check(!e.decide(input(80, at: date(hour: 6, minute: 59))).topUpActive, "before the start time: not active")
        check(e.decide(input(80, at: date(hour: 7))).topUpActive, "at the start time: active")
        check(e.decide(input(90, at: date(hour: 9))).mode == .normal, "charges during the window")
        check(!e.decide(input(80, at: date(hour: 13, minute: 1))).topUpActive, "after the window: gives up")
        check(!e.decide(input(80, at: date(day: 6, hour: 7))).topUpActive, "Tuesday: weekday not selected")
        check(e.decide(input(80, at: date(day: 12, hour: 7))).topUpActive, "next Monday: active again")

        e = engine { $0.limit = 80; $0.schedules = [sched] }
        _ = e.decide(input(95, at: date(hour: 8)))
        check(e.decide(input(100, at: date(hour: 8, minute: 30))).mode == .hold, "reached target: back to holding")
        check(!e.decide(input(85, at: date(hour: 9))).topUpActive, "a completed top-up doesn't restart inside its window")

        e = engine { $0.limit = 80; $0.schedules = [sched] }
        check(!e.decide(input(80, plugged: false, at: date(hour: 8))).topUpActive, "unplugged at start time: waits")
        check(e.decide(input(80, plugged: true, at: date(hour: 9))).topUpActive, "plugged in later inside the window: starts")

        var late = sched
        late.weekdays = [1, 2, 3, 4, 5, 6, 7]
        late.minuteOfDay = 23 * 60 + 30
        e = engine { $0.limit = 80; $0.schedules = [late]; $0.topUpWindowMinutes = 240 }
        check(e.decide(input(80, at: date(day: 6, hour: 1))).topUpActive, "a window that crosses midnight still counts")

        var off = sched
        off.enabled = false
        e = engine { $0.limit = 80; $0.schedules = [off] }
        check(!e.decide(input(80, at: date(hour: 8))).topUpActive, "disabled schedule is ignored")

        var two = sched
        two.targetPercent = 90
        e = engine { $0.limit = 70; $0.schedules = [two, sched] }
        check(e.decide(input(75, at: date(hour: 8))).effectiveLimit == 100, "overlapping schedules: the higher target wins")

        print("sanitizing and coding")
        var wild = ChargePolicyConfig()
        wild.limit = 5; wild.sailingRange = 99; wild.dischargeTolerance = 0; wild.topUpWindowMinutes = 1
        var bad = TopUpSchedule()
        bad.targetPercent = 10; bad.minuteOfDay = 99999; bad.weekdays = [0, 9, 3, 3]
        wild.schedules = [bad]
        let clean = wild.sanitized
        check(clean.limit == 50, "limit can't go below 50%")
        check(clean.sailingRange == 10 && clean.dischargeTolerance == 1 && clean.topUpWindowMinutes == 30, "ranges clamped")
        check(clean.schedules[0].targetPercent == 50 && clean.schedules[0].minuteOfDay == 1439, "schedule clamped")
        check(clean.schedules[0].weekdays == [3], "invalid and duplicate weekdays removed")

        let json = "{\"enabled\":true,\"limit\":75}".data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(ChargePolicyConfig.self, from: json)
        check(decoded?.enabled == true && decoded?.limit == 75 && decoded?.sailingRange == 3,
              "old or partial settings files decode with defaults")
        var cfg = ChargePolicyConfig()
        cfg.schedules = [sched]
        let round = try? JSONDecoder().decode(ChargePolicyConfig.self, from: JSONEncoder().encode(cfg))
        check(round == cfg, "settings survive a JSON round trip")

        print("pause charging when hot")
        e = engine { $0.limit = 80; $0.hotLimitCelsius = 40 }
        check(e.decide(input(60, temp: 39.9)).mode == .normal, "39.9 °C: charges")
        d = e.decide(input(60, temp: 40))
        check(d.mode == .hold && d.hotPaused, "40 °C: charging paused")
        check(d.reason.contains("hot") && d.reason.contains("37"), "reason says hot and when it resumes (\(d.reason))")
        check(e.decide(input(60, temp: 38)).mode == .hold, "38 °C: still paused (needs 3 °C of cooling)")
        check(e.decide(input(60)).mode == .hold, "no reading: stays paused")
        d = e.decide(input(60, temp: 37))
        check(d.mode == .normal && !d.hotPaused, "37 °C: charging resumes")
        check(e.decide(input(60, temp: 39)).mode == .normal, "39 °C after cooling: still charging (re-arms at 40)")

        e = engine { $0.enabled = false }
        d = e.decide(input(60, temp: 41))
        check(d.mode == .hold && d.hotPaused, "heat pause works even with Manage charging off")
        e = engine { $0.enabled = false; $0.pauseWhenHot = false }
        check(e.decide(input(60, temp: 45)).mode == .normal, "pause-when-hot switched off: charges")
        e = engine()
        d = e.decide(input(60, plugged: false, temp: 45))
        check(d.mode == .normal && !d.hotPaused, "on battery: nothing to pause")

        e = engine()
        check(e.decide(input(29, temp: 42)).mode == .normal, "below 30% a hot battery still charges")
        check(e.decide(input(31, temp: 42)).mode == .normal, "and keeps charging past 30% until it cools (no flapping)")
        check(e.decide(input(32, temp: 36)).mode == .normal, "cooled: normal")
        check(e.decide(input(33, temp: 41)).mode == .hold, "hot again above 30%: paused again")

        e = engine { $0.limit = 80; $0.autoDischarge = true }
        d = e.decide(input(90, temp: 42))
        check(d.mode == .discharge && d.hotPaused, "discharging already doesn't charge: keeps discharging")
        e = engine { $0.limit = 80 }
        e.startTopUp(target: 100, now: date(hour: 12))
        check(e.decide(input(85, temp: 42)).mode == .hold, "heat beats a top-up")

        e = engine { $0.hotLimitCelsius = 35 }
        check(e.decide(input(60, temp: 35)).mode == .hold, "custom 35 °C limit")
        var hotCfg = ChargePolicyConfig()
        hotCfg.hotLimitCelsius = 60
        check(hotCfg.sanitized.hotLimitCelsius == 50, "hot limit clamped to 50 °C")
        hotCfg.hotLimitCelsius = 10
        check(hotCfg.sanitized.hotLimitCelsius == 30, "hot limit clamped to 30 °C")
        hotCfg.hotLimitCelsius = .nan
        check(hotCfg.sanitized.hotLimitCelsius == 40, "NaN hot limit falls back to 40 °C")
        check(decoded?.pauseWhenHot == true && decoded?.hotLimitCelsius == 40,
              "older settings files get pause-when-hot on at 40 °C")

        print("\(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
