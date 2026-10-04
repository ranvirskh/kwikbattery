//
//  ChargeTimelineView.swift
//  KwikBattery
//
//  Shown in place of the hero card when you tap it: the charge level over the
//  last 24 hours, with the time spent plugged in shaded, and the last sleep.
//

import SwiftUI
import Charts

struct ChargeTimelineView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @ObservedObject private var history = ChargeHistory.shared
    @ObservedObject private var sleep = SleepDrainMonitor.shared

    let onClose: () -> Void

    private static let window: TimeInterval = 24 * 60 * 60

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-Self.window)
        let points = history.log.points(from: start, to: now)
        let spans = history.log.pluggedSpans(from: start, to: now)
        let tint = monitor.info.levelColor

        VStack(alignment: .leading, spacing: 8) {
            header

            if points.count < 2 {
                collecting
            } else {
                chart(points: points, spans: spans, start: start, now: now, tint: tint)
                    .frame(height: 110)
                stats(points: points, spans: spans)
            }

            if let report = sleep.recentReport {
                HStack(spacing: 5) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.indigo)
                    Text(SleepDrain.summary(report))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            Text("Charge, Last 24 Hours")
                .font(PanelFont.title(13))
            Spacer()
            Text("\(monitor.info.percentage)%")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(monitor.info.levelColor)
        }
    }

    private var collecting: some View {
        HStack(spacing: 7) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(Color.white.opacity(0.5))
            Text("Collecting data. The graph fills in as the charge level changes.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func chart(points: [ChargePoint], spans: [DateInterval],
                       start: Date, now: Date, tint: Color) -> some View {
        Chart {
            ForEach(spans, id: \.start) { span in
                RectangleMark(xStart: .value("Plugged in", span.start),
                              xEnd: .value("Unplugged", span.end),
                              yStart: .value("Bottom", 0),
                              yEnd: .value("Top", 100))
                    .foregroundStyle(Color.green.opacity(0.13))
            }
            ForEach(points, id: \.time) { point in
                LineMark(x: .value("Time", point.time),
                         y: .value("Charge", point.percent))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .chartXScale(domain: start...now)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel(format: .dateTime.hour())
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel()
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }

    private func stats(points: [ChargePoint], spans: [DateInterval]) -> some View {
        let low = points.map(\.percent).min() ?? 0
        let high = points.map(\.percent).max() ?? 0
        let pluggedMinutes = Int(spans.reduce(0) { $0 + $1.duration } / 60)
        return HStack(spacing: 6) {
            tile(title: "Lowest", value: "\(low)%")
            tile(title: "Highest", value: "\(high)%")
            tile(title: "Plugged in", value: Format.duration(minutes: pluggedMinutes))
        }
    }

    private func tile(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title.uppercased())
                .font(PanelFont.eyebrow(8))
                .tracking(0.4)
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}
