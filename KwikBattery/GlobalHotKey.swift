//
//  GlobalHotKey.swift
//  KwikBattery
//
//  Opens the panel from anywhere with a keyboard shortcut (Settings › General).
//  Uses Carbon's RegisterEventHotKey, which needs no Accessibility or Input
//  Monitoring permission: the system delivers only this one key combination.
//

import Carbon.HIToolbox
import Combine

@MainActor
final class GlobalHotKey: ObservableObject {
    static let shared = GlobalHotKey()

    /// Called on the main actor when the shortcut is pressed.
    var onPress: (@MainActor () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var current: HotKeyChoice = .off

    /// The shortcut that couldn't be registered because another app owns it.
    @Published private(set) var failedChoice: HotKeyChoice?

    private init() {}

    func apply(_ choice: HotKeyChoice) {
        // The warning belongs to the combination that failed; choosing another one (or Off) clears it.
        if let failed = failedChoice, failed != choice { failedChoice = nil }
        guard choice != current else { return }
        unregister()
        current = choice
        guard let modifiers = choice.carbonModifiers else { return }
        // HotKeyChoice spells Carbon's masks out (it is Foundation-only); make
        // sure they still agree with Carbon's own constants.
        assert(HotKeyChoice.commandMask == UInt32(cmdKey)
               && HotKeyChoice.optionMask == UInt32(optionKey)
               && HotKeyChoice.controlMask == UInt32(controlKey)
               && HotKeyChoice.keyCodeB == UInt32(kVK_ANSI_B))
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4B57_4B42), id: 1)   // 'KWKB'
        let status = RegisterEventHotKey(HotKeyChoice.keyCodeB, modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            // Another app already owns this combination.
            NSLog("KwikBattery: couldn't register \(choice.title) (OSStatus \(status))")
            hotKeyRef = nil
            current = .off
            failedChoice = choice
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // A C callback can't capture context; it reaches the shared instance.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Task { @MainActor in GlobalHotKey.shared.onPress?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }
}
