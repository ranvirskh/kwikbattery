//
//  AppEnergyMonitor.swift
//  KwikBattery
//
//  "Top Energy Users": which apps are using the most power right now.
//
//  macOS has no public per-app watt API. We use the same "Energy Impact"
//  score Activity Monitor shows, sampled with the built-in `top` tool:
//
//      top -l 2 -s 1 -o power -stats pid,power,command -n 40
//
//  (two samples one second apart; the second one has meaningful values).
//  Helper processes are grouped under the app bundle they live in, so all
//  the "Google Chrome Helper" processes count toward "Google Chrome".
//  Each app's share of the total score is also turned into an approximate
//  wattage using the Mac's live system power.
//

import AppKit
import Combine
import Darwin

struct AppEnergyUsage: Identifiable, Equatable {
    let id: String          // bundle path, or process name for non-app processes
    let name: String
    let appPath: String?
    let impact: Double      // Activity Monitor "Energy Impact" score
    let percent: Double     // share of the whole Mac's energy impact, 0–100
}

@MainActor
final class AppEnergyMonitor: ObservableObject {
    static let shared = AppEnergyMonitor()

    @Published private(set) var apps: [AppEnergyUsage] = []
    @Published private(set) var hasLoaded = false

    private var timer: AnyCancellable?
    private var isSampling = false
    private var iconCache: [String: NSImage] = [:]

    private init() {}

    /// Sample every few seconds while the dropdown is open.
    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            sample()
            timer = Timer.publish(every: 4, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.sample() }
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    func icon(for app: AppEnergyUsage) -> NSImage {
        let key = app.appPath ?? "__generic__"
        if let cached = iconCache[key] { return cached }
        let image: NSImage
        if let path = app.appPath {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil) ?? NSImage()
        }
        iconCache[key] = image
        return image
    }

    private func sample() {
        guard !isSampling else { return }
        isSampling = true
        Task {
            let result = await Self.loadUsage()
            self.apps = result
            self.hasLoaded = true
            self.isSampling = false
        }
    }

    // MARK: - Sampling (off the main actor)

    nonisolated static func loadUsage() async -> [AppEnergyUsage] {
        guard let output = runTop() else { return [] }
        let processes = parseTop(output)

        // Total across *every* process, so percentages are "share of the Mac".
        let grandTotal = processes
            .filter { $0.command != "top" }
            .reduce(0) { $0 + Swift.max(0, $1.impact) }
        guard grandTotal > 0 else { return [] }

        var totals: [String: (name: String, path: String?, impact: Double)] = [:]
        for process in processes where process.impact > 0 {
            if process.command == "top" { continue }
            let appPath = enclosingAppPath(for: process.pid)
            let key = appPath ?? process.command
            let name = appPath.map { displayName(forAppAt: $0) } ?? friendlyProcessName(process.command)
            var entry = totals[key] ?? (name: name, path: appPath, impact: 0)
            entry.impact += process.impact
            totals[key] = entry
        }

        // Apps only: skip background system processes that aren't inside an .app.
        return totals
            .filter { $0.value.path != nil }
            .map { entry in
                AppEnergyUsage(id: entry.key,
                               name: entry.value.name,
                               appPath: entry.value.path,
                               impact: entry.value.impact,
                               percent: entry.value.impact / grandTotal * 100)
            }
            .filter { $0.percent >= 0.5 }
            .sorted { $0.impact > $1.impact }
            .prefix(5)
            .map { $0 }
    }

    struct ProcessSample {
        let pid: pid_t
        let impact: Double
        let command: String
    }

    nonisolated static func runTop() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "2", "-s", "1", "-o", "power", "-stats", "pid,power,command", "-n", "40"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Parses the *last* sample's process table: "PID  POWER  COMMAND".
    nonisolated static func parseTop(_ output: String) -> [ProcessSample] {
        let lines = output.components(separatedBy: .newlines)
        guard let headerIndex = lines.lastIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("PID") && trimmed.contains("POWER")
        }) else { return [] }

        var result: [ProcessSample] = []
        for line in lines[(headerIndex + 1)...] {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = pid_t(parts[0]),
                  let impact = Double(parts[1]) else { continue }
            let command = String(parts[2]).trimmingCharacters(in: .whitespaces)
            result.append(ProcessSample(pid: pid, impact: impact, command: command))
        }
        return result
    }

    /// "/Applications/Google Chrome.app/Contents/…/Helper" → "/Applications/Google Chrome.app"
    nonisolated static func enclosingAppPath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app") : nil) else {
            return nil
        }
        // Outermost bundle (the first ".app" in the path).
        return String(path[path.startIndex..<range.upperBound]).replacingOccurrences(of: ".app/", with: ".app")
    }

    nonisolated static func displayName(forAppAt path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let bundle = Bundle(url: url) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    nonisolated static func friendlyProcessName(_ command: String) -> String {
        switch command {
        case "kernel_task":   return "macOS (kernel)"
        case "WindowServer":  return "Display (WindowServer)"
        case "mds", "mds_stores", "mdworker_shared": return "Spotlight indexing"
        case "backupd":       return "Time Machine"
        default:              return command
        }
    }
}
