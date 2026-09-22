//
//  BluetoothDeviceMonitor.swift
//  KwikBattery
//
//  Battery levels of connected Bluetooth accessories (AirPods, Magic Mouse,
//  keyboards, headphones…).
//
//  Two sources, merged:
//   1. `system_profiler SPBluetoothDataType -json` — the same data as
//      System Information › Bluetooth. Includes AirPods left/right/case levels.
//      It takes ~0.5–1 s, so it runs off the main thread and not too often.
//   2. IORegistry "AppleDeviceManagementHIDEventService" entries — Apple's
//      Magic Mouse / Keyboard / Trackpad publish "BatteryPercent" there.
//

import Foundation
import Combine
import IOKit

struct BluetoothDevice: Identifiable, Equatable {
    enum Kind: Equatable {
        case airPods, airPodsPro, airPodsMax, headphones
        case mouse, keyboard, trackpad
        case speaker, gamepad, phone, other
    }

    let id: String
    let name: String
    let kind: Kind
    var mainLevel: Int?
    var leftLevel: Int?
    var rightLevel: Int?
    var caseLevel: Int?
    var isCharging: Bool = false
    /// Where the reading came from, e.g. "USB", "Wi-Fi", "Bluetooth".
    var connection: String = "Bluetooth"
    /// Watts this device is drawing from the Mac (USB-powered devices).
    var chargingWatts: Double? = nil
    /// When this reading was taken. Older readings are shown dimmed.
    var lastSeen: Date = Date()
    /// Marketing model name, e.g. "iPhone 17" (Apple mobile devices only).
    var model: String? = nil

    /// The number to show for the device as a whole.
    var displayLevel: Int? {
        if let mainLevel { return mainLevel }
        let buds = [leftLevel, rightLevel].compactMap { $0 }
        if let lowest = buds.min() { return lowest }
        return caseLevel
    }

    var hasBudLevels: Bool {
        leftLevel != nil || rightLevel != nil || caseLevel != nil
    }

    var symbolName: String {
        switch kind {
        case .airPods:    return "airpods"
        case .airPodsPro: return "airpodspro"
        case .airPodsMax: return "airpodsmax"
        case .headphones: return "headphones"
        case .mouse:      return "magicmouse.fill"
        case .keyboard:   return "keyboard"
        case .trackpad:   return "rectangle.and.hand.point.up.left.fill"
        case .speaker:    return "hifispeaker.fill"
        case .gamepad:    return "gamecontroller.fill"
        case .phone:      return "iphone"
        case .other:      return connection == "USB" ? "cable.connector" : "dot.radiowaves.left.and.right"
        }
    }
}

@MainActor
final class BluetoothDeviceMonitor: ObservableObject {
    static let shared = BluetoothDeviceMonitor()

