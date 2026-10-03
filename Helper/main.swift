//
//  main.swift  —  kwikbatteryd, KwikBattery's privileged charge-control helper
//
//  Runs as a root LaunchDaemon (installed by install-helper.sh). It is the only
//  part of KwikBattery that ever WRITES to the SMC, and it does so only to flip
//  two switches:
//      • "inhibit charging"  – the battery stops taking charge (the Mac runs from
//                              the adapter, the battery just sits there)
//      • "disable adapter"   – the Mac runs from the battery while plugged in
//  The decision logic lives in ChargePolicy.swift. This file talks to the
//  hardware, to the app (a Unix socket) and to macOS power events.
//
//  Safety rules this daemon follows
//    • On start, on SIGTERM/SIGINT and before every sleep it puts the adapter
//      back on. A discharging Mac must never go to sleep or quit with its adapter off.
//    • Every write is read back; if the SMC doesn't hold the value, the feature
//      is switched off and the error is reported instead of guessed at.
//    • Values are re-checked every tick, so a reset by macOS is corrected.
//    • Unknown Macs are left alone: only keys that actually exist are used.
//
//  Command line (all but --daemon work without a running daemon)
//      kwikbatteryd --probe     read-only: list which charge-control keys this Mac has
//      kwikbatteryd --keys CH B0  read-only: list every SMC key starting with those prefixes
//      kwikbatteryd --restore   force normal charging (adapter on, charging allowed)
//      kwikbatteryd --daemon    run the helper (what launchd does)
//

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Darwin

// MARK: - SMC access (read + write)

