//
//  AppSettings.swift
//  KwikBattery
//
//  Central place for UserDefaults keys and their default values.
//  SwiftUI views use @AppStorage with these same keys; non-UI code
//  (NotificationManager, MenuBarController) reads them through `AppSettings`.
//

import Foundation

enum SettingsKey {
    static let showPercentage       = "showPercentage"
    static let useFahrenheit        = "useFahrenheit"

    static let notifyFullCharge     = "notifyFullCharge"
    static let notifyLowBattery     = "notifyLowBattery"
    static let lowBatteryThreshold  = "lowBatteryThreshold"      // percent (Double)
    static let notifyHealth         = "notifyHealth"
    static let healthThreshold      = "healthThreshold"          // percent (Double)
    static let notifySlowCharging   = "notifySlowCharging"
    static let slowChargingWatts    = "slowChargingWatts"        // watts (Double)

    static let lowPowerMode         = "lowPowerMode"
    static let showLowPowerToggle   = "showLowPowerToggle"       // in the dropdown
    static let lastHealthAlertDate  = "lastHealthAlertDate"      // internal
}

enum SettingsDefault {
    static let showPercentage       = true
    static let useFahrenheit        = false
    static let notifyFullCharge     = true
    static let notifyLowBattery     = true
    static let lowBatteryThreshold  = 20.0
    static let notifyHealth         = true
    static let healthThreshold      = 80.0
    static let notifySlowCharging   = true
    static let slowChargingWatts    = 10.0
    static let lowPowerMode         = false
    static let showLowPowerToggle   = true
}

enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    /// Registers fallback values so `bool(forKey:)` / `double(forKey:)` return
    /// sensible values before the user has ever opened Settings.
    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.showPercentage:      SettingsDefault.showPercentage,
            SettingsKey.useFahrenheit:       SettingsDefault.useFahrenheit,
            SettingsKey.notifyFullCharge:    SettingsDefault.notifyFullCharge,
            SettingsKey.notifyLowBattery:    SettingsDefault.notifyLowBattery,
            SettingsKey.lowBatteryThreshold: SettingsDefault.lowBatteryThreshold,
            SettingsKey.notifyHealth:        SettingsDefault.notifyHealth,
            SettingsKey.healthThreshold:     SettingsDefault.healthThreshold,
            SettingsKey.notifySlowCharging:  SettingsDefault.notifySlowCharging,
            SettingsKey.slowChargingWatts:   SettingsDefault.slowChargingWatts,
            SettingsKey.lowPowerMode:        SettingsDefault.lowPowerMode,
            SettingsKey.showLowPowerToggle:  SettingsDefault.showLowPowerToggle,
        ])
    }

    static var showPercentage: Bool      { defaults.bool(forKey: SettingsKey.showPercentage) }
    static var useFahrenheit: Bool       { defaults.bool(forKey: SettingsKey.useFahrenheit) }
    static var notifyFullCharge: Bool    { defaults.bool(forKey: SettingsKey.notifyFullCharge) }
    static var notifyLowBattery: Bool    { defaults.bool(forKey: SettingsKey.notifyLowBattery) }
    static var lowBatteryThreshold: Double { defaults.double(forKey: SettingsKey.lowBatteryThreshold) }
    static var notifyHealth: Bool        { defaults.bool(forKey: SettingsKey.notifyHealth) }
    static var healthThreshold: Double   { defaults.double(forKey: SettingsKey.healthThreshold) }
    static var notifySlowCharging: Bool  { defaults.bool(forKey: SettingsKey.notifySlowCharging) }
    static var slowChargingWatts: Double { defaults.double(forKey: SettingsKey.slowChargingWatts) }
    static var lowPowerMode: Bool        { defaults.bool(forKey: SettingsKey.lowPowerMode) }
    static var showLowPowerToggle: Bool  { defaults.bool(forKey: SettingsKey.showLowPowerToggle) }

    static func setLowPowerMode(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsKey.lowPowerMode)
    }
}
