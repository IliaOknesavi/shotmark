import AppKit
import UniformTypeIdentifiers

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Редактор разметки. Два режима: обычное окно для готового снимка и
/// «поверх экрана» — замороженный монитор во весь экран, где рисуешь и выделяешь область прямо в момент снимка.
@MainActor
final class Editor: NSObject, NSWindowDelegate {
    static var open: [String: Editor] = [:]
    /// Уровень снимка «поверх экрана»: по окну на монитор. Уровни складываются стопкой —
    /// ⌘⇧4 внутри уровня снимает экран вместе с ним и открывает следующий.
    private final class Level {
        var editors: [Editor] = []
        var done: (() -> Void)?
        var result: Shot?
    }
    private static var levels: [Level] = []
    private weak var level: Level?

    let shot: Shot
    let window: NSWindow
    let canvas: Canvas
    let isOverlay: Bool
    var waiters: [() -> Void] = []

    static let tools: [(id: String, symbol: String, tip: String)] = [
        ("select", "cursorarrow", "Выбор (V): двигать и менять размер; правая кнопка по фигуре — свойства"),
        ("crop", "crop", "Область (C): отпусти — снимок, клик — окно, правая кнопка — сброс"),
        ("arrow", "arrow.up.right", "Стрелка (A)"), ("line", "line.diagonal", "Линия (L)"),
        ("rect", "rectangle", "Прямоугольник (R)"), ("ellipse", "circle", "Эллипс (E)"),
        ("pen", "pencil", "Перо (P)"), ("marker", "highlighter", "Маркер (M)"),
        ("text", "textformat", "Текст (T)"), ("callout", "text.bubble", "Выноска (O)"),
        ("step", "1.circle", "Шаг (N)"), ("blur", "drop", "Размытие (B)"),
        ("pixelate", "square.grid.3x3", "Пикселизация (X)"), ("loupe", "plus.magnifyingglass", "Лупа (Z)"),
    ]
    static let keys: [Character: String] = ["a": "arrow", "l": "line", "r": "rect", "e": "ellipse", "p": "pen", "m": "marker",
                                            "t": "text", "o": "callout", "n": "step", "b": "blur", "x": "pixelate", "z": "loupe", "c": "crop", "v": "select"]

