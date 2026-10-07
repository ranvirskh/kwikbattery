//
//  InsightsTracking.swift
//  KwikBattery
//
//  The live side of two 1.11 features (their logic is in LimitPayoff.swift and
//  AppEnergyAlerts.swift):
//    - how long the charge limit kept the battery below full
//    - alerts for an app that keeps using a lot of power on battery
//  Neither adds a timer or a process: both ride on readings the app already takes.
//

import AppKit
import Combine
import UserNotifications

// MARK: - Charge limit payoff

@MainActor
final class LimitPayoffStore: ObservableObject {
    static let shared = LimitPayoffStore()

    @Published private(set) var ledger = LimitLedger()

    fileprivate var lastSample: Date?
    private var lastSave = Date.distantPast
    private var dirty = false
    private var fileURL: URL { UsageTracking.directoryURL.appendingPathComponent("limit-payoff.json") }

    private init() {}

    private var sleepObserver: NSObjectProtocol?

    func load() {
        // The Mac isn't plugged-in-and-held while it sleeps: the helper puts the
        // adapter back first. Don't credit the gap after waking.
        if sleepObserver == nil {
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    LimitPayoffStore.shared.lastSample = nil
                    LimitPayoffStore.shared.flush()
                }
            }
        }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            var loaded = try JSONDecoder().decode(LimitLedger.self, from: data)
            loaded.prune(today: EnergyLedger.key(for: Date()))
            ledger = loaded
        } catch {
            let salvage = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: salvage)
            try? FileManager.default.moveItem(at: fileURL, to: salvage)
            NSLog("KwikBattery: limit payoff unreadable (\(error)); kept a copy at \(salvage.path)")
        }
    }

    /// Called with every battery reading. Credits the time since the last one
    /// when the charge limit is what's holding the battery below full.
    func sample(_ info: BatteryInfo) {
        let now = Date()
        let previous = lastSample
        lastSample = now
        guard let previous, info.hasBattery else { return }

        let control = ChargeControl.shared
        guard control.reachable, let s = control.status else { return }
        let held = LimitPayoff.isHeldByLimit(helperEnabled: s.policy.enabled,
                                             mode: s.mode,
                                             effectiveLimit: s.effectiveLimit,
                                             topUpActive: s.topUpActive,
                                             hotPaused: s.hotPaused ?? false,
                                             pluggedIn: s.pluggedIn,
                                             percent: info.percentage)
        guard held else { return }
        let minutes = now.timeIntervalSince(previous) / 60
        guard minutes > 0 else { return }
        // Readings arrive every 5 minutes with the panel closed (15 in Low Power
        // Mode), so allow a gap of one and a half intervals; sleep is handled above.
        let allowance = AppSettings.lowPowerMode ? 22.5 : 7.5
        ledger.record(day: EnergyLedger.key(for: now), percent: info.percentage,
                      minutes: minutes, maxMinutes: allowance)
        dirty = true
        // A minute of credit isn't worth a disk write: save every 5 minutes.
        if now.timeIntervalSince(lastSave) >= 300 { flush() }
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        lastSave = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: UsageTracking.directoryURL, withIntermediateDirectories: true)
            try encoder.encode(ledger).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("KwikBattery: couldn't save limit payoff: \(error)")
        }
    }

    func reset() {
        ledger = LimitLedger()
        dirty = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Lines for the Charge control settings and the panel.
    var weekLine: String? {
        ledger.summary(lastDays: 7, today: EnergyLedger.key(for: Date()))
            .map { LimitPayoff.line($0, period: "this week") }
    }

    var lifetimeLine: String? {
        guard let s = ledger.lifetimeSummary(), let since = ledger.since else { return nil }
        return LimitPayoff.line(s, period: "since \(since)")
    }
}

// MARK: - App energy alerts

@MainActor
final class AppEnergyAlertWatcher {
    static let shared = AppEnergyAlertWatcher()

    static let categoryID = "com.kwikbattery.appEnergy"
    static let quitAction = "com.kwikbattery.appEnergy.quit"
    static let ignoreAction = "com.kwikbattery.appEnergy.ignore"

    private var engine = AppEnergyAlertEngine()

    private init() {}

    func reset() { engine.reset() }

    /// Called by EnergyHistory after each battery-only sample.
    func evaluate(apps: [AppEnergyUsage], systemWatts: Double, interval: TimeInterval) {
        guard AppSettings.notifyAppEnergy, systemWatts.isFinite, systemWatts > 0 else {
            engine.reset()
            return
        }
        let samples = apps.map {
            AppEnergyAlertEngine.Sample(id: $0.id, name: $0.name, watts: $0.percent / 100 * systemWatts)
        }
        let alerts = engine.update(samples,
                                   at: Date(),
                                   interval: interval,
                                   thresholdWatts: AppSettings.appEnergyWatts,
                                   sustainMinutes: 10,
                                   ignoring: Set(AppSettings.ignoredEnergyApps))
        guard !alerts.isEmpty else { return }

        let info = BatteryMonitor.shared.info
        for alert in alerts {
            var body = "\(alert.name) has been using about \(Format.watts(alert.watts)) for \(alert.minutes) minutes"
            if let minutes = info.timeToEmptyMinutes,
               let extra = AppEnergyAlertEngine.extraMinutes(timeLeftMinutes: minutes,
                                                            systemWatts: systemWatts, appWatts: alert.watts),
               extra >= 10 {
                body += ". Without it the battery would last about \(Format.duration(minutes: extra)) longer"
            }
            body += "."
            let path = apps.first { $0.id == alert.id }?.appPath
            var userInfo: [String: String] = ["appID": alert.id, "appName": alert.name]
            if let path { userInfo["appPath"] = path }
            NotificationManager.shared.deliver(id: "app-energy-\(alert.id)",
                                               title: "\(alert.name) Is Draining the Battery",
                                               body: body,
                                               category: path == nil ? nil : Self.categoryID,
                                               userInfo: userInfo)
        }
    }

    /// Notification buttons: quit the app, or stop alerting about it.
    func handle(action: String, appID: String?, appPath: String?) {
        switch action {
        case Self.quitAction:
            guard let appPath else { return }
            let me = Bundle.main.bundleIdentifier
            // Only the exact app the alert named, and never the Finder or ourselves.
            for app in NSWorkspace.shared.runningApplications
            where app.bundleURL?.path == appPath
                && app.bundleIdentifier != me
                && app.bundleIdentifier != "com.apple.finder" {
                app.terminate()
            }
        case Self.ignoreAction:
            guard let appID else { return }
            var ignored = AppSettings.ignoredEnergyApps
            if !ignored.contains(appID) { ignored.append(appID) }
            AppSettings.setIgnoredEnergyApps(ignored)
        default:
            break
        }
    }
}