final class SMC {
    private struct KeyDataVersion {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    private struct PLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }
    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var padding0: UInt8 = 0, padding1: UInt8 = 0, padding2: UInt8 = 0
    }
    private typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    private struct KeyData {
        var key: UInt32 = 0
        var version = KeyDataVersion()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let selector: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdWriteBytes: UInt8 = 6
    private static let cmdKeyInfo: UInt8 = 9
    private static let cmdKeyFromIndex: UInt8 = 8

    private var connection: io_connect_t = 0
    private(set) var isOpen = false

    init() {
        guard MemoryLayout<KeyData>.stride == 80 else { return }   // wrong layout: never talk to the SMC
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        isOpen = IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
    }

    deinit { if isOpen { IOServiceClose(connection) } }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(connection, Self.selector, &input,
                                          MemoryLayout<KeyData>.stride, &output, &outputSize)
        guard r == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private func info(_ key: String) -> KeyInfo? {
        guard isOpen else { return nil }
        var req = KeyData()
        req.key = Self.fourCC(key)
        req.data8 = Self.cmdKeyInfo
        guard let out = call(&req), out.keyInfo.dataSize > 0, out.keyInfo.dataSize <= 32 else { return nil }
        return out.keyInfo
    }

    /// Size in bytes of a key, or nil if this Mac doesn't have it.
    func size(of key: String) -> Int? { info(key).map { Int($0.dataSize) } }

    func read(_ key: String) -> [UInt8]? {
        guard let ki = info(key) else { return nil }
        var req = KeyData()
        req.key = Self.fourCC(key)
        req.keyInfo.dataSize = ki.dataSize
        req.data8 = Self.cmdReadBytes
        guard let out = call(&req) else { return nil }
        let all: [UInt8] = withUnsafeBytes(of: out.bytes) { Array($0) }
        return Array(all.prefix(Int(ki.dataSize)))
    }

    // MARK: Read-only key discovery (used by --keys)

    private static func string(from code: UInt32) -> String {
        let b = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }

    func keyCount() -> Int? {
        guard let b = read("#KEY"), b.count == 4 else { return nil }
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    func keyName(at index: Int) -> String? {
        guard isOpen else { return nil }
        var req = KeyData()
        req.data8 = Self.cmdKeyFromIndex
        req.data32 = UInt32(index)
        guard let out = call(&req) else { return nil }
        return Self.string(from: out.key)
    }

    func typeName(of key: String) -> String? { info(key).map { Self.string(from: $0.dataType) } }

    /// Writes exactly the key's declared number of bytes. Needs root.
    @discardableResult
    func write(_ key: String, _ value: [UInt8]) -> Bool {
        guard let ki = info(key), Int(ki.dataSize) == value.count else { return false }
        var req = KeyData()
        req.key = Self.fourCC(key)
        req.keyInfo.dataSize = ki.dataSize
        req.data8 = Self.cmdWriteBytes
        withUnsafeMutableBytes(of: &req.bytes) { buf in
            for (i, b) in value.enumerated() { buf[i] = b }
        }
        return call(&req) != nil
    }
}

// MARK: - The two switches

/// One logical switch made of one or more SMC keys.
struct SMCSwitch {
    struct Key { let name: String; let on: [UInt8]; let off: [UInt8] }
    let keys: [Key]
    var label: String { keys.map(\.name).joined(separator: "+") }
}

enum Candidates {
    // Charging inhibit. Newer firmware uses CHTE; older Apple silicon uses CH0B + CH0C.
    static let chargeInhibit: [SMCSwitch] = [
        SMCSwitch(keys: [.init(name: "CHTE", on: [1, 0, 0, 0], off: [0, 0, 0, 0])]),
        SMCSwitch(keys: [.init(name: "CH0B", on: [2], off: [0]),
                         .init(name: "CH0C", on: [2], off: [0])]),
    ]
    // Adapter off (run on battery while plugged in). Newer: CHIE; older: CH0I.
    static let adapterOff: [SMCSwitch] = [
        SMCSwitch(keys: [.init(name: "CHIE", on: [0x08], off: [0])]),
        SMCSwitch(keys: [.init(name: "CH0I", on: [1], off: [0])]),
    ]

    static func firstAvailable(_ options: [SMCSwitch], in smc: SMC) -> SMCSwitch? {
        options.first { opt in opt.keys.allSatisfy { smc.size(of: $0.name) == $0.on.count } }
    }
}

extension SMC {
    func isOn(_ s: SMCSwitch) -> Bool? {
        var all = true
        for k in s.keys {
            guard let v = read(k.name) else { return nil }
            if v != k.on { all = false }
        }
        return all
    }

    /// Sets the switch and confirms the SMC kept the value.
    func set(_ s: SMCSwitch, on: Bool) -> Bool {
        for k in s.keys { if !write(k.name, on ? k.on : k.off) { return false } }
        return isOn(s) == on
    }
}

// MARK: - Battery / lid readings

enum Sensors {
    static func battery() -> (percent: Int, onAC: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            let maxCap = (d[kIOPSMaxCapacityKey] as? Int) ?? 100
            let pct = (maxCap == 100 || maxCap == 0) ? cap : Int((Double(cap) / Double(maxCap) * 100).rounded())
            let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (pct, ac)
        }
        return nil
    }

    static func lidClosed() -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        let v = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (v as? Bool) ?? false
    }
}

// MARK: - Controller

final class Controller {
    let queue = DispatchQueue(label: "com.kwikbattery.helper.state")
    private let smc = SMC()
    private var chargeSwitch: SMCSwitch?
    private var adapterSwitch: SMCSwitch?
    private var engine = PolicyEngine()
    private var status = HelperStatus()
    private var inhibitWanted = false
    private var adapterOffWanted = false
    private var sleeping = false
    private var broken: String?

    init() {
        chargeSwitch = Candidates.firstAvailable(Candidates.chargeInhibit, in: smc)
        adapterSwitch = Candidates.firstAvailable(Candidates.adapterOff, in: smc)
        status.chargeKey = chargeSwitch?.label
        status.adapterKey = adapterSwitch?.label
        if !smc.isOpen { broken = "Couldn't open the SMC." }
        else if chargeSwitch == nil && adapterSwitch == nil { broken = "This Mac doesn't expose a known charge-control key." }
        loadPolicy()
        restoreNormal()           // always start from a known state
        tick()
    }

    // MARK: Persistence

