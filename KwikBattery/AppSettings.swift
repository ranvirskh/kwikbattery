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
    static let shareUsageCount      = "shareUsageCount"          // anonymous daily count

    // 1.8
    static let trackEnergyHistory   = "trackEnergyHistory"
    static let notifyHot            = "notifyHot"
    static let hotThreshold         = "hotThreshold"             // °C (Double)
    static let notifyWeakCharger    = "notifyWeakCharger"
    static let notifyChargingPaused = "notifyChargingPaused"
    static let smoothTimeEstimate   = "smoothTimeEstimate"
    static let menuBarText          = "menuBarText"              // MenuBarTextMode raw value

    // 1.9
    static let notifySleepDrain     = "notifySleepDrain"
    static let sleepDrainPerHour    = "sleepDrainPerHour"        // %/hour (Double)
    static let notifyDeviceLow      = "notifyDeviceLow"
    static let deviceLowThreshold   = "deviceLowThreshold"       // percent (Double)
    static let openPanelHotKey      = "openPanelHotKey"          // HotKeyChoice raw value

    // 1.11
    static let notifyAppEnergy      = "notifyAppEnergy"
    static let appEnergyWatts       = "appEnergyWatts"           // watts (Double)
    static let ignoredEnergyApps    = "ignoredEnergyApps"        // app ids, one per line
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
    static let shareUsageCount      = true
    static let trackEnergyHistory   = true
    static let notifyHot            = true
    static let hotThreshold         = 40.0
    static let notifyWeakCharger    = true
    static let notifyChargingPaused = false
    static let smoothTimeEstimate   = false
    static let menuBarText          = MenuBarTextMode.none.rawValue
    static let notifySleepDrain     = true
    static let sleepDrainPerHour    = 1.5
    static let notifyDeviceLow      = true
    static let deviceLowThreshold   = 20.0
    static let openPanelHotKey      = HotKeyChoice.off.rawValue
    static let notifyAppEnergy      = true
    static let appEnergyWatts       = 8.0
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
            SettingsKey.shareUsageCount:     SettingsDefault.shareUsageCount,
            SettingsKey.trackEnergyHistory:  SettingsDefault.trackEnergyHistory,
            SettingsKey.notifyHot:           SettingsDefault.notifyHot,
            SettingsKey.hotThreshold:        SettingsDefault.hotThreshold,
            SettingsKey.notifyWeakCharger:   SettingsDefault.notifyWeakCharger,
            SettingsKey.notifyChargingPaused: SettingsDefault.notifyChargingPaused,
            SettingsKey.smoothTimeEstimate:  SettingsDefault.smoothTimeEstimate,
            SettingsKey.menuBarText:         SettingsDefault.menuBarText,
            SettingsKey.notifySleepDrain:    SettingsDefault.notifySleepDrain,
            SettingsKey.sleepDrainPerHour:   SettingsDefault.sleepDrainPerHour,
            SettingsKey.notifyDeviceLow:     SettingsDefault.notifyDeviceLow,
            SettingsKey.deviceLowThreshold:  SettingsDefault.deviceLowThreshold,
            SettingsKey.openPanelHotKey:     SettingsDefault.openPanelHotKey,
            SettingsKey.notifyAppEnergy:     SettingsDefault.notifyAppEnergy,
            SettingsKey.appEnergyWatts:      SettingsDefault.appEnergyWatts,
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
    static var shareUsageCount: Bool     { defaults.bool(forKey: SettingsKey.shareUsageCount) }
    static var trackEnergyHistory: Bool  { defaults.bool(forKey: SettingsKey.trackEnergyHistory) }
    static var notifyHot: Bool           { defaults.bool(forKey: SettingsKey.notifyHot) }
    static var hotThreshold: Double      { defaults.double(forKey: SettingsKey.hotThreshold) }
    static var notifyWeakCharger: Bool   { defaults.bool(forKey: SettingsKey.notifyWeakCharger) }
    static var notifyChargingPaused: Bool { defaults.bool(forKey: SettingsKey.notifyChargingPaused) }
    static var smoothTimeEstimate: Bool  { defaults.bool(forKey: SettingsKey.smoothTimeEstimate) }
    static var notifySleepDrain: Bool    { defaults.bool(forKey: SettingsKey.notifySleepDrain) }
    static var sleepDrainPerHour: Double { defaults.double(forKey: SettingsKey.sleepDrainPerHour) }
    static var notifyDeviceLow: Bool     { defaults.bool(forKey: SettingsKey.notifyDeviceLow) }
    static var deviceLowThreshold: Double { defaults.double(forKey: SettingsKey.deviceLowThreshold) }
    static var notifyAppEnergy: Bool     { defaults.bool(forKey: SettingsKey.notifyAppEnergy) }
    static var appEnergyWatts: Double    { defaults.double(forKey: SettingsKey.appEnergyWatts) }
    /// App ids the user chose not to be warned about, one per line (a single
    /// string, so Settings can watch it with @AppStorage).
    static var ignoredEnergyApps: [String] {
        (defaults.string(forKey: SettingsKey.ignoredEnergyApps) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
    static func setIgnoredEnergyApps(_ ids: [String]) {
        defaults.set(ids.joined(separator: "\n"), forKey: SettingsKey.ignoredEnergyApps)
    }
    static var openPanelHotKey: HotKeyChoice {
        HotKeyChoice(rawValue: defaults.string(forKey: SettingsKey.openPanelHotKey) ?? "") ?? .off
    }
    static var menuBarText: MenuBarTextMode {
        MenuBarTextMode(rawValue: defaults.string(forKey: SettingsKey.menuBarText) ?? "") ?? .none
    }

    static func setShareUsageCount(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsKey.shareUsageCount)
    }

    static func setLowPowerMode(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsKey.lowPowerMode)
    }
}
