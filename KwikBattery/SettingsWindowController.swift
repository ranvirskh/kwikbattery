//
//  SettingsWindowController.swift
//  KwikBattery
//
//  Hosts SettingsView in a regular AppKit window. Menu-bar-only (LSUIElement)
//  apps can't rely on SwiftUI's Settings scene being reachable, so we manage
//  the window ourselves.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = SettingsView()
                .environmentObject(NotificationManager.shared)

            let hosting = NSHostingController(rootView: root)
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered,
                                     defer: false)
            newWindow.title = "KwikBattery Settings"
            newWindow.contentViewController = hosting
            newWindow.isReleasedWhenClosed = false
            newWindow.setContentSize(NSSize(width: 480, height: 680))
            newWindow.center()
            newWindow.setFrameAutosaveName("KwikBatterySettingsWindow")
            window = newWindow
        }

        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