    private func loadPolicy() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: HelperPaths.policyFile)),
           let cfg = try? JSONDecoder().decode(ChargePolicyConfig.self, from: data) {
            engine.config = cfg.sanitized
        }
    }

    private func savePolicy() {
        try? FileManager.default.createDirectory(atPath: HelperPaths.policyDirectory,
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(engine.config) {
            try? data.write(to: URL(fileURLWithPath: HelperPaths.policyFile), options: .atomic)
        }
    }

    // MARK: Hardware

    /// Adapter on, charging allowed. Safe to call any time.
    func restoreNormal() {
        if let a = adapterSwitch { _ = smc.set(a, on: false) }
        if let c = chargeSwitch { _ = smc.set(c, on: false) }
        inhibitWanted = false
        adapterOffWanted = false
    }

    /// Called before sleep: never sleep with the adapter off.
    func prepareForSleep() {
        sleeping = true
        if let a = adapterSwitch { _ = smc.set(a, on: false) }
        adapterOffWanted = false
    }

    func didWake() {
        sleeping = false
        tick()
    }

    private func apply(_ mode: ChargeMode, lidClosed: Bool) {
        guard broken == nil else { return }

        guard let charge = chargeSwitch else {
            // No "inhibit charging" key on this Mac (macOS 27 on M1 Max has none).
            // Emulate holding the limit by cycling the adapter: while the policy says
            // hold or discharge, the Mac runs from the battery; once the battery has
            // fallen `sailingRange` below the limit the policy says normal and it
            // charges again. Never with the lid closed unless the user allowed that,
            // because the Mac would sleep on a draining battery.
            guard let a = adapterSwitch else { return }
            let lidBlocks = lidClosed && !engine.config.sanitized.dischargeWithLidClosed
            let wantOff = mode != .normal && !sleeping && !lidBlocks
            if smc.isOn(a) != wantOff {
                if !smc.set(a, on: wantOff) { fail("The SMC wouldn't accept the adapter switch (\(a.label))."); return }
            }
            inhibitWanted = false
            adapterOffWanted = wantOff
            return
        }

        var wantInhibit = mode != .normal
        var wantAdapterOff = mode == .discharge
        if wantAdapterOff && adapterSwitch == nil { wantAdapterOff = false; wantInhibit = true }
        if sleeping { wantAdapterOff = false }

        // Order matters: inhibit before cutting the adapter; adapter back before releasing inhibit.
        if wantAdapterOff {
            if smc.isOn(charge) != true { guard setCharge(charge, true) else { return } }
            if let a = adapterSwitch, smc.isOn(a) != true {
                if !smc.set(a, on: true) { fail("The SMC wouldn't accept the adapter switch (\(a.label))."); return }
            }
        } else {
            if let a = adapterSwitch, smc.isOn(a) != false {
                if !smc.set(a, on: false) { fail("Couldn't switch the adapter back on (\(a.label))."); return }
            }
            if smc.isOn(charge) != wantInhibit { guard setCharge(charge, wantInhibit) else { return } }
        }
        inhibitWanted = wantInhibit
        adapterOffWanted = wantAdapterOff
    }

    private func setCharge(_ c: SMCSwitch, _ on: Bool) -> Bool {
        if smc.set(c, on: on) { return true }
        fail("The SMC wouldn't hold the charge-control value (\(c.label)).")
        return false
    }

    /// A write that doesn't stick means the keys on this Mac don't behave as expected.
    /// Go back to normal charging and stop touching the hardware.
    private func fail(_ message: String) {
        broken = message
        if let a = adapterSwitch { _ = smc.set(a, on: false) }
        if let c = chargeSwitch { _ = smc.set(c, on: false) }
        inhibitWanted = false
        adapterOffWanted = false
    }

    // MARK: Loop

    func tick() {
        guard let reading = Sensors.battery() else {
            status.error = "Couldn't read the battery."
            return
        }
        let lid = Sensors.lidClosed()
        let pluggedIn = reading.onAC || adapterOffWanted
        let decision = engine.decide(PolicyInput(percent: reading.percent, pluggedIn: pluggedIn,
                                                 lidClosed: lid, now: Date()))
        apply(decision.mode, lidClosed: lid)

        status.percent = reading.percent
        status.pluggedIn = pluggedIn
        status.lidClosed = lid
        status.mode = broken == nil ? decision.mode : .normal
        status.reason = broken == nil ? decision.reason : "Charge control is paused"
        status.effectiveLimit = decision.effectiveLimit
        status.topUpActive = decision.topUpActive
        status.error = broken
        status.emulatedHold = (chargeSwitch == nil && adapterSwitch != nil) ? true : nil
        status.policy = engine.config
    }

    // MARK: Requests

    func handle(_ req: HelperRequest) -> HelperStatus {
        switch req.cmd {
        case "setPolicy":
            if let p = req.policy {
                engine.config = p.sanitized
                savePolicy()
                broken = (smc.isOpen && (chargeSwitch != nil || adapterSwitch != nil)) ? nil : broken   // a new policy retries
                if !engine.config.enabled { restoreNormal() }
            }
        case "topUpNow":
            engine.startTopUp(target: req.target ?? 100, now: Date())
        case "cancelTopUp":
            engine.cancelTopUp()
        case "restore":
            restoreNormal()
        default:
            break
        }
        tick()
        return status
    }

    func currentStatus() -> HelperStatus { status }
}

