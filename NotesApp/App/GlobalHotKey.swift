import Carbon
import Foundation

/// A system-wide hotkey through Carbon's RegisterEventHotKey, which needs no
/// accessibility permission. Default: ⌃⌥⌘R toggles recording from any app.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    init(keyCode: UInt32 = 15 /* R */, modifiers: UInt32 = UInt32(cmdKey | optionKey | controlKey), callback: @escaping () -> Void) {
        self.callback = callback
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().callback()
            return noErr
        }, 1, &spec, selfPointer, &handlerRef)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F5445), id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
