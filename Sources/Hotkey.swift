import AppKit
import Carbon

/// A global hotkey (e.g. ⌃⌥Y). Carbon hotkeys need no Accessibility / Input Monitoring
/// permission and report both press and release.
final class Hotkey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private static var registry: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?

    private let id: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var ref: EventHotKeyRef?
    private var isDown = false

    init(keyCode: UInt32, modifiers: UInt32 = UInt32(controlKey | optionKey), enabled: Bool = true) {
        Hotkey.installHandler()
        id = Hotkey.nextID
        Hotkey.nextID += 1
        self.keyCode = keyCode
        self.modifiers = modifiers
        Hotkey.registry[id] = self
        if enabled { setEnabled(true) }
    }

    /// Registers or releases the shortcut, so it only swallows the keys while needed.
    func setEnabled(_ on: Bool) {
        if on, ref == nil {
            RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4255_4459), id: id), // "BUDY"
                                GetApplicationEventTarget(), 0, &ref)
        } else if !on, let r = ref {
            UnregisterEventHotKey(r)
            ref = nil
            isDown = false
        }
    }

    private func fire(_ pressed: Bool) {
        guard pressed != isDown else { return }
        isDown = pressed
        pressed ? onPress?() : onRelease?()
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            DispatchQueue.main.async { Hotkey.registry[id]?.fire(pressed) }
            return noErr
        }, 2, &types, nil, &handler)
    }
}