// MARK: - Unix socket server

func consoleUID() -> uid_t {
    var st = stat()
    return stat("/dev/console", &st) == 0 ? st.st_uid : 0
}

func serve(controller: Controller) {
    unlink(HelperPaths.socket)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    _ = HelperPaths.socket.withCString { strlcpy(&addr.sun_path.0, $0, MemoryLayout.size(ofValue: addr.sun_path)) }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else { NSLog("kwikbatteryd: bind failed: \(errno)"); return }
    chmod(HelperPaths.socket, 0o666)       // access is checked per connection below
    listen(fd, 8)

    DispatchQueue.global(qos: .utility).async {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == 0 || uid == consoleUID() else {
                close(client); continue
            }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            var data = Data()
            var byte: UInt8 = 0
            while data.count < 65536, read(client, &byte, 1) == 1, byte != 0x0A { data.append(byte) }

            let response: HelperStatus
            if let req = try? JSONDecoder().decode(HelperRequest.self, from: data) {
                response = controller.queue.sync { controller.handle(req) }
            } else {
                var s = controller.queue.sync { controller.currentStatus() }
                s.error = "Bad request"
                response = s
            }
            if var out = try? JSONEncoder().encode(response) {
                out.append(0x0A)
                out.withUnsafeBytes { _ = write(client, $0.baseAddress, out.count) }
            }
            close(client)
        }
    }
}

// MARK: - Power events (sleep / wake)

// IOKit's message constants are C macros Swift can't import (iokit_common_msg(x) = 0xE0000000 | x).
private let msgCanSystemSleep: UInt32 = 0xE000_0270
private let msgSystemWillSleep: UInt32 = 0xE000_0280
private let msgSystemHasPoweredOn: UInt32 = 0xE000_0300

private var rootPort: io_connect_t = 0
private var sharedController: Controller?

private func powerCallback(_ refcon: UnsafeMutableRawPointer?, _ service: io_service_t,
                           _ type: UInt32, _ arg: UnsafeMutableRawPointer?) {
    switch type {
    case msgCanSystemSleep:
        IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    case msgSystemWillSleep:
        sharedController?.prepareForSleep()          // runs on the controller queue
        IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    case msgSystemHasPoweredOn:
        sharedController?.didWake()
    default:
        break
    }
}

// MARK: - Entry point

func runProbe() {
    let smc = SMC()
    print("SMC open: \(smc.isOpen)")
    for key in ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "CHWA", "CHBI", "BCLM", "BFCL"] {
        if let size = smc.size(of: key), let v = smc.read(key) {
            print("\(key)  size \(size)  value \(v.map { String(format: "%02x", $0) }.joined(separator: " "))")
        } else {
            print("\(key)  not present")
        }
    }
    let charge = Candidates.firstAvailable(Candidates.chargeInhibit, in: smc)
    let adapter = Candidates.firstAvailable(Candidates.adapterOff, in: smc)
    print("Charge inhibit via: \(charge?.label ?? "none")")
    print("Adapter off via:    \(adapter?.label ?? "none")")
    if let b = Sensors.battery() { print("Battery \(b.percent)%  on AC: \(b.onAC)") }
    print("Lid closed: \(Sensors.lidClosed())")
    print("Running as root: \(geteuid() == 0)")
}

var testSMC: SMC?
var testSwitch: SMCSwitch?

