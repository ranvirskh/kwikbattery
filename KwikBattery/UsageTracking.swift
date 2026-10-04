//
//  UsageTracking.swift
//  KwikBattery
//
//  The live side of the 1.9 features (the logic is in UsageInsights.swift):
//  the 48-hour charge timeline, the "since unplugged" session, the sleep-drain
//  report and low-battery alerts for Bluetooth devices. All of it is kept on
//  this Mac: charge-history.json in Application Support, the rest in defaults.
//
//  `UsageTracking.start()` wires everything up from one place, so the app
//  delegate only needs a single line.
//

import AppKit
import Combine

@MainActor
enum UsageTracking {
    private static var cancellables = Set<AnyCancellable>()

    static func start() {
        ChargeHistory.shared.load()
        DischargeSessionStore.shared.load()
        SleepDrainMonitor.shared.start()

        BatteryMonitor.shared.$info
            .dropFirst()
            .sink { info in
                guard info.hasBattery else { return }
                ChargeHistory.shared.record(info)
                DischargeSessionStore.shared.update(info)
            }
            .store(in: &cancellables)

        BluetoothDeviceMonitor.shared.$devices
            .dropFirst()
            .sink { devices in DeviceAlertWatcher.shared.evaluate(devices) }
            .store(in: &cancellables)
    }

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KwikBattery", isDirectory: true)
    }
}

// MARK: - Charge timeline

@MainActor
final class ChargeHistory: ObservableObject {
    static let shared = ChargeHistory()

    @Published private(set) var log = ChargeLog()

    private var fileURL: URL { UsageTracking.directoryURL.appendingPathComponent("charge-history.json") }
    private var loaded = false

    private init() {}

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            log = try decoder.decode(ChargeLog.self, from: data)
        } catch {
            // Same rule as the other histories: never overwrite a file we can't read.
            let salvage = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: salvage)
            try? FileManager.default.moveItem(at: fileURL, to: salvage)
            NSLog("KwikBattery: charge history unreadable (\(error)); kept a copy at \(salvage.path)")
        }
    }

    func record(_ info: BatteryInfo) {
        var updated = log
        guard updated.record(percent: info.percentage, pluggedIn: info.isPluggedIn, at: Date()) else { return }
        log = updated
        save()
    }

    func reset() {
        log = ChargeLog()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: UsageTracking.directoryURL, withIntermediateDirectories: true)
            try encoder.encode(log).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("KwikBattery: couldn't save charge history: \(error)")
        }
    }
}

// MARK: - Since unplugged

@MainActor
final class DischargeSessionStore: ObservableObject {
    static let shared = DischargeSessionStore()

    @Published private(set) var session: DischargeSession?

    private let defaultsKey = "usage.dischargeSession"

    private init() {}

    func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        session = try? JSONDecoder().decode(DischargeSession.self, from: data)
    }

    func update(_ info: BatteryInfo) {
        let next = DischargeSession.update(session, pluggedIn: info.isPluggedIn, percent: info.percentage,
                                           capacity: info.currentCapacity, at: Date())
        guard next != session else { return }
        session = next
        if let next, let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    func summary(for info: BatteryInfo) -> DischargeSession.Summary? {
        guard !info.isPluggedIn, let session else { return nil }
        return session.summary(percent: info.percentage, capacity: info.currentCapacity,
                               voltage: info.voltage, at: Date())
    }
}

// MARK: - Sleep drain

@MainActor
final class SleepDrainMonitor: ObservableObject {
    static let shared = SleepDrainMonitor()

    @Published private(set) var lastReport: SleepDrain.Report?

    private var sleepMark: SleepDrain.Mark?
    private var observers: [NSObjectProtocol] = []
    private let defaultsKey = "usage.lastSleepReport"

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            lastReport = try? JSONDecoder().decode(SleepDrain.Report.self, from: data)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SleepDrainMonitor.shared.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SleepDrainMonitor.shared.didWake() }
        })
    }

    /// The report, if it's from the last day (older ones aren't news).
    var recentReport: SleepDrain.Report? {
        guard let lastReport, Date().timeIntervalSince(lastReport.wokeAt) < 24 * 60 * 60 else { return nil }
        return lastReport
    }

    private func willSleep() {
        // The idle reading can be minutes old; take a fresh one before sleeping.
        BatteryMonitor.shared.refresh()
        let info = BatteryMonitor.shared.info
        guard info.hasBattery else {
            sleepMark = nil
            return
        }
        sleepMark = SleepDrain.Mark(time: Date(), percent: info.percentage, pluggedIn: info.isPluggedIn)
    }

    private func didWake() {
        guard let mark = sleepMark else { return }
        sleepMark = nil
        let wokeAt = Date()
        // The battery driver takes a few seconds after wake to report a settled
        // percentage, so read it a little later but date the reading at wake.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            BatteryMonitor.shared.refresh()
            self.finish(mark: mark, wokeAt: wokeAt)
        }
    }

    private func finish(mark: SleepDrain.Mark, wokeAt: Date) {
        let info = BatteryMonitor.shared.info
        guard info.hasBattery else { return }
        let wake = SleepDrain.Mark(time: wokeAt, percent: info.percentage, pluggedIn: info.isPluggedIn)
        guard let report = SleepDrain.report(sleep: mark, wake: wake) else { return }
        lastReport = report
        if let data = try? JSONEncoder().encode(report) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        guard AppSettings.notifySleepDrain,
              SleepDrain.isHeavy(report, thresholdPerHour: AppSettings.sleepDrainPerHour) else { return }
        NotificationManager.shared.deliver(
            id: "sleep-drain",
            title: "Battery Drained While Asleep",
            body: SleepDrain.summary(report) + ". Something may have kept the Mac partly awake: "
                + "check Power Nap and \"Wake for network access\" in System Settings › Battery › Options.")
    }
}

// MARK: - Bluetooth device alerts

@MainActor
final class DeviceAlertWatcher {
    static let shared = DeviceAlertWatcher()

    private var alerts = DeviceBatteryAlerts()
    /// Readings older than this are a remembered level, not a current one.
    private let maxAge: TimeInterval = 15 * 60

    private init() {}

    func evaluate(_ devices: [BluetoothDevice]) {
        let now = Date()
        let readings = devices
            .filter { $0.kind != .phone && now.timeIntervalSince($0.lastSeen) <= maxAge }
            .map { device -> DeviceBatteryAlerts.Reading in
                // Earbuds: the lower bud. The case level alone means they're in the case.
                let buds = [device.leftLevel, device.rightLevel].compactMap { $0 }
                return DeviceBatteryAlerts.Reading(id: device.id, name: device.name,
                                                   level: device.mainLevel ?? buds.min(),
                                                   isCharging: device.isCharging)
            }
        let threshold = Int(AppSettings.deviceLowThreshold)
        let newlyLow = alerts.update(readings, threshold: threshold)
        guard AppSettings.notifyDeviceLow else { return }
        for reading in newlyLow {
            guard let level = reading.level else { continue }
            NotificationManager.shared.deliver(
                id: "device-low-\(reading.id)",
                title: "\(reading.name): \(level)%",
                body: "\(reading.name) is at or below your \(threshold)% alert level. Charge it soon.")
        }
    }
}
