//
//  HealthHistory.swift
//  KwikBattery
//
//  Long-term record of battery health, so you can see whether it's degrading
//  and how fast — the thing a single "86%" reading can't tell you.
//
//  One snapshot per day is plenty: health moves by fractions of a percent a
//  week. Stored as JSON in Application Support, a few KB even after years.
//

import Foundation
import Combine

struct HealthSnapshot: Codable, Identifiable, Equatable {
    var id: String { day }
    let day: String           // "yyyy-MM-dd", one per day
    let date: Date
    let healthPercent: Double
    let cycleCount: Int
    let maxCapacity: Int?
    let designCapacity: Int?
}

@MainActor
final class HealthHistory: ObservableObject {
    static let shared = HealthHistory()

    @Published private(set) var snapshots: [HealthSnapshot] = []

    private let fileURL: URL
    let directoryURL: URL

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directoryURL = base.appendingPathComponent("KwikBattery", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("health-history.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        load()
    }

    /// Records today's reading once per day.
    func record(_ info: BatteryInfo) {
        guard info.hasBattery,
              let health = info.healthPercent,
              let cycles = info.cycleCount else { return }

        let today = Self.dayFormatter.string(from: Date())
        guard !snapshots.contains(where: { $0.day == today }) else { return }

        snapshots.append(HealthSnapshot(day: today,
                                        date: Calendar.current.startOfDay(for: Date()),
                                        healthPercent: (health * 10).rounded() / 10,
                                        cycleCount: cycles,
                                        maxCapacity: info.maxCapacity,
                                        designCapacity: info.designCapacity))
        snapshots.sort { $0.date < $1.date }
        save()
    }

    func reset() {
        snapshots = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Insights

    var daysTracked: Int { snapshots.count }

    /// Health change over the given window, if there's enough data.
    func healthChange(overDays days: Int) -> Double? {
        guard let latest = snapshots.last else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: latest.date) ?? latest.date
        guard let earliest = snapshots.first(where: { $0.date >= cutoff }),
              earliest.day != latest.day else { return nil }
        return latest.healthPercent - earliest.healthPercent
    }

    func cyclesAdded(overDays days: Int) -> Int? {
        guard let latest = snapshots.last else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: latest.date) ?? latest.date
        guard let earliest = snapshots.first(where: { $0.date >= cutoff }),
              earliest.day != latest.day else { return nil }
        return latest.cycleCount - earliest.cycleCount
    }

    /// Plain-language summary, or nil while there's too little data to be honest.
    var summary: String? {
        guard snapshots.count >= 2, let latest = snapshots.last, let first = snapshots.first else { return nil }
        let span = Calendar.current.dateComponents([.day], from: first.date, to: latest.date).day ?? 0
        guard span >= 7 else { return nil }

        let change = latest.healthPercent - first.healthPercent
        let perMonth = change / Double(span) * 30.0

        if abs(change) < 0.5 {
            return "Health has held steady over \(span) days."
        }
        if change > 0 {
            return "Health has read \(String(format: "%.1f", change))% higher over \(span) days — small rises are normal."
        }
        let rate = String(format: "%.1f", abs(perMonth))
        return "Health is down \(String(format: "%.1f", abs(change)))% over \(span) days, about \(rate)% a month."
    }

    // MARK: - Storage

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        snapshots = ((try? decoder.decode([HealthSnapshot].self, from: data)) ?? [])
            .sorted { $0.date < $1.date }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try encoder.encode(snapshots).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("KwikBattery: couldn't save health history: \(error)")
        }
    }
}
