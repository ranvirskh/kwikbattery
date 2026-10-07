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

    /// Scanning is the most expensive thing this app does: one `system_profiler`
    /// plus, when libimobiledevice is installed, an `idevice_id` and several
    /// `ideviceinfo` calls per device. At one scan a minute that was ~1,440 runs
    /// a day, nearly all of them refreshing a list nobody was looking at.
    ///
    /// But it can't stop entirely either. A phone is only detectable while it is
    /// unlocked and reachable, so the background scans are what *catch* it; the
    /// remember-for-an-hour window then keeps it on screen afterwards. With no
    /// background scanning there is nothing to remember, and the phone simply
    /// stops appearing.
    ///
    /// So: a slow background scan to keep catching devices, and the faster one
    /// in `setActive(true)` only while the panel is actually open.
    private let backgroundInterval: TimeInterval = 600   // 10 minutes
    private let foregroundInterval: TimeInterval = 60

    func start() {
        refresh()
        scheduleScan(every: AppSettings.lowPowerMode ? 1800 : backgroundInterval)
    }

    /// Switches between the fast scan used while the panel is open and the slow
    /// background one. Never stops scanning altogether -- see `start()`.
    func setActive(_ active: Bool) {
        if active {
            scheduleScan(every: AppSettings.lowPowerMode ? 300 : foregroundInterval)
        } else {
            scheduleScan(every: AppSettings.lowPowerMode ? 1800 : backgroundInterval)
        }
    }

    private func scheduleScan(every interval: TimeInterval) {
        timerCancellable?.cancel()
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

    /// The Bluetooth profile, the HID battery reads and the iPhone/iPad lookups
    /// are independent, so they run together: a slow or unreachable phone (up to
    /// ~25 s over Wi-Fi) can no longer hold up AirPods and keyboards.
    nonisolated static func loadDevices() async -> [BluetoothDevice] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let parts = concurrently(3) { index -> [BluetoothDevice] in
                    switch index {
                    case 0:  return parseSystemProfiler(runSystemProfiler())
                    case 1:  return readAppleMobileDevices()
                    default: return readHIDDevices()
                    }
                }
                var devices = parts[0] ?? []
                devices.append(contentsOf: parts[1] ?? [])
                for hid in parts[2] ?? [] {
                    let alreadyListed = devices.contains { $0.name.caseInsensitiveCompare(hid.name) == .orderedSame }
                    if !alreadyListed {
                        devices.append(hid)
                    }
                }
                continuation.resume(returning: devices.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                })
            }
        }
    }

    /// Runs `work(0)` … `work(count - 1)` at the same time and returns their
    /// results in order. Each call gets its own thread (these calls mostly wait
    /// on a child process), so nesting it can't starve the pool the way
    /// concurrentPerform would.
    nonisolated static func concurrently<T>(_ count: Int, _ work: @escaping (Int) -> T) -> [T?] {
        guard count > 0 else { return [] }
        let box = ResultBox<T>(count)
        let group = DispatchGroup()
        for index in 0..<count {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                box.set(index, work(index))
                group.leave()
            }
        }
        group.wait()
        return box.values
    }

    final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T?]

        init(_ count: Int) { items = Array(repeating: nil, count: count) }

        func set(_ index: Int, _ value: T) {
            lock.lock()
            items[index] = value
            lock.unlock()
        }

        var values: [T?] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// `system_profiler` normally answers in a second or two; 25 s is "stuck".
    nonisolated static func runSystemProfiler() -> Data? {
        runToolData("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 25)
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

        // 1. List USB and Wi-Fi devices at the same time. Wi-Fi lookups go over
        //    the network and are far slower than USB, so they get a longer budget.
        let connections: [(flag: String, name: String, timeout: TimeInterval)] =
            [("-l", "USB", 4), ("-n", "Wi-Fi", 8)]
        let listings = concurrently(connections.count) { index in
            runTool(idList, [connections[index].flag], timeout: connections[index].timeout) ?? ""
        }

        // A phone on USB is asked over USB first; one that is also visible over
        // Wi-Fi is remembered, in case the USB answer fails.
        var found: [(udid: String, connection: String)] = []
        var seen = Set<String>()
        var alsoWireless = Set<String>()
        for (index, listing) in listings.enumerated() {
            let udids = (listing ?? "")
                .split(whereSeparator: \.isNewline)
                .compactMap { line in line.split(separator: " ").first.map(String.init) }
                .filter { !$0.isEmpty }
            for udid in udids {
                if seen.insert(udid).inserted {
                    found.append((udid, connections[index].name))
                } else {
                    alsoWireless.insert(udid)
                }
            }
        }
        let targets = found
        let wireless = alsoWireless

        // 2. Ask every device at the same time (previously one after another).
        let answers = concurrently(targets.count) { index in
            queryMobileDevice(info: info, udid: targets[index].udid, connection: targets[index].connection)
        }
        var devices = answers.compactMap { $0 ?? nil }

        // 3. A phone that didn't answer over USB gets one more try over Wi-Fi.
        var retry: [String] = []
        for (index, target) in targets.enumerated()
        where (answers[index] ?? nil) == nil && target.connection == "USB" && wireless.contains(target.udid) {
            retry.append(target.udid)
        }
        let retryList = retry
        if !retryList.isEmpty {
            let again = concurrently(retryList.count) { index in
                queryMobileDevice(info: info, udid: retryList[index], connection: "Wi-Fi")
            }
            devices.append(contentsOf: again.compactMap { $0 ?? nil })
        }
        return devices
    }

    /// One iPhone or iPad's battery and names. The four reads are independent,
    /// so they run together; nil if the battery can't be read.
    nonisolated static func queryMobileDevice(info: String, udid: String, connection: String) -> BluetoothDevice? {
        let isWireless = (connection == "Wi-Fi")
        let timeout: TimeInterval = isWireless ? 15 : 6
        var base = ["-u", udid]
        if isWireless { base.insert("-n", at: 0) }

        // Ask for each field by name: a bare `ideviceinfo` dumps the device's
        // whole property list, which is slow and needlessly large.
        let queries: [[String]] = [
            base + ["-q", "com.apple.mobile.battery"],
            base + ["-k", "DeviceName"],
            base + ["-k", "DeviceClass"],
            base + ["-k", "ProductType"],
        ]
        let answers = concurrently(queries.count) { runTool(info, queries[$0], timeout: timeout) }
        guard let batteryText = answers[0] ?? nil else { return nil }
        let battery = parseKeyValues(batteryText)
        guard let level = battery["BatteryCurrentCapacity"].flatMap({ Int($0) }) else { return nil }

        func text(_ index: Int) -> String {
            ((answers[index] ?? nil) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = text(1)
        let isPad = text(2).lowercased().contains("ipad")
        let modelName = AppleModelNames.name(forProductType: text(3)) ?? (isPad ? "iPad" : "iPhone")

        // Lets the power-flow code label this USB port with the model name.
        DeviceNameCache.shared.set(modelName, forSerial: udid)

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
        return device
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
        runToolData(path, arguments, timeout: timeout).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Same, as raw bytes. A tool that ignores the polite stop is killed.
    nonisolated static func runToolData(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
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
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        // Give the reader a moment to pick up whatever is still buffered.
        let drainDeadline = Date().addingTimeInterval(1.0)
        while !reader.isFinished && Date() < drainDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { return nil }
        return collected.data
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
