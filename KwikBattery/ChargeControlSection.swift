//
//  ChargeControlSection.swift
//  KwikBattery
//
//  The "Charge control" block of the Settings window: charge limit, automatic
//  discharge, clamshell behaviour and top-up scheduling. All of it is sent to
//  the privileged helper (see ChargeControl.swift).
//

import SwiftUI

struct ChargeControlSection: View {
    @ObservedObject private var control = ChargeControl.shared

    var body: some View {
        Section {
            if !control.reachable {
                helperMissing
            } else {
                statusRows
                heatRows
                limitRows
                dischargeRows
                topUpRows
                scheduleRows
                helperFooter
            }
        } header: {
            Text("Charge control")
        } footer: {
            Text("Holding the battery below 100% reduces wear. KwikBattery switches charging back to normal whenever it quits, the Mac sleeps, or something doesn't respond as expected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: control.config) { control.pushConfig() }
    }

    // MARK: Not installed

    private var helperMissing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Charge control needs a small helper that runs with administrator rights, because only an administrator can tell the battery to stop charging or discharge.")
                .font(.callout)
            HStack {
                Button(control.installing ? "Installing…" : "Install Helper…") { control.installHelper() }
                    .disabled(control.installing)
                Text("You'll be asked for your password once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = control.installMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: Status

    @ViewBuilder private var statusRows: some View {
        if let s = control.status {
            Toggle("Manage charging", isOn: $control.config.enabled)
            HStack {
                Text("Now")
                Spacer()
                Text(s.reason).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            if let error = s.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if s.chargeKey == nil && s.adapterKey == nil {
                Text("This Mac doesn't expose a charge-control switch, so charge control isn't available here. Run  kwikbatteryd --keys CH  and open an issue with the output.")
                    .font(.caption).foregroundStyle(.orange)
            } else if s.chargeKey == nil {
                Text("This Mac has no \"stop charging\" switch, so the limit is held by letting it run on the battery from the limit down to \(control.config.sailingRange)% below, then charging again. Wear is still reduced; the battery just cycles in that small band.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if s.adapterKey == nil {
                Text("This Mac can hold its charge but has no adapter switch, so automatic discharge isn't available.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Heat

    @ViewBuilder private var heatRows: some View {
        Toggle("Pause charging when the battery is hot", isOn: $control.config.pauseWhenHot)
        Text(heatCaption)
            .font(.caption)
            .foregroundStyle(control.status?.hotPaused == true ? Color.orange : Color.secondary)
    }

    private var heatCaption: String {
        let limit = control.config.hotLimitCelsius
        let threshold = AppSettings.useFahrenheit
            ? String(format: "%.0f °F", limit * 9 / 5 + 32)
            : String(format: "%.0f °C", limit)
        if control.status?.hotPaused == true {
            let now = control.status?.temperatureC.map {
                Format.temperature(celsius: $0, fahrenheit: AppSettings.useFahrenheit)
            } ?? "hot"
            return "Paused now: the battery is \(now). Charging resumes once it has cooled 3 °C."
        }
        return "At \(threshold) (the Hot battery alert's temperature, set under Notifications). Works even with Manage charging off. Charging resumes after the battery cools 3 °C, and never stays paused below 30%."
    }

    // MARK: Limit

    @ViewBuilder private var limitRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Charge limit").foregroundStyle(.secondary)
                Spacer()
                Text(control.config.limit >= 100 ? "100% (off)" : "\(control.config.limit)%").monospacedDigit()
            }
            Slider(value: Binding(get: { Double(control.config.limit) },
                                  set: { control.config.limit = Int($0) }),
                   in: 50...100, step: 1)
                .labelsHidden()
        }
        .disabled(!control.config.enabled)

        Stepper("Resume charging \(control.config.sailingRange)% below the limit",
                value: $control.config.sailingRange, in: 1...10)
            .disabled(!control.config.enabled)
    }

    // MARK: Discharge

    @ViewBuilder private var dischargeRows: some View {
        Toggle("Discharge automatically down to the limit", isOn: $control.config.autoDischarge)
            .disabled(!control.config.enabled || control.status?.adapterKey == nil)
        if control.config.autoDischarge {
            Stepper("Start when more than \(control.config.dischargeTolerance)% above the limit",
                    value: $control.config.dischargeTolerance, in: 1...10)
                .disabled(!control.config.enabled)
            Toggle("Keep discharging with the lid closed", isOn: $control.config.dischargeWithLidClosed)
                .disabled(!control.config.enabled)
            Text("For clamshell use with an external display. Without a display the Mac sleeps with the lid closed; KwikBattery then switches the adapter back on first, so it never sleeps on a draining battery.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Top-up

    @ViewBuilder private var topUpRows: some View {
        HStack {
            if control.status?.topUpActive == true {
                Text("Topping up to \(control.status?.effectiveLimit ?? 100)%")
                Spacer()
                Button("Cancel top-up") { control.cancelTopUp() }
            } else {
                Text("Top up now")
                Spacer()
                Button("Charge to 100%") { control.topUpNow(target: 100) }
                    .disabled(!control.config.enabled)
            }
        }
    }

    private static let weekdayLetters = ["S", "M", "T", "W", "T", "F", "S"]

    @ViewBuilder private var scheduleRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Scheduled top-ups")
            Text("Charge past the limit at a set time, e.g. before you leave in the morning. When it reaches its target it goes back to the limit.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach($control.config.schedules) { $schedule in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("", isOn: $schedule.enabled).labelsHidden()
                    DatePicker("", selection: timeBinding($schedule), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("to")
                    Stepper("\(schedule.targetPercent)%", value: $schedule.targetPercent, in: 50...100, step: 5)
                    Spacer()
                    Button(role: .destructive) {
                        control.config.schedules.removeAll { $0.id == schedule.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let on = schedule.weekdays.contains(day)
                        Button(Self.weekdayLetters[day - 1]) {
                            if on { schedule.weekdays.removeAll { $0 == day } }
                            else { schedule.weekdays.append(day) }
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .gray)
                        .controlSize(.small)
                    }
                }
            }
            .opacity(schedule.enabled ? 1 : 0.5)
            .disabled(!control.config.enabled)
        }
        Button {
            control.config.schedules.append(TopUpSchedule())
        } label: { Label("Add top-up", systemImage: "plus") }
            .disabled(!control.config.enabled)
    }

    private func timeBinding(_ schedule: Binding<TopUpSchedule>) -> Binding<Date> {
        Binding(
            get: {
                let cal = Calendar.current
                let day = cal.startOfDay(for: Date())
                return cal.date(byAdding: .minute, value: schedule.wrappedValue.minuteOfDay, to: day) ?? day
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                schedule.wrappedValue.minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    // MARK: Footer

    private var helperFooter: some View {
        HStack {
            Button("Restore normal charging") { control.restoreNormalCharging() }
            Spacer()
            Button("Remove Helper…") { control.uninstallHelper() }
        }
        .controlSize(.small)
    }
}
