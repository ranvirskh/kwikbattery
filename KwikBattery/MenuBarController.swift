//
//  MenuBarController.swift
//  KwikBattery
//
//  Owns the NSStatusItem (icon + percentage) and the NSPopover dropdown.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    /// Last values actually drawn, so identical updates don't redraw the icon.
    private var lastDrawn: (percentage: Int, state: ChargingState, showPercent: Bool)?

    init(monitor: BatteryMonitor, devices: BluetoothDeviceMonitor, openSettings: @escaping () -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // --- Popover -------------------------------------------------------
        let panel = BatteryPanelView(openSettings: { [weak self] in
            self?.popover.performClose(nil)
            openSettings()
        })
        .environmentObject(monitor)
        .environmentObject(devices)
        .environmentObject(AppEnergyMonitor.shared)
        .environmentObject(AnimationBudget.shared)
        .environmentObject(UpdateChecker.shared)
        .environmentObject(HealthHistory.shared)
        .environmentObject(EnergyHistory.shared)
        .environment(\.colorScheme, .dark)

        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = .preferredContentSize   // popover follows SwiftUI's size
        popover.contentViewController = hosting
        popover.behavior = .transient                   // closes when clicking elsewhere
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        // --- Status item button ----------------------------------------------
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            // Tabular digits, so " 2h 30m" doesn't jiggle the menu bar as it counts.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        // Redraw when battery info changes OR when a setting changes
        // (e.g. "show percentage" toggled in Settings).
        let settingsChanged = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in true }
            .prepend(true)

        // The smoothed run time is published separately, so the "Time left"
        // menu bar text also follows it.
        monitor.$info
            .combineLatest(settingsChanged, RunTimeStore.shared.$smoothedMinutes)
            .receive(on: RunLoop.main)
            .sink { [weak self] info, _, _ in
                self?.updateButton(with: info)
            }
            .store(in: &cancellables)
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            BatteryMonitor.shared.setLiveUpdates(true)   // 1-second updates while open
            BluetoothDeviceMonitor.shared.refreshIfStale()
            BluetoothDeviceMonitor.shared.setActive(true)
            // Sampling is switched off in popoverDidClose, but NSPopover reuses
            // its content view, so SwiftUI's .onAppear never fires again on a
            // reopen -- leaving the list frozen on its first reading. Restart it
            // here, honouring whether the user has the section collapsed.
            if UserDefaults.standard.object(forKey: "panel.energyExpanded") as? Bool ?? true {
                AppEnergyMonitor.shared.setActive(true)
            }
            AnimationBudget.shared.setActive(true)
            UpdateChecker.shared.checkIfDue()
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        BatteryMonitor.shared.setLiveUpdates(false)
        AppEnergyMonitor.shared.setActive(false)
        AnimationBudget.shared.setActive(false)
        // Device scanning is the app's most expensive recurring work, and the
        // list is only visible while the panel is open.
        BluetoothDeviceMonitor.shared.setActive(false)
    }

    // MARK: - Icon

    private func updateButton(with info: BatteryInfo) {
        guard let button = statusItem.button else { return }

        // Optional text next to the icon. Set BEFORE the icon cache check below:
        // the text changes (time left, watts) far more often than the icon does.
        let text = menuBarText(for: info)
        if button.title != text {
            button.title = text
            button.imagePosition = text.isEmpty ? .imageOnly : .imageLeft
        }

        // The icon only depends on these three things; re-rendering it for an
        // unchanged reading is pure waste (we refresh far more often than the
        // percentage actually moves).
        let signature = (info.percentage, info.state, AppSettings.showPercentage)
        if let lastDrawn, lastDrawn == signature {
            button.toolTip = tooltip(for: info)
            return
        }
        lastDrawn = signature

        if info.hasBattery {
            button.image = MenuBarIconRenderer.image(percentage: info.percentage,
                                                     state: info.state,
                                                     tint: iconTint(for: info),
                                                     showPercentage: AppSettings.showPercentage)
        } else {
            let image = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "No battery")
            image?.isTemplate = true
            button.image = image
        }
        button.toolTip = tooltip(for: info)
    }

    private func menuBarText(for info: BatteryInfo) -> String {
        let mode = AppSettings.menuBarText
        guard info.hasBattery, mode != .none else { return "" }
        let minutes = RunTimeStore.shared.menuBarMinutes(for: info, smooth: AppSettings.smoothTimeEstimate)
        return MenuBarText.text(mode: mode, percentage: info.percentage,
                                minutes: minutes, watts: info.batteryWatts)
    }

    private func iconTint(for info: BatteryInfo) -> NSColor {
        BatteryLevelColor.nsColor(percentage: info.percentage, isCharging: info.state == .charging)
    }

    private func tooltip(for info: BatteryInfo) -> String {
        guard info.hasBattery else { return "KwikBattery — no battery detected" }
        var parts = ["\(info.percentage)% · \(info.stateDescription)"]
        if let h = info.healthPercent { parts.append("Health \(Format.percent(h))") }
        if let c = info.cycleCount { parts.append("\(c) cycles") }
        return parts.joined(separator: "\n")
    }
}

