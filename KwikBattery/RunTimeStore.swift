//
//  RunTimeStore.swift
//  KwikBattery
//
//  Feeds every battery reading into RunTimeEstimator and publishes the
//  smoothed "time left". The estimator always runs (it's a few doubles), so
//  switching "Smoother time-remaining estimate" on in Settings takes effect at
//  once instead of after another 10 minutes of collecting.
//

import Foundation
import Combine

@MainActor
final class RunTimeStore: ObservableObject {
    static let shared = RunTimeStore()

    @Published private(set) var smoothedMinutes: Int?

    private var estimator = RunTimeEstimator()

    private init() {}

    func record(_ info: BatteryInfo, at date: Date = Date()) {
        estimator.add(percent: Double(info.percentage),
                      at: date,
                      onBattery: info.hasBattery && !info.isPluggedIn)
        let minutes = estimator.minutesRemaining
        if minutes != smoothedMinutes { smoothedMinutes = minutes }
    }

    /// Minutes to show as "time left": the smoothed figure when it's switched on
    /// and has enough data, otherwise macOS's own estimate.
    func timeToEmpty(for info: BatteryInfo, smooth: Bool) -> Int? {
        guard info.state == .discharging else { return info.timeToEmptyMinutes }
        if smooth, let smoothedMinutes { return smoothedMinutes }
        return info.timeToEmptyMinutes
    }

    /// The minutes the menu bar's "Time left" text shows for this state.
    func menuBarMinutes(for info: BatteryInfo, smooth: Bool) -> Int? {
        switch info.state {
        case .discharging: return timeToEmpty(for: info, smooth: smooth)
        case .charging:    return info.timeToFullMinutes
        default:           return nil
        }
    }
}
