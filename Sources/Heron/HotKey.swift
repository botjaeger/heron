import AppKit
import Carbon.HIToolbox
import HeronUI

/// The AI usage panel's global shortcut (Settings › AI Usage › Global shortcut), registered with
/// Carbon's `RegisterEventHotKey`: it works from any app and needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registered: String?
    var action: () -> Void = {}

    /// Registers `shortcut` ("⌥⌘U"), replacing the last one; nil or an unreadable one unregisters.
    func set(_ shortcut: String?) {
        guard shortcut != registered else { return }
        unregister()
        guard let shortcut, let key = AIShortcut(string: shortcut) else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4845_524E), id: 1)  // 'HERN'
        let status = RegisterEventHotKey(UInt32(key.keyCode), key.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { registered = shortcut } else { NSLog("Heron: shortcut \(shortcut) is taken (\(status))") }
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, data in
                guard let data else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(data).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { hotKey.action() } }
                return noErr
            }, 1, &spec, me, &handler)
    }
}
