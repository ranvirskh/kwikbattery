//
//  BatteryPanelView.swift
//  KwikBattery
//
//  The dark dropdown shown from the menu bar.
//

import SwiftUI
import AppKit

struct BatteryPanelView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var devices: BluetoothDeviceMonitor
    @EnvironmentObject private var energy: AppEnergyMonitor
    @EnvironmentObject private var budget: AnimationBudget
    @EnvironmentObject private var updates: UpdateChecker
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = SettingsDefault.useFahrenheit
    @AppStorage(SettingsKey.lowPowerMode) private var lowPowerMode = SettingsDefault.lowPowerMode
    @AppStorage(SettingsKey.showLowPowerToggle) private var showLowPowerToggle = SettingsDefault.showLowPowerToggle

    @AppStorage("panel.powerExpanded") private var powerExpanded = true
    @AppStorage("panel.infoExpanded") private var infoExpanded = true
    @AppStorage("panel.devicesExpanded") private var devicesExpanded = true
    @AppStorage("panel.energyExpanded") private var energyExpanded = true

    @State private var refreshSpin = 0.0
    @State private var confirmingUpdate = false
    @State private var showingHealthHistory = false

    let openSettings: () -> Void

    private var info: BatteryInfo { monitor.info }
    private var levelColor: Color { info.levelColor }

    var body: some View {
        VStack(spacing: 6) {
            topBar

            updateBanner

            if info.hasBattery {
                heroCard
                    .appearEffect()

                PanelSection("Battery Information", icon: "info", tint: Color.blue,
                             isExpanded: $infoExpanded) {
                    if showingHealthHistory {
                        HealthHistoryView {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showingHealthHistory = false
                            }
                        }
                        .transition(.opacity)
                    } else {
                        batteryInformation
                            .transition(.opacity)
                    }
                }
                .appearEffect(delay: 0.05)

                PanelSection("Power & Electrical", icon: "bolt.fill",
                             tint: info.state == .charging ? Color.green : Color.orange,
                             isExpanded: $powerExpanded) {
                    PowerElectricalView(info: info)
                }
                .appearEffect(delay: 0.10)

                PanelSection("Top Energy Users", icon: "flame.fill", tint: Color.pink,
                             isExpanded: $energyExpanded) {
                    energyUsers
                        // Sampling runs `top`; don't pay for it when collapsed.
                        .onAppear { energy.setActive(true) }
                        .onDisappear { energy.setActive(false) }
                }
                .appearEffect(delay: 0.12)
            } else {
                noBatteryCard
            }

            PanelSection(devicesTitle, icon: "headphones", tint: Color.teal,
                         isExpanded: $devicesExpanded) {
                connectedDevices
            }
            .appearEffect(delay: 0.15)

            footer
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
        .background(background)
        .foregroundStyle(Color.white)
    }

    private var devicesTitle: String {
        let count = allDevices.count
        return count == 0 ? "Connected Devices" : "Connected Devices (\(count))"
    }

    /// Bluetooth / iPhone devices plus anything the Mac is powering over USB.
    private var allDevices: [BluetoothDevice] {
        var list = devices.devices
        for accessory in info.poweredAccessories {
            let baseName = accessory.name.components(separatedBy: " · ").first ?? accessory.name
            let lower = baseName.lowercased()
            let isAppleMobile = lower.contains("iphone") || lower.contains("ipad")
            if let index = list.firstIndex(where: { device in
                (isAppleMobile && device.kind == .phone && device.connection == "USB")
                    || device.name.lowercased() == lower
                    || device.model?.lowercased() == lower
            }) {
                list[index].chargingWatts = accessory.watts
            } else {
                var device = BluetoothDevice(id: "usb-\(accessory.id)",
                                             name: baseName,
                                             kind: BluetoothDeviceMonitor.kind(name: baseName, minorType: ""),
                                             mainLevel: nil,
                                             leftLevel: nil,
                                             rightLevel: nil,
                                             caseLevel: nil)
                device.connection = "USB"
                device.chargingWatts = accessory.watts
                list.append(device)
            }
        }
        return list
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 7) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text("KwikBattery")
                .font(PanelFont.title(13))
            Spacer()
            if showLowPowerToggle {
                Button {
                    lowPowerMode.toggle()
                    AnimationBudget.shared.setActive(true)   // apply immediately
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: lowPowerMode ? "leaf.fill" : "leaf")
                            .font(.system(size: 9, weight: .bold))
                        Text("Low Power")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(lowPowerMode ? Color.green : Color.white.opacity(0.45))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(lowPowerMode ? Color.green.opacity(0.18) : Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help(lowPowerMode ? "Low Power Mode on — slower updates, no animation" : "Low Power Mode off")
            }
            CircleIconButton(systemName: "arrow.clockwise", help: "Refresh", action: {
                withAnimation(.easeInOut(duration: 0.6)) { refreshSpin += 360 }
                monitor.refresh()
                devices.invalidateCache()
                devices.refresh()
            })
            .rotationEffect(.degrees(refreshSpin))
            CircleIconButton(systemName: "gearshape.fill", help: "Settings", action: openSettings)
        }
    }

    // MARK: - Update banner

    @ViewBuilder
    private var updateBanner: some View {
        switch updates.state {
        case .available(let version, _, _):
            banner(icon: "arrow.down.circle.fill", tint: Color.blue,
                   title: "Update available",
                   subtitle: "Version \(version) — you have \(updates.currentVersion)") {
                HStack(spacing: 6) {
                    Button("Later") { updates.skipCurrentOffer() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.5))
                    Button("Update") { confirmingUpdate = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.blue))
                }
            }
            .confirmationDialog("Update KwikBattery to \(version)?",
                                isPresented: $confirmingUpdate, titleVisibility: .visible) {
                Button("Download and Install") { updates.downloadAndInstall() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("KwikBattery will download version \(version) from GitHub, check it, replace this copy and relaunch.")
            }

        case .downloading:
            banner(icon: "arrow.down.circle", tint: Color.blue,
                   title: "Downloading update…",
                   subtitle: "This takes a few seconds") {
                ProgressView().controlSize(.small)
            }

        case .readyToRelaunch:
            banner(icon: "checkmark.circle.fill", tint: Color.green,
                   title: "Update installed",
                   subtitle: "Relaunch to start using it") {
                Button("Relaunch") { updates.relaunch() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green))
            }

        case .failed(let message):
            banner(icon: "exclamationmark.triangle.fill", tint: Color.orange,
                   title: "Update failed",
                   subtitle: message) {
                Button("Dismiss") { updates.dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
            }

        case .idle, .checking, .upToDate:
            EmptyView()
        }
    }

    private func banner<Trailing: View>(icon: String, tint: Color, title: String, subtitle: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .offset(y: -6)))
    }

    // MARK: - Hero card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(info.percentage)")
                        .font(PanelFont.hero(32))
                        .monospacedDigit()
                        .foregroundStyle(
                            LinearGradient(colors: [levelColor, levelColor.opacity(0.75)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .contentTransition(.numericText(value: Double(info.percentage)))
                        .shadow(color: levelColor.opacity(0.35), radius: 10)
                    Text("%")
                        .font(PanelFont.title(15))
                        .foregroundStyle(levelColor.opacity(0.8))
                }
                .animation(budget.stage.transition, value: info.percentage)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        BatteryGlyph(fraction: Double(info.percentage) / 100.0,
                                     tint: levelColor,
                                     isCharging: info.state == .charging)
                        Text(info.shortStatus)
                            .font(PanelFont.body(11.5))
                            .foregroundStyle(Color.white.opacity(0.9))
                    }
                    Text(info.adapterWatts.map { "\($0) W adapter" } ?? (info.isPluggedIn ? "Adapter connected" : "Unplugged"))
                        .font(PanelFont.caption(10))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .padding(.leading, 8)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeTitle)
                        .font(PanelFont.eyebrow(8))
                        .tracking(0.8)
                        .foregroundStyle(Color.white.opacity(0.45))
                    Text(timeValue)
                        .font(PanelFont.title(15))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }

            LevelBar(fraction: Double(info.percentage) / 100.0, tint: levelColor, height: 6, showTicks: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [levelColor.opacity(0.45), Color.white.opacity(0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Battery information (compact tile grid)

    private var batteryInformation: some View {
        let columns = [GridItem(.flexible(), spacing: 5),
                       GridItem(.flexible(), spacing: 5),
                       GridItem(.flexible(), spacing: 5)]
        return VStack(alignment: .leading, spacing: 5) {
            LazyVGrid(columns: columns, spacing: 5) {
                InfoTile(icon: healthGrade.icon, label: "Health",
                         value: info.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—",
                         tint: healthGrade.color) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(healthGrade.label)
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(healthGrade.color.opacity(0.85))
                        LevelBar(fraction: (info.healthPercent ?? 0) / 100.0, tint: healthGrade.color, height: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(healthGrade.color.opacity(0.7))
                        .padding(5)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showingHealthHistory = true
                    }
                }
                .help("Show battery health over time")

                InfoTile(icon: "arrow.triangle.2.circlepath", label: "Cycles",
                         value: info.cycleCount.map { "\($0)" } ?? "—",
                         tint: cycleColor) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("of 1000")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.5))
                        LevelBar(fraction: Double(info.cycleCount ?? 0) / 1000.0, tint: cycleColor, height: 3)
                    }
                }

                InfoTile(icon: "thermometer.medium", label: "Temp",
                         value: primaryTemperature,
                         tint: temperatureGrade.color,
                         caption: "\(secondaryTemperature) · \(temperatureGrade.label)")

                InfoTile(icon: "battery.100percent", label: "Capacity",
                         value: info.maxCapacity.map { "\($0)" } ?? "—",
                         tint: Color.white,
                         caption: info.designCapacity.map { "of \($0) mAh" } ?? "mAh")

                InfoTile(icon: "powerplug.fill", label: "Adapter",
                         value: info.adapterWatts.map { "\($0) W" } ?? (info.isPluggedIn ? "On" : "None"),
                         tint: info.isPluggedIn ? Color.green : Color.white.opacity(0.6),
                         caption: info.isPluggedIn ? (info.adapterName ?? "Connected") : "Unplugged")

                if serviceNeeded {
                    // Only surfaces when the battery actually needs attention.
                    InfoTile(icon: "exclamationmark.triangle.fill",
                             label: "Service",
                             value: info.condition == "Normal" || info.condition == "Unknown" ? "Recommended" : info.condition,
                             tint: Color.orange,
                             caption: "Check with Apple")
                } else {
                    InfoTile(icon: "drop.fill", label: "Charge",
                             value: info.currentCapacity.map { "\($0)" } ?? "\(info.percentage)%",
                             tint: levelColor,
                             caption: info.currentCapacity == nil ? " " : "mAh stored")
                }
            }

            Text(healthAdvice)
                .font(PanelFont.caption(10))
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
        }
    }

    private var cycleColor: Color {
        let cycles = info.cycleCount ?? 0
        if cycles >= 1000 { return Color.red }
        if cycles >= 800 { return Color.orange }
        return Color.purple
    }

    /// True when macOS flags the battery, or health has dropped below 80%.
    private var serviceNeeded: Bool {
        if info.condition != "Normal" && info.condition != "Unknown" { return true }
        if let h = info.healthPercent, h < 80 { return true }
        return false
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }

    // MARK: - Top energy users

    @ViewBuilder
    private var energyUsers: some View {
        if energy.apps.isEmpty {
            HStack(spacing: 6) {
                if !energy.hasLoaded {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Measuring app energy use…")
                } else {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(Color.green)
                    Text("No apps are using noticeable energy.")
                }
            }
            .font(PanelFont.caption(10))
            .foregroundStyle(Color.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 5) {
                ForEach(energy.apps) { app in
                    EnergyRow(app: app, icon: energy.icon(for: app))
                }
            }
            .animation(budget.stage.transition, value: energy.apps.map { $0.id })
        }
    }

    // MARK: - Connected devices

    @ViewBuilder
    private var connectedDevices: some View {
        let list = allDevices
        if list.isEmpty {
            HStack(spacing: 8) {
                if devices.isLoading && !devices.hasLoadedOnce {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Looking for devices…")
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Color.white.opacity(0.4))
                    Text("No connected devices with battery or power info.")
                }
            }
            .font(PanelFont.caption(10.5))
            .foregroundStyle(Color.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                // Only when no phone is listed at all — a remembered (stale)
                // iPhone still counts as listed.
                if devices.mobileLookup == .noDevicePaired,
                   !list.contains(where: { $0.kind == .phone }) {
                    iPhoneHint
                }
                ForEach(Array(list.enumerated()), id: \.element.id) { index, device in
                    if index > 0 {
                        divider.padding(.leading, 30)
                    }
                    DeviceRow(device: device)
                }
            }
        }
    }

    /// Shown only when the lookup tools ran successfully but listed no device.
    /// States the fact; the usual reasons are offered as a hint, not a cause.
    private var iPhoneHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text("No iPhone found")
                    .font(PanelFont.body(11))
                    .foregroundStyle(Color.white.opacity(0.7))
                Text("Unlock it on the same Wi-Fi, or check Local Network access")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button {
                SystemSettingsLink.openLocalNetworkSettings()
            } label: {
                Text("Settings")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
    }

    private var noBatteryCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.teal.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("No internal battery")
                    .font(PanelFont.title(13))
                Text("This Mac runs on wall power.")
                    .font(PanelFont.caption(10.5))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Footer & background

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                Circle()
                    .fill(levelColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: levelColor, radius: 3)
                Text("Live · updated \(info.lastUpdated.formatted(date: .omitted, time: .standard))")
            }
            .font(PanelFont.caption())
            .foregroundStyle(Color.white.opacity(0.4))
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.12), Color(white: 0.07)],
                           startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(levelColor.opacity(0.22))
                .frame(width: 300, height: 300)
                .blur(radius: 90)
                .offset(x: -130, y: -280)
            Circle()
                .fill(Color.teal.opacity(0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 90)
                .offset(x: 150, y: 260)
        }
        .animation(budget.stage.transition, value: info.percentage)
        .ignoresSafeArea()
    }

    // MARK: - Derived values

    private var timeTitle: String {
        info.state == .charging ? "UNTIL FULL" : "TIME LEFT"
    }

    private var timeValue: String {
        switch info.state {
        case .charging:
            return info.timeToFullMinutes.map { Format.duration(minutes: $0) } ?? "…"
        case .discharging:
            return info.timeToEmptyMinutes.map { Format.duration(minutes: $0) } ?? "…"
        case .full:        return "Full"
        case .notCharging: return "On AC"
        case .noBattery:   return "—"
        }
    }

    private var cycleText: String {
        guard let cycles = info.cycleCount else { return "—" }
        return "\(cycles.formatted())/1000"
    }

    private struct Grade {
        let label: String
        let icon: String
        let color: Color
        var detail: String = ""
    }

    private var healthGrade: Grade {
        guard let h = info.healthPercent else {
            return Grade(label: "Unknown", icon: "questionmark.circle.fill", color: Color.gray)
        }
        if h >= 90 { return Grade(label: "Excellent", icon: "checkmark.seal.fill", color: Color.green) }
        if h >= 80 { return Grade(label: "Good", icon: "checkmark.seal.fill", color: Color.green) }
        if h >= 70 { return Grade(label: "Fair", icon: "exclamationmark.triangle.fill", color: Color.yellow) }
        return Grade(label: "Poor", icon: "xmark.octagon.fill", color: Color.red)
    }

    private var healthAdvice: String {
        if info.condition != "Normal" && info.condition != "Unknown" {
            return "macOS reports: \(info.condition)."
        }
        switch healthGrade.label {
        case "Excellent", "Good": return "Your battery is in great shape."
        case "Fair":              return "Capacity is reduced. Keep an eye on it."
        case "Poor":              return "Consider servicing your battery with Apple."
        default:                  return "Health data isn't available on this Mac."
        }
    }

    private var temperatureGrade: Grade {
        guard let c = info.temperatureCelsius else {
            return Grade(label: "Unknown", icon: "questionmark.circle.fill", color: Color.gray, detail: "Not reported")
        }
        if c < 35 { return Grade(label: "Normal", icon: "checkmark.circle.fill", color: Color.green, detail: "Optimal performance") }
        if c < 40 { return Grade(label: "Warm", icon: "exclamationmark.circle.fill", color: Color.orange, detail: "Consider a lighter load") }
        return Grade(label: "Hot", icon: "flame.fill", color: Color.red, detail: "Let your Mac cool down")
    }

    private var primaryTemperature: String {
        guard let c = info.temperatureCelsius else { return "—" }
        return Format.temperature(celsius: c, fahrenheit: useFahrenheit)
    }

    private var secondaryTemperature: String {
        guard let c = info.temperatureCelsius else { return " " }
        return Format.temperature(celsius: c, fahrenheit: !useFahrenheit)
    }
}

