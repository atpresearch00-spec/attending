import AppKit
import Carbon

@MainActor final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private let action: @MainActor () -> Void
    init(action: @escaping @MainActor () -> Void) throws {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let install = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.action() }
            return noErr
        }, 1, &event, context, &handler)
        guard install == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(install)) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Space), event.modifierFlags.contains([.command, .shift]) {
                self?.action(); return nil
            }
            return event
        }
        let id = EventHotKeyID(signature: 0x41535452, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
        guard result == noErr else {
            invalidate()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }
    func invalidate() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
