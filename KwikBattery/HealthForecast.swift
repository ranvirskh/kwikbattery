//
//  HealthForecast.swift
//  KwikBattery
//
//  Where is battery health heading? A straight-line fit through the daily
//  health readings (HealthHistory), turned into "about X% a month" and "reaches
//  80% around <date>". 80% is where Apple considers a Mac battery worn enough
//  to service.
//
//  Foundation only, so it compiles into the insights tests.
//

import Foundation

enum HealthForecast {
    struct Reading: Equatable {
        let date: Date
        let health: Double
        let cycles: Int
    }

    enum Confidence: String, Equatable {
        /// Under 6 weeks of data, or the readings scatter widely.
        case low
        case fair
        case good
    }

    struct Result: Equatable {
        /// Fitted change per 30 days; negative means health is falling.
        let percentPerMonth: Double
        let cyclesPerMonth: Double
        /// Health lost per 100 charge cycles, when cycles were added over the span.
        let percentPer100Cycles: Double?
        /// The fitted health today (smooths out day-to-day measurement noise).
        let fittedHealth: Double
        let spanDays: Int
        let confidence: Confidence
        /// Days until the fitted line reaches the target; 0 if already there.
        /// nil when health isn't falling measurably, or the date is over 20 years out.
        let daysToTarget: Int?
        let targetDate: Date?
        /// True when the line is flat enough that no date is worth quoting.
        let isSteady: Bool
    }

    /// Fewer points or a shorter span than this and any slope is noise.
    static let minimumPoints = 5
    static let minimumSpanDays = 21
    /// A fall slower than this (about 0.1% a year) counts as steady.
    static let steadyPerDay = 0.1 / 365.0
    static let farFutureDays = 20 * 365

    static func forecast(_ readings: [Reading], now: Date = Date(), target: Double = 80) -> Result? {
        let sorted = readings
            .filter { $0.health.isFinite && $0.health > 0 && $0.health < 200 }
            .sorted { $0.date < $1.date }
        guard sorted.count >= minimumPoints, let first = sorted.first, let last = sorted.last else { return nil }
        let spanSeconds = last.date.timeIntervalSince(first.date)
        let spanDays = spanSeconds / 86400
        guard spanDays >= Double(minimumSpanDays) else { return nil }

        let xs = sorted.map { $0.date.timeIntervalSince(first.date) / 86400 }
        let ys = sorted.map(\.health)
        guard let fit = leastSquares(xs, ys) else { return nil }

        let lastX = xs[xs.count - 1]
        let fitted = fit.intercept + fit.slope * lastX

        // Cycles: same fit, for the rate.
        let cycleFit = leastSquares(xs, sorted.map { Double($0.cycles) })
        let cyclesPerDay = Swift.max(0, cycleFit?.slope ?? 0)

        var per100: Double?
        if cyclesPerDay > 0.01, fit.slope < 0 {
            per100 = fit.slope / cyclesPerDay * 100
        }

        let confidence: Confidence
        if spanDays >= 90, fit.r2 >= 0.5 { confidence = .good }
        else if spanDays >= 42, fit.r2 >= 0.2 || abs(fit.slope) < steadyPerDay { confidence = .fair }
        else { confidence = .low }

        let steady = fit.slope > -steadyPerDay
        var daysTo: Int?
        var targetDate: Date?
        if fitted <= target {
            daysTo = 0
            targetDate = now
        } else if !steady {
            let days = (fitted - target) / -fit.slope
            if days.isFinite, days <= Double(farFutureDays) {
                daysTo = Int(days.rounded())
                targetDate = now.addingTimeInterval(days * 86400)
            }
        }

        return Result(percentPerMonth: fit.slope * 30,
                      cyclesPerMonth: cyclesPerDay * 30,
                      percentPer100Cycles: per100,
                      fittedHealth: fitted,
                      spanDays: Int(spanDays.rounded()),
                      confidence: confidence,
                      daysToTarget: daysTo,
                      targetDate: targetDate,
                      isSteady: steady)
    }

    /// Plain-language read-out for the Health panel.
    static func summary(_ r: Result, target: Double = 80, calendar: Calendar = .current) -> String {
        let rate = String(format: "%.1f", abs(r.percentPerMonth))
        var text: String
        if let days = r.daysToTarget, days == 0 {
            text = "Health is at or below \(Int(target))% on the trend line."
        } else if r.isSteady {
            text = "Health is holding steady (\(rate)% a month on the trend line)."
        } else if let date = r.targetDate, let days = r.daysToTarget {
            text = "Falling about \(rate)% a month. On this trend it reaches \(Int(target))% around \(monthYear(date, calendar: calendar))"
            text += days < 60 ? " (soon)." : "."
        } else {
            text = "Health is falling very slowly: more than 20 years from \(Int(target))% on this trend."
        }
        if r.confidence == .low {
            text += " Early estimate: it firms up with more weeks of readings."
        }
        return text
    }

    static func monthYear(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        let names = ["January", "February", "March", "April", "May", "June", "July",
                     "August", "September", "October", "November", "December"]
        let month = Swift.min(Swift.max((c.month ?? 1) - 1, 0), 11)
        return "\(names[month]) \(c.year ?? 0)"
    }

    struct Fit {
        let slope: Double
        let intercept: Double
        let r2: Double
    }

    /// Ordinary least squares y = intercept + slope·x. nil if x has no spread.
    static func leastSquares(_ xs: [Double], _ ys: [Double]) -> Fit? {
        let n = Double(xs.count)
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - meanX) * (x - meanX)
            sxy += (x - meanX) * (y - meanY)
            syy += (y - meanY) * (y - meanY)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 0
        return Fit(slope: slope, intercept: intercept, r2: r2)
    }
}
