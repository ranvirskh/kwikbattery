//
//  PanelComponents.swift
//  KwikBattery
//
//  Reusable building blocks for the dark dropdown panel.
//

import SwiftUI
import AppKit

// MARK: - Typography

enum PanelFont {
    static func hero(_ size: CGFloat = 54) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func title(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    static func caption(_ size: CGFloat = 10.5) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    static func metric(_ size: CGFloat = 18) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
    static func eyebrow(_ size: CGFloat = 9.5) -> Font { .system(size: size, weight: .bold, design: .rounded) }
}

// MARK: - SF Symbol with fallback

extension Image {
    /// Uses `name` when this macOS has it, otherwise `fallback`.
    init(safeSystemName name: String, fallback: String) {
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            self.init(systemName: name)
        } else {
            self.init(systemName: fallback)
        }
    }
}

// MARK: - Collapsible section card

struct PanelSection<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @Binding var isExpanded: Bool
    let content: () -> Content

    init(_ title: String,
         icon: String,
         tint: Color,
         isExpanded: Binding<Bool>,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(tint.gradient))
                    Text(title)
                        .font(PanelFont.title(13))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .rotationEffect(.degrees(isExpanded ? 0 : 180))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
                content()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Bars

/// Rounded progress bar that animates to its value, with optional quarter ticks.
struct LevelBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 8
    var showTicks: Bool = false

    @State var shown: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: Swift.max(height, geo.size.width * CGFloat(shown)))
                    .shadow(color: tint.opacity(0.45), radius: 6)
                if showTicks {
                    ForEach([0.25, 0.5, 0.75], id: \.self) { tick in
                        Rectangle()
                            .fill(Color.black.opacity(0.35))
                            .frame(width: 1.5, height: height)
                            .offset(x: geo.size.width * CGFloat(tick))
                    }
                }
            }
        }
        .frame(height: height)
        .onAppear {
            shown = 0
            withAnimation(.spring(response: 1.0, dampingFraction: 0.85).delay(0.08)) {
                shown = clamp(fraction)
            }
        }
        .onChange(of: fraction) {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                shown = clamp(fraction)
            }
        }
    }

    private func clamp(_ v: Double) -> Double {
        Swift.min(Swift.max(v, 0), 1)
    }
}

// MARK: - Metric tile (monospaced electrical values)

struct MetricTile: View {
    let label: String
    let value: String
    var unit: String = ""
    var tint: Color = .white
    var alignment: HorizontalAlignment = .leading
    var size: CGFloat = 14

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label.uppercased())
                .font(PanelFont.eyebrow(8))
                .tracking(0.5)
                .foregroundStyle(Color.white.opacity(0.45))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(PanelFont.metric(size))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: size * 0.62, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .animation(.snappy, value: value)
    }
}

// MARK: - Small battery glyph (SwiftUI)

struct BatteryGlyph: View {
    let fraction: Double
    let tint: Color
    var isCharging: Bool = false

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(tint.opacity(0.55), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: Swift.max(2, 17 * CGFloat(Swift.min(Swift.max(fraction, 0), 1))))
                    .padding(2)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 22, height: 11)
            RoundedRectangle(cornerRadius: 1)
                .fill(tint.opacity(0.55))
                .frame(width: 1.8, height: 4)
        }
    }
}

// MARK: - Buttons

struct CircleIconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void

    @State var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct StatusBadge: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(tint)
    }
}

// MARK: - Compact info tile

struct InfoTile<Footer: View>: View {
    let icon: String
    let label: String
    let value: String
    let tint: Color
    let footer: () -> Footer

    @State private var hovering = false

    init(icon: String, label: String, value: String, tint: Color,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.icon = icon
        self.label = label
        self.value = value
        self.tint = tint
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                Text(label.uppercased())
                    .font(PanelFont.eyebrow(8))
                    .tracking(0.5)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            footer()
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(tint.opacity(hovering ? 0.45 : 0.12), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

extension InfoTile where Footer == Text {
    init(icon: String, label: String, value: String, tint: Color, caption: String) {
        self.init(icon: icon, label: label, value: value, tint: tint) {
            Text(caption)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }
}
