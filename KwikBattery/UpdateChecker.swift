//
//  UpdateChecker.swift
//  KwikBattery
//
//  Checks GitHub Releases for a newer version and, once the user agrees,
//  downloads it, verifies it and swaps the app in place.
//
//  Deliberately simple and transparent:
//   • One unauthenticated GET to the public releases API, at most once a day.
//   • Nothing is downloaded until the user clicks Update and confirms.
//   • The download must be a .zip from this repo's release assets, served over
//     HTTPS. After unzipping we check it really is KwikBattery.app and that its
//     code signature is intact before replacing anything.
//   • The running copy is moved aside (not deleted) until the swap succeeds.
//

import AppKit
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String, url: URL)
        case downloading(progress: Double)
        case readyToRelaunch
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// github.com/<owner>/<repo> — same repo the app is published from.
    private let owner = "ranvirskh"
    private let repo = "kwikbattery"

    private let lastCheckKey = "update.lastCheck"
    private let skippedVersionKey = "update.skippedVersion"

    private init() {}

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// Called at launch and when the popover opens; only hits the network once a day.
    func checkIfDue() {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        check()
    }

    func check() {
        guard case .downloading = state else {
            Task { await performCheck() }
            return
        }
    }

    private func performCheck() async {
        state = .checking
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)

        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            state = .failed("Bad update URL")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KwikBattery/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .failed("GitHub returned an error")
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                state = .failed("Unexpected response")
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = (json["body"] as? String) ?? ""

            // The downloadable app must be a .zip asset on the release itself.
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let zip = assets.first { asset in
                let name = (asset["name"] as? String)?.lowercased() ?? ""
                return name.hasSuffix(".zip") && name.contains("kwikbattery")
            }
            guard Self.isNewer(latest, than: currentVersion) else {
                state = .upToDate
                return
            }
            guard let urlString = zip?["browser_download_url"] as? String,
                  let assetURL = URL(string: urlString),
                  assetURL.scheme == "https",
                  assetURL.host?.hasSuffix("github.com") == true || assetURL.host?.hasSuffix("githubusercontent.com") == true else {
                state = .failed("No download found for \(latest)")
                return
            }
            if UserDefaults.standard.string(forKey: skippedVersionKey) == latest {
                state = .idle
                return
            }
            state = .available(version: latest, notes: notes, url: assetURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func skipCurrentOffer() {
        if case .available(let version, _, _) = state {
            UserDefaults.standard.set(version, forKey: skippedVersionKey)
        }
        state = .idle
    }

    func dismiss() {
        state = .idle
    }

    // MARK: - Download & install

    /// Downloads the release zip, checks it, and swaps it with the running app.
    func downloadAndInstall() {
        guard case .available(let version, _, let url) = state else { return }
        state = .downloading(progress: 0)

        Task {
            do {
                let (temporaryFile, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    state = .failed("Download failed")
                    return
                }
                state = .downloading(progress: 0.7)

                let installed = try await Task.detached(priority: .userInitiated) {
                    try UpdateChecker.installUpdate(from: temporaryFile, version: version)
                }.value

                state = installed ? .readyToRelaunch : .failed("Could not install the update")
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Unzips, validates and replaces the running bundle. Runs off the main actor.
    nonisolated static func installUpdate(from archive: URL, version: String) throws -> Bool {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("KwikBatteryUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Unzip with the system tool (handles Apple's archive quirks).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { return false }

        // It must contain exactly the app we expect.
        let contents = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.lastPathComponent == "KwikBattery.app" }) else {
            return false
        }
        guard let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return false
        }

        // The signature must be intact — catches a corrupted or tampered download.
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", newApp.path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { return false }

        // Swap: keep the old copy aside until the new one is in place.
        let installedURL = Bundle.main.bundleURL
        let backup = work.appendingPathComponent("previous.app")
        if fm.fileExists(atPath: installedURL.path) {
            try? fm.moveItem(at: installedURL, to: backup)
        }
        do {
            try fm.copyItem(at: newApp, to: installedURL)
        } catch {
            // Put the original back if the copy failed.
            if fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: installedURL)
            }
            throw error
        }
        return true
    }

    /// Quits and relaunches the freshly installed copy.
    func relaunch() {
        let path = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Compares dotted versions numerically: "1.10" is newer than "1.9".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