    let toolPicker = NSSegmentedControl()
    let colorWell = NSColorWell(style: .minimal)
    let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 20, target: nil, action: nil)
    let fillBox = NSButton(checkboxWithTitle: "Заливка", target: nil, action: nil)

    @discardableResult
    static func show(_ shot: Shot) -> Editor {
        if let e = open[shot.id] { e.front(); return e }
        let e = Editor(shot: shot)
        open[shot.id] = e
        e.front()
        return e
    }

    /// Ждать, пока человек закроет редактор.
    func waitClose() async {
        await withCheckedContinuation { c in waiters.append { c.resume() } }
    }

    /// Снимок «в момент»: экраны замирают, на них рисуют и выделяют область. nil — отмена.
    static func captureInPlace(hint: String? = nil) async -> Shot? {
        let frozen = await Capture.freezeAll(includeSelf: true)
        guard !frozen.isEmpty else {
            NSSound.beep()
            Permissions.explain()
            return nil
        }
        let wins = Overlay.windowList()
        let lv = Level()
        levels.append(lv)
        NSApp.activate(ignoringOtherApps: true)
        for s in NSScreen.screens {
            guard let img = frozen[s.displayID] else { continue }
            let e = Editor(shot: Store.shared.temp(img, source: "screen"), screen: s, hint: hint, windows: wins)
            e.level = lv
            lv.editors.append(e)
        }
        focus(lv)
        await withCheckedContinuation { c in lv.done = { c.resume() } }
        levels.removeAll { $0 === lv }
        if let below = levels.last { focus(below) }
        return lv.result
    }

    private static func focus(_ lv: Level) {
        let mouse = NSEvent.mouseLocation
        for e in lv.editors {
            e.window.orderFrontRegardless()
            if let s = e.window.screen, NSMouseInRect(mouse, s.frame, false) {
                e.window.makeKey()
                e.window.makeFirstResponder(e.canvas)
            }
        }
    }

    init(shot: Shot, screen: NSScreen? = nil, hint: String? = nil, windows: [(CGWindowID, CGRect)] = []) {
        self.shot = shot
        isOverlay = screen != nil
        canvas = Canvas(shot: shot)
        if let screen {
            window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            // выше Dock и строки меню, но ниже контекстных меню (иначе меню правой кнопки окажется под снимком)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.acceptsMouseMovedEvents = true
            canvas.fullBleed = true
            canvas.screenTL = screen.topLeftFrame
            canvas.winRects = windows
        } else {
            let vis = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let k = shot.source.hasPrefix("file") ? 1 : (NSScreen.main?.backingScaleFactor ?? 2)
            let want = CGSize(width: max(900, shot.size.width / k + 40), height: shot.size.height / k + 100)
            let size = CGSize(width: min(want.width, vis.width * 0.9), height: min(want.height, vis.height * 0.9))
            window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        }
        super.init()
        window.title = "Shotmark — \(shot.id)"
        window.isReleasedWhenClosed = false
        window.delegate = self

        toolPicker.segmentCount = Editor.tools.count
        toolPicker.trackingMode = .selectOne
        for (i, t) in Editor.tools.enumerated() {
            toolPicker.setImage(NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.tip), forSegment: i)
            toolPicker.setToolTip(t.tip, forSegment: i)
            toolPicker.setWidth(30, forSegment: i)
        }
        toolPicker.selectedSegment = Editor.tools.firstIndex { $0.id == (isOverlay ? "crop" : "arrow") }!
        toolPicker.target = self; toolPicker.action = #selector(toolChanged)
        colorWell.color = .systemRed
        colorWell.target = self; colorWell.action = #selector(styleChanged)
        widthSlider.target = self; widthSlider.action = #selector(styleChanged)
        widthSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        widthSlider.toolTip = "Толщина"
        fillBox.target = self; fillBox.action = #selector(styleChanged)

        func button(_ symbol: String, _ tip: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: sel)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            b.keyEquivalent = key
            b.keyEquivalentModifierMask = mods
            return b
        }
        let undoB = button("arrow.uturn.backward", "Отменить (⌘Z)", #selector(undo), "z")
        let redoB = button("arrow.uturn.forward", "Повторить (⌘⇧Z)", #selector(redo), "Z", [.command, .shift])
        let done = NSButton(title: isOverlay ? "Копировать" : "Готово", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded

        if isOverlay {
            done.toolTip = "Скопировать в буфер и закрыть (↩ или ⌘C)"
            let cancel = button("xmark", "Отмена (Esc)", #selector(cancelTapped))
            var rows: [NSView] = []
            if let hint {
                let l = NSTextField(wrappingLabelWithString: hint)
                l.font = .systemFont(ofSize: 13, weight: .semibold)
                l.preferredMaxLayoutWidth = 700
                rows.append(l)
            }
            let bar = NSStackView(views: [toolPicker, colorWell, widthSlider, fillBox, undoB, redoB,
                                          button("macwindow", "Открыть в редакторе (⌘E)", #selector(toEditor), "e"),
                                          button("doc.on.doc", "Копировать (⌘C)", #selector(copyImage), "c"),
                                          done, cancel])
            bar.spacing = 8
            rows.append(bar)
            let col = NSStackView(views: rows)
            col.orientation = .vertical
            col.alignment = .leading
            col.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            let panel = NSVisualEffectView()
            panel.material = .hudWindow
            panel.blendingMode = .withinWindow
            panel.state = .active
            panel.wantsLayer = true
            panel.layer?.cornerRadius = 10
            panel.addSubview(col)
            col.translatesAutoresizingMaskIntoConstraints = false
            panel.translatesAutoresizingMaskIntoConstraints = false
            canvas.translatesAutoresizingMaskIntoConstraints = true
            canvas.frame = CGRect(origin: .zero, size: window.frame.size)
            canvas.autoresizingMask = [.width, .height]
            window.contentView = canvas
            canvas.addSubview(panel)
            NSLayoutConstraint.activate([
                col.leadingAnchor.constraint(equalTo: panel.leadingAnchor), col.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                col.topAnchor.constraint(equalTo: panel.topAnchor), col.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
                panel.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
                panel.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 36),
            ])
        } else {
            window.center()
            done.toolTip = "Скопировать в буфер и закрыть (⌘↩)"
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let bar = NSStackView(views: [toolPicker, colorWell, widthSlider, fillBox, spacer, undoB, redoB,
                                          button("doc.on.doc", "Копировать (⌘C)", #selector(copyImage), "c"),
                                          button("square.and.arrow.down", "Сохранить (⌘S)", #selector(save), "s"),
                                          done])
            bar.orientation = .horizontal
            bar.spacing = 8
            bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            let root = NSStackView(views: [bar, canvas])
            root.orientation = .vertical
            root.spacing = 0
            root.alignment = .leading
            bar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            canvas.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            window.contentView = root
        }
        canvas.editor = self
        shot.observers[ObjectIdentifier(self)] = { [weak self] in self?.canvas.refresh() }
    }

    func front() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    var tool: String { Editor.tools[toolPicker.selectedSegment].id }
    func select(tool id: String) {
        if let i = Editor.tools.firstIndex(where: { $0.id == id }) { toolPicker.selectedSegment = i; toolChanged() }
    }

    func style(_ type: String, _ pts: [CGPoint]) -> Ann {
        Ann(type: type, points: pts, color: hex(colorWell.color), width: CGFloat(widthSlider.doubleValue),
            fill: fillBox.state == .on ? true : nil)
    }

    @objc func toolChanged() {
        canvas.cancelText()
        canvas.toolChanged()
        window.makeFirstResponder(canvas)
    }
    @objc func styleChanged() {}
    @objc func undo() { canvas.cancelText(); shot.undo() }
    @objc func redo() { canvas.cancelText(); shot.redo() }

    @objc func copyImage() {
        canvas.commitText()
        if isOverlay { return finishOverlay() }
        copyToClipboard(Render.image(shot))
    }

    @objc func doneTapped() {
        canvas.commitText()
        if isOverlay { return finishOverlay() }
        copyImage()
        window.close()
    }

    @objc func cancelTapped() { closeLevel(result: nil) }

    @objc func toEditor() {
        canvas.commitText()
        finishOverlay(copy: false)
        Editor.show(shot)
    }

    @objc func save() {
        canvas.commitText()
        if isOverlay { return finishOverlay() }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png, .jpeg]
        p.nameFieldStringValue = "Shotmark \(shot.id).png"
        p.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        p.beginSheetModal(for: window) { [shot] r in
            guard r == .OK, let url = p.url else { return }
            let type: UTType = url.pathExtension.lowercased().hasPrefix("jp") ? .jpeg : .png
            try? encode(Render.image(shot), as: type).write(to: url)
        }
    }

    /// Esc: сначала гасит ввод текста, потом закрывает.
    func escape() {
        if canvas.isEditingText { canvas.cancelText(); return }
        if isOverlay { closeLevel(result: nil) } else { window.close() }
    }

    /// Выделения нет — берётся весь монитор.
    private func finishOverlay(copy: Bool = true) {
        Store.shared.persist(shot)
        if copy { deliverCapture(Render.image(shot)) }
        closeLevel(result: shot)
    }

    /// Закрывает только свой уровень: нижние остаются открытыми.
    private func closeLevel(result: Shot?) {
        guard let lv = level else { return }
        lv.result = result
        for e in lv.editors {
            e.canvas.cancelText()
            e.shot.observers[ObjectIdentifier(e)] = nil
            e.window.orderOut(nil)
            if e.shot !== result { Store.shared.discard(e.shot) }
        }
        lv.editors.removeAll()
        lv.done?()
        lv.done = nil
    }

    func windowWillClose(_ n: Notification) {
        guard !isOverlay else { return }
        canvas.commitText()
        shot.observers[ObjectIdentifier(self)] = nil
        Editor.open[shot.id] = nil
        if Editor.open.isEmpty { NSApp.setActivationPolicy(.accessory) }
        waiters.forEach { $0() }
        waiters.removeAll()
    }
}

/// Снимок человека: в буфер обмена и в ~/Pictures/Screenshots/ГГГГ-ММ/, со звуком затвора.
@discardableResult
func deliverCapture(_ img: CGImage) -> URL? {
    copyToClipboard(img)
    playShutter()
    let now = Date()
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM"
    let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screenshots").appendingPathComponent(f.string(from: now))
    f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    var url = dir.appendingPathComponent("Shotmark_\(f.string(from: now)).png")
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("Shotmark_\(f.string(from: now))_\(n).png"); n += 1
    }
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encode(img, as: .png).write(to: url)
        return url
    } catch {
        NSLog("Shotmark: не удалось сохранить \(url.path): \(error)")
        return nil
    }
}

func playShutter() {
    NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
            byReference: true)?.play()
}

@MainActor
final class Canvas: NSView, NSTextFieldDelegate {
    let shot: Shot
    weak var editor: Editor?
    private var cached: CGImage?
    private var draft: Ann?
    private var field: NSTextField?
    private var pending: Ann?        // text/callout ждёт ввода текста
    /// Режим поверх экрана: снимок на весь монитор 1:1, клик инструментом «Область» выбирает окно.
    var fullBleed = false
    var screenTL = CGRect.zero
    var winRects: [(CGWindowID, CGRect)] = []
    private var hover: CGRect?       // окно под курсором, в пикселях снимка
    private var pendingIndex: Int?   // правим текст существующей аннотации
    // инструмент «Выбор»
    private var selected: Int?
    private var drag: (handle: Int?, start: CGPoint, orig: Ann)?
    private var live: Ann?

    var isEditingText: Bool { field != nil }

    init(shot: Shot) {
        self.shot = shot
        super.init(frame: .zero)
        setContentHuggingPriority(.init(1), for: .vertical)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: editor?.tool == "select" ? .arrow : .crosshair) }

    func refresh() {
        if let i = selected, i >= shot.state.anns.count { selected = nil }
        cached = nil
        needsDisplay = true
    }

    func toolChanged() {
        if editor?.tool != "select" { selected = nil }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private var tolerance: CGFloat { 6 / fit.scale }

    private func hit(_ p: CGPoint) -> Int? {
        shot.state.anns.indices.reversed().first { Render.bounds(shot.state.anns[$0]).insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
    }

    private var fit: (scale: CGFloat, origin: CGPoint) {
        let s = shot.size
        if fullBleed { return (bounds.width / s.width, .zero) }
        // снимок экрана — не крупнее 1:1 к физическим пикселям; картинка из файла — до 1:1 к точкам
        let maxScale = shot.source.hasPrefix("file") ? 1 : 1 / (window?.backingScaleFactor ?? 2)
        let scale = max(0.05, min(maxScale, (bounds.width - 20) / s.width, (bounds.height - 20) / s.height))
        return (scale, CGPoint(x: (bounds.width - s.width * scale) / 2, y: (bounds.height - s.height * scale) / 2))
    }

    private func toImage(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        let f = fit
        return CGPoint(x: ((p.x - f.origin.x) / f.scale).rounded(), y: ((p.y - f.origin.y) / f.scale).rounded())
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let f = fit
        return CGPoint(x: p.x * f.scale + f.origin.x, y: p.y * f.scale + f.origin.y)
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: .black)?.setFill()
        bounds.fill()
        if cached == nil { cached = Render.image(shot, crop: false, skip: drag != nil ? selected : nil) }
        let f = fit
        let imgRect = CGRect(origin: f.origin, size: CGSize(width: shot.size.width * f.scale, height: shot.size.height * f.scale))
        ctx.interpolationQuality = .high
        Render.drawImage(cached!, in: imgRect, ctx: ctx)
        ctx.saveGState()
        ctx.translateBy(x: f.origin.x, y: f.origin.y)
        ctx.scaleBy(x: f.scale, y: f.scale)
        if let c = shot.state.crop {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.addRect(CGRect(origin: .zero, size: shot.size)); ctx.addRect(c)
            ctx.fillPath(using: .evenOdd)
        }
        if fullBleed, draft == nil, shot.state.crop == nil, editor?.tool == "crop", let h = hover {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(3 / f.scale)
            ctx.stroke(h)
        }
        if fullBleed, let r = draft?.type == "crop" ? draft.map(Render.rect) : shot.state.crop {
            let text = "\(Int(r.width)) × \(Int(r.height)) px" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12 / f.scale, weight: .medium),
                                                        .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.7)]
            text.draw(at: CGPoint(x: r.minX, y: max(0, r.minY - 18 / f.scale)), withAttributes: attrs)
        }
        if let l = live { Render.draw(l, in: ctx, base: shot.base) }
        if let i = selected, i < shot.state.anns.count {
            let a = live ?? shot.state.anns[i]
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1.5 / f.scale)
            if !a.isSegment {
                ctx.saveGState()
                ctx.setLineDash(phase: 0, lengths: [5 / f.scale, 3 / f.scale])
                ctx.stroke(Render.bounds(a))
                ctx.restoreGState()
            }
            let hs = 8 / f.scale
            for h in a.handles() {
                let r = CGRect(x: h.x - hs / 2, y: h.y - hs / 2, width: hs, height: hs)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(r)
                ctx.stroke(r)
            }
        }
        if let d = draft {
            if ["blur", "pixelate", "crop"].contains(d.type) {
                ctx.setStrokeColor(NSColor.systemBlue.cgColor)
                ctx.setLineWidth(2 / f.scale)
                ctx.setLineDash(phase: 0, lengths: [6 / f.scale, 4 / f.scale])
                ctx.stroke(Render.rect(d))
            } else {
                Render.draw(d, in: ctx, base: shot.base)
            }
        }
        ctx.restoreGState()
    }

    /// Правая кнопка: во время протягивания сбрасывает фигуру или область, иначе закрывает режим поверх экрана.
    override func rightMouseDown(with e: NSEvent) {
        if draft != nil {
            draft = nil
            needsDisplay = true
        } else if let i = hit(toImage(e)) {
            commitText()
            selected = i
            needsDisplay = true
            NSMenu.popUpContextMenu(menu(for: i), with: e, for: self)
        } else if fullBleed {
            editor?.escape()
        } else {
            super.rightMouseDown(with: e)
        }
    }

    override func mouseMoved(with e: NSEvent) {
        guard fullBleed else { return }
        let p = convert(e.locationInWindow, from: nil)
        let g = CGPoint(x: p.x + screenTL.minX, y: p.y + screenTL.minY)
        let k = shot.size.width / bounds.width
        let h = winRects.first { $0.1.contains(g) }.map { r -> CGRect in
            let l = r.1.offsetBy(dx: -screenTL.minX, dy: -screenTL.minY)
            return CGRect(x: l.minX * k, y: l.minY * k, width: l.width * k, height: l.height * k).integral
                .intersection(CGRect(origin: .zero, size: shot.size))
        }
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        guard let ed = editor else { return }
        let p = toImage(e)
        if ed.tool == "select" {
            if let i = selected, i < shot.state.anns.count,
               let k = shot.state.anns[i].handles().firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= tolerance * 1.5 }) {
                drag = (k, p, shot.state.anns[i])
            } else if let i = hit(p) {
                selected = i
                drag = (nil, p, shot.state.anns[i])
            } else {
                selected = nil
            }
            if e.clickCount == 2, let i = selected, ["text", "callout"].contains(shot.state.anns[i].type) {
                drag = nil
                editText(i)
                return
            }
            cached = nil
            needsDisplay = true
            return
        }
        switch ed.tool {
        case "step":
            var a = ed.style("step", [p]); a.number = shot.nextStep
            shot.apply { $0.anns.append(a) }
        case "text":
            beginText(ed.style("text", [p]), at: p)
        default:
            draft = ed.style(ed.tool, [p, p])
        }
    }

    override func mouseDragged(with e: NSEvent) { track(e) }

    /// Обновляет тянущуюся фигуру по позиции мыши; зовётся и при отпускании, чтобы конечная точка была точной.
    private func track(_ e: NSEvent) {
        if let dr = drag {
            let p = toImage(e)
            live = dr.handle.map { dr.orig.resized(handle: $0, to: p) }
                ?? dr.orig.translated(by: CGVector(dx: p.x - dr.start.x, dy: p.y - dr.start.y))
            needsDisplay = true
            return
        }
        guard var d = draft else { return }
        var p = toImage(e)
        if e.modifierFlags.contains(.shift), d.points.count == 2, ["line", "arrow"].contains(d.type) {
            let s = d.points[0], dx = p.x - s.x, dy = p.y - s.y
            let a = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4), len = hypot(dx, dy)
            p = CGPoint(x: s.x + cos(a) * len, y: s.y + sin(a) * len)
        } else if e.modifierFlags.contains(.shift), ["rect", "ellipse"].contains(d.type) {
            let s = d.points[0], side = max(abs(p.x - s.x), abs(p.y - s.y))
            p = CGPoint(x: s.x + (p.x < s.x ? -side : side), y: s.y + (p.y < s.y ? -side : side))
        }
        if d.type == "pen" || d.type == "marker" { d.points.append(p) } else { d.points[1] = p }
        draft = d
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if drag != nil || draft != nil { track(e) }
        if drag != nil {
            if let l = live, let i = selected, l != drag?.orig { shot.apply { $0.anns[i] = l } }
            drag = nil
            live = nil
            refresh()
            return
        }
        guard let d = draft else { return }
        draft = nil
        let moved = d.points.count > 2 || (d.points.count == 2 && hypot(d.points[1].x - d.points[0].x, d.points[1].y - d.points[0].y) > 2)
        switch d.type {
        case "crop":
            let r = Render.rect(d)
            if fullBleed {
                // как в ShareX: отпустил — снимок; клик — окно под курсором, мимо окон — весь монитор
                shot.apply { $0.crop = moved ? r : hover }
                editor?.doneTapped()
                return
            }
            if moved { shot.apply { $0.crop = r } }
            else if shot.state.crop != nil { shot.apply { $0.crop = nil } }
        case "callout":
            var a = d
            if !moved { a.points = [d.points[0], CGPoint(x: d.points[0].x + 40, y: d.points[0].y - 60)] }
            beginText(a, at: a.points[1])
        case "loupe":
            var a = d
            if !moved { a.points = [d.points[0]] }
            shot.apply { $0.anns.append(a) }
        default:
            if moved { shot.apply { $0.anns.append(d) } }
        }
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        if let ch = e.charactersIgnoringModifiers?.lowercased().first, e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let t = Editor.keys[ch] {
            editor?.select(tool: t)
        } else if e.keyCode == 36 || e.keyCode == 76, fullBleed || e.modifierFlags.contains(.command) {
            editor?.doneTapped()
        } else if e.keyCode == 51 || e.keyCode == 117, let i = selected {
            selected = nil
            shot.apply { $0.anns.remove(at: i) }
        } else if e.keyCode == 53, selected != nil {
            selected = nil
            needsDisplay = true
        } else if e.keyCode == 53 {
            editor?.escape()
        } else {
            super.keyDown(with: e)
        }
    }

    // MARK: свойства по правой кнопке

    private static let palette: [(String, String)] = [
        ("Красный", "#FF3B30"), ("Оранжевый", "#FF9500"), ("Жёлтый", "#FFCC00"), ("Зелёный", "#34C759"),
        ("Синий", "#007AFF"), ("Фиолетовый", "#AF52DE"), ("Белый", "#FFFFFF"), ("Чёрный", "#000000"),
    ]

    private func menu(for i: Int) -> NSMenu {
        let a = shot.state.anns[i]
        let m = NSMenu()
        m.autoenablesItems = false
        func item(_ title: String, checked: Bool = false, image: NSImage? = nil, _ f: @escaping () -> Void) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: #selector(runItem(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = f
            it.state = checked ? .on : .off
            it.image = image
            return it
        }
        func change(_ f: @escaping (inout Ann) -> Void) -> () -> Void {
            { [weak self] in
                guard let self, i < self.shot.state.anns.count else { return }
                self.shot.apply { f(&$0.anns[i]) }
            }
        }
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let s = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            s.submenu = NSMenu()
            items.forEach { s.submenu!.addItem($0) }
            m.addItem(s)
        }
        let t = a.type
        if t == "text" || t == "callout" { m.addItem(item("Изменить текст…") { [weak self] in self?.editText(i) }) }
        if t != "blur" && t != "pixelate" {
            sub("Цвет", Canvas.palette.map { name, hx in
                item(name, checked: (a.color ?? "#FF3B30").uppercased().hasPrefix(hx), image: swatch(hx), change { $0.color = hx })
            })
        }
        if ["arrow", "line", "rect", "ellipse", "pen", "marker", "callout", "loupe"].contains(t) {
            sub("Толщина", [2, 4, 6, 10, 16].map { w in
                item("\(w) px", checked: Int(a.width ?? 4) == w, change { $0.width = CGFloat(w) })
            })
        }
        let sizes: [(String, CGFloat)]? = switch t {
        case "text", "callout": [("Мелкий", 18), ("Средний", 26), ("Крупный", 40), ("Огромный", 64)]
        case "step": [("Мелкий", 12), ("Средний", 18), ("Крупный", 28), ("Огромный", 44)]
        case "loupe": [("Малая", 50), ("Средняя", 80), ("Большая", 130), ("Огромная", 200)]
        case "blur": [("Слабая", 5), ("Средняя", 12), ("Сильная", 24), ("Очень сильная", 48)]
        case "pixelate": [("Мелкие пиксели", 8), ("Средние", 16), ("Крупные", 32), ("Очень крупные", 64)]
        default: nil
        }
        if let sizes {
            let cur = a.size ?? a.defaultSize
            sub(t == "blur" || t == "pixelate" ? "Сила" : "Размер", sizes.map { name, v in
                item(name, checked: abs(cur - v) < 0.5, change { $0.size = v })
            })
        }
        if t == "rect" || t == "ellipse" {
            m.addItem(item("Заливка", checked: a.fill == true, change { $0.fill = $0.fill == true ? nil : true }))
        }
        m.addItem(.separator())
        m.addItem(item("Удалить") { [weak self] in
            guard let self, i < self.shot.state.anns.count else { return }
            self.selected = nil
            self.shot.apply { $0.anns.remove(at: i) }
        })
        return m
    }

    @objc private func runItem(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }

    private func swatch(_ hx: String) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color(hx).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.gray.setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }

    // MARK: ввод текста

    private func editText(_ i: Int) {
        let a = shot.state.anns[i]
        pendingIndex = i
        beginText(a, at: a.type == "callout" && a.points.count > 1 ? a.points[1] : a.points[0])
        field?.stringValue = a.text ?? ""
    }

    private func beginText(_ a: Ann, at p: CGPoint) {
        pending = a
        let v = toView(p)
        let fontSize = max(11, (a.size ?? a.defaultSize) * fit.scale)
        let f = NSTextField(frame: CGRect(x: v.x, y: v.y, width: 260, height: fontSize + 10))
        f.font = .boldSystemFont(ofSize: fontSize)
        f.textColor = color(a.color)
        f.placeholderString = "Текст, Enter"
        f.delegate = self
        f.target = self
        f.action = #selector(fieldDone)
        addSubview(f)
        field = f
        window?.makeFirstResponder(f)
    }

    @objc private func fieldDone() { commitText() }

    func controlTextDidEndEditing(_ n: Notification) { commitText() }

    func commitText() {
        guard let f = field, var a = pending else { return }
        let idx = pendingIndex
        field = nil; pending = nil; pendingIndex = nil
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview()
        a.text = text
        if let i = idx, i < shot.state.anns.count {
            shot.apply { text.isEmpty ? _ = $0.anns.remove(at: i) : ($0.anns[i] = a) }
        } else if !text.isEmpty {
            shot.apply { $0.anns.append(a) }
        }
        window?.makeFirstResponder(self)
    }

    func cancelText() {
        field?.removeFromSuperview()
        field = nil; pending = nil; pendingIndex = nil
    }
}
