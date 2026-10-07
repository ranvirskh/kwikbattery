//
//  CommandLineTool.swift
//  KwikBattery
//
//  Controls KwikBattery from Terminal, scripts and the Shortcuts app (use the
//  "Run Shell Script" action). Everything here talks to the same helper the
//  Settings window uses, so the app and the command line always agree.
//
//      KwikBattery --status                     battery snapshot (JSON)
//      KwikBattery --helper-status              what the charge-control helper is doing (JSON)
//      KwikBattery --charge-limit 80            hold the battery at 80% (50-100; 100 = no limit)
//      KwikBattery --charge-limit current       hold it at the charge it has right now
//      KwikBattery --charge-limit off           stop managing charging
//      KwikBattery --top-up [95]                charge past the limit now (default 100)
//      KwikBattery --cancel-top-up              back to the limit
//      KwikBattery --low-power on|off           switch Low Power Mode now
//      KwikBattery --restore                    charge normally right now
//
//  Each command prints one line (or JSON) and exits: 0 on success, 1 if the
//  helper isn't installed, 2 for a bad command.
//

import Foundation

enum CommandLineTool {
    static let usage = """
    KwikBattery command line
      --status                    battery snapshot as JSON
      --helper-status             charge-control helper status as JSON
      --charge-limit 80|current|off   hold the battery at a charge (50-100), at its current charge, or stop managing
      --top-up [percent]          charge past the limit now (default 100)
      --cancel-top-up             return to the limit
      --low-power on|off          switch Low Power Mode now
      --restore                   charge normally right now
    Charge commands need the helper (Settings > Charge control > Install Helper).
    """

    /// Commands the app handles elsewhere (it launches normally or exits there).
    static let handledElsewhere: Set<String> = ["--status", "--smc-diag", "--idevice-diag"]

    /// An exit code when `arguments` held a command-line command, nil to start the app.
    static func run(_ arguments: [String]) -> Int32? {
        let args = Array(arguments.dropFirst())
        guard let command = args.first(where: { $0.hasPrefix("--") }) else { return nil }
        if handledElsewhere.contains(command) { return nil }
        let value = args.drop(while: { $0 != command }).dropFirst().first

        switch command {
        case "--help":
            print(usage)
            return 0
        case "--helper-status":
            guard let status = HelperSocket.send(HelperRequest(cmd: "status")) else { return missingHelper() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(data: (try? encoder.encode(status)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}")
            return 0
        case "--charge-limit":
            return setChargeLimit(value)
        case "--top-up":
            let target = value.flatMap { Int($0) } ?? 100
            guard (50...100).contains(target) else { return bad("top-up target must be 50-100") }
            return report(HelperSocket.send(HelperRequest(cmd: "topUpNow", target: target)),
                          done: "Topping up to \(target)%.")
        case "--cancel-top-up":
            return report(HelperSocket.send(HelperRequest(cmd: "cancelTopUp")), done: "Top-up cancelled.")
        case "--restore":
            return report(HelperSocket.send(HelperRequest(cmd: "restore")), done: "Charging normally.")
        case "--low-power":
            guard let value, ["on", "off"].contains(value.lowercased()) else { return bad("use --low-power on or off") }
            let on = value.lowercased() == "on"
            guard let current = HelperSocket.send(HelperRequest(cmd: "status")) else { return missingHelper() }
            guard current.version >= 3 else {
                print("Low Power Mode control needs the newer helper. Use Update Helper in Settings > Charge control.")
                return 1
            }
            return report(HelperSocket.send(HelperRequest(cmd: "setLowPower", lowPower: on)),
                          done: "Low Power Mode \(on ? "on" : "off").")
        default:
            return bad("unknown command \(command)")
        }
    }

    private static func setChargeLimit(_ value: String?) -> Int32 {
        guard let value else { return bad("use --charge-limit 80, current or off") }
        guard let status = HelperSocket.send(HelperRequest(cmd: "status")) else { return missingHelper() }
        var policy = status.policy

        switch value.lowercased() {
        case "off":
            policy.enabled = false
        case "current":
            let info = BatteryMonitor.readSnapshot()
            guard info.hasBattery else { return bad("no battery to read") }
            policy.enabled = true
            policy.limit = Swift.min(Swift.max(info.percentage, 50), 100)
        default:
            guard let limit = Int(value), (50...100).contains(limit) else {
                return bad("the limit must be a number from 50 to 100")
            }
            policy.enabled = true
            policy.limit = limit
        }
        let done = policy.enabled ? "Charge limit set to \(policy.limit)%." : "Charge control is off."
        return report(HelperSocket.send(HelperRequest(cmd: "setPolicy", policy: policy)), done: done)
    }

    private static func report(_ status: HelperStatus?, done: String) -> Int32 {
        guard let status else { return missingHelper() }
        print(done + " Now: " + status.reason + ".")
        return 0
    }

    private static func missingHelper() -> Int32 {
        print("The charge-control helper isn't installed or isn't running. Install it in KwikBattery > Settings > Charge control.")
        return 1
    }

    private static func bad(_ message: String) -> Int32 {
        print("kwikbattery: \(message)\n\n\(usage)")
        return 2
    }
}
