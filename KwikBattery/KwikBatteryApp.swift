//
//  KwikBatteryApp.swift
//  KwikBattery
//
//  App entry point. KwikBattery is a menu-bar-only app: LSUIElement = YES in
//  Info.plist hides the Dock icon, and everything is driven by AppDelegate.
//

import SwiftUI
import AppKit
import Combine

@main
struct KwikBatteryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `KwikBattery --smc-diag` prints live SMC readings and exits (used by build.sh).
        if CommandLine.arguments.contains("--idevice-diag") {
            print(BluetoothDeviceMonitor.diagnosticReport())
            exit(0)
        }
        // `KwikBattery --status` prints a JSON snapshot and exits (for scripts / Shortcuts).
        if CommandLine.arguments.contains("--status") {
            print(BatteryStatus.json(for: BatteryMonitor.readSnapshot()))
            exit(0)
        }
        if CommandLine.arguments.contains("--smc-diag") {
            for round in 1...3 {
                print("--- SMC reading \(round) ---")
                print(SMCReader.shared.diagnosticReport())
                Thread.sleep(forTimeInterval: 1)
            }
            exit(0)
        }
    }

    var body: some Scene {
        // SwiftUI requires at least one scene. The real settings window is
        // managed by SettingsWindowController (opened from the popover), but
        // wiring the same view here keeps ⌘, working if the app is ever active.
        Settings {
            SettingsView()
                .environmentObject(NotificationManager.shared)
                .environmentObject(AnimationBudget.shared)
                .environmentObject(HealthHistory.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private let settingsWindowController = SettingsWindowController()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside LSUIElement: never show a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        AppSettings.registerDefaults()

        let monitor = BatteryMonitor.shared
        let devices = BluetoothDeviceMonitor.shared
        let notifications = NotificationManager.shared

        notifications.setUp()

        menuBarController = MenuBarController(monitor: monitor, devices: devices) { [weak self] in
            self?.settingsWindowController.show()
        }

        // Every fresh reading: evaluate alerts.
        monitor.$info
            .dropFirst()
            .sink { info in
                notifications.evaluate(info)
                HealthHistory.shared.record(info)
                RunTimeStore.shared.record(info)
            }
            .store(in: &cancellables)

        monitor.start()
        ChargeControl.shared.start()
        EnergyHistory.shared.start()
        UsageTracking.start()
        UpdateChecker.shared.checkIfDue()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            UsagePing.start()
        }
        devices.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        BatteryMonitor.shared.stop()
        BluetoothDeviceMonitor.shared.stop()
        AppEnergyMonitor.shared.setActive(false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // closing Settings must not quit a menu bar app
    }
}
