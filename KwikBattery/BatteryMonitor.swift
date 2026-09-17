//
//  BatteryMonitor.swift
//  KwikBattery
//
//  Wraps every IOKit call KwikBattery makes and publishes a `BatteryInfo`.
//
//  There are two IOKit data sources, and we merge them:
//
//  1. The Power Sources API (IOKit/ps/IOPowerSources.h)
//     - IOPSCopyPowerSourcesInfo()      -> an opaque "blob" snapshot
//     - IOPSCopyPowerSourcesList(blob)  -> array of power-source handles
//     - IOPSGetPowerSourceDescription() -> a CFDictionary per source
//     This is the stable, documented API that the macOS battery menu uses.
//     It gives charge %, charging state, AC/battery, time estimates and a
//     coarse health string. It does NOT give mAh, cycles, volts or temperature.
//
//  2. The IORegistry entry of the "AppleSmartBattery" driver
//     - IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
//     - IORegistryEntryCreateCFProperties(...)
//     This is the same data `ioreg -rn AppleSmartBattery` prints. It is not a
//     formally documented API, so key names differ a little between Intel and
//     Apple Silicon and between macOS versions — every read below is optional
//     and falls back gracefully. Reading these properties does NOT require
//     root, the SMC, or any special entitlement.
//
//  Updates are reactive: IOPSNotificationCreateRunLoopSource fires whenever
//  the power source changes (plug/unplug, % change). Because temperature,
//  voltage and amperage change without triggering that notification, we also
//  poll lightly every 30 seconds.
//

import Foundation
import Combine
import IOKit
import IOKit.ps

/// C callback for IOPSNotificationCreateRunLoopSource.
/// Declared at file scope so it is a plain, non-isolated C function pointer
/// (IOPowerSourceCallbackType = @convention(c) (UnsafeMutableRawPointer?) -> Void).
/// A C function pointer cannot capture Swift context, so the BatteryMonitor
/// instance travels through the `context` void* instead.
private let batteryPowerSourceCallback: IOPowerSourceCallbackType = { context in
    guard let context else { return }
    let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
    // The run loop source is added to the *main* run loop, so this callback
    // always executes on the main thread — assert that and hop onto MainActor.
    MainActor.assumeIsolated {
        monitor.refresh()
    }
}

