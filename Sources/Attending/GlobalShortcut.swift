import AppKit
import Carbon

/// System-wide keyboard shortcuts. One Carbon handler dispatches by hot-key ID, so
/// several shortcuts can be registered without each firing for the others.
@MainActor final class GlobalShortcut {
    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var handler: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private var hotKey: EventHotKeyRef?
    private var localMonitor: Any?
    private let id: UInt32

    /// ⌘⇧Space by default. While Attending is frontmost the key also arrives as a local event.
    init(keyCode: Int = kVK_Space, modifiers: Int = cmdKey | shiftKey, action: @escaping @MainActor () -> Void) throws {
        try Self.installHandler()
        id = Self.nextID; Self.nextID += 1
        Self.actions[id] = action
        let flags = Self.flags(modifiers)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(keyCode), event.modifierFlags.intersection([.command, .shift, .option, .control]) == flags {
                action(); return nil
            }
            return event
        }
        let result = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x41535452, id: id), GetApplicationEventTarget(), 0, &hotKey)
        guard result == noErr else {
            invalidate()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }
    func invalidate() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        Self.actions[id] = nil
    }

    private static func installHandler() throws {
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey) == noErr else { return OSStatus(eventNotHandledErr) }
            let id = hotKey.id
            MainActor.assumeIsolated { GlobalShortcut.actions[id]?() }
            return noErr
        }, 1, &event, nil, &handler)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private static func flags(_ modifiers: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & controlKey != 0 { flags.insert(.control) }
        return flags
    }
}
