//
//  UsagePing.swift
//  KwikBattery
//
//  An anonymous, once-a-day "someone is using KwikBattery" count, so the developer
//  can tell roughly how many people use the app.
//
//  What is sent: one HTTPS GET to the developer's own counter containing the app
//  version in the URL path, e.g. /launch/1.7.1. That's all. There is no install ID,
//  no account, no battery or device data, no cookies, and nothing is stored on the
//  Mac beyond the time of the last ping. The counter can only count distinct
//  visitors the way any web server can (from the request itself).
//
//  It is ON by default, announced once with a notice when it first applies, and
//  can be switched off at any time in Settings → General. When off, nothing at all
//  is sent.
//

import AppKit
import Foundation

enum UsagePing {
    /// The counter host (a GoatCounter site). Empty = not configured = nothing is ever sent.
    static let counterHost = "kiwkbattery.goatcounter.com"

    private static let lastPingKey = "usage.lastPing"
    private static let noticeShownKey = "usage.noticeShown"

    static var isEnabled: Bool { AppSettings.shareUsageCount }

    /// Shows the one-time notice, then sends today's count if it's due.
    @MainActor
    static func start() {
        guard !counterHost.isEmpty else { return }
        showNoticeIfNeeded()
        pingIfDue()
    }

    @MainActor
    private static func showNoticeIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: noticeShownKey) else { return }
        defaults.set(true, forKey: noticeShownKey)

        let alert = NSAlert()
        alert.messageText = "Anonymous usage count"
        alert.informativeText = """
        So the developer can see roughly how many people use KwikBattery, it now sends one \
        anonymous request per day containing only the app version.

        No battery data, no device information, no account and no personal details are sent. \
        You can turn this off any time in Settings → General.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Turn Off")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            AppSettings.setShareUsageCount(false)
        }
    }

    @MainActor
    private static func pingIfDue() {
        guard isEnabled, !counterHost.isEmpty else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastPingKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = counterHost
        parts.path = "/count"
        parts.queryItems = [URLQueryItem(name: "p", value: "/launch/\(version)")]
        guard let url = parts.url else { return }

        // Ephemeral session: no cookies, no cache, no credentials.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        var request = URLRequest(url: url)
        request.setValue("KwikBattery/\(version)", forHTTPHeaderField: "User-Agent")

        URLSession(configuration: config).dataTask(with: request) { _, response, _ in
            // Only count the day as done if the counter actually answered.
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                UserDefaults.standard.set(Date(), forKey: lastPingKey)
            }
        }.resume()
    }
}
