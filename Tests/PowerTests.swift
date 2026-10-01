//
//  PowerTests.swift
//  KwikBattery
//
//  Regression tests for the battery power calculation. Run with:
//      bash build.sh --test
//
//  No Xcode test target needed: BatteryInfo.swift only imports Foundation, so it
//  compiles together with this file into a small command-line program that exits
//  non-zero if any check fails.
//
//  Every number below is a real reading from a MacBook Pro (M-series, 87 W
//  adapter), not an invented one. The bug these guard against: the app showed
//  "0.7 W" charging power while the battery was taking ~58 W, because it trusted
//  the SMC's PPBR sensor (which reads ~0.7 W while charging) over voltage × current.
//

import Foundation

@main
struct PowerTests {
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
                     tolerance: Double = 0.01, line: Int = #line) {
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

    /// A Mac on its adapter and charging.
    static func charging(volts: Double, amps: Double,
                         load: Double? = nil, input: Double? = nil) -> BatteryInfo {
        var i = BatteryInfo()
        i.hasBattery = true
        i.isPluggedIn = true
        i.isCharging = true
        i.adapterWatts = 86
        i.voltage = volts
        i.amperage = amps
        i.systemLoad = load
        i.systemPowerIn = input
        return i
    }

    static func main() {
        // 1. The reported bug, exactly as it appeared on screen.
        //    12.55 V, 4625 mA, 28.0 W system load, 86 W adapter.
        print("screenshot case")
        let shot = charging(volts: 12.55, amps: 4.625, load: 28.0)
        near(shot.batteryWatts, 58.04, "battery charging power is V x I, not 0.7 W")
        check((shot.batteryWatts ?? 0) > 50, "must not collapse to a PPBR-style 0.7 W")
        check(shot.state == .charging, "state is charging")
        near(shot.systemLoadWatts, 28.0, "system load passes through")
        near(shot.inputWatts, 86.04, "input = load + battery = the adapter's 86 W", tolerance: 0.1)

        // 2. Three consecutive readings from a real capture (84% and charging).
        //    PPBR read 0.737 / 0.728 / 0.724 W at the same instants.
        print("captured charging readings")
        near(charging(volts: 12.686, amps: 3.393).batteryWatts, 43.04, "capture reading 1")
        near(charging(volts: 12.680, amps: 3.294).batteryWatts, 41.77, "capture reading 2")
        near(charging(volts: 12.684, amps: 3.273).batteryWatts, 41.51, "capture reading 3")

        // 3. V x I reproduces the registry's own BatteryData.BatteryPower (mW).
        print("agrees with the registry")
        near(charging(volts: 12.368, amps: 1.321).batteryWatts, 16.338, "registry sample 2", tolerance: 0.005)
        near(charging(volts: 12.589, amps: 2.425).batteryWatts, 30.528, "registry sample 3", tolerance: 0.005)

        // 4. Energy balance: adapter in = system load + battery power.
        //    Measured: PSTR 14.881 W, PDTR 58.353 W (they differ by SMC sample timing).
        print("energy balance")
        let balanced = charging(volts: 12.686, amps: 3.393, load: 14.881)
        near(balanced.inputWatts, 58.353, "derived input matches measured adapter power", tolerance: 1.0)
        let derivedLoad = charging(volts: 12.686, amps: 3.393, input: 58.353)
        near(derivedLoad.systemLoadWatts, 15.31, "load derived from input - battery")
        check(!derivedLoad.systemLoadIsMeasured, "derived load is flagged as not measured")
        check(shot.systemLoadIsMeasured, "sensor load is flagged as measured")

        // 5. Discharging, including while plugged in (the adapter hadn't ramped up).
        print("discharging")
        var onBattery = BatteryInfo()
        onBattery.hasBattery = true
        onBattery.voltage = 12.064
        onBattery.amperage = -1.109
        near(onBattery.batteryWatts, -13.379, "negative while discharging")
        check(onBattery.state == .discharging, "state is discharging")
        near(onBattery.systemLoadWatts, 13.379, "on battery, load is |battery power|")
        onBattery.systemLoad = 12.42
        near(onBattery.systemLoadWatts, 12.42, "a measured load wins over the derived one")

        // Undersized adapter: the battery is topping up the system, so
        // load = input - (negative battery power) = input + discharge.
        var undersized = charging(volts: 12.0, amps: -1.0, input: 30)
        undersized.isCharging = false
        near(undersized.systemLoadWatts, 42.0, "discharge adds to the adapter's input")

        // 6. Missing or bad data is never turned into a number.
        print("missing / invalid data")
        var noVolts = BatteryInfo()
        noVolts.amperage = 2.0
        check(noVolts.batteryWatts == nil, "no voltage -> nil")
        var noAmps = BatteryInfo()
        noAmps.voltage = 12.0
        check(noAmps.batteryWatts == nil, "no current -> nil")
        check(charging(volts: 12.0, amps: .nan).batteryWatts == nil, "NaN current -> nil")
        check(charging(volts: .infinity, amps: 1.0).batteryWatts == nil, "infinite voltage -> nil")

        // 7. Live SMC pairing: voltage and current are applied together or not at all.
        print("live SMC pairing")
        var live = charging(volts: 12.064, amps: 1.0)
        live.applyLiveBattery(volts: 12.686, amps: 3.393)
        near(live.voltage, 12.686, "pair applied: voltage")
        near(live.amperage, 3.393, "pair applied: current")
        near(live.batteryWatts, 43.04, "pair applied: power")

        var voltsOnly = charging(volts: 12.064, amps: 1.0)
        voltsOnly.applyLiveBattery(volts: 12.686, amps: nil)
        near(voltsOnly.voltage, 12.064, "voltage alone is not applied")
        near(voltsOnly.amperage, 1.0, "current untouched")

        var ampsOnly = charging(volts: 12.064, amps: 1.0)
        ampsOnly.applyLiveBattery(volts: nil, amps: 3.393)
        near(ampsOnly.voltage, 12.064, "current alone is not applied")
        near(ampsOnly.amperage, 1.0, "registry current kept")

        var badReading = charging(volts: 12.064, amps: 1.0)
        badReading.applyLiveBattery(volts: 12.5, amps: .nan)
        near(badReading.amperage, 1.0, "NaN reading ignored")

        // 8. Direction follows the live current, in both directions.
        print("charging direction")
        var stale = charging(volts: 12.0, amps: 0.5)       // stale flag says "charging"
        stale.applyLiveBattery(volts: 12.0, amps: -1.2)
        check(!stale.isCharging, "negative live current clears a stale charging flag")
        near(stale.batteryWatts, -14.4, "and the power is negative to match")
        check(stale.state == .notCharging, "plugged in, not charging")

        var started = charging(volts: 12.0, amps: -0.5)
        started.isCharging = false                          // flag lags behind
        started.applyLiveBattery(volts: 12.5, amps: 2.0)
        check(started.isCharging, "positive live current sets charging")

        var unplugged = BatteryInfo()
        unplugged.hasBattery = true
        unplugged.applyLiveBattery(volts: 12.0, amps: 0.2)
        check(!unplugged.isCharging, "never 'charging' when not plugged in")

        var noise = charging(volts: 12.0, amps: 0.0)
        noise.applyLiveBattery(volts: 12.0, amps: 0.02)
        check(noise.isCharging, "current inside the +/-50 mA dead band leaves the flag alone")

        print("\n\(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
