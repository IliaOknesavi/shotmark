import AppKit
import Carbon.HIToolbox

/// Глобальные сочетания через Carbon: не требуют разрешения «Универсальный доступ».
@MainActor
enum Hotkeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    /// false — сочетание уже занято (например, системой).
    @discardableResult
    static func register(key: Int, mods: Int, _ fn: @escaping () -> Void) -> Bool {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.handlers[id]?() } }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(handlers.count + 1)
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: OSType(0x53484D4B), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        guard st == noErr else { return false }
        handlers[id] = fn
        return true
    }
}
