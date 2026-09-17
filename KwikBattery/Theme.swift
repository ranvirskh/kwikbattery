//
//  Theme.swift
//  KwikBattery
//
//  State-driven color palette + small reusable styling helpers.
//

import SwiftUI

struct StateTheme: Equatable {
    let primary: Color
    let secondary: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var verticalGradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .top, endPoint: .bottom)
    }

    static let charging = StateTheme(primary: Color(red: 0.20, green: 0.85, blue: 0.47),
                                     secondary: Color(red: 0.02, green: 0.62, blue: 0.56))
    static let full     = StateTheme(primary: Color(red: 0.27, green: 0.65, blue: 1.00),
                                     secondary: Color(red: 0.40, green: 0.38, blue: 0.96))
    static let paused   = StateTheme(primary: Color(red: 1.00, green: 0.74, blue: 0.24),
                                     secondary: Color(red: 0.98, green: 0.47, blue: 0.20))
    static let normal   = StateTheme(primary: Color(red: 0.16, green: 0.80, blue: 0.78),
                                     secondary: Color(red: 0.16, green: 0.52, blue: 0.96))
    static let medium   = StateTheme(primary: Color(red: 1.00, green: 0.80, blue: 0.20),
                                     secondary: Color(red: 0.98, green: 0.58, blue: 0.16))
    static let low      = StateTheme(primary: Color(red: 1.00, green: 0.33, blue: 0.36),
                                     secondary: Color(red: 0.86, green: 0.16, blue: 0.45))
    static let neutral  = StateTheme(primary: Color.gray, secondary: Color.gray.opacity(0.6))
}

extension BatteryInfo {
    /// Green above 20%, orange 20–10%, red below 10%; green while charging.
    var theme: StateTheme {
        if !hasBattery { return .neutral }
        if state == .charging { return .charging }
        if percentage < 10 { return .low }
        if percentage <= 20 { return .paused }
        return .charging
    }

    var levelColor: Color {
        Color(nsColor: BatteryLevelColor.nsColor(percentage: percentage, isCharging: state == .charging))
    }

    /// Short status label for the panel's pill.
    var shortStatus: String {
        switch state {
        case .charging:    return "Charging"
        case .discharging: return "On Battery"
        case .full:        return "Fully Charged"
        case .notCharging: return "Plugged In"
        case .noBattery:   return "No Battery"
        }
    }

    var statusIcon: String {
        switch state {
        case .charging:    return "bolt.fill"
        case .discharging: return "battery.75percent"
        case .full:        return "checkmark.circle.fill"
        case .notCharging: return "powerplug.fill"
        case .noBattery:   return "questionmark.circle"
        }
    }
}

// MARK: - Card styling

struct CardBackground: ViewModifier {
    var tint: Color = .clear
    var highlighted: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(highlighted ? 0.08 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(highlighted ? 0.55 : 0.14), lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(tint: Color = .primary, highlighted: Bool = false) -> some View {
        modifier(CardBackground(tint: tint, highlighted: highlighted))
    }

    /// Fades + slides a view in the first time it appears.
    func appearEffect(delay: Double = 0) -> some View {
        modifier(AppearEffect(delay: delay))
    }
}

struct AppearEffect: ViewModifier {
    let delay: Double
    @State var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 10)
            .scaleEffect(visible ? 1 : 0.97)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(delay)) {
                    visible = true
                }
            }
            .onDisappear { visible = false }
    }
}
