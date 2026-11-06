import AppKit
import UniformTypeIdentifiers

/// Окно редактора разметки. Одно на снимок.
@MainActor
final class Editor: NSObject, NSWindowDelegate {
    static var open: [String: Editor] = [:]

    let shot: Shot
    let window: NSWindow
    let canvas: Canvas
    var waiters: [() -> Void] = []

    static let tools: [(id: String, symbol: String, tip: String)] = [
        ("arrow", "arrow.up.right", "Стрелка (A)"), ("line", "line.diagonal", "Линия (L)"),
        ("rect", "rectangle", "Прямоугольник (R)"), ("ellipse", "circle", "Эллипс (E)"),
        ("pen", "pencil", "Перо (P)"), ("marker", "highlighter", "Маркер (M)"),
        ("text", "textformat", "Текст (T)"), ("callout", "text.bubble", "Выноска (O)"),
        ("step", "1.circle", "Шаг (N)"), ("blur", "drop", "Размытие (B)"),
        ("pixelate", "square.grid.3x3", "Пикселизация (X)"), ("loupe", "plus.magnifyingglass", "Лупа (Z)"),
        ("crop", "crop", "Обрезка (C)"),
    ]
    static let keys: [Character: String] = ["a": "arrow", "l": "line", "r": "rect", "e": "ellipse", "p": "pen", "m": "marker",
                                            "t": "text", "o": "callout", "n": "step", "b": "blur", "x": "pixelate", "z": "loupe", "c": "crop"]

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

    private init(shot: Shot) {
        self.shot = shot
        canvas = Canvas(shot: shot)
        let vis = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let want = CGSize(width: max(720, shot.size.width / scale + 40), height: shot.size.height / scale + 100)
        let size = CGSize(width: min(want.width, vis.width * 0.9), height: min(want.height, vis.height * 0.9))
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Shotmark — \(shot.id)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        toolPicker.segmentCount = Editor.tools.count
        toolPicker.trackingMode = .selectOne
        for (i, t) in Editor.tools.enumerated() {
            toolPicker.setImage(NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.tip), forSegment: i)
            toolPicker.setToolTip(t.tip, forSegment: i)
            toolPicker.setWidth(30, forSegment: i)
        }
        toolPicker.selectedSegment = 0
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
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let done = NSButton(title: "Готово", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        done.toolTip = "Скопировать в буфер и закрыть (⌘↩)"
        let bar = NSStackView(views: [toolPicker, colorWell, widthSlider, fillBox, spacer,
                                      button("arrow.uturn.backward", "Отменить (⌘Z)", #selector(undo), "z"),
                                      button("arrow.uturn.forward", "Повторить (⌘⇧Z)", #selector(redo), "Z", [.command, .shift]),
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

    @objc func toolChanged() { canvas.cancelText(); window.makeFirstResponder(canvas) }
    @objc func styleChanged() {}
    @objc func undo() { canvas.cancelText(); shot.undo() }
    @objc func redo() { canvas.cancelText(); shot.redo() }
    @objc func copyImage() { canvas.commitText(); copyToClipboard(Render.image(shot)) }
    @objc func doneTapped() { copyImage(); window.close() }

    @objc func save() {
        canvas.commitText()
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

    func windowWillClose(_ n: Notification) {
        canvas.commitText()
        shot.observers[ObjectIdentifier(self)] = nil
        Editor.open[shot.id] = nil
        if Editor.open.isEmpty { NSApp.setActivationPolicy(.accessory) }
        waiters.forEach { $0() }
        waiters.removeAll()
    }
}

@MainActor
final class Canvas: NSView, NSTextFieldDelegate {
    let shot: Shot
    weak var editor: Editor?
    private var cached: CGImage?
    private var draft: Ann?
    private var field: NSTextField?
    private var pending: Ann?        // text/callout ждёт ввода текста

    init(shot: Shot) {
        self.shot = shot
        super.init(frame: .zero)
        setContentHuggingPriority(.init(1), for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func refresh() { cached = nil; needsDisplay = true }

    private var fit: (scale: CGFloat, origin: CGPoint) {
        let s = shot.size
        // не крупнее 1 пикселя снимка на 1 физический пиксель экрана
        let scale = max(0.05, min(1 / (window?.backingScaleFactor ?? 2), (bounds.width - 20) / s.width, (bounds.height - 20) / s.height))
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
        if cached == nil { cached = Render.image(shot, crop: false) }
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

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        guard let ed = editor else { return }
        let p = toImage(e)
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

    override func mouseDragged(with e: NSEvent) {
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
        guard let d = draft else { return }
        draft = nil
        let moved = d.points.count > 2 || (d.points.count == 2 && hypot(d.points[1].x - d.points[0].x, d.points[1].y - d.points[0].y) > 2)
        switch d.type {
        case "crop":
            let r = Render.rect(d)
            shot.apply { $0.crop = moved ? r : nil }
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
        } else if e.keyCode == 53 {
            editor?.window.close()
        } else {
            super.keyDown(with: e)
        }
    }

    // MARK: ввод текста

    private func beginText(_ a: Ann, at p: CGPoint) {
        pending = a
        let v = toView(p)
        let fontSize = max(11, (a.size ?? (14 + (a.width ?? 4) * 3)) * fit.scale)
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
        field = nil; pending = nil
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview()
        if !text.isEmpty { a.text = text; shot.apply { $0.anns.append(a) } }
        window?.makeFirstResponder(self)
    }

    func cancelText() {
        field?.removeFromSuperview()
        field = nil; pending = nil
    }
}
