//
//  ChargePolicy.swift
//  KwikBattery
//
//  The brain of charge control: given the battery state and the user's settings,
//  decide whether the Mac should charge normally, hold its charge, or discharge.
//
//  This file is pure logic (Foundation only, no IOKit, no UI). It is compiled into
//  both the app and the privileged helper (kwikbatteryd), and it is covered by
//  Tests/ChargePolicyTests.swift (`bash build.sh --test`).
//
//  Modes
//    normal     charge freely                      (adapter on, charging allowed)
//    hold       stay where we are, don't charge    (adapter on, charging inhibited)
//    discharge  run on the battery while plugged in (adapter off, charging inhibited)
//
//  Priority, highest first
//    1. An active top-up (manual "Top up now" or a schedule) charges to its target.
//    2. Automatic discharge brings the battery down to the limit.
//    3. The charge limit holds the battery at the limit and resumes charging once
//       it has fallen `sailingRange` points below it.
//

import Foundation

enum ChargeMode: String, Codable {
    case normal, hold, discharge
}

/// Charge to `targetPercent` starting at `minuteOfDay` on the given weekdays.
struct TopUpSchedule: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled = true
    /// `Calendar` weekday numbers: 1 = Sunday … 7 = Saturday.
    var weekdays: [Int] = [2, 3, 4, 5, 6]
    var minuteOfDay = 7 * 60
    var targetPercent = 100
}

struct ChargePolicyConfig: Codable, Equatable {
    var enabled = false
    /// Hold the battery at this percentage (100 = no limit).
    var limit = 80
    /// Resume charging once the battery is this many points below the limit.
    var sailingRange = 3
    /// Discharge automatically when the battery is above the limit.
    var autoDischarge = false
    /// Start discharging only when more than this many points above the limit.
    var dischargeTolerance = 2
    /// Allow discharging with the lid closed (only useful with an external display;
    /// without one the Mac sleeps and the helper switches the adapter back on).
    var dischargeWithLidClosed = false
    var schedules: [TopUpSchedule] = []
    /// A scheduled top-up that hasn't reached its target gives up after this long.
    var topUpWindowMinutes = 360

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChargePolicyConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? d.limit
        sailingRange = try c.decodeIfPresent(Int.self, forKey: .sailingRange) ?? d.sailingRange
        autoDischarge = try c.decodeIfPresent(Bool.self, forKey: .autoDischarge) ?? d.autoDischarge
        dischargeTolerance = try c.decodeIfPresent(Int.self, forKey: .dischargeTolerance) ?? d.dischargeTolerance
        dischargeWithLidClosed = try c.decodeIfPresent(Bool.self, forKey: .dischargeWithLidClosed) ?? d.dischargeWithLidClosed
        schedules = try c.decodeIfPresent([TopUpSchedule].self, forKey: .schedules) ?? d.schedules
        topUpWindowMinutes = try c.decodeIfPresent(Int.self, forKey: .topUpWindowMinutes) ?? d.topUpWindowMinutes
    }

    /// The same settings with every value forced into a safe range.
    var sanitized: ChargePolicyConfig {
        var c = self
        c.limit = min(max(limit, 50), 100)
        c.sailingRange = min(max(sailingRange, 1), 10)
        c.dischargeTolerance = min(max(dischargeTolerance, 1), 10)
        c.topUpWindowMinutes = min(max(topUpWindowMinutes, 30), 1440)
        c.schedules = schedules.map { s in
            var s = s
            s.targetPercent = min(max(s.targetPercent, 50), 100)
            s.minuteOfDay = min(max(s.minuteOfDay, 0), 1439)
            s.weekdays = Array(Set(s.weekdays.filter { (1...7).contains($0) })).sorted()
            return s
        }
        return c
    }
}

struct PolicyInput {
    var percent: Int
    /// On an adapter (the helper also reports true while *it* has the adapter switched off).
    var pluggedIn: Bool
    var lidClosed: Bool
    var now: Date
}

struct PolicyDecision: Equatable {
    var mode: ChargeMode
    var reason: String
    var effectiveLimit: Int
    var topUpActive: Bool
}

struct PolicyEngine {
    var config = ChargePolicyConfig()
    var calendar = Calendar.current

    private(set) var holding = false
    private(set) var discharging = false
    private(set) var manualTopUp: (target: Int, expires: Date)?
    private var completed: [UUID: Date] = [:]

    init(config: ChargePolicyConfig = ChargePolicyConfig(), calendar: Calendar = .current) {
        self.config = config
        self.calendar = calendar
    }

    mutating func startTopUp(target: Int, now: Date, duration: TimeInterval = 12 * 3600) {
        manualTopUp = (min(max(target, 50), 100), now.addingTimeInterval(duration))
    }

    mutating func cancelTopUp(now: Date = Date()) {
        manualTopUp = nil
        // Also dismiss any scheduled top-up that is running right now.
        for s in config.sanitized.schedules {
            if let start = latestStart(of: s, now: now, windowMinutes: config.sanitized.topUpWindowMinutes) {
                completed[s.id] = start
            }
        }
    }

