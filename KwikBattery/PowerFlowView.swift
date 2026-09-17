//
//  PowerFlowView.swift
//  KwikBattery
//
//  "Power & Electrical": live usage / voltage / current, plus a ribbon
//  (Sankey-style) power-flow diagram:
//
//     ┌────────┐ ════ 71.7 W ════════▶ ┌──────────┐  Battery (while charging)
//     │ Source │ ════ 18.2 W ════════▶ ├──────────┤  MacBook
//     │ (124W) │ ════ 14.2 W ════════▶ └──────────┘  Connected devices (USB power out)
//     └────────┘
//
//  Ribbon thickness on the left is proportional to the watts it carries.
//  A slow, soft shimmer drifts through each ribbon so it reads like liquid.
//

import SwiftUI

struct PowerElectricalView: View {
    let info: BatteryInfo

    private let green = Color(red: 0.26, green: 0.84, blue: 0.42)
    private let blue  = Color(red: 0.42, green: 0.70, blue: 1.00)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            metricsHeader

            HStack(spacing: 5) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("Power Flow")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Color.white.opacity(0.5))

            SankeyFlowView(sourceIcon: info.isPluggedIn ? "powerplug.fill" : nil,
                           sourceTitle: sourceTitle,
                           sourceSubtitle: info.isPluggedIn ? nil : "\(info.percentage)%",
                           sourceTint: info.isPluggedIn ? Color.white : info.levelColor,
                           batteryFraction: Double(info.percentage) / 100.0,
                           destinations: destinations)
                .frame(height: 96)

            statusFooter
        }
    }

    // MARK: - Header metrics

    private var metricsHeader: some View {
        VStack(spacing: 5) {
            HStack(alignment: .top) {
                MetricTile(label: "Power Usage", value: number(info.systemLoadWatts, "%.1f"), unit: "W", size: 14)
                MetricTile(label: "Voltage", value: number(info.voltage, "%.2f"), unit: "V",
                           alignment: .trailing, size: 14)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CURRENT")
                        .font(PanelFont.eyebrow(8))
                        .tracking(0.5)
                        .foregroundStyle(Color.white.opacity(0.45))
                    HStack(spacing: 5) {
                        Text(currentText)
                            .font(PanelFont.metric(14))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: currentText)
                        if let amps = info.amperage, abs(amps) >= 0.005 {
                            Image(systemName: amps >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(amps >= 0 ? green : Color.white.opacity(0.5))
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: stateIcon)
                            .font(.system(size: 10, weight: .bold))
                        Text(stateText)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(stateColor)
                    if let status = voltageStatus {
                        Text(status.text)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(status.color)
                    }
                }
            }
        }
    }

    private var currentText: String {
        guard let amps = info.amperage else { return "—" }
        return "\(Int((abs(amps) * 1000).rounded())) mA"
    }

    private var stateText: String {
        switch info.state {
        case .charging:    return "Charging"
        case .discharging: return "Discharging"
        case .full:        return "Fully Charged"
        case .notCharging: return "On Adapter"
        case .noBattery:   return "No Battery"
        }
    }

    private var stateIcon: String {
        switch info.state {
        case .charging:    return "bolt.fill"
        case .discharging: return "battery.50percent"
        case .full:        return "checkmark.circle.fill"
        case .notCharging: return "powerplug.fill"
        case .noBattery:   return "questionmark.circle"
        }
    }

    private var stateColor: Color {
        switch info.state {
        case .charging, .full: return green
        case .notCharging:     return Color.orange
        default:               return Color.white.opacity(0.7)
        }
    }

    /// Lithium-ion cells normally sit between ~3.0 V and ~4.45 V.
    private var voltageStatus: (text: String, color: Color)? {
        guard !info.cellVoltages.isEmpty else { return nil }
        let normal = info.cellVoltages.allSatisfy { (3.0...4.45).contains($0) }
        if normal {
            return (text: "Normal voltage", color: green)
        }
        return (text: "Unusual cell voltage", color: Color.orange)
    }

    // MARK: - Flow data

    private var sourceTitle: String {
        if info.isPluggedIn {
            if let rated = info.adapterWatts { return "\(rated)W" }
            return info.inputWatts.map { String(format: "%.0fW", $0) } ?? "AC"
        }
        return "Batt"
    }

    private var destinations: [FlowEndpoint] {
        var list: [FlowEndpoint] = []

        if info.state == .charging, let w = info.batteryWatts, w >= 0.05 {
            list.append(FlowEndpoint(id: "battery",
                                     watts: w,
                                     label: watts(w, approximate: false),
                                     icon: "battery.100percent.bolt",
                                     caption: "Battery",
                                     tint: green,
                                     highlighted: true))
        }

        let macWatts = info.macOwnWatts ?? info.systemLoadWatts ?? 0
        list.append(FlowEndpoint(id: "mac",
                                 watts: Swift.max(macWatts, 0.1),
                                 label: watts(info.macOwnWatts ?? info.systemLoadWatts,
                                              approximate: !info.isPluggedIn && info.batteryPowerMeasured == nil),
                                 icon: "laptopcomputer",
                                 caption: "MacBook",
                                 tint: Color.white,
                                 highlighted: false))

        // Keep: power the Mac is sending out to connected devices.
        if info.accessoryWatts >= 0.05 {
            list.append(FlowEndpoint(id: "devices",
                                     watts: info.accessoryWatts,
                                     label: watts(info.accessoryWatts, approximate: info.accessoryWattsIsEstimate),
                                     icon: devicesIcon,
                                     caption: devicesCaption,
                                     tint: blue,
                                     highlighted: false))
        }
        return list
    }

    private var devicesIcon: String {
        let names = info.poweredAccessories.map { $0.name.lowercased() }
        if names.count == 1, let name = names.first {
            if name.contains("iphone") { return "iphone" }
            if name.contains("ipad") { return "ipad" }
        }
        return "cable.connector"
    }

    private var devicesCaption: String {
        let accessories = info.poweredAccessories
        if accessories.count == 1, let only = accessories.first {
            return only.name.components(separatedBy: " · ").first ?? only.name
        }
        return "\(accessories.count) devices"
    }

    // MARK: - Footer

    private var statusFooter: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                footerIcon
                Text(footerHeadline)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .contentTransition(.numericText())
            }
            if info.state == .notCharging {
                Text(info.holdReason)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            Text(workloadText)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var footerIcon: some View {
        switch info.state {
        case .charging:
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(green)
                .symbolEffect(.pulse, options: .repeating.speed(0.4))
        case .discharging:
            BatteryGlyph(fraction: Double(info.percentage) / 100.0, tint: info.levelColor)
                .scaleEffect(0.8)
        default:
            Image(systemName: "powerplug.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }

    private var footerHeadline: String {
        switch info.state {
        case .charging:
            if let w = info.batteryWatts { return String(format: "Charging at %.0f W", w) }
            return "Charging"
        case .discharging:
            if let w = info.systemLoadWatts { return String(format: "On battery • %.0f W", w) }
            return "On battery"
        case .full:
            if let w = info.inputWatts { return String(format: "On adapter • %.0f W", w) }
            return "On adapter"
        case .notCharging:
            if let w = info.inputWatts { return String(format: "Running on adapter • %.0f W", w) }
            return "Running on adapter"
        case .noBattery:
            return "Running on wall power"
        }
    }

    /// Rough description of what the Mac is doing, based on its own power draw.
    private var workloadText: String {
        guard let w = info.macOwnWatts ?? info.systemLoadWatts else { return " " }
        switch w {
        case ..<6:  return "Light workload: idle or reading"
        case ..<15: return "Moderate workload: browsing or everyday apps"
        case ..<35: return "Active workload: multitasking or media"
        default:    return "Heavy workload: pro apps or gaming"
        }
    }

    // MARK: - Formatting

    private func number(_ value: Double?, _ format: String) -> String {
        guard let value else { return "—" }
        return String(format: format, value)
    }

    private func watts(_ value: Double?, approximate: Bool) -> String {
        guard let value else { return "— W" }
        return (approximate ? "~" : "") + String(format: "%.1f W", value)
    }
}

// MARK: - Sankey diagram

struct FlowEndpoint: Identifiable, Equatable {
    let id: String
    let watts: Double
    let label: String
    let icon: String
    let caption: String
    let tint: Color
    /// Filled with a strong color gradient (the battery while charging).
    let highlighted: Bool
}

struct SankeyFlowView: View {
    let sourceIcon: String?
    let sourceTitle: String
    let sourceSubtitle: String?
    let sourceTint: Color
    let batteryFraction: Double
    let destinations: [FlowEndpoint]

    private let boxWidth: CGFloat = 46
    private let gap: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let layout = SankeyLayout(size: geo.size, boxWidth: boxWidth, gap: gap,
                                      watts: destinations.map { $0.watts })
            ZStack(alignment: .topLeading) {
                ribbons(layout: layout)

                sourceBox
                    .frame(width: boxWidth, height: geo.size.height)
                    .position(x: boxWidth / 2, y: geo.size.height / 2)

                ForEach(Array(destinations.enumerated()), id: \.element.id) { index, destination in
                    let rect = layout.destinationRect(index)
                    destinationBox(destination)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity)

                    Text(destination.label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.95))
                        .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                        .contentTransition(.numericText())
                        .fixedSize()
                        .position(layout.labelPoint(index))
                }
            }
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: destinations.map { $0.id })
        }
    }

    // MARK: Ribbons

    private func ribbons(layout: SankeyLayout) -> some View {
        // 6 fps is plenty here: the shimmer has a 5-second period and the
        // ripple is purely decorative, so redrawing the whole Canvas 30 times
        // a second burns CPU/GPU (and battery) with no visible benefit.
        TimelineView(.animation(minimumInterval: 1.0 / 6.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let fromX = layout.ribbonStartX
                let toX = layout.ribbonEndX

                for (index, destination) in destinations.enumerated() {
                    let ribbon = layout.ribbonPath(index)

                    // Base glass / color fill, fading toward the destination.
                    let colors: [Color] = destination.highlighted
                        ? [destination.tint.opacity(0.95), destination.tint.opacity(0.55), Color.white.opacity(0.14)]
                        : [Color.white.opacity(0.30), Color.white.opacity(0.16), Color.white.opacity(0.10)]
                    context.fill(ribbon,
                                 with: .linearGradient(Gradient(colors: colors),
                                                       startPoint: CGPoint(x: fromX, y: 0),
                                                       endPoint: CGPoint(x: toX, y: 0)))
                    if !destination.highlighted && destination.tint != Color.white {
                        context.fill(ribbon, with: .color(destination.tint.opacity(0.14)))
                    }

                    // Slow liquid shimmer drifting along the ribbon.
                    var liquid = context
                    liquid.clip(to: ribbon)
                    let span = toX - fromX
                    let period = 5.0
                    let phase = (t / period + Double(index) * 0.33).truncatingRemainder(dividingBy: 1.0)
                    let center = fromX - 50 + (span + 100) * CGFloat(phase)
                    liquid.fill(Path(CGRect(x: center - 50, y: 0, width: 100, height: size.height)),
                                with: .linearGradient(Gradient(colors: [Color.white.opacity(0),
                                                                        Color.white.opacity(0.18),
                                                                        Color.white.opacity(0)]),
                                                      startPoint: CGPoint(x: center - 50, y: 0),
                                                      endPoint: CGPoint(x: center + 50, y: 0)))

                    // Gentle ripple along the top edge.
                    let ripplePhase = t * 0.8 + Double(index)
                    var ripple = Path()
                    let range = layout.leftRange(index)
                    var x = fromX + 12
                    ripple.move(to: CGPoint(x: x, y: range.top + 3))
                    while x < fromX + span * 0.22 {
                        x += 3
                        let y = range.top + 3 + CGFloat(sin(Double(x) / 7.0 + ripplePhase)) * 0.8
                        ripple.addLine(to: CGPoint(x: x, y: y))
                    }
                    liquid.stroke(ripple, with: .color(Color.white.opacity(0.22)), lineWidth: 0.8)

                    // Soft rim.
                    context.stroke(ribbon, with: .color(Color.white.opacity(0.10)), lineWidth: 0.8)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Boxes

    private var sourceBox: some View {
        VStack(spacing: 6) {
            if let sourceIcon {
                Image(systemName: sourceIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(sourceTint)
            } else {
                BatteryGlyph(fraction: batteryFraction, tint: sourceTint)
            }
            Text(sourceTitle)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if let sourceSubtitle {
                Text(sourceSubtitle)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(sourceTint)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(glassBox)
    }

    private func destinationBox(_ destination: FlowEndpoint) -> some View {
        VStack(spacing: 2) {
            Image(safeSystemName: destination.icon, fallback: "bolt.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(destination.highlighted ? destination.tint : Color.white.opacity(0.8))
            Text(destination.caption)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(glassBox)
    }

    private var glassBox: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
    }
}

/// Geometry shared by the ribbon drawing and the label / box overlay.
struct SankeyLayout {
    let size: CGSize
    let boxWidth: CGFloat
    let gap: CGFloat
    let watts: [Double]

    private var count: Int { Swift.max(watts.count, 1) }

    var ribbonStartX: CGFloat { boxWidth + 4 }
    var ribbonEndX: CGFloat { size.width - boxWidth - 4 }

    func destinationRect(_ index: Int) -> CGRect {
        let height = (size.height - gap * CGFloat(count - 1)) / CGFloat(count)
        return CGRect(x: size.width - boxWidth,
                      y: CGFloat(index) * (height + gap),
                      width: boxWidth,
                      height: height)
    }

    /// Ribbon thickness at the source side, proportional to watts.
    private var leftThickness: [CGFloat] {
        let n = watts.count
        guard n > 0 else { return [] }
        let available = size.height - gap * CGFloat(n - 1)
        let total = watts.reduce(0, +)
        let minimum: CGFloat = 16
        let raw: [CGFloat] = watts.map { w in
            guard total > 0 else { return available / CGFloat(n) }
            return Swift.max(minimum, available * CGFloat(w / total))
        }
        let sum = raw.reduce(0, +)
        guard sum > 0 else { return raw }
        return raw.map { $0 * available / sum }
    }

    func leftRange(_ index: Int) -> (top: CGFloat, bottom: CGFloat) {
        let thickness = leftThickness
        guard index < thickness.count else { return (0, 0) }
        var y: CGFloat = 0
        for j in 0..<index { y += thickness[j] + gap }
        return (y, y + thickness[index])
    }

    func rightRange(_ index: Int) -> (top: CGFloat, bottom: CGFloat) {
        let rect = destinationRect(index)
        return (rect.minY, rect.maxY)
    }

    func ribbonPath(_ index: Int) -> Path {
        let left = leftRange(index)
        let right = rightRange(index)
        let x0 = ribbonStartX
        let x1 = ribbonEndX
        let span = x1 - x0
        let bendStart = x0 + span * 0.22
        let bendEnd = x0 + span * 0.62
        let mid = (bendStart + bendEnd) / 2
        let rl = Swift.min(10, (left.bottom - left.top) / 2)
        let rr = Swift.min(10, (right.bottom - right.top) / 2)

        var p = Path()
        p.move(to: CGPoint(x: x0 + rl, y: left.top))
        p.addLine(to: CGPoint(x: bendStart, y: left.top))
        p.addCurve(to: CGPoint(x: bendEnd, y: right.top),
                   control1: CGPoint(x: mid, y: left.top),
                   control2: CGPoint(x: mid, y: right.top))
        p.addLine(to: CGPoint(x: x1 - rr, y: right.top))
        p.addQuadCurve(to: CGPoint(x: x1, y: right.top + rr), control: CGPoint(x: x1, y: right.top))
        p.addLine(to: CGPoint(x: x1, y: right.bottom - rr))
        p.addQuadCurve(to: CGPoint(x: x1 - rr, y: right.bottom), control: CGPoint(x: x1, y: right.bottom))
        p.addLine(to: CGPoint(x: bendEnd, y: right.bottom))
        p.addCurve(to: CGPoint(x: bendStart, y: left.bottom),
                   control1: CGPoint(x: mid, y: right.bottom),
                   control2: CGPoint(x: mid, y: left.bottom))
        p.addLine(to: CGPoint(x: x0 + rl, y: left.bottom))
        p.addQuadCurve(to: CGPoint(x: x0, y: left.bottom - rl), control: CGPoint(x: x0, y: left.bottom))
        p.addLine(to: CGPoint(x: x0, y: left.top + rl))
        p.addQuadCurve(to: CGPoint(x: x0 + rl, y: left.top), control: CGPoint(x: x0, y: left.top))
        p.closeSubpath()
        return p
    }

    /// Where the watt label sits: in the wide section just before the destination.
    func labelPoint(_ index: Int) -> CGPoint {
        let right = rightRange(index)
        let x0 = ribbonStartX
        let x1 = ribbonEndX
        return CGPoint(x: x0 + (x1 - x0) * 0.72, y: (right.top + right.bottom) / 2)
    }
}
