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
        }

        // Redraw when battery info changes OR when a setting changes
        // (e.g. "show percentage" toggled in Settings).
        let settingsChanged = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in true }
            .prepend(true)

        monitor.$info
            .combineLatest(settingsChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] info, _ in
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
            AppEnergyMonitor.shared.setActive(true)
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
    }

    // MARK: - Icon

    private func updateButton(with info: BatteryInfo) {
        guard let button = statusItem.button else { return }

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
        button.title = ""
        button.toolTip = tooltip(for: info)
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

