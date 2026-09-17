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
            }
            .store(in: &cancellables)

        monitor.start()
        devices.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        BatteryMonitor.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // closing Settings must not quit a menu bar app
    }
}
