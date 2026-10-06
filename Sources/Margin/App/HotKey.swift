import Carbon.HIToolbox
import AppKit

/// System-wide shortcut via Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = action
        Self.installHandlerIfNeeded()

        var carbonMods: UInt32 = 0
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D52_474E) /* MRGN */, id: id)
        RegisterEventHotKey(keyCode, carbonMods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