    @Published private(set) var devices: [BluetoothDevice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false
    /// What the last iPhone/iPad lookup actually did. Used for an honest
    /// message instead of guessing at a cause.
    enum MobileLookup: Equatable {
        case toolsMissing          // libimobiledevice isn't installed
        case noDevicePaired        // tools ran fine, nothing was listed
        case found                 // at least one device answered
    }
    @Published private(set) var mobileLookup: MobileLookup = .toolsMissing

    private var timerCancellable: AnyCancellable?
    private var lastRefresh: Date = .distantPast
    /// Last good reading per device id, so a phone that locks (and stops
    /// answering) stays listed as a stale entry instead of vanishing.
    private var remembered: [String: BluetoothDevice] = [:]

    /// How long a device that has stopped reporting stays listed (dimmed).
    /// A locked iPhone is still sitting next to you, so its last reading stays
    /// useful for a while. A keyboard that stops answering is usually out of
    /// range or switched off, where an hour-old level would just mislead.
    private let rememberPhoneFor: TimeInterval = 60 * 60
    private let rememberAccessoryFor: TimeInterval = 10 * 60

    private func rememberWindow(for device: BluetoothDevice) -> TimeInterval {
        device.kind == .phone ? rememberPhoneFor : rememberAccessoryFor
    }

    private init() {}

    /// One scan at launch, then a slow periodic scan. Simple and predictable:
    /// devices come and go (phone locks, AirPods go in the case), so the list
    /// has to be re-checked on a timer rather than cached cleverly.
    /// The cost is one `system_profiler` per interval, which is modest.
    func start() {
        refresh()
        let interval: TimeInterval = AppSettings.lowPowerMode ? 300 : 60
        timerCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    /// Stops any pending work (called when the app quits).
    func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    /// Called when the popover opens; avoids re-running system_profiler constantly.
    /// Called when the popover opens: refresh unless we just did.
    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 15 {
            refresh()
        }
    }

    /// Forces the next refreshIfStale() to actually run (used by the Refresh button).
    func invalidateCache() {
        lastRefresh = .distantPast
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        lastRefresh = Date()
        Task {
            let fresh = await Self.loadDevices()
            self.devices = self.merge(fresh: fresh)
            self.mobileLookup = Self.mobileToolsInstalled()
                ? (fresh.contains { $0.kind == .phone } ? .found : .noDevicePaired)
                : .toolsMissing
            self.isLoading = false
            self.hasLoadedOnce = true
        }
    }

    /// Keeps devices that answered recently but didn't this time — an iPhone
    /// that has locked, AirPods back in the case, and so on. They're shown
    /// dimmed with their age rather than disappearing from the list.
    private func merge(fresh: [BluetoothDevice]) -> [BluetoothDevice] {
        let now = Date()
        for device in fresh {
            var stamped = device
            stamped.lastSeen = now
            remembered[device.id] = stamped
        }
        remembered = remembered.filter { entry in
            now.timeIntervalSince(entry.value.lastSeen) < rememberWindow(for: entry.value)
        }

        let freshIDs = Set(fresh.map { $0.id })
        let stale = remembered.values
            .filter { !freshIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return fresh.map { device -> BluetoothDevice in
            var stamped = device
            stamped.lastSeen = now
            return stamped
        } + stale
    }

    // MARK: - Loading (off the main actor)

    nonisolated static func loadDevices() async -> [BluetoothDevice] {
        var devices = parseSystemProfiler(runSystemProfiler())
        devices.append(contentsOf: readAppleMobileDevices())
        for hid in readHIDDevices() {
            let alreadyListed = devices.contains { $0.name.caseInsensitiveCompare(hid.name) == .orderedSame }
            if !alreadyListed {
                devices.append(hid)
            }
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated static func runSystemProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("KwikBattery: could not run system_profiler: \(error)")
            return nil
        }
        // Read before waiting so a large output can't fill the pipe and deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// Expected shape (macOS 13+):
    /// { "SPBluetoothDataType": [ { "device_connected": [ { "Name": { "device_address": "…",
    ///   "device_minorType": "Headphones", "device_batteryLevelLeft": "90%", … } } ] } ] }
    nonisolated static func parseSystemProfiler(_ data: Data?) -> [BluetoothDevice] {
        guard let data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var result: [BluetoothDevice] = []
        for controller in controllers {
            guard let connected = controller["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }
                    let main = percent(props["device_batteryLevelMain"]) ?? percent(props["device_batteryLevel"])
                    let left = percent(props["device_batteryLevelLeft"])
                    let right = percent(props["device_batteryLevelRight"])
                    let caseLevel = percent(props["device_batteryLevelCase"])
                    guard main != nil || left != nil || right != nil || caseLevel != nil else { continue }

                    let minorType = (props["device_minorType"] as? String) ?? ""
                    let address = (props["device_address"] as? String) ?? name
                    result.append(BluetoothDevice(id: address,
                                                  name: name,
                                                  kind: kind(name: name, minorType: minorType),
                                                  mainLevel: main,
                                                  leftLevel: left,
                                                  rightLevel: right,
                                                  caseLevel: caseLevel))
                }
            }
        }
        return result
    }

    /// Apple Magic accessories report their level on this IORegistry class.
    nonisolated static func readHIDDevices() -> [BluetoothDevice] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [BluetoothDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let productRef = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0),
                  let product = productRef.takeRetainedValue() as? String,
                  let batteryRef = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0),
                  let battery = batteryRef.takeRetainedValue() as? NSNumber else { continue }

            if result.contains(where: { $0.name == product }) { continue }
            result.append(BluetoothDevice(id: "hid-\(product)",
                                          name: product,
                                          kind: kind(name: product, minorType: ""),
                                          mainLevel: battery.intValue,
                                          leftLevel: nil,
                                          rightLevel: nil,
                                          caseLevel: nil))
        }
        return result
    }

    // MARK: - iPhone / iPad battery (optional libimobiledevice)

    /// macOS has no public API for an iPhone's battery level. If the free,
    /// open-source libimobiledevice tools are installed
    /// (`brew install libimobiledevice`), use them to read it over USB or Wi-Fi.
    nonisolated static func readAppleMobileDevices() -> [BluetoothDevice] {
        guard let idList = findTool("idevice_id"), let info = findTool("ideviceinfo") else { return [] }

        var result: [BluetoothDevice] = []
        var seen = Set<String>()
        for (flag, connection) in [("-l", "USB"), ("-n", "Wi-Fi")] {
            // Wi-Fi lookups go over the network and are far slower than USB,
            // so they get a longer budget; 5 s was cutting them off entirely.
            let isWireless = (connection == "Wi-Fi")
            let listTimeout: TimeInterval = isWireless ? 8 : 4
            let queryTimeout: TimeInterval = isWireless ? 15 : 6
            let listing = runTool(idList, [flag], timeout: listTimeout) ?? ""
            let udids = listing
                .split(whereSeparator: \.isNewline)
                .map { line -> String in
                    guard let first = line.split(separator: " ").first else { return "" }
                    return String(first)
                }
                .filter { !$0.isEmpty }

            for udid in udids where !seen.contains(udid) {
                var base = ["-u", udid]
                if connection == "Wi-Fi" { base.insert("-n", at: 0) }

                guard let batteryText = runTool(info, base + ["-q", "com.apple.mobile.battery"],
                                                timeout: queryTimeout) else { continue }
                let battery = parseKeyValues(batteryText)
                guard let level = battery["BatteryCurrentCapacity"].flatMap({ Int($0) }) else { continue }

                // Ask for each field by name: a bare `ideviceinfo` dumps the
                // device's whole property list, which is slow and needlessly large.
                func value(_ key: String) -> String {
                    (runTool(info, base + ["-k", key], timeout: queryTimeout) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let name = value("DeviceName")
                let isPad = value("DeviceClass").lowercased().contains("ipad")
                let productType = value("ProductType")
                let modelName = AppleModelNames.name(forProductType: productType)
                    ?? (isPad ? "iPad" : "iPhone")

                // Lets the power-flow code label this USB port with the model name.
                DeviceNameCache.shared.set(modelName, forSerial: udid)

                seen.insert(udid)
                var device = BluetoothDevice(id: "idevice-\(udid)",
                                             name: name.isEmpty ? (isPad ? "iPad" : "iPhone") : name,
                                             kind: .phone,
                                             mainLevel: level,
                                             leftLevel: nil,
                                             rightLevel: nil,
                                             caseLevel: nil)
                device.isCharging = (battery["BatteryIsCharging"] ?? "").lowercased() == "true"
                device.connection = connection
                device.model = modelName
                result.append(device)
            }
        }
        return result
    }

    /// Are the optional libimobiledevice tools installed?
    nonisolated static func mobileToolsInstalled() -> Bool {
        findTool("idevice_id") != nil && findTool("ideviceinfo") != nil
    }

    nonisolated static func findTool(_ name: String) -> String? {
        let folders = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.homebrew/bin"]
        for folder in folders {
            let path = folder + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a command-line tool and returns its output (nil on failure / timeout).
    nonisolated static func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain the pipe on a background thread WHILE the tool runs. A pipe
        // only buffers ~64 KB: waiting for exit before reading deadlocks as
        // soon as a tool prints more than that (e.g. a full `ideviceinfo`
        // property list), which looks exactly like a timeout.
        let collected = OutputBuffer()
        let reader = Thread {
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
        }
        reader.start()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        // Give the reader a moment to pick up whatever is still buffered.
        let drainDeadline = Date().addingTimeInterval(1.0)
        while !reader.isFinished && Date() < drainDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: collected.data, encoding: .utf8)
    }

    /// Thread-safe accumulator for a child process's output.
    final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            lock.lock()
            storage.append(chunk)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// Parses "Key: value" lines.
    nonisolated static func parseKeyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    // MARK: - Diagnostics

    /// Prints exactly what the app's own iPhone lookup does, step by step.
    /// Used by `KwikBattery --idevice-diag` (see build.sh).
    nonisolated static func diagnosticReport() -> String {
        var lines: [String] = []
        let idList = findTool("idevice_id")
        let info = findTool("ideviceinfo")
        lines.append("idevice_id  : \(idList ?? "NOT FOUND")")
        lines.append("ideviceinfo : \(info ?? "NOT FOUND")")
        guard let idList, let info else {
            lines.append("→ tools missing, giving up")
            return lines.joined(separator: "\n")
        }

        for (flag, connection) in [("-l", "USB"), ("-n", "Wi-Fi")] {
            let started = Date()
            let listing = runTool(idList, [flag], timeout: 8)
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            lines.append("")
            lines.append("[\(connection)] idevice_id \(flag) → \(listing == nil ? "nil (timeout/failure)" : "ok") in \(elapsed)")
            let udids = (listing ?? "")
                .split(whereSeparator: \.isNewline)
                .map { String($0.split(separator: " ").first ?? "") }
                .filter { !$0.isEmpty }
            lines.append("  UDIDs: \(udids.isEmpty ? "(none)" : udids.joined(separator: ", "))")

            for udid in udids {
                var base = ["-u", udid]
                if connection == "Wi-Fi" { base.insert("-n", at: 0) }
                let t0 = Date()
                let battery = runTool(info, base + ["-q", "com.apple.mobile.battery"], timeout: 15)
                let dt = String(format: "%.2fs", Date().timeIntervalSince(t0))
                lines.append("  battery query (\(dt)): \(battery == nil ? "nil (timeout/failure)" : "ok")")
                if let battery {
                    let parsed = parseKeyValues(battery)
                    lines.append("    raw bytes: \(battery.utf8.count), keys: \(parsed.count)")
                    lines.append("    BatteryCurrentCapacity = \(parsed["BatteryCurrentCapacity"] ?? "MISSING")")
                    lines.append("    first line: \(battery.split(whereSeparator: \.isNewline).first.map(String.init) ?? "(empty)")")
                }
                let t1 = Date()
                let name = runTool(info, base + ["-k", "DeviceName"], timeout: 15)
                lines.append("  DeviceName (\(String(format: "%.2fs", Date().timeIntervalSince(t1)))): \(name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil")")
            }
        }

        lines.append("")
        let devices = readAppleMobileDevices()
        lines.append("readAppleMobileDevices() returned \(devices.count) device(s)")
        for d in devices {
            lines.append("  • \(d.name) — \(d.mainLevel.map { "\($0)%" } ?? "no level") via \(d.connection), model \(d.model ?? "?")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    nonisolated static func percent(_ value: Any?) -> Int? {
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    nonisolated static func kind(name: String, minorType: String) -> BluetoothDevice.Kind {
        let n = name.lowercased()
        let m = minorType.lowercased()
        if n.contains("airpods max") { return .airPodsMax }
        if n.contains("airpods pro") { return .airPodsPro }
        if n.contains("airpods") { return .airPods }
        if m.contains("headphone") || m.contains("headset") || n.contains("beats") { return .headphones }
        if m.contains("mouse") || n.contains("mouse") { return .mouse }
        if m.contains("keyboard") || n.contains("keyboard") { return .keyboard }
        if m.contains("trackpad") || n.contains("trackpad") { return .trackpad }
        if m.contains("speaker") || n.contains("speaker") { return .speaker }
        if m.contains("gamepad") || m.contains("joystick") || n.contains("controller") { return .gamepad }
        if m.contains("phone") || n.contains("iphone") { return .phone }
        return .other
    }
}
