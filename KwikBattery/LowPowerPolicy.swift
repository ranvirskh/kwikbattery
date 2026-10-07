//
//  LowPowerPolicy.swift
//  KwikBattery
//
//  Scheduled Low Power Mode: switch it on when the charge falls to a level or
//  during set hours, and back off afterwards. Turning Low Power Mode on and off
//  needs administrator rights (`pmset`), so the decision is made here and the
//  privileged helper (kwikbatteryd) carries it out.
//
//  Pure logic (Foundation only). Compiled into the app, the helper and the tests.
//
//  Rules
//    - It acts only when the *wish* changes (a wish starts or ends), never every
//      tick, so switching Low Power Mode off yourself in the middle of a window
//      sticks until the next one.
//    - It turns off only what it turned on. If Low Power Mode was already on when
//      a window began, it is left alone afterwards.
//

import Foundation

struct LowPowerWindow: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled = true
    /// `Calendar` weekday numbers the window *starts* on: 1 = Sunday … 7 = Saturday.
    var weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    var startMinute = 22 * 60
    /// Minutes after midnight. Earlier than `startMinute` means it ends the next morning.
    var endMinute = 7 * 60

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinute != endMinute else { return false }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let today = calendar.component(.weekday, from: date)
        let yesterday = today == 1 ? 7 : today - 1
        if startMinute < endMinute {
            return weekdays.contains(today) && minute >= startMinute && minute < endMinute
        }
        // Crosses midnight: the late part belongs to today's start, the early part to yesterday's.
        return (weekdays.contains(today) && minute >= startMinute)
            || (weekdays.contains(yesterday) && minute < endMinute)
    }
}

struct LowPowerConfig: Codable, Equatable {
    var enabled = false
    /// Switch on at or below this charge while on battery (0 = never by charge level).
    var belowPercent = 20
    var windows: [LowPowerWindow] = []
    /// A window applies only while unplugged (the usual wish: save battery, not power).
    var windowsOnBatteryOnly = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LowPowerConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        belowPercent = try c.decodeIfPresent(Int.self, forKey: .belowPercent) ?? d.belowPercent
        windows = try c.decodeIfPresent([LowPowerWindow].self, forKey: .windows) ?? d.windows
        windowsOnBatteryOnly = try c.decodeIfPresent(Bool.self, forKey: .windowsOnBatteryOnly) ?? d.windowsOnBatteryOnly
    }

    var sanitized: LowPowerConfig {
        var c = self
        c.belowPercent = belowPercent <= 0 ? 0 : Swift.min(Swift.max(belowPercent, 5), 80)
        c.windows = windows.prefix(8).map { w in
            var w = w
            w.startMinute = Swift.min(Swift.max(w.startMinute, 0), 1439)
            w.endMinute = Swift.min(Swift.max(w.endMinute, 0), 1439)
            w.weekdays = Array(Set(w.weekdays.filter { (1...7).contains($0) })).sorted()
            return w
        }
        return c
    }
}

struct LowPowerEngine {
    enum Action: Equatable {
        case none, enable, disable
    }

    /// What must survive a helper restart: whether we own the current Low Power Mode.
    struct State: Codable, Equatable {
        var wasWanted = false
        var weTurnedOn = false
    }

    var config = LowPowerConfig()
    var calendar = Calendar.current
    private(set) var state = State()

    init(config: LowPowerConfig = LowPowerConfig(), calendar: Calendar = .current, state: State = State()) {
        self.config = config
        self.calendar = calendar
        self.state = state
    }

    /// True when the settings want Low Power Mode on right now.
    func wanted(percent: Int, pluggedIn: Bool, now: Date) -> Bool {
        let c = config.sanitized
        guard c.enabled else { return false }
        if c.belowPercent > 0, !pluggedIn, percent <= c.belowPercent { return true }
        if !(c.windowsOnBatteryOnly && pluggedIn),
           c.windows.contains(where: { $0.contains(now, calendar: calendar) }) { return true }
        return false
    }

    /// `systemState` is read only when the wish changes (it may start a process),
    /// and returns nil when Low Power Mode's current state can't be read.
    mutating func decide(percent: Int, pluggedIn: Bool, now: Date,
                         systemState: () -> Bool?) -> Action {
        let want = wanted(percent: percent, pluggedIn: pluggedIn, now: now)
        if want == state.wasWanted { return .none }
        state.wasWanted = want

        if want {
            // Already on (the user's own choice)? Leave it, and don't claim it.
            if systemState() == true {
                state.weTurnedOn = false
                return .none
            }
            state.weTurnedOn = true
            return .enable
        }
        guard state.weTurnedOn else { return .none }
        state.weTurnedOn = false
        // If the user already switched it off, there's nothing to do.
        return systemState() == false ? .none : .disable
    }

    /// Reports whether the helper's `pmset` call for `action` worked. A failed
    /// switch is undone in the bookkeeping, so the same action is tried again
    /// instead of being forgotten (which would leave Low Power Mode stuck).
    mutating func confirm(_ action: Action, ok: Bool) {
        guard !ok else { return }
        switch action {
        case .enable:
            state.weTurnedOn = false
            state.wasWanted = false
        case .disable:
            state.weTurnedOn = true
            state.wasWanted = true
        case .none:
            break
        }
    }

    /// The user (or the helper stopping) asked for Low Power Mode to be given
    /// back: returns whether it should be switched off.
    mutating func release() -> Bool {
        let owned = state.weTurnedOn
        state = State()
        return owned
    }

    /// The user set Low Power Mode by hand: ownership no longer applies.
    mutating func userChangedSystemState() {
        state.weTurnedOn = false
    }

    // MARK: - pmset

    /// `pmset -g custom`: the lowpowermode value under "Battery Power:" and
    /// "AC Power:". macOS's "Only on Battery" is battery 1 / AC 0, which a
    /// blanket `-a 0` would flatten, so the helper puts these back afterwards.
    static func parsePmsetCustom(_ output: String) -> (battery: Bool?, ac: Bool?) {
        var section = ""
        var battery: Bool?
        var ac: Bool?
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Battery Power") { section = "battery"; continue }
            if trimmed.hasPrefix("AC Power") { section = "ac"; continue }
            if trimmed.hasPrefix("UPS Power") { section = "ups"; continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let on = flag(parts[0], parts[1]) else { continue }
            if section == "battery" { battery = on }
            else if section == "ac" { ac = on }
        }
        return (battery, ac)
    }

    /// One `pmset` line as Low Power Mode on/off. Older macOS prints
    /// `lowpowermode 0|1`; newer macOS prints `powermode 0|1|2` (1 = Low Power,
    /// 2 = High Power). nil for any other line.
    private static func flag(_ key: Substring, _ value: Substring) -> Bool? {
        guard let v = Int(value) else { return nil }
        if key == "lowpowermode" { return v != 0 }
        if key == "powermode" { return v == 1 }
        return nil
    }

    /// Reads Low Power Mode from `pmset -g` output (`lowpowermode`, else
    /// `powermode`). nil if neither line is there.
    static func parsePmset(_ output: String) -> Bool? {
        var fallback: Bool?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let on = flag(parts[0], parts[1]) else { continue }
            if parts[0] == "lowpowermode" { return on }
            fallback = on
        }
        return fallback
    }
}
