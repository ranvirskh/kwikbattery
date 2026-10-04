//
//  EnergyHistory.swift
//  KwikBattery
//
//  Which apps used the battery over the last day, week and month.
//
//  Every 5 minutes (15 in Low Power Mode), and only while running on battery,
//  this samples the same Energy Impact table as "Top Energy Users" and credits
//  each app with its share of the Mac's measured power for the interval (see
//  EnergyLedger). On AC power nothing is sampled: that energy didn't come out
//  of the battery, and not forking `top` is the cheapest sample there is.
//
//  Stored only on this Mac, in
//  ~/Library/Application Support/KwikBattery/energy-history.json.
//

import Foundation
import Combine

@MainActor
final class EnergyHistory: ObservableObject {
    static let shared = EnergyHistory()

    @Published private(set) var ledger = EnergyLedger()

    private let fileURL: URL
    private let directoryURL: URL

    private var timer: AnyCancellable?
    private var timerInterval: TimeInterval = 0
    /// When the timer last fired (sampled or not). A sample is credited with the
    /// time since then, capped at one interval: after sleep there's no catch-up.
    private var lastTick: Date?
    private var isSampling = false

    private static let appCount = 12

    private var interval: TimeInterval { AppSettings.lowPowerMode ? 15 * 60 : 5 * 60 }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directoryURL = base.appendingPathComponent("KwikBattery", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("energy-history.json")
        load()
    }

    var todayKey: String { EnergyLedger.key(for: Date()) }

    func start() {
        lastTick = Date()
        schedule()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func reset() {
        ledger = EnergyLedger()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Sampling

    private func schedule() {
        timerInterval = interval
        timer = Timer.publish(every: timerInterval, tolerance: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let now = Date()
        let previous = lastTick ?? now
        lastTick = now
        // Low Power Mode was switched since the timer was made.
        if timerInterval != interval { schedule() }

        guard AppSettings.trackEnergyHistory, !isSampling else { return }
        let info = BatteryMonitor.shared.info
        guard info.hasBattery, !info.isPluggedIn,
              let watts = info.systemLoadWatts, watts.isFinite, watts > 0 else { return }

        let elapsed = now.timeIntervalSince(previous)
        let seconds = Swift.min(Swift.max(elapsed, 0), timerInterval)
        guard seconds > 0 else { return }

        isSampling = true
        let running = AppEnergyMonitor.runningApps()
        let day = EnergyLedger.key(for: now)
        Task {
            let apps = await AppEnergyMonitor.loadUsage(runningApps: running, limit: Self.appCount)
            self.isSampling = false
            // `top` failing gives an empty list; the day's total would still be
            // right, but a sample with no apps at all is more likely a glitch.
            guard !apps.isEmpty else { return }
            self.ledger.record(day: day,
                               apps: apps.map { (id: $0.id, name: $0.name, appPath: $0.appPath, percentShare: $0.percent) },
                               systemLoadWatts: watts,
                               seconds: seconds)
            self.save()
        }
    }

    // MARK: - Storage

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            var loaded = try JSONDecoder().decode(EnergyLedger.self, from: data)
            loaded.prune(today: todayKey)
            ledger = loaded
        } catch {
            // Same rule as HealthHistory: a file that won't decode is kept aside,
            // never silently overwritten by the next sample.
            let salvage = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: salvage)
            try? FileManager.default.moveItem(at: fileURL, to: salvage)
            NSLog("KwikBattery: energy history unreadable (\(error)); kept a copy at \(salvage.path)")
            ledger = EnergyLedger()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try encoder.encode(ledger).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("KwikBattery: couldn't save energy history: \(error)")
        }
    }
}
