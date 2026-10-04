//
//  SettingsExtras.swift
//  KwikBattery
//
//  The 1.8 settings rows. Kept out of SettingsView.swift so that file only
//  gains one line per section (it is also edited on the charge-control branch).
//

import SwiftUI

/// Rows added to Settings › General.
struct GeneralExtrasSettings: View {
    @AppStorage(SettingsKey.menuBarText) private var menuBarText = SettingsDefault.menuBarText
    @AppStorage(SettingsKey.smoothTimeEstimate) private var smoothTimeEstimate = SettingsDefault.smoothTimeEstimate
    @AppStorage(SettingsKey.trackEnergyHistory) private var trackEnergyHistory = SettingsDefault.trackEnergyHistory

    @State private var confirmingReset = false

    var body: some View {
        Picker("Menu bar text", selection: $menuBarText) {
            ForEach(MenuBarTextMode.allCases) { mode in
                Text(mode.title).tag(mode.rawValue)
            }
        }
        Text("Shown next to the menu bar icon. Time left counts down on battery and up to full while charging; Watts is the battery's power (− discharging, + charging).")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Smoother time-remaining estimate", isOn: $smoothTimeEstimate)
        Text("Works out time left from how fast the percentage has fallen over the last 45 minutes, instead of the momentary draw macOS uses. Needs about 10 minutes on battery; until then macOS's figure is shown.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Track app energy over time", isOn: $trackEnergyHistory)
        HStack(alignment: .top) {
            Text("Every 5 minutes on battery (15 in Low Power Mode), records which apps are using energy. Kept only on this Mac; nothing is sent anywhere. Tap the chart icon on Top Energy Users to see it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset energy history…") { confirmingReset = true }
                .controlSize(.small)
                .confirmationDialog("Delete all recorded app energy history?",
                                    isPresented: $confirmingReset, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) { EnergyHistory.shared.reset() }
                    Button("Cancel", role: .cancel) {}
                }
        }
    }
}

/// Rows added to Settings › Notifications.
struct NotificationExtrasSettings: View {
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = SettingsDefault.useFahrenheit
    @AppStorage(SettingsKey.notifyHot) private var notifyHot = SettingsDefault.notifyHot
    @AppStorage(SettingsKey.hotThreshold) private var hotThreshold = SettingsDefault.hotThreshold
    @AppStorage(SettingsKey.notifyWeakCharger) private var notifyWeakCharger = SettingsDefault.notifyWeakCharger
    @AppStorage(SettingsKey.notifyChargingPaused) private var notifyChargingPaused = SettingsDefault.notifyChargingPaused

    var body: some View {
        Toggle("Hot battery alert", isOn: $notifyHot)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Alert at or above")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(thresholdText)
                    .monospacedDigit()
            }
            Slider(value: $hotThreshold, in: 30...50, step: 1)
                .labelsHidden()
        }
        .disabled(!notifyHot)
        Text("Alerts only: it does not pause charging yet. Re-arms once the battery cools 3 °C below the threshold.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Charger can't keep up alert", isOn: $notifyWeakCharger)
        Text("When the Mac is plugged in but the battery has been draining for 3 minutes. Also shows a Charger check line under Power & Electrical.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Charging paused notice", isOn: $notifyChargingPaused)
        Text("When the Mac is plugged in but macOS has paused charging for 2 minutes, with the reason.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var thresholdText: String {
        if useFahrenheit {
            return String(format: "%.0f °F", hotThreshold * 9.0 / 5.0 + 32.0)
        }
        return String(format: "%.0f °C", hotThreshold)
    }
}
