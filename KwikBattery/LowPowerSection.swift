//
//  LowPowerSection.swift
//  KwikBattery
//
//  Settings › Low Power Mode: switch it on automatically when the charge gets
//  low or during set hours, and off again afterwards. macOS only lets an
//  administrator change Low Power Mode from outside System Settings, so this
//  uses the same charge-control helper (the schedule itself lives in LowPowerPolicy.swift).
//

import SwiftUI

struct LowPowerSection: View {
    @ObservedObject private var control = ChargeControl.shared

    private static let weekdayLetters = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        if control.reachable {
            Section {
                if control.supportsLowPower {
                    rows
                } else {
                    Text("Scheduled Low Power Mode needs the newer helper. Use Update Helper under Charge control above.")
                        .font(.callout)
                }
            } header: {
                Text("Low Power Mode")
            } footer: {
                Text("KwikBattery only switches off Low Power Mode if it was the one that switched it on. If you turn it off yourself during a window, it stays off until the next window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var rows: some View {
        Toggle("Switch Low Power Mode on automatically", isOn: $control.config.lowPower.enabled)

        Stepper(levelText, value: $control.config.lowPower.belowPercent, in: 0...80, step: 5)
            .disabled(!control.config.lowPower.enabled)

        VStack(alignment: .leading, spacing: 2) {
            Text("During set hours")
            Text("For example overnight, or while you're usually away from a charger.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach($control.config.lowPower.windows) { $window in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("", isOn: $window.enabled).labelsHidden()
                    DatePicker("", selection: Self.timeBinding($window.startMinute),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("to")
                    DatePicker("", selection: Self.timeBinding($window.endMinute),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer()
                    Button(role: .destructive) {
                        control.config.lowPower.windows.removeAll { $0.id == window.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let on = window.weekdays.contains(day)
                        Button(Self.weekdayLetters[day - 1]) {
                            if on { window.weekdays.removeAll { $0 == day } }
                            else { window.weekdays.append(day) }
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .gray)
                        .controlSize(.small)
                    }
                }
            }
            .opacity(window.enabled ? 1 : 0.5)
            .disabled(!control.config.lowPower.enabled)
        }
        Button {
            control.config.lowPower.windows.append(LowPowerWindow())
        } label: { Label("Add hours", systemImage: "plus") }
            .disabled(!control.config.lowPower.enabled || control.config.lowPower.windows.count >= 8)

        Toggle("Only while on battery", isOn: $control.config.lowPower.windowsOnBatteryOnly)
            .disabled(!control.config.lowPower.enabled)

        HStack {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Turn on now") { control.setLowPower(true) }
            Button("Turn off now") { control.setLowPower(false) }
        }
        .controlSize(.small)
    }

    private var levelText: String {
        let n = control.config.lowPower.belowPercent
        return n <= 0 ? "Not by charge level" : "On battery at or below \(n)%"
    }

    private var statusText: String {
        control.status?.lowPowerManaged == true
            ? "On now, switched on by KwikBattery's schedule."
            : "Use the buttons to switch it by hand; the schedule won't undo your choice."
    }

    /// A time-of-day (minutes after midnight) shown as a date for DatePicker.
    private static func timeBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                // Set the clock time directly: adding minutes to midnight is an
                // hour off on the two days a year the clocks change.
                let cal = Calendar.current
                let m = Swift.min(Swift.max(minute.wrappedValue, 0), 1439)
                return cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                minute.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }
}
