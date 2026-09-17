//
//  NotificationManager.swift
//  KwikBattery
//
//  Watches each new BatteryInfo and posts local notifications.
//  Every alert fires once per "episode" and re-arms when the condition clears,
//  so you never get spammed every 30 seconds.
//

import Foundation
import Combine
import UserNotifications

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()
    private let presenter = NotificationPresenter()

    // Episode state
    private var didNotifyFull = false
    private var didNotifyLow = false
    private var didNotifySlow = false
    private var slowChargeStartedAt: Date?

    /// How long charging must stay below the watt threshold before we alert.
    private let slowChargeGracePeriod: TimeInterval = 180
    /// Minimum gap between repeated "health below threshold" alerts.
    private let healthAlertInterval: TimeInterval = 7 * 24 * 60 * 60

    private init() {}

    func setUp() {
        center.delegate = presenter
        requestAuthorization()
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("KwikBattery: notification authorization error: \(error)") }
            Task { @MainActor in
                NotificationManager.shared.refreshAuthorizationStatus()
            }
        }
    }

    func refreshAuthorizationStatus() {
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                NotificationManager.shared.authorizationStatus = status
            }
        }
    }

    // MARK: - Evaluation

    func evaluate(_ info: BatteryInfo) {
        guard info.hasBattery else { return }
        checkFullCharge(info)
        checkLowBattery(info)
        checkHealth(info)
        checkSlowCharging(info)
    }

    /// 1. Reached 100% while plugged in → "unplug now".
    private func checkFullCharge(_ info: BatteryInfo) {
        if AppSettings.notifyFullCharge, info.isPluggedIn, info.percentage >= 100 {
            guard !didNotifyFull else { return }
            didNotifyFull = true
            post(id: "full",
                 title: "Battery Fully Charged",
                 body: "Your battery is at 100%. You can unplug the charger now.")
        } else if !info.isPluggedIn || info.percentage < 95 {
            didNotifyFull = false
        }
    }

    /// 2. Dropped to/below the low threshold while unplugged.
    private func checkLowBattery(_ info: BatteryInfo) {
        let threshold = Int(AppSettings.lowBatteryThreshold)
        if AppSettings.notifyLowBattery, !info.isPluggedIn, info.percentage <= threshold {
            guard !didNotifyLow else { return }
            didNotifyLow = true
            post(id: "low",
                 title: "Low Battery: \(info.percentage)%",
                 body: "Battery is at or below your \(threshold)% alert level. Consider plugging in.")
        } else if info.isPluggedIn || info.percentage > threshold {
            didNotifyLow = false
        }
    }

    /// 3. Health dropped below the configured threshold (repeats at most weekly).
    private func checkHealth(_ info: BatteryInfo) {
        guard AppSettings.notifyHealth, let health = info.healthPercent else { return }
        let threshold = AppSettings.healthThreshold
        guard health < threshold else { return }

        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: SettingsKey.lastHealthAlertDate) as? Date,
           Date().timeIntervalSince(last) < healthAlertInterval {
            return
        }
        defaults.set(Date(), forKey: SettingsKey.lastHealthAlertDate)
        post(id: "health",
             title: "Battery Health Below \(Int(threshold))%",
             body: "Battery health is now \(Format.percent(health)) (\(info.condition)). Consider having it checked.")
    }

    /// 4. Charging, but the power flowing into the battery is suspiciously low
    ///    for a sustained period → possible bad cable or weak adapter.
    private func checkSlowCharging(_ info: BatteryInfo) {
        guard AppSettings.notifySlowCharging,
              info.isPluggedIn, info.isCharging,
              info.percentage < 90,                 // charging naturally tapers near full
              let watts = info.batteryWatts, watts > 0 else {
            slowChargeStartedAt = nil
            if !info.isPluggedIn { didNotifySlow = false }
            return
        }

        let minimum = AppSettings.slowChargingWatts
        guard watts < minimum else {
            slowChargeStartedAt = nil
            return
        }

        let start = slowChargeStartedAt ?? Date()
        slowChargeStartedAt = start
        guard !didNotifySlow, Date().timeIntervalSince(start) >= slowChargeGracePeriod else { return }
        didNotifySlow = true

        var body = "The battery is only receiving \(Format.watts(watts)) (alert threshold: \(Int(minimum)) W)."
        if let adapter = info.adapterWatts {
            body += " Adapter reports \(adapter) W."
        }
        body += " Check your cable and power adapter."
        post(id: "slow", title: "Charging Slowly", body: body)
    }

    // MARK: - Posting

    func sendTestNotification() {
        post(id: "test-\(UUID().uuidString)",
             title: "KwikBattery Notifications Work",
             body: "You'll see battery alerts like this one.")
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: "com.kwikbattery.\(id)", content: content, trigger: nil)
        center.add(request) { error in
            if let error { NSLog("KwikBattery: failed to deliver notification: \(error)") }
        }
    }
}

/// Lets banners appear even when KwikBattery is the active app (e.g. popover open).
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