@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published private(set) var info: BatteryInfo = .empty

    private var runLoopSource: CFRunLoopSource?
    private var pollCancellable: AnyCancellable?
    /// Background refresh rate vs. the rate while the dropdown is open.
    /// While the dropdown is closed nothing on screen changes except the menu
    /// bar percentage, and IOPSNotificationCreateRunLoopSource already wakes us
    /// the instant the charge level or charger state changes. So the idle timer
    /// is only a safety net (for values that change without an IOPS event, like
    /// temperature and battery health), not the main update path.
    private let idleInterval: TimeInterval = 300
    // 2 s rather than 1 s: each refresh copies the whole AppleSmartBattery
    // property table and makes up to 7 SMC syscalls, so this roughly halves
    // the syscall volume while the readings still feel live.
    private let liveInterval: TimeInterval = 2
    private var isLive = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        refresh()
        registerForPowerSourceChanges()

        // Light polling for values IOPS notifications don't cover (temp, watts).
        schedulePolling()
    }

    /// While the dropdown is open, refresh every second so voltage / watts feel live.
    func setLiveUpdates(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live { refresh() }
        schedulePolling()
    }

    private func schedulePolling() {
        pollCancellable?.cancel()
        pollCancellable = Timer.publish(every: isLive ? liveInterval : idleInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func stop() {
        pollCancellable?.cancel()
        pollCancellable = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            runLoopSource = nil
        }
    }

    /// Re-reads all IOKit data and publishes a fresh `BatteryInfo`.
    func refresh() {
        let ps = Self.readInternalBatteryPowerSource()
        let sb = Self.readSmartBatteryProperties()
        let adapter = Self.readAdapterDetails()
        var newInfo = Self.makeBatteryInfo(powerSource: ps, smartBattery: sb, adapter: adapter)
        newInfo.poweredAccessories = AccessoryPowerReader.read(smartBattery: sb)
        if newInfo.hasBattery {
            Self.applyLiveSMC(to: &newInfo)
        }
        info = newInfo
    }

    /// Overlays fast-updating SMC sensor values on top of the (slow) IORegistry data.
    nonisolated static func applyLiveSMC(to info: inout BatteryInfo) {
        let smc = SMCReader.shared
        guard smc.isAvailable else { return }
        let live = smc.snapshot(referenceAmps: info.amperage, referenceVolts: info.voltage)

        if let v = live.batteryVoltage { info.voltage = v }
        if let a = live.batteryCurrent {
            info.amperage = a
            if info.isPluggedIn && a > 0.05 { info.isCharging = true }
        }
        if let p = live.batteryPower {
            info.batteryPowerMeasured = p
        } else if live.batteryVoltage != nil || live.batteryCurrent != nil {
            // Intel: no battery-power key, so let batteryWatts use live V × A.
            info.batteryPowerMeasured = nil
        }
        if let p = live.systemPower { info.systemLoad = p }

        if info.isPluggedIn {
            if let p = live.adapterPower { info.systemPowerIn = p }
            if let v = live.adapterVoltage { info.systemVoltageIn = v }
            if let a = live.adapterCurrent { info.systemCurrentIn = a }
        }
    }

    // MARK: - IOKit: change notifications

    private func registerForPowerSourceChanges() {
        guard runLoopSource == nil else { return }

        // IOPSNotificationCreateRunLoopSource takes a plain C function pointer
        // (see `batteryPowerSourceCallback` above) plus a void* context. We pass
        // `self` as that context and recover it inside the callback.
        // `passUnretained` is safe because BatteryMonitor is a process-lifetime singleton.
        let context = Unmanaged.passUnretained(self).toOpaque()

        // The function follows the CF "Create" rule, so we own the returned
        // source: takeRetainedValue() hands that ownership to ARC.
        guard let source = IOPSNotificationCreateRunLoopSource(batteryPowerSourceCallback, context)?.takeRetainedValue() else {
            NSLog("KwikBattery: IOPSNotificationCreateRunLoopSource failed; relying on polling only.")
            return
        }
        // commonModes => updates keep arriving even while a menu/popover is tracking.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        runLoopSource = source
    }

    // MARK: - IOKit: Power Sources API

    /// Returns the description dictionary of the internal battery, or nil on
    /// Macs without one.
    ///
    /// Key strings used below (they are #defines in IOPSKeys.h; we use the
    /// literal values to keep things explicit):
    ///   "Type"                  kIOPSTypeKey            == "InternalBattery"
    ///   "Is Present"            kIOPSIsPresentKey
    ///   "Current Capacity"      kIOPSCurrentCapacityKey (percent on modern macOS)
    ///   "Max Capacity"          kIOPSMaxCapacityKey     (100 on modern macOS)
    ///   "Is Charging"           kIOPSIsChargingKey
    ///   "Is Charged"            kIOPSIsChargedKey
    ///   "Power Source State"    kIOPSPowerSourceStateKey == "AC Power" | "Battery Power"
    ///   "Time to Empty"         kIOPSTimeToEmptyKey     (minutes, -1 = calculating)
    ///   "Time to Full Charge"   kIOPSTimeToFullChargeKey (minutes, -1 = calculating)
    ///   "BatteryHealth"         kIOPSBatteryHealthKey   ("Good" | "Fair" | "Poor" …)
    ///   "BatteryHealthCondition" kIOPSBatteryHealthConditionKey ("Check Battery", "Service Recommended"…)
    nonisolated static func readInternalBatteryPowerSource() -> [String: Any]? {
        // Snapshot of all power sources. Follows the Copy rule → retained.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }

        // Array of opaque handles, one per power source (battery, UPS, …). Also Copy → retained.
        guard let cfSources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        let sources = cfSources as NSArray

        for source in sources {
            // "Get" rule: the dictionary is owned by `blob`, so we must NOT release it.
            guard let unmanagedDesc = IOPSGetPowerSourceDescription(blob, source as CFTypeRef) else { continue }
            let desc = unmanagedDesc.takeUnretainedValue() as NSDictionary
            guard let dict = desc as? [String: Any] else { continue }
            if (dict["Type"] as? String) == "InternalBattery" {
                return dict
            }
        }
        return nil
    }

    /// Details of the connected power adapter, e.g. ["Watts": 96, "Name": "96W USB-C Power Adapter", …].
    nonisolated static func readAdapterDetails() -> [String: Any]? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() else { return nil }
        return (details as NSDictionary) as? [String: Any]
    }

    // MARK: - IOKit: AppleSmartBattery registry entry

    /// All properties of the AppleSmartBattery IORegistry entry.
    ///
    /// Useful keys (units in brackets). "Raw" variants are needed on Apple
    /// Silicon, where the non-raw MaxCapacity/CurrentCapacity are percentages:
    ///   CycleCount                [count]
    ///   DesignCapacity            [mAh]   (also inside "BatteryData" on some models)
    ///   AppleRawMaxCapacity       [mAh]   Apple Silicon: real full-charge capacity
    ///   NominalChargeCapacity     [mAh]   alternative full-charge capacity
    ///   MaxCapacity               [mAh on Intel, % on Apple Silicon]
    ///   AppleRawCurrentCapacity   [mAh]
    ///   CurrentCapacity           [mAh on Intel, % on Apple Silicon]
    ///   Voltage                   [mV]
    ///   Amperage / InstantAmperage [mA, signed; + charging, − discharging]
    ///   Temperature               [centi-°C, e.g. 3012 = 30.12 °C]
    ///   IsCharging, ExternalConnected, FullyCharged, BatteryInstalled [Bool]
    ///   AvgTimeToEmpty / AvgTimeToFull [minutes, 65535 = invalid]
    ///   PermanentFailureStatus    [non-zero = battery fault]
    ///   ChargerData.NotChargingReason [non-zero = charging paused by the system]
    nonisolated static func readSmartBatteryProperties() -> [String: Any]? {
        // IOServiceMatching builds a matching dictionary for the driver class.
        // IOServiceGetMatchingService *consumes* that dictionary (no release needed)
        // and returns an io_service_t we DO need to release with IOObjectRelease.
        // kIOMainPortDefault (macOS 12+) replaces the deprecated kIOMasterPortDefault.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        // io_service_t is a mach port number; 0 (IO_OBJECT_NULL) means "not found"
        // — e.g. on a Mac mini / iMac / Mac Studio.
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        // Copies the entry's entire property table into a CFMutableDictionary.
        // "Create" rule → takeRetainedValue(). Options must be 0.
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    // MARK: - Parsing

    /// CF numbers arrive as NSNumber.
    nonisolated private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    /// Signed values (Amperage, Temperature on some models) are sometimes
    /// exposed as unsigned integers holding a two's-complement bit pattern,
    /// e.g. -1500 mA shows up as 18446744073709550116 (64-bit) or 64036 (16-bit).
    nonisolated private static func signedInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        var v = Int(truncatingIfNeeded: number.int64Value)
        if v > 32_767 && v <= 65_535 { v -= 65_536 }   // 16-bit two's complement
        return v
    }

    nonisolated private static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        return (value as? NSNumber)?.boolValue
    }

    /// Merges the two IOKit sources into a `BatteryInfo`.
    nonisolated static func makeBatteryInfo(powerSource ps: [String: Any]?,
                                            smartBattery sb: [String: Any]?,
                                            adapter: [String: Any]?) -> BatteryInfo {
        var info = BatteryInfo()
        info.lastUpdated = Date()

        let present = bool(ps?["Is Present"]) ?? bool(sb?["BatteryInstalled"]) ?? (ps != nil || sb != nil)
        info.hasBattery = present && (ps != nil || sb != nil)
        guard info.hasBattery else { return info }

        // --- Charge percentage ---------------------------------------------
        if let cur = int(ps?["Current Capacity"]), let maxCap = int(ps?["Max Capacity"]), maxCap > 0 {
            info.percentage = Int((Double(cur) / Double(maxCap) * 100).rounded())
        } else if let cur = int(sb?["CurrentCapacity"]), let maxCap = int(sb?["MaxCapacity"]), maxCap > 0 {
            // Intel: both mAh; Apple Silicon: both percentages (max == 100). Ratio works for both.
            info.percentage = Int((Double(cur) / Double(maxCap) * 100).rounded())
        }
        info.percentage = Swift.min(Swift.max(info.percentage, 0), 100)

        // --- Charging state -------------------------------------------------
        if let state = ps?["Power Source State"] as? String {
            info.isPluggedIn = (state == "AC Power")
        } else {
            info.isPluggedIn = bool(sb?["ExternalConnected"]) ?? false
        }
        // Either source saying "charging" counts (they occasionally disagree).
        info.isCharging = (bool(ps?["Is Charging"]) ?? false) || (bool(sb?["IsCharging"]) ?? false)
        info.isFullyCharged = bool(ps?["Is Charged"]) ?? bool(sb?["FullyCharged"]) ?? false

        // --- Capacities (mAh) -----------------------------------------------
        let batteryData = sb?["BatteryData"] as? [String: Any]
        info.designCapacity = int(sb?["DesignCapacity"]) ?? int(batteryData?["DesignCapacity"])

        if let raw = int(sb?["AppleRawMaxCapacity"]), raw > 0 {
            info.maxCapacity = raw                                    // Apple Silicon
        } else if let nominal = int(sb?["NominalChargeCapacity"]), nominal > 0 {
            info.maxCapacity = nominal
        } else if let maxCap = int(sb?["MaxCapacity"]), maxCap > 100 {
            info.maxCapacity = maxCap                                  // Intel (mAh)
        }

        if let raw = int(sb?["AppleRawCurrentCapacity"]), raw > 0 {
            info.currentCapacity = raw
        } else if let cur = int(sb?["CurrentCapacity"]), let maxCap = int(sb?["MaxCapacity"]), maxCap > 100 {
            info.currentCapacity = cur
        }

        info.cycleCount = int(sb?["CycleCount"]) ?? int(batteryData?["CycleCount"])

        // --- Time estimates -------------------------------------------------
        // IOPS returns -1 while macOS is still calculating.
        if let tte = int(ps?["Time to Empty"]), tte > 0, !info.isPluggedIn {
            info.timeToEmptyMinutes = tte
        } else if let avg = int(sb?["AvgTimeToEmpty"]), avg > 0, avg < 65_535, !info.isPluggedIn {
            info.timeToEmptyMinutes = avg
        }
        if let ttf = int(ps?["Time to Full Charge"]), ttf > 0, info.isCharging {
            info.timeToFullMinutes = ttf
        } else if let avg = int(sb?["AvgTimeToFull"]), avg > 0, avg < 65_535, info.isCharging {
            info.timeToFullMinutes = avg
        }

        // --- Electrical: V × A = W -------------------------------------------
        if let mv = int(sb?["Voltage"]) ?? int(sb?["AppleRawBatteryVoltage"]), mv > 0 {
            info.voltage = Double(mv) / 1000.0
        }
        if let ma = signedInt(sb?["Amperage"]) ?? signedInt(sb?["InstantAmperage"]) {
            info.amperage = Double(ma) / 1000.0
        }

        // Per-cell voltages (mV array) — used for the "Normal voltage" check.
        if let cells = (sb?["CellVoltage"] as? [NSNumber]) ?? (batteryData?["CellVoltage"] as? [NSNumber]) {
            info.cellVoltages = cells.map { $0.doubleValue / 1000.0 }.filter { $0 > 0 }
        }

        // Adapter rating: prefer the IOPS adapter API, fall back to the registry copy.
        let adapterDict = adapter ?? (sb?["AdapterDetails"] as? [String: Any])
        if info.isPluggedIn, let watts = int(adapterDict?["Watts"]), watts > 0 {
            info.adapterWatts = watts
            info.adapterName = (adapterDict?["Name"] as? String) ?? (adapterDict?["Description"] as? String)
        }

        // --- Temperature ------------------------------------------------------
        // Reported in hundredths of a degree Celsius. Some models expose
        // "VirtualTemperature" instead. Ignore obviously bogus values.
        if let t = signedInt(sb?["Temperature"]) ?? signedInt(sb?["VirtualTemperature"]) {
            let c = Double(t) / 100.0
            if c > -40 && c < 120 && t != 0 { info.temperatureCelsius = c }
        }

        // --- Condition ----------------------------------------------------------
        info.condition = condition(powerSource: ps, smartBattery: sb)

        // --- Charging sanity check ------------------------------------------
        // Current flowing INTO the battery is the ground truth: if the flags
        // say "not charging" but >50 mA is going in, it is charging.
        if info.isPluggedIn, !info.isCharging, let amps = info.amperage, amps > 0.05 {
            info.isCharging = true
        }

        // Why macOS is holding the charge (non-zero = charging inhibited).
        if let chargerData = sb?["ChargerData"] as? [String: Any] {
            info.notChargingReason = int(chargerData["NotChargingReason"]) ?? 0
        }

        // --- Live power telemetry ------------------------------------------
        // Apple silicon exposes a "PowerTelemetryData" dictionary with the
        // real-time power budget (all values in mW / mV / mA):
        //   SystemPowerIn    power arriving from the adapter
        //   SystemVoltageIn  voltage at the power input
        //   SystemCurrentIn  current at the power input
        //   SystemLoad       power consumed by the whole system, including
        //                    power sent out to USB accessories
        //   BatteryPower     power going into / out of the battery
        // Intel Macs don't have it; the UI then falls back to V × A estimates.
        if let telemetry = sb?["PowerTelemetryData"] as? [String: Any] {
            if info.isPluggedIn, let mw = int(telemetry["SystemPowerIn"]), mw > 0 {
                info.systemPowerIn = Double(mw) / 1000.0
            }
            if info.isPluggedIn, let mv = int(telemetry["SystemVoltageIn"]), mv > 0 {
                info.systemVoltageIn = Double(mv) / 1000.0
            }
            if info.isPluggedIn, let ma = int(telemetry["SystemCurrentIn"]), ma > 0 {
                info.systemCurrentIn = Double(ma) / 1000.0
            }
            if let mw = int(telemetry["SystemLoad"]), mw > 0 {
                info.systemLoad = Double(mw) / 1000.0
            }
            if let mw = int(telemetry["BatteryPower"]), mw > 0, mw < 250_000 {
                info.batteryPowerMeasured = Double(mw) / 1000.0
            }
        }

        // USB-C Power Delivery contract negotiated with the adapter.
        if info.isPluggedIn {
            if let mv = int(adapterDict?["AdapterVoltage"]), mv > 0 {
                info.adapterVoltage = Double(mv) / 1000.0
            }
            if let ma = int(adapterDict?["Current"]), ma > 0 {
                info.adapterCurrent = Double(ma) / 1000.0
            }
        }

        return info
    }

    /// Maps IOKit's health strings to what System Settings shows.
    nonisolated private static func condition(powerSource ps: [String: Any]?, smartBattery sb: [String: Any]?) -> String {
        // Present only when something is wrong, e.g. "Check Battery", "Service Recommended".
        if let c = ps?["BatteryHealthCondition"] as? String, !c.isEmpty {
            return c
        }
        if let failure = int(sb?["PermanentFailureStatus"]), failure != 0 {
            return "Service Recommended"
        }
        if let health = ps?["BatteryHealth"] as? String {
            switch health {
            case "Good":                  return "Normal"
            case "Fair":                  return "Fair"
            case "Poor", "Check Battery": return "Service Recommended"
            default:                      return health
            }
        }
        return "Unknown"
    }
}
