//
//  SettingsExtras.swift
//  KwikBattery
//
//  The 1.8 settings rows. Kept out of SettingsView.swift so that file only
//  gains one line per section (it is also edited on the charge-control branch).
//

import SwiftUI
import AppKit

/// Rows added to Settings › General.
struct GeneralExtrasSettings: View {
    @AppStorage(SettingsKey.menuBarText) private var menuBarText = SettingsDefault.menuBarText
    @AppStorage(SettingsKey.smoothTimeEstimate) private var smoothTimeEstimate = SettingsDefault.smoothTimeEstimate
    @AppStorage(SettingsKey.trackEnergyHistory) private var trackEnergyHistory = SettingsDefault.trackEnergyHistory
    @AppStorage(SettingsKey.openPanelHotKey) private var openPanelHotKey = SettingsDefault.openPanelHotKey

    @ObservedObject private var hotKey = GlobalHotKey.shared
    @State private var confirmingReset = false
    @State private var exportMessage: String?

    var body: some View {
        Picker("Keyboard shortcut to open KwikBattery", selection: $openPanelHotKey) {
            ForEach(HotKeyChoice.allCases) { choice in
                Text(choice.title).tag(choice.rawValue)
            }
        }
        Text(hotKey.failedChoice == nil
             ? "Works from any app. Needs no extra permissions. If another app already uses the combination, it won't register."
             : "Another app already uses that combination, so it didn't register. Pick a different one.")
            .font(.caption)
            .foregroundStyle(hotKey.failedChoice == nil ? Color.secondary : Color.orange)

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

        HStack(alignment: .top) {
            Text(exportMessage ?? "Saves health, app energy and charge history as CSV files you can open in Numbers or Excel.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Export history as CSV…") { exportMessage = HistoryExport.run() }
                .controlSize(.small)
        }
    }
}

/// Writes the three histories as CSV files into a folder the user picks.
@MainActor
enum HistoryExport {
    /// Returns a one-line result for Settings, or nil if the user cancelled.
    static func run() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the KwikBattery CSV files."
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }

        let stamp = EnergyLedger.key(for: Date())
        let health = CSV.make(
            header: ["date", "health_percent", "cycle_count", "max_capacity_mah", "design_capacity_mah"],
            rows: HealthHistory.shared.snapshots.map { snapshot in
                [snapshot.day,
                 CSV.number(snapshot.healthPercent, places: 1),
                 "\(snapshot.cycleCount)",
                 snapshot.maxCapacity.map { "\($0)" } ?? "",
                 snapshot.designCapacity.map { "\($0)" } ?? ""]
            })
        let files: [(String, String)] = [
            ("KwikBattery-health-\(stamp).csv", health),
            ("KwikBattery-app-energy-\(stamp).csv", CSV.energy(EnergyHistory.shared.ledger)),
            ("KwikBattery-charge-\(stamp).csv", CSV.charge(ChargeHistory.shared.log)),
        ]
        do {
            for (name, text) in files {
                try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
        return "Exported 3 files to \(folder.lastPathComponent)."
    }
}

/// Rows added to Settings › Notifications.
struct NotificationExtrasSettings: View {
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = SettingsDefault.useFahrenheit
    @AppStorage(SettingsKey.notifyHot) private var notifyHot = SettingsDefault.notifyHot
    @AppStorage(SettingsKey.hotThreshold) private var hotThreshold = SettingsDefault.hotThreshold
    @AppStorage(SettingsKey.notifyWeakCharger) private var notifyWeakCharger = SettingsDefault.notifyWeakCharger
    @AppStorage(SettingsKey.notifyChargingPaused) private var notifyChargingPaused = SettingsDefault.notifyChargingPaused
    @ObservedObject private var chargeControl = ChargeControl.shared
    @AppStorage(SettingsKey.notifySleepDrain) private var notifySleepDrain = SettingsDefault.notifySleepDrain
    @AppStorage(SettingsKey.sleepDrainPerHour) private var sleepDrainPerHour = SettingsDefault.sleepDrainPerHour
    @AppStorage(SettingsKey.notifyDeviceLow) private var notifyDeviceLow = SettingsDefault.notifyDeviceLow
    @AppStorage(SettingsKey.deviceLowThreshold) private var deviceLowThreshold = SettingsDefault.deviceLowThreshold
    @AppStorage(SettingsKey.notifyAppEnergy) private var notifyAppEnergy = SettingsDefault.notifyAppEnergy
    @AppStorage(SettingsKey.appEnergyWatts) private var appEnergyWatts = SettingsDefault.appEnergyWatts
    @AppStorage(SettingsKey.ignoredEnergyApps) private var ignoredRaw = ""

    private var ignoredCount: Int { ignoredRaw.split(separator: "\n").filter { !$0.isEmpty }.count }

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
        Text(chargeControl.pausesWhenHot
             ? "Charging is also paused at this temperature (Charge control). Re-arms once the battery cools 3 °C below the threshold."
             : "Re-arms once the battery cools 3 °C below the threshold. To also pause charging at this temperature, install the charge-control helper (Charge control, above).")
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

        Toggle("Sleep drain alert", isOn: $notifySleepDrain)
        labeledSlider(title: "Alert when sleep drain is above",
                      value: $sleepDrainPerHour, range: 0.5...5, step: 0.5,
                      text: String(format: "%.1f%%/h", sleepDrainPerHour))
            .disabled(!notifySleepDrain)
        Text("After waking from at least 30 minutes asleep on battery, if 3% or more was lost. The last sleep is always shown under the charge timeline (tap the big percentage).")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Low battery alerts for AirPods, mice and keyboards", isOn: $notifyDeviceLow)
        labeledSlider(title: "Alert at or below",
                      value: $deviceLowThreshold, range: 5...50, step: 5,
                      text: "\(Int(deviceLowThreshold))%")
            .disabled(!notifyDeviceLow)

        Toggle("Alert when an app keeps draining the battery", isOn: $notifyAppEnergy)
        labeledSlider(title: "Alert when an app uses more than",
                      value: $appEnergyWatts, range: 3...25, step: 1,
                      text: "\(Int(appEnergyWatts)) W")
            .disabled(!notifyAppEnergy)
        Text("On battery only, after an app has stayed above that for about 10 minutes. Uses the samples from Track app energy over time, so that must be on. The alert has buttons to quit the app or stop warning about it.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if ignoredCount > 0 {
            HStack {
                Text("\(ignoredCount) app\(ignoredCount == 1 ? "" : "s") ignored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Warn about them again") { ignoredRaw = "" }
                .controlSize(.small)
            }
        }
    }

    private func labeledSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                               step: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(text)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    private var thresholdText: String {
        if useFahrenheit {
            return String(format: "%.0f °F", hotThreshold * 9.0 / 5.0 + 32.0)
        }
        return String(format: "%.0f °C", hotThreshold)
    }
}
