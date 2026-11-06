import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
enum Permissions {
    static func explain() {
        let a = NSAlert()
        a.messageText = "Shotmark нужен доступ к записи экрана"
        a.informativeText = "Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука: включите Shotmark, затем перезапустите приложение."
        a.addButton(withTitle: "Открыть настройки")
        a.addButton(withTitle: "Позже")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}

/// Действия по сочетаниям и из меню.
@MainActor
enum Actions {
    /// ⌘⇧3: весь монитор сразу в буфер и в историю.
    static func fullScreen() {
        Task {
            do {
                let sh = Store.shared.add(try await Capture.screen(index: nil, includeSelf: true), source: "screen")
                deliverCapture(sh.base)
            } catch { NSLog("Shotmark: \(error)"); Permissions.explain() }
        }
    }

    /// ⌘⇧4: экран замирает, разметка и выбор области прямо на нём.
    static func select() {
        Task { _ = await Editor.captureInPlace() }
    }

    static func toggleRecording() {
        Task {
            do {
                if Recorder.shared.isRecording {
                    let url = try await Recorder.shared.stop()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    guard let sel = await Overlay.select(hint: "Запись экрана: выделите область или окно") else { return }
                    switch sel {
                    case .area(_, let r), .window(_, let r): _ = try await Recorder.shared.start(rect: r)
                    }
                }
            } catch {
                let a = NSAlert(error: error)
                a.runModal()
            }
        }
    }

    static func openImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url, let img = loadImage(url) else { return }
        Editor.show(Store.shared.add(img, source: "file \(url.path)"))
    }
}

/// Системные ⌘⇧3/4/5 (и варианты с ⌃) в com.apple.symbolichotkeys. Меняются только по нажатию пункта меню.
enum SystemShortcuts {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    private static let ids: [(String, [Int])] = [("28", [51, 20, 1179648]), ("29", [51, 20, 1441792]),
                                                 ("30", [52, 21, 1179648]), ("31", [52, 21, 1441792]), ("184", [53, 23, 1179648])]

    static var enabled: Bool {
        let all = CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
        return ids.contains { id, _ in ((all[id] as? [String: Any])?["enabled"] as? Bool) ?? true }
    }

    static func set(enabled: Bool) {
        var all = CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
        for (id, params) in ids {
            all[id] = ["enabled": enabled, "value": ["parameters": params, "type": "standard"]] as [String: Any]
        }
        CFPreferencesSetAppValue(key, all as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        // применяет сочетания без выхода из системы
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        p.arguments = ["-u"]
        try? p.run()
        p.waitUntilExit()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let mcp = MCPServer()
    var busy: [String] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        status.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shotmark")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        let cmdShift = cmdKey | shiftKey
        for (key, name, fn) in [(kVK_ANSI_3, "⌘⇧3", Actions.fullScreen), (kVK_ANSI_4, "⌘⇧4", Actions.select),
                                (kVK_ANSI_5, "⌘⇧5", Actions.toggleRecording)] {
            if !Hotkeys.register(key: key, mods: cmdShift, fn) { busy.append(name) }
        }
        if SystemShortcuts.enabled { busy = ["⌘⇧3", "⌘⇧4", "⌘⇧5"] }
        Recorder.shared.onChange = { [weak self] in
            self?.status.button?.image = NSImage(systemSymbolName: Recorder.shared.isRecording ? "record.circle.fill" : "camera.viewfinder",
                                                 accessibilityDescription: "Shotmark")
        }
        mcp.start()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if SystemShortcuts.enabled { offerDisableSystemShortcuts() }
        // автозапуск включается один раз при первом запуске; дальше — как решил человек в меню
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            setLaunchAtLogin(true)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Shotmark: автозапуск \(on ? "включить" : "выключить") не удалось: \(error)")
        }
        NSLog("Shotmark: автозапуск \(SMAppService.mainApp.status.rawValue)")
    }

    /// Значок может спрятаться в переполненной строке меню, поэтому предлагаем отключение сами.
    func offerDisableSystemShortcuts() {
        let a = NSAlert()
        a.messageText = "Отдать ⌘⇧3, ⌘⇧4 и ⌘⇧5 приложению Shotmark?"
        a.informativeText = "Сейчас эти сочетания перехватывают стандартные скриншоты macOS. Вернуть их можно в меню Shotmark или в Системных настройках → Клавиатура → Сочетания клавиш → Снимки экрана."
        a.addButton(withTitle: "Отключить системные")
        a.addButton(withTitle: "Не сейчас")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            SystemShortcuts.set(enabled: false)
            Hotkeys.reregister()
        }
    }

    /// Повторный запуск (Spotlight, Finder) — меню прямо у курсора.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let menu = status.menu else { return false }
        menuNeedsUpdate(menu)
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ key: String = "", _ fn: @escaping () -> Void) {
            let i = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
            i.keyEquivalentModifierMask = [.command, .shift]
            i.target = self
            i.representedObject = fn
            menu.addItem(i)
        }
        item("Весь экран", "3", Actions.fullScreen)
        item("Область или окно", "4", Actions.select)
        item(Recorder.shared.isRecording ? "Остановить запись" : "Записать экран…", "5", Actions.toggleRecording)
        menu.addItem(.separator())
        item("Открыть изображение…") { Actions.openImage() }
        item("Последний снимок") { if let s = Store.shared.get(nil) { Editor.show(s) } }
        item("Папка снимков") { NSWorkspace.shared.open(Store.shared.shotsDir) }
        menu.addItem(.separator())
        busy = SystemShortcuts.enabled ? ["⌘⇧3", "⌘⇧4", "⌘⇧5"] : []
        if !busy.isEmpty {
            let i = NSMenuItem(title: "Сейчас их перехватывает macOS: \(busy.joined(separator: ", "))", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        if SystemShortcuts.enabled {
            item("Отключить системные сочетания скриншотов") {
                SystemShortcuts.set(enabled: false)
                Hotkeys.reregister()
            }
        } else {
            item("Вернуть системные сочетания скриншотов") { SystemShortcuts.set(enabled: true) }
        }
        let login = SMAppService.mainApp.status
        item("Запускать при входе") { [weak self] in self?.setLaunchAtLogin(login != .enabled) }
        menu.items.last?.state = login == .enabled ? .on : .off
        item("Скопировать команду подключения MCP") { [mcp] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(mcp.addCommand, forType: .string)
        }
        menu.addItem(.separator())
        item("Выход") { NSApp.terminate(nil) }
    }

    @objc func run(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
