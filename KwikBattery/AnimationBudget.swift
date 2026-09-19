//
//  AnimationBudget.swift
//  KwikBattery
//
//  One shared clock for every animation in the dropdown, so the whole panel
//  winds down together instead of each effect running on its own timer.
//
//  Stages, measured from the moment the popover opens:
//     0–15 s   .full     60 fps — you're actively looking
//    15–20 s   .reduced  8 fps  — gentle step-down
//     20 s+    .stopped  no repainting at all; the panel is a still image
//
//  Opening the popover again restarts at .full. Live *numbers* keep updating
//  on their own schedule (BatteryMonitor) — this only governs decorative
//  motion: the liquid shimmer, bubbles, pulsing symbols and bar transitions.
//

import SwiftUI

enum AnimationStage {
    case full
    case reduced
    case stopped

    /// Frames per second for TimelineView-driven drawing.
    var frameRate: Double {
        switch self {
        case .full:    return 60
        case .reduced: return 8
        case .stopped: return 1      // effectively idle; paused separately
        }
    }

    var isAnimating: Bool { self != .stopped }

    /// Animation used for value changes (bars, numbers); nil = jump instantly.
    var transition: Animation? {
        switch self {
        case .full:    return .spring(response: 0.6, dampingFraction: 0.85)
        case .reduced: return .easeOut(duration: 0.35)
        case .stopped: return nil
        }
    }
}

@MainActor
final class AnimationBudget: ObservableObject {
    static let shared = AnimationBudget()

    @Published private(set) var stage: AnimationStage = .full

    /// Seconds of full-speed animation, then reduced, then stopped.
    private let fullDuration: TimeInterval = 15
    private let reducedDuration: TimeInterval = 5

    private var windDown: Task<Void, Never>?

    private init() {}

    /// Called when the popover opens (restart) and closes (stop immediately).
    func setActive(_ active: Bool) {
        windDown?.cancel()
        guard active else {
            stage = .stopped
            windDown = nil
            return
        }
        // Low Power Mode skips the smooth phase entirely.
        stage = AppSettings.lowPowerMode ? .reduced : .full
        windDown = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(15 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stage = .reduced
            try? await Task.sleep(nanoseconds: UInt64(5 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stage = .stopped
        }
    }
}
