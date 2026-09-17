//
//  SettingsView.swift
//  KwikBattery
//
//  Settings window content. Every option is free and unlocked.
//

import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var notifications: NotificationManager

    // General
    @AppStorage(SettingsKey.showPercentage) private var showPercentage = SettingsDefault.showPercentage
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = SettingsDefault.useFahrenheit

    // Notifications
    @AppStorage(SettingsKey.notifyFullCharge) private var notifyFullCharge = SettingsDefault.notifyFullCharge
    @AppStorage(SettingsKey.notifyLowBattery) private var notifyLowBattery = SettingsDefault.notifyLowBattery
    @AppStorage(SettingsKey.lowBatteryThreshold) private var lowBatteryThreshold = SettingsDefault.lowBatteryThreshold
    @AppStorage(SettingsKey.notifyHealth) private var notifyHealth = SettingsDefault.notifyHealth
    @AppStorage(SettingsKey.healthThreshold) private var healthThreshold = SettingsDefault.healthThreshold
    @AppStorage(SettingsKey.notifySlowCharging) private var notifySlowCharging = SettingsDefault.notifySlowCharging
    @AppStorage(SettingsKey.slowChargingWatts) private var slowChargingWatts = SettingsDefault.slowChargingWatts

    // Launch at login (SMAppService, macOS 13+)
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            generalSection
            notificationsSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 560, idealHeight: 680)
        .onAppear {
            refreshLoginItemStatus()
            notifications.refreshAuthorizationStatus()
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if loginItemStatus == .requiresApproval {
                HStack {
                    Text("Approve KwikBattery in Login Items to finish enabling this.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
            if let loginItemError {
                Text(loginItemError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle("Show percentage inside the menu bar battery", isOn: $showPercentage)

            Picker("Temperature unit", selection: $useFahrenheit) {
                Text("Celsius (°C)").tag(false)
                Text("Fahrenheit (°F)").tag(true)
            }
        }
    }

    private var notificationsSection: some View {
        Section {
            HStack {
                Text("Permission")
                Spacer()
                Text(authorizationText)
                    .foregroundStyle(notifications.authorizationStatus == .denied ? Color.red : Color.secondary)
                if notifications.authorizationStatus == .denied {
                    Button("Open Settings") { openNotificationSettings() }
                        .controlSize(.small)
                } else if notifications.authorizationStatus == .notDetermined {
                    Button("Allow…") { notifications.requestAuthorization() }
                        .controlSize(.small)
                }
            }

            Toggle("Remind me to unplug at 100%", isOn: $notifyFullCharge)

            Toggle("Low battery alert (on battery power)", isOn: $notifyLowBattery)
            ThresholdSlider(title: "Alert at or below",
                            value: $lowBatteryThreshold, range: 5...50, step: 1, unit: "%")
                .disabled(!notifyLowBattery)

            Toggle("Battery health alert", isOn: $notifyHealth)
            ThresholdSlider(title: "Alert when health is below",
                            value: $healthThreshold, range: 50...100, step: 1, unit: "%")
                .disabled(!notifyHealth)
                .onChange(of: healthThreshold) {
                    // Let a new threshold trigger an alert right away if it applies.
                    UserDefaults.standard.removeObject(forKey: SettingsKey.lastHealthAlertDate)
                }

            Toggle("Slow charging alert (bad cable / adapter)", isOn: $notifySlowCharging)
            ThresholdSlider(title: "Alert when charging below",
                            value: $slowChargingWatts, range: 3...60, step: 1, unit: " W")
                .disabled(!notifySlowCharging)

            HStack {
                Spacer()
                Button("Send Test Notification") { notifications.sendTestNotification() }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Each alert fires once, then re-arms when the condition clears. Health alerts repeat at most once a week. Slow-charging alerts need 3 minutes of low charging power below 90%.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("KwikBattery")
                Spacer()
                Text("Version \(appVersion)")
                    .foregroundStyle(.secondary)
            }
            Text("Every feature is free and unlocked. No accounts, no tracking, no network access.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Quit KwikBattery") { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var authorizationText: String {
        switch notifications.authorizationStatus {
        case .authorized, .provisional: return "Allowed"
        case .denied:                               return "Denied"
        case .notDetermined:                        return "Not requested"
        @unknown default:                           return "Unknown"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't update login item: \(error.localizedDescription)"
        }
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
        launchAtLogin = (loginItemStatus == .enabled || loginItemStatus == .requiresApproval)
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A labeled slider showing its current value.
private struct ThresholdSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value))\(unit)")
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}
