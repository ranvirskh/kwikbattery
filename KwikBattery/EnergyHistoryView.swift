//
//  EnergyHistoryView.swift
//  KwikBattery
//
//  Shown in place of "Top Energy Users" when you tap its chart icon: which
//  apps used the most battery today, this week and this month.
//

import SwiftUI
import AppKit

struct EnergyHistoryView: View {
    @EnvironmentObject private var history: EnergyHistory
    @EnvironmentObject private var energy: AppEnergyMonitor
    @AppStorage(SettingsKey.trackEnergyHistory) private var trackEnergyHistory = SettingsDefault.trackEnergyHistory

    let onClose: () -> Void

    private enum Period: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 days"
        case month = "30 days"

        var id: String { rawValue }

        var days: Int {
            switch self {
            case .today: return 1
            case .week:  return 7
            case .month: return 30
            }
        }
    }

    @State private var period: Period = .today

    private static let maxRows = 8

    var body: some View {
        let today = history.todayKey
        let rankings = history.ledger.rankings(forDays: period.days, endingOn: today)
        let total = history.ledger.totalWh(forDays: period.days, endingOn: today)

        VStack(alignment: .leading, spacing: 10) {
            header(total: total)

            if history.ledger.isEmpty {
                collecting
            } else {
                picker
                if rankings.isEmpty {
                    emptyPeriod
                } else {
                    VStack(spacing: 6) {
                        ForEach(rankings.prefix(Self.maxRows)) { row in
                            EnergyHistoryRow(ranking: row, icon: energy.icon(forAppPath: row.path))
                        }
                    }
                }
            }

            Text("Figures are approximate: each app's share of macOS's Energy Impact × the Mac's measured power, sampled every 5 minutes on battery. Kept only on this Mac.")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(total: Double) -> some View {
        HStack(spacing: 7) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            Text("App Energy Over Time")
                .font(PanelFont.title(13))
            Spacer()
            if total > 0 {
                Text(String(format: "%.1f Wh", total))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.pink)
                    .help("Energy the Mac used on battery in this period")
            }
        }
    }

    private var collecting: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: trackEnergyHistory ? "calendar.badge.clock" : "pause.circle")
                    .foregroundStyle(Color.white.opacity(0.5))
                Text(trackEnergyHistory
                     ? "Collecting data. The first figures appear after 5 minutes on battery."
                     : "Tracking is off. Turn on \"Track app energy over time\" in Settings.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Nothing is recorded while the Mac is plugged in.")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var emptyPeriod: some View {
        HStack(spacing: 7) {
            Image(systemName: "powerplug.fill")
                .foregroundStyle(Color.white.opacity(0.5))
            Text(period == .today
                 ? "No time on battery recorded today yet."
                 : "No time on battery recorded in this period.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var picker: some View {
        Picker("", selection: $period) {
            ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}

private struct EnergyHistoryRow: View {
    let ranking: EnergyLedger.Ranking
    let icon: NSImage

    private var percent: Double { ranking.shareOfTotal * 100 }

    private var tint: Color {
        if percent >= 40 { return Color.red }
        if percent >= 20 { return Color.orange }
        return Color(red: 0.42, green: 0.78, blue: 1.0)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ranking.name)
                        .font(PanelFont.body(11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(String(format: ranking.wh < 10 ? "%.2f Wh" : "%.1f Wh", ranking.wh))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(String(format: "%.0f%%", percent))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .frame(minWidth: 30, alignment: .trailing)
                }
                LevelBar(fraction: ranking.shareOfTotal, tint: tint, height: 3)
            }
        }
    }
}
