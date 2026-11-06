import AppKit
import Carbon.HIToolbox

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
    static func shot(from sel: Selection) async throws -> Shot {
        switch sel {
        case .area(let img, _): return Store.shared.add(img, source: "area")
        case .window(let id, _): return Store.shared.add(try await Capture.window(id), source: "window \(id)")
        }
    }

    /// После ручного снимка: в буфер и в редактор.
    static func deliver(_ sh: Shot) {
        copyToClipboard(sh.base)
        Editor.show(sh)
    }

    static func fullScreen() {
        Task {
            do { deliver(Store.shared.add(try await Capture.screen(index: nil), source: "screen")) }
            catch { NSLog("Shotmark: \(error)"); Permissions.explain() }
        }
    }

    static func select() {
        Task {
            guard let sel = await Overlay.select() else { return }
            do { deliver(try await shot(from: sel)) } catch { NSLog("Shotmark: \(error)") }
        }
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
        Recorder.shared.onChange = { [weak self] in
            self?.status.button?.image = NSImage(systemSymbolName: Recorder.shared.isRecording ? "record.circle.fill" : "camera.viewfinder",
                                                 accessibilityDescription: "Shotmark")
        }
        mcp.start()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
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
        if !busy.isEmpty {
            let i = NSMenuItem(title: "Заняты системой: \(busy.joined(separator: ", "))", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
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
