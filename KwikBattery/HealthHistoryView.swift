//
//  HealthHistoryView.swift
//  KwikBattery
//
//  The panel shown when you click the Health tile: a graph of battery health
//  over time, cycle growth, and a plain-language read on the trend.
//

import SwiftUI
import Charts

struct HealthHistoryView: View {
    @EnvironmentObject private var history: HealthHistory
    @EnvironmentObject private var monitor: BatteryMonitor

    let onClose: () -> Void

    private enum Metric: String, CaseIterable, Identifiable {
        case health = "Health"
        case cycles = "Cycles"
        var id: String { rawValue }
    }

    @State private var metric: Metric = .health

    private var info: BatteryInfo { monitor.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if history.snapshots.count < 2 {
                collecting
            } else {
                picker
                chart
                    .frame(height: 130)
                insights
            }

            if let summary = history.summary {
                Text(summary)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            Text("Battery Health Over Time")
                .font(PanelFont.title(13))
            Spacer()
            Text(info.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.green)
        }
    }

    private var collecting: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(Color.white.opacity(0.5))
                Text(history.snapshots.isEmpty
                     ? "Collecting data — the first reading is saved today."
                     : "One day recorded. The graph appears once there are two.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Text("KwikBattery saves one reading a day. Trends become meaningful after a couple of weeks.")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var picker: some View {
        Picker("", selection: $metric) {
            ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    @ViewBuilder
    private var chart: some View {
        let tint: Color = metric == .health ? .green : .purple
        Chart(history.snapshots) { snapshot in
            AreaMark(x: .value("Date", snapshot.date),
                     y: .value(metric.rawValue, value(for: snapshot)))
                .foregroundStyle(
                    LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.monotone)
            LineMark(x: .value("Date", snapshot.date),
                     y: .value(metric.rawValue, value(for: snapshot)))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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

    private func value(for snapshot: HealthSnapshot) -> Double {
        metric == .health ? snapshot.healthPercent : Double(snapshot.cycleCount)
    }

    private var domain: ClosedRange<Double> {
        let values = history.snapshots.map { value(for: $0) }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        if metric == .health {
            return Swift.max(0, (low - 2).rounded(.down))...Swift.min(105, Swift.max(high + 1, low + 2).rounded(.up))
        }
        return Swift.max(0, low - 5)...(high + 5)
    }

    private var insights: some View {
        HStack(spacing: 6) {
            insightTile(title: "30 days",
                        value: history.healthChange(overDays: 30).map { String(format: "%+.1f%%", $0) } ?? "—")
            insightTile(title: "90 days",
                        value: history.healthChange(overDays: 90).map { String(format: "%+.1f%%", $0) } ?? "—")
            insightTile(title: "Cycles/mo",
                        value: history.cyclesAdded(overDays: 30).map { "+\($0)" } ?? "—")
            insightTile(title: "Tracked",
                        value: "\(history.daysTracked)d")
        }
    }

    private func insightTile(title: String, value: String) -> some View {
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