/// Interactive hardware check: switches the adapter off for ~8 s while plugged in, reports
/// what macOS saw, and always switches it back on. Run with sudo, on the charger.
func runAdapterTest() {
    guard geteuid() == 0 else { print("Run with sudo."); exit(1) }
    let smc = SMC()
    guard let a = Candidates.firstAvailable(Candidates.adapterOff, in: smc) else {
        print("No adapter switch on this Mac."); return
    }
    testSMC = smc; testSwitch = a
    let restore: @convention(c) (Int32) -> Void = { _ in
        if let s = testSMC, let sw = testSwitch { _ = s.set(sw, on: false) }
        print("\nInterrupted: adapter switched back on.")
        exit(1)
    }
    signal(SIGINT, restore); signal(SIGTERM, restore)

    func line(_ label: String) {
        let b = Sensors.battery()
        print("\(label): battery \(b.map { "\($0.percent)%" } ?? "?"), on AC: \(b.map { String($0.onAC) } ?? "?"), \(a.label) = \(smc.isOn(a).map { $0 ? "ON (adapter off)" : "off (normal)" } ?? "?")")
    }
    line("Before")
    guard Sensors.battery()?.onAC == true else {
        print("Plug in the charger first, then run this again."); return
    }
    print("Switching the adapter off for 8 seconds…")
    let ok = smc.set(a, on: true)
    print("write accepted and held: \(ok)")
    for _ in 1...4 { sleep(2); line("During") }
    let back = smc.set(a, on: false)
    print("switched back on, held: \(back)")
    sleep(3)
    line("After")
    print(ok && back ? "RESULT: the adapter switch works on this Mac." : "RESULT: the switch did not behave; nothing was left changed.")
}

func runKeys(prefixes: [String]) {
    let smc = SMC()
    guard let count = smc.keyCount() else { print("Couldn't read the SMC key count."); return }
    print("# \(count) SMC keys; showing prefixes: \(prefixes.isEmpty ? "all" : prefixes.joined(separator: " "))")
    for i in 0..<count {
        guard let name = smc.keyName(at: i) else { continue }
        if !prefixes.isEmpty && !prefixes.contains(where: { name.hasPrefix($0) }) { continue }
        let type = smc.typeName(of: name) ?? "?"
        let bytes = smc.read(name)
        let hex = bytes.map { $0.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "(unreadable)"
        print("\(name)  [\(type)]  size \(bytes?.count ?? 0)  \(hex)")
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "--daemon"
switch mode {
case "--probe":
    runProbe()
case "--test-adapter":
    runAdapterTest()
case "--keys":
    runKeys(prefixes: Array(CommandLine.arguments.dropFirst(2)))
case "--restore":
    guard geteuid() == 0 else { print("Run with sudo."); exit(1) }
    let smc = SMC()
    if let a = Candidates.firstAvailable(Candidates.adapterOff, in: smc) { print("adapter on: \(smc.set(a, on: false))") }
    if let c = Candidates.firstAvailable(Candidates.chargeInhibit, in: smc) { print("charging allowed: \(smc.set(c, on: false))") }
case "--daemon":
    guard geteuid() == 0 else { print("kwikbatteryd must run as root (it is started by launchd)."); exit(1) }
    let controller = Controller()
    sharedController = controller
    serve(controller: controller)

    // Poll every 5 seconds.
    let timer = DispatchSource.makeTimerSource(queue: controller.queue)
    timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
    timer.setEventHandler { controller.tick() }
    timer.resume()

    // Always leave the Mac charging normally when we're told to stop.
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: controller.queue)
        s.setEventHandler { controller.restoreNormal(); unlink(HelperPaths.socket); exit(0) }
        s.resume()
        sources.append(s)
    }

    // Sleep / wake notifications, delivered on the controller queue.
    var notifyPort: IONotificationPortRef?
    var notifier: io_object_t = 0
    rootPort = IORegisterForSystemPower(nil, &notifyPort, powerCallback, &notifier)
    if let notifyPort { IONotificationPortSetDispatchQueue(notifyPort, controller.queue) }

    dispatchMain()
default:
    print("usage: kwikbatteryd [--probe | --keys [PREFIX…] | --test-adapter | --restore | --daemon]")
    exit(2)
}
