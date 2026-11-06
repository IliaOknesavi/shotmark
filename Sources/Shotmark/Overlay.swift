import AppKit

enum Selection {
    case area(CGImage, CGRect)      // кадр из замороженного экрана; рамка в глобальных точках (слева сверху)
    case window(CGWindowID, CGRect)
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Полноэкранное выделение: экран замораживается, тянешь — область, клик — окно под курсором, Esc — отмена.
@MainActor
final class Overlay {
    private static var current: Overlay?
    private var windows: [NSWindow] = []
    private var cont: CheckedContinuation<Selection?, Never>?

    static func select(hint: String? = nil) async -> Selection? {
        if current != nil { return nil }
        let o = Overlay()
        current = o
        defer { current = nil }
        return await o.run(hint: hint)
    }

    private func run(hint: String?) async -> Selection? {
        let content = try? await Capture.content()
        var frozen: [CGDirectDisplayID: CGImage] = [:]
        if let content {
            for d in content.displays { frozen[d.displayID] = try? await Capture.display(d, in: content) }
        }
        guard !frozen.isEmpty else {
            NSSound.beep()
            Permissions.explain()
            return nil
        }
        let wins = Overlay.windowList()
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { c in
            cont = c
            for s in NSScreen.screens {
                guard let img = frozen[s.displayID] else { continue }
                let w = OverlayWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.setFrame(s.frame, display: false)
                w.level = .screenSaver
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                w.isReleasedWhenClosed = false
                w.acceptsMouseMovedEvents = true
                let v = OverlayView(frame: CGRect(origin: .zero, size: s.frame.size), image: img,
                                    screenTL: s.topLeftFrame, windows: wins, hint: hint) { [weak self] sel in self?.finish(sel) }
                w.contentView = v
                w.makeKeyAndOrderFront(nil)
                if NSMouseInRect(NSEvent.mouseLocation, s.frame, false) { w.makeKey(); w.makeFirstResponder(v) }
                windows.append(w)
            }
        }
    }

    private func finish(_ sel: Selection?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        cont?.resume(returning: sel)
        cont = nil
    }

    /// Обычные окна других приложений, спереди назад, глобальные точки слева сверху.
    static func windowList() -> [(CGWindowID, CGRect)] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  (d[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  let n = d[kCGWindowNumber as String] as? UInt32,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 20, r.height > 20 else { return nil }
            return (n, r)
        }
    }
}

private final class OverlayView: NSView {
    let image: CGImage
    let screenTL: CGRect
    let wins: [(CGWindowID, CGRect)]
    let hint: String?
    let done: (Selection?) -> Void
    var start: CGPoint?
    var cur: CGPoint?
    var hover: (CGWindowID, CGRect)?

    init(frame: CGRect, image: CGImage, screenTL: CGRect, windows: [(CGWindowID, CGRect)], hint: String?, done: @escaping (Selection?) -> Void) {
        self.image = image; self.screenTL = screenTL; self.wins = windows; self.hint = hint; self.done = done
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    var selRect: CGRect? {
        guard let s = start, let c = cur else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
    }

    func local(_ g: CGRect) -> CGRect { g.offsetBy(dx: -screenTL.minX, dy: -screenTL.minY) }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let g = CGPoint(x: p.x + screenTL.minX, y: p.y + screenTL.minY)
        hover = wins.first { $0.1.contains(g) }
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil); cur = start }
    override func mouseDragged(with e: NSEvent) { cur = convert(e.locationInWindow, from: nil); needsDisplay = true }

    override func mouseUp(with e: NSEvent) {
        cur = convert(e.locationInWindow, from: nil)
        if let r = selRect, r.width > 3, r.height > 3 {
            let k = CGFloat(image.width) / bounds.width
            let px = CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k).integral
            if let piece = image.cropping(to: px) {
                done(.area(piece, r.offsetBy(dx: screenTL.minX, dy: screenTL.minY)))
                return
            }
        }
        if let h = hover { done(.window(h.0, h.1)) } else { done(.area(image, screenTL)) }
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { done(nil) }                    // Esc
        else if e.keyCode == 36 || e.keyCode == 3 { done(.area(image, screenTL)) }  // Enter или F — весь экран
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Render.drawImage(image, in: bounds, ctx: ctx)
        let hole = selRect ?? hover.map { local($0.1) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addRect(bounds)
        if let hole { ctx.addRect(hole) }
        ctx.fillPath(using: .evenOdd)
        if let hole {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(selRect == nil ? 3 : 1)
            ctx.stroke(hole)
            let label = "\(Int(hole.width)) × \(Int(hole.height))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                        .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.7)]
            label.draw(at: CGPoint(x: hole.minX, y: max(0, hole.minY - 18)), withAttributes: attrs)
        }
        let text = (hint.map { $0 + "\n" } ?? "") + "Тяни — область · клик — окно · Enter — весь экран · Esc — отмена"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        let s = (text as NSString).boundingRect(with: CGSize(width: 900, height: 200), options: .usesLineFragmentOrigin, attributes: attrs).size
        let box = CGRect(x: bounds.midX - s.width / 2 - 14, y: 40, width: s.width + 28, height: s.height + 16)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(with: box.insetBy(dx: 14, dy: 8), options: .usesLineFragmentOrigin, attributes: attrs)
    }
}