// MARK: - Device row

private struct EnergyRow: View {
    @EnvironmentObject private var budget: AnimationBudget
    let app: AppEnergyUsage
    let icon: NSImage

    private var tint: Color {
        if app.percent >= 40 { return Color.red }
        if app.percent >= 20 { return Color.orange }
        return Color(red: 0.42, green: 0.78, blue: 1.0)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(PanelFont.body(11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text("\(Int(app.percent.rounded()))%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .animation(budget.stage.transition, value: Int(app.percent.rounded()))
                }
                LevelBar(fraction: app.percent / 100.0, tint: tint, height: 3)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: BluetoothDevice
    /// Ticks every 30s while the panel is open so ages stay honest.
    @State private var now = Date()

    private let water = Color(red: 0.38, green: 0.80, blue: 1.00)

    private var level: Int? { device.displayLevel }

    private var tint: Color {
        guard let level else { return water }
        if level < 10 { return Color.red }
        if level <= 20 { return Color.orange }
        if level >= 100 { return Color.green }
        return Color.white.opacity(0.9)
    }

    private var valueText: String {
        if let level { return "\(level)%" }
        if let watts = device.chargingWatts { return String(format: "%.1f W", watts) }
        return "—"
    }

    private var barFraction: Double {
        if let level { return Double(level) / 100.0 }
        if let watts = device.chargingWatts { return Swift.min(watts / 20.0, 1) }
        return 0
    }

    /// Readings older than a minute are treated as stale. `now` is driven by
    /// the panel's clock so this re-evaluates while the popover is open —
    /// otherwise a row created while fresh would look fresh indefinitely.
    private var staleness: String? {
        let age = now.timeIntervalSince(device.lastSeen)
        guard age > 60 else { return nil }
        let minutes = Int(age / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    }

    private var isStale: Bool { staleness != nil }

    private var detailText: String? {
        var parts: [String] = []
        if let stale = staleness { parts.append(stale) }
        if let model = device.model, model != device.name { parts.append(model) }
        if device.connection != "Bluetooth" { parts.append(device.connection) }
        if let watts = device.chargingWatts {
            parts.append(level == nil ? "powered by Mac" : String(format: "charging from Mac · %.1f W", watts))
        } else if device.isCharging {
            parts.append("charging")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(safeSystemName: device.symbolName, fallback: "dot.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle((level ?? 100) <= 20 ? tint : Color.white.opacity(0.75))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(device.name)
                        .font(PanelFont.body(11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if device.hasBudLevels {
                        HStack(spacing: 5) {
                            budLabel("L", device.leftLevel)
                            budLabel("R", device.rightLevel)
                            budLabel("C", device.caseLevel)
                        }
                    }
                    if device.chargingWatts != nil || device.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(water)
                    }
                    Spacer(minLength: 4)
                    Text(valueText)
                        .font(.system(size: 12, weight: .bold, design: level == nil ? Font.Design.monospaced : Font.Design.rounded))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                }
                LevelBar(fraction: barFraction, tint: tint, height: 3)
                if let detailText {
                    Text(detailText)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(isStale ? 0.45 : 1)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    @ViewBuilder
    private func budLabel(_ title: String, _ value: Int?) -> some View {
        if let value {
            HStack(spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.white.opacity(0.4))
                Text("\(value)")
                    .foregroundStyle(value < 10 ? Color.red : (value <= 20 ? Color.orange : Color.green))
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
    }
}

// MARK: - System Settings deep link

enum SystemSettingsLink {
    /// Privacy & Security › Local Network
    static func openLocalNetworkSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    static func openBatterySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.battery",
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
