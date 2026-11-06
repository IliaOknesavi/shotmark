import AppKit
import Carbon.HIToolbox

/// Глобальные сочетания через Carbon: не требуют разрешения «Универсальный доступ».
@MainActor
enum Hotkeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var regs: [(key: Int, mods: Int, id: UInt32, ref: EventHotKeyRef?)] = []
    private static var installed = false

    /// false — сочетание уже занято другим приложением.
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
        handlers[id] = fn
        let ref = make(key, mods, id)
        regs.append((key, mods, id, ref))
        return ref != nil
    }

    /// Перерегистрировать всё, например после того как macOS отпустила свои сочетания.
    static func reregister() {
        regs = regs.map { r in
            if let ref = r.ref { UnregisterEventHotKey(ref) }
            return (r.key, r.mods, r.id, make(r.key, r.mods, r.id))
        }
    }

    private static func make(_ key: Int, _ mods: Int, _ id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: OSType(0x53484D4B), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        return st == noErr ? ref : nil
    }
}
