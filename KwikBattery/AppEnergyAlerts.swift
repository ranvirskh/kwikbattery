//
//  AppEnergyAlerts.swift
//  KwikBattery
//
//  "Safari has been using about 9 W for 10 minutes." Watches the per-app energy
//  samples that Energy history already takes (so it costs nothing extra) and
//  reports an app once per episode when it stays above a power threshold.
//
//  Foundation only (compiled into the insights tests).
//

import Foundation

struct AppEnergyAlertEngine {
    struct Sample: Equatable {
        let id: String
        let name: String
        /// Estimated draw: the app's share of the Mac's energy × system power.
        let watts: Double
    }

    struct Alert: Equatable {
        let id: String
        let name: String
        let watts: Double
        let minutes: Int
    }

    /// An app counts as quiet again after this long below the threshold.
    static let rearmAfter: TimeInterval = 10 * 60

    private struct Streak {
        var since: Date
        var last: Date
        var peak: Double
    }

    private var streaks: [String: Streak] = [:]
    private var alerted: Set<String> = []
    private var belowSince: [String: Date] = [:]

    /// Feeds one round of samples. `interval` is how often samples arrive; a gap
    /// longer than 2.5 intervals (sleep, plugged in) breaks a streak.
    /// Returns the apps that just crossed the "sustained" mark.
    mutating func update(_ samples: [Sample],
                         at now: Date,
                         interval: TimeInterval,
                         thresholdWatts: Double,
                         sustainMinutes: Double,
                         ignoring ignored: Set<String> = []) -> [Alert] {
        // A streak needs at least two samples, whatever the interval is.
        let sustain = Swift.max(sustainMinutes * 60, interval * 2)
        var alerts: [Alert] = []
        let hot = samples.filter { $0.watts.isFinite && $0.watts >= thresholdWatts && !ignored.contains($0.id) }
        let hotIDs = Set(hot.map(\.id))

        for sample in hot {
            belowSince[sample.id] = nil
            if var streak = streaks[sample.id], now.timeIntervalSince(streak.last) <= interval * 2.5,
               now >= streak.last {
                streak.last = now
                streak.peak = Swift.max(streak.peak, sample.watts)
                streaks[sample.id] = streak
            } else {
                streaks[sample.id] = Streak(since: now, last: now, peak: sample.watts)
            }
            // A little slack: samples are stamped when their (slow) measurement
            // finishes, so "10 minutes" can arrive as 9 minutes 56 seconds.
            if let streak = streaks[sample.id], !alerted.contains(sample.id),
               now.timeIntervalSince(streak.since) >= sustain - interval * 0.2 {
                alerted.insert(sample.id)
                alerts.append(Alert(id: sample.id, name: sample.name, watts: sample.watts,
                                    minutes: Int((now.timeIntervalSince(streak.since) / 60).rounded())))
            }
        }

        // Everything that wasn't above the threshold this round.
        for id in Array(streaks.keys) where !hotIDs.contains(id) {
            streaks[id] = nil
        }
        for id in alerted where !hotIDs.contains(id) {
            let since = belowSince[id] ?? now
            belowSince[id] = since
            if now.timeIntervalSince(since) >= Self.rearmAfter {
                alerted.remove(id)
                belowSince[id] = nil
            }
        }
        return alerts
    }

    /// How many minutes longer the battery would last if `appWatts` of the
    /// current `systemWatts` disappeared. nil when the numbers don't allow an
    /// honest answer (no time estimate, or the app is essentially all of the load).
    static func extraMinutes(timeLeftMinutes: Int, systemWatts: Double, appWatts: Double) -> Int? {
        guard timeLeftMinutes > 0, systemWatts.isFinite, appWatts.isFinite,
              systemWatts > 0, appWatts > 0, appWatts < systemWatts - 0.5 else { return nil }
        let remainingWh = Double(timeLeftMinutes) / 60 * systemWatts
        let newMinutes = remainingWh / (systemWatts - appWatts) * 60
        return Int((newMinutes - Double(timeLeftMinutes)).rounded())
    }

    /// Forget everything (plugged in, or tracking turned off).
    mutating func reset() {
        streaks = [:]
        alerted = []
        belowSince = [:]
    }
}
