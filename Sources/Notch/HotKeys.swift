import Carbon

/// System-wide shortcuts through Carbon hot keys: no Accessibility permission needed.
/// They are only registered while a permission request is waiting.
@MainActor
final class HotKeys {
    struct Shortcut {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
    }

    static let allow = Shortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Y")
    static let deny = Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥N")

    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    /// Returns false if another app already owns the shortcut.
    @discardableResult
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        Self.installHandler()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F5443), id: id) // 'NOTC'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        Self.actions[id] = action
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        Self.actions.removeAll()
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotKeys.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
