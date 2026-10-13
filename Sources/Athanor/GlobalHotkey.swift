import Carbon.HIToolbox
import Foundation

/// One system-wide shortcut through Carbon's RegisterEventHotKey, which needs
/// no Accessibility permission, unlike watching all key presses.
@MainActor
final class GlobalHotkey {
    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func set(_ hotkey: Hotkey?) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        guard let hotkey else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4154_484E), id: 1) // 'ATHN'
        RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { hotkey.action?() }
            }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
