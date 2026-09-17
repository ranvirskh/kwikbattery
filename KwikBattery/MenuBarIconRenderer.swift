//
//  MenuBarIconRenderer.swift
//  KwikBattery
//
//  Draws the menu bar battery, iPhone-style:
//   • the percentage number sits inside the battery
//   • the fill moves in 10% increments
//   • green above 20%, orange 20–10%, red below 10% (always green while charging)
//   • a small lightning bolt next to the battery while charging
//

import AppKit

enum BatteryLevelColor {
    /// Level thresholds shared by the menu bar icon and the dropdown.
    static func nsColor(percentage: Int, isCharging: Bool) -> NSColor {
        if isCharging { return .systemGreen }
        if percentage < 10 { return .systemRed }
        if percentage <= 20 { return .systemOrange }
        return .systemGreen
    }
}

enum MenuBarIconRenderer {

    /// Fill level rounded to the nearest 10% (never fully empty while > 0%).
    static func steppedFraction(for percentage: Int) -> CGFloat {
        let clamped = Swift.min(Swift.max(percentage, 0), 100)
        var stepped = Int((Double(clamped) / 10.0).rounded()) * 10
        if stepped == 0 && clamped > 0 { stepped = 5 }
        return CGFloat(stepped) / 100.0
    }

    static func image(percentage: Int,
                      state: ChargingState,
                      tint: NSColor,
                      showPercentage: Bool) -> NSImage {
        let isCharging = (state == .charging)
        let fraction = steppedFraction(for: percentage)

        let bodySize = NSSize(width: 27, height: 13)
        let capWidth: CGFloat = 2
        let boltWidth: CGFloat = isCharging ? 8 : 0
        let size = NSSize(width: bodySize.width + capWidth + 2 + boltWidth, height: 14)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }

            let bodyRect = NSRect(x: 0.5, y: 0.5, width: bodySize.width, height: bodySize.height)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 4.2, yRadius: 4.2)

            // Track (empty part): a translucent gray that reads on light & dark menu bars.
            NSColor.systemGray.withAlphaComponent(0.45).setFill()
            bodyPath.fill()

            // Level fill, clipped to the rounded body.
            let fillRect = NSRect(x: bodyRect.minX, y: bodyRect.minY,
                                  width: bodyRect.width * fraction, height: bodyRect.height)
            cg.saveGState()
            bodyPath.addClip()
            tint.setFill()
            NSBezierPath(rect: fillRect).fill()
            cg.restoreGState()

            // Terminal cap
            let cap = NSBezierPath(roundedRect: NSRect(x: bodyRect.maxX + 1.2, y: 4.5, width: capWidth, height: 5),
                                   xRadius: 1, yRadius: 1)
            (fraction >= 1 ? tint : NSColor.systemGray.withAlphaComponent(0.6)).setFill()
            cap.fill()

            // Percentage text inside the battery.
            if showPercentage {
                let text = "\(percentage)"
                let pointSize: CGFloat = percentage >= 100 ? 8.5 : 9.5
                let base = NSFont.systemFont(ofSize: pointSize, weight: .heavy)
                let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? base

                let string = NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.white,
                ])
                let textSize = string.size()
                let origin = NSPoint(x: bodyRect.midX - textSize.width / 2,
                                     y: bodyRect.midY - font.capHeight / 2 + font.descender)
                // Soft shadow keeps white digits legible on green/orange/gray.
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.2,
                             color: NSColor.black.withAlphaComponent(0.55).cgColor)
                string.draw(at: origin)
                cg.restoreGState()
            }

            // Charging bolt to the right of the battery.
            if isCharging {
                let x = bodyRect.maxX + capWidth + 3
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: x + 4.6, y: 13.6))
                bolt.line(to: NSPoint(x: x + 0.2, y: 6.2))
                bolt.line(to: NSPoint(x: x + 3.3, y: 6.2))
                bolt.line(to: NSPoint(x: x + 2.4, y: 0.4))
                bolt.line(to: NSPoint(x: x + 6.8, y: 7.8))
                bolt.line(to: NSPoint(x: x + 3.7, y: 7.8))
                bolt.close()
                tint.setFill()
                bolt.fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Battery \(percentage)%"
        return image
    }
}