    var topUpIsActive: Bool { manualTopUp != nil || activeScheduledTarget != nil }
    private var activeScheduledTarget: Int?

    mutating func decide(_ input: PolicyInput) -> PolicyDecision {
        let c = config.sanitized
        let pct = min(max(input.percent, 0), 100)
        activeScheduledTarget = nil

        guard c.enabled else {
            holding = false; discharging = false; manualTopUp = nil
            return PolicyDecision(mode: .normal, reason: "Charge control is off", effectiveLimit: 100, topUpActive: false)
        }
        guard input.pluggedIn else {
            holding = false; discharging = false
            return PolicyDecision(mode: .normal, reason: "On battery", effectiveLimit: c.limit, topUpActive: false)
        }

        // 1. Top-ups.
        var target: Int?
        if let manual = manualTopUp {
            if input.now >= manual.expires || pct >= manual.target {
                manualTopUp = nil
            } else {
                target = manual.target
            }
        }
        for s in c.schedules where s.enabled {
            guard let start = latestStart(of: s, now: input.now, windowMinutes: c.topUpWindowMinutes),
                  completed[s.id] != start else { continue }
            if pct >= s.targetPercent {
                completed[s.id] = start
            } else {
                target = max(target ?? 0, s.targetPercent)
                activeScheduledTarget = max(activeScheduledTarget ?? 0, s.targetPercent)
            }
        }
        if let target {
            holding = false; discharging = false
            return PolicyDecision(mode: .normal, reason: "Topping up to \(target)%",
                                  effectiveLimit: target, topUpActive: true)
        }

        let limit = c.limit
        if limit >= 100 {
            holding = false; discharging = false
            return PolicyDecision(mode: .normal, reason: "No charge limit", effectiveLimit: 100, topUpActive: false)
        }

        // 2. Automatic discharge.
        if c.autoDischarge {
            if pct > limit + c.dischargeTolerance {
                discharging = true
            } else if pct <= limit {
                discharging = false
            }
            if discharging {
                if input.lidClosed && !c.dischargeWithLidClosed {
                    return PolicyDecision(mode: .hold,
                                          reason: "Holding at \(pct)% (lid closed, discharge paused)",
                                          effectiveLimit: limit, topUpActive: false)
                }
                return PolicyDecision(mode: .discharge,
                                      reason: "Discharging \(pct)% → \(limit)%",
                                      effectiveLimit: limit, topUpActive: false)
            }
        } else {
            discharging = false
        }

        // 3. Charge limit with a sailing range.
        if pct >= limit {
            holding = true
        } else if pct <= limit - c.sailingRange {
            holding = false
        }
        if holding {
            return PolicyDecision(mode: .hold, reason: "Holding at \(pct)% (limit \(limit)%)",
                                  effectiveLimit: limit, topUpActive: false)
        }
        return PolicyDecision(mode: .normal, reason: "Charging to \(limit)%",
                              effectiveLimit: limit, topUpActive: false)
    }

    /// The most recent start time of `schedule` that is still inside its window.
    func latestStart(of schedule: TopUpSchedule, now: Date, windowMinutes: Int) -> Date? {
        let today = calendar.startOfDay(for: now)
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  schedule.weekdays.contains(calendar.component(.weekday, from: day)),
                  let start = calendar.date(byAdding: .minute, value: schedule.minuteOfDay, to: day)
            else { continue }
            let age = now.timeIntervalSince(start)
            if age >= 0 && age < Double(windowMinutes) * 60 { return start }
        }
        return nil
    }
}

// MARK: - App ⇄ helper messages

struct HelperRequest: Codable {
    /// "status", "setPolicy", "topUpNow", "cancelTopUp", "restore"
    var cmd: String
    var policy: ChargePolicyConfig?
    var target: Int?
}

struct HelperStatus: Codable {
    var version = 1
    var percent: Int?
    var pluggedIn = false
    var lidClosed = false
    var mode: ChargeMode = .normal
    var reason = ""
    var effectiveLimit = 100
    var topUpActive = false
    /// The SMC keys this Mac was found to support (nil = not supported).
    var chargeKey: String?
    var adapterKey: String?
    /// True when this Mac has no "inhibit charging" key and the limit is held by cycling the adapter.
    var emulatedHold: Bool?
    var error: String?
    var policy = ChargePolicyConfig()
}

enum HelperPaths {
    static let socket = "/var/run/kwikbattery.sock"
    static let policyDirectory = "/Library/Application Support/KwikBattery"
    static let policyFile = "/Library/Application Support/KwikBattery/policy.json"
    static let label = "com.kwikbattery.helper"
    static let binary = "/Library/PrivilegedHelperTools/kwikbatteryd"
    static let plist = "/Library/LaunchDaemons/com.kwikbattery.helper.plist"
}
