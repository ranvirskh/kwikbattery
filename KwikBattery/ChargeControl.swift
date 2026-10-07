//
//  ChargeControl.swift
//  KwikBattery
//
//  App-side connection to the privileged helper (kwikbatteryd). The app never
//  writes to the SMC itself: it sends the user's settings to the helper over a
//  local Unix socket and shows what the helper reports back. If the helper isn't
//  installed, everything else in KwikBattery works exactly as before.
//

import Foundation
import AppKit
import Combine
import Darwin

/// Blocking request/response over the helper's Unix socket (one JSON line each way).
enum HelperSocket {
    static func send(_ request: HelperRequest) -> HelperStatus? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = HelperPaths.socket.withCString { strlcpy(&addr.sun_path.0, $0, MemoryLayout.size(ofValue: addr.sun_path)) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, var payload = try? JSONEncoder().encode(request) else { return nil }
        payload.append(0x0A)
        let sent = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        guard sent == payload.count else { return nil }

        var data = Data()
        var byte: UInt8 = 0
        while data.count < 262_144, read(fd, &byte, 1) == 1, byte != 0x0A { data.append(byte) }
        return try? JSONDecoder().decode(HelperStatus.self, from: data)
    }
}

@MainActor
final class ChargeControl: ObservableObject {
    static let shared = ChargeControl()

    @Published private(set) var status: HelperStatus?
    @Published private(set) var reachable = false
    @Published private(set) var installMessage: String?
    @Published private(set) var installing = false
    /// The settings the user is editing. Loaded from the helper the first time it answers.
    @Published var config = ChargePolicyConfig()

    private var loadedFromHelper = false
    private var timer: Timer?
    private var defaultsObserver: AnyCancellable?
    private var pushTask: DispatchWorkItem?
    /// When the user last changed a setting here. A status reply that was already
    /// in flight must not overwrite an edit that is only seconds old.
    private var lastEdit = Date.distantPast
    /// A policy just copied from the helper. The Settings view reacts to that
    /// change by pushing the config; this lets that one echo be skipped.
    private var adoptedPolicy: ChargePolicyConfig?
    /// Identifies the newest push, so an older one finishing can't clear it.
    private var pushToken = UUID()
    private let io = DispatchQueue(label: "com.kwikbattery.helper.client")

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // The helper pauses charging at the Hot battery alert's temperature, so
        // a change to that slider is passed on.
        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncHotLimit() }
    }

    /// Keeps the helper's hot limit equal to Settings › Notifications › Hot battery alert.
    private func syncHotLimit() {
        guard loadedFromHelper else { return }
        let limit = AppSettings.hotThreshold
        guard limit.isFinite, abs(config.hotLimitCelsius - limit) > 0.01 else { return }
        config.hotLimitCelsius = limit
        pushConfig()
    }

    /// True when the helper is installed and will pause charging when the battery is hot.
    var pausesWhenHot: Bool { reachable && (status?.version ?? 0) >= 2 && config.pauseWhenHot }

    /// True when the installed helper can run Low Power Mode on a schedule.
    var supportsLowPower: Bool { reachable && (status?.version ?? 0) >= 3 }

    /// An installed helper older than this app expects: it keeps working, but
    /// lacks newer features (like the heat pause) until it's reinstalled.
    var helperOutdated: Bool {
        guard reachable, let version = status?.version else { return false }
        return version < HelperStatus.currentVersion
    }

    func poll() {
        io.async { [weak self] in
            let s = HelperSocket.send(HelperRequest(cmd: "status"))
            DispatchQueue.main.async { self?.apply(s) }
        }
    }

    private func apply(_ s: HelperStatus?) {
        reachable = s != nil
        status = s
        if let s, !loadedFromHelper {
            loadedFromHelper = true
            adoptedPolicy = s.policy
            config = s.policy
            syncHotLimit()
        } else if let s, pushTask == nil, Date().timeIntervalSince(lastEdit) > 6, s.policy != config {
            // Changed from outside the app (the command line, Shortcuts): the
            // helper's copy is the truth, as long as nothing of ours is waiting to be sent.
            adoptedPolicy = s.policy
            config = s.policy
        }
    }

    /// Sends the edited settings to the helper (debounced so sliders don't flood it).
    func pushConfig() {
        guard loadedFromHelper else { return }
        if let adopted = adoptedPolicy {
            adoptedPolicy = nil
            if config == adopted { return }       // the helper's own settings coming back: nothing to send
        }
        lastEdit = Date()
        pushTask?.cancel()
        let snapshot = config
        let token = UUID()
        pushToken = token
        let work = DispatchWorkItem { [weak self] in
            let s = HelperSocket.send(HelperRequest(cmd: "setPolicy", policy: snapshot))
            DispatchQueue.main.async {
                if self?.pushToken == token { self?.pushTask = nil }
                self?.apply(s)
            }
        }
        pushTask = work
        io.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func topUpNow(target: Int) {
        send(HelperRequest(cmd: "topUpNow", target: target))
    }

    func cancelTopUp() {
        send(HelperRequest(cmd: "cancelTopUp"))
    }

    func restoreNormalCharging() {
        send(HelperRequest(cmd: "restore"))
    }

    /// Switches Low Power Mode on or off now (needs the helper; it runs `pmset`).
    func setLowPower(_ on: Bool) {
        send(HelperRequest(cmd: "setLowPower", lowPower: on))
    }

    private func send(_ request: HelperRequest) {
        io.async { [weak self] in
            let s = HelperSocket.send(request)
            DispatchQueue.main.async { self?.apply(s) }
        }
    }

    // MARK: Installing the helper

    /// Runs install-helper.sh (bundled in the app) with an administrator prompt.
    func installHelper() {
        guard !installing else { return }
        guard let script = Bundle.main.path(forResource: "install-helper", ofType: "sh") else {
            installMessage = "This build doesn't include the helper. Build with build.sh --install, or run install-helper.sh from the source folder."
            return
        }
        installing = true
        installMessage = nil
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/bash \" & quoted form of \"\(escaped)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let message: String?
            if result == nil {
                let text = (error?[NSAppleScript.errorMessage] as? String) ?? "Installation was cancelled."
                message = text
            } else {
                message = nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.installing = false
                self.installMessage = message
                self.loadedFromHelper = false
                self.poll()
            }
        }
    }

    func uninstallHelper() {
        guard !installing else { return }
        guard let script = Bundle.main.path(forResource: "uninstall-helper", ofType: "sh") else { return }
        installing = true
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/bash \" & quoted form of \"\(escaped)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                self?.installing = false
                self?.loadedFromHelper = false
                self?.poll()
            }
        }
    }
}
