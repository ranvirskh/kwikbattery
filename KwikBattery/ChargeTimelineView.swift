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
    @ObservedObject private var payoff = LimitPayoffStore.shared

    let onClose: () -> Void

    @State private var showTemperature = false

    private static let window: TimeInterval = 24 * 60 * 60

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-Self.window)
        let points = history.log.points(from: start, to: now)
        let spans = history.log.pluggedSpans(from: start, to: now)
        let tint = monitor.info.levelColor
        let hasTemperatures = points.filter { $0.celsius != nil }.count >= 2

        VStack(alignment: .leading, spacing: 8) {
            header

            if points.count < 2 {
                collecting
            } else {
                if hasTemperatures { metricPicker }
                if showTemperature && hasTemperatures {
                    temperatureChart(points: points, spans: spans, start: start, now: now)
                        .frame(height: 110)
                    temperatureStats(points: points, now: now)
                } else {
                    chart(points: points, spans: spans, start: start, now: now, tint: tint)
                        .frame(height: 110)
                    stats(points: points, spans: spans)
                }
            }

            if let line = payoff.weekLine {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.green)
                    Text(line)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    private var metricPicker: some View {
        Picker("", selection: $showTemperature) {
            Text("Charge").tag(false)
            Text("Temperature").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    private func displayTemperature(_ celsius: Double) -> Double {
        AppSettings.useFahrenheit ? celsius * 9.0 / 5.0 + 32.0 : celsius
    }

    private func temperatureChart(points: [ChargePoint], spans: [DateInterval],
                                  start: Date, now: Date) -> some View {
        let readings = points.filter { $0.celsius != nil }
        let limit = displayTemperature(AppSettings.hotThreshold)
        let values = readings.map { displayTemperature($0.celsius ?? 0) }
        let low = Swift.min(values.min() ?? limit, limit) - 2
        let high = Swift.max(values.max() ?? limit, limit) + 2
        return Chart {
            ForEach(spans, id: \.start) { span in
                RectangleMark(xStart: .value("Plugged in", span.start),
                              xEnd: .value("Unplugged", span.end),
                              yStart: .value("Bottom", low),
                              yEnd: .value("Top", high))
                    .foregroundStyle(Color.green.opacity(0.13))
            }
            RuleMark(y: .value("Hot limit", limit))
                .foregroundStyle(Color.orange.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(readings, id: \.time) { point in
                LineMark(x: .value("Time", point.time),
                         y: .value("Temperature", displayTemperature(point.celsius ?? 0)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .chartXScale(domain: start...now)
        .chartYScale(domain: low...high)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel(format: .dateTime.hour())
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel()
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }

    private func temperatureStats(points: [ChargePoint], now: Date) -> some View {
        let summary = TemperatureTrend.summary(points, hotLimit: AppSettings.hotThreshold, until: now)
        let fahrenheit = AppSettings.useFahrenheit
        return HStack(spacing: 6) {
            tile(title: "Coolest",
                 value: summary.map { Format.temperature(celsius: $0.lowest, fahrenheit: fahrenheit) } ?? "—")
            tile(title: "Warmest",
                 value: summary.map { Format.temperature(celsius: $0.highest, fahrenheit: fahrenheit) } ?? "—")
            tile(title: "Time hot",
                 value: summary.map { Format.duration(minutes: $0.minutesHot) } ?? "—")
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
