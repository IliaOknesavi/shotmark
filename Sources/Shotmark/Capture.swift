import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
    /// Рамка в глобальных координатах с началом слева сверху (как у CGWindow и SCDisplay).
    var topLeftFrame: CGRect {
        let h0 = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: h0 - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// Захват через ScreenCaptureKit. Все прямоугольники — глобальные точки, начало слева сверху.
@MainActor
enum Capture {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    static func scale(_ id: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first { $0.displayID == id }?.backingScaleFactor ?? 2
    }

    private static func ownApp(_ c: SCShareableContent) -> [SCRunningApplication] {
        c.applications.filter { $0.processID == getpid() }
    }

    private static func shoot(_ filter: SCContentFilter, size: CGSize, scale: CGFloat,
                              source: CGRect? = nil, cursor: Bool = false) async throws -> CGImage {
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int((size.width * scale).rounded()))
        cfg.height = max(1, Int((size.height * scale).rounded()))
        if let source { cfg.sourceRect = source }
        cfg.showsCursor = cursor
        cfg.captureResolution = .best
        cfg.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    static func display(_ d: SCDisplay, in c: SCShareableContent, includeSelf: Bool = false) async throws -> CGImage {
        let filter = SCContentFilter(display: d, excludingApplications: includeSelf ? [] : ownApp(c), exceptingWindows: [])
        return try await shoot(filter, size: d.frame.size, scale: scale(d.displayID))
    }

    /// Монитор по номеру (0 — главный) или тот, где курсор.
    static func screen(index: Int?) async throws -> CGImage {
        let c = try await content()
        let d: SCDisplay?
        if let index {
            guard index >= 0, index < c.displays.count else { throw ShotError("нет монитора с номером \(index)") }
            d = c.displays[index]
        } else {
            let m = NSEvent.mouseLocation
            let id = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) }?.displayID
            d = c.displays.first { $0.displayID == id } ?? c.displays.first
        }
        guard let d else { throw ShotError("мониторы не найдены") }
        return try await display(d, in: c)
    }

    static func area(_ r: CGRect) async throws -> CGImage {
        let c = try await content()
        let center = CGPoint(x: r.midX, y: r.midY)
        guard let d = c.displays.first(where: { $0.frame.contains(center) }) ?? c.displays.first(where: { $0.frame.intersects(r) })
        else { throw ShotError("область вне мониторов") }
        // shortcut: область, задевающая два монитора, обрезается по монитору с её центром
        let local = r.intersection(d.frame).offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
        guard !local.isEmpty else { throw ShotError("пустая область") }
        let filter = SCContentFilter(display: d, excludingApplications: ownApp(c), exceptingWindows: [])
        return try await shoot(filter, size: local.size, scale: scale(d.displayID), source: local)
    }

    static func window(_ id: CGWindowID) async throws -> CGImage {
        let c = try await content()
        guard let w = c.windows.first(where: { $0.windowID == id }) else { throw ShotError("окно \(id) не найдено") }
        let d = c.displays.first { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }
        return try await shoot(SCContentFilter(desktopIndependentWindow: w), size: w.frame.size,
                               scale: scale(d?.displayID ?? CGMainDisplayID()))
    }

    /// Все видимые окна приложения одним кадром (фон прозрачный).
    static func app(_ query: String) async throws -> CGImage {
        let c = try await content()
        let q = query.lowercased()
        guard let app = c.applications.first(where: { $0.applicationName.lowercased() == q || $0.bundleIdentifier.lowercased() == q })
                ?? c.applications.first(where: { $0.applicationName.lowercased().contains(q) })
        else { throw ShotError("приложение «\(query)» не найдено среди запущенных") }
        let wins = c.windows.filter { $0.owningApplication?.processID == app.processID && $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 1 }
        guard let first = wins.first else { throw ShotError("у «\(app.applicationName)» нет видимых окон") }
        let union = wins.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        guard let d = c.displays.first(where: { $0.frame.contains(CGPoint(x: union.midX, y: union.midY)) }) ?? c.displays.first
        else { throw ShotError("мониторы не найдены") }
        let local = union.intersection(d.frame).offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
        let filter = SCContentFilter(display: d, including: [app], exceptingWindows: [])
        return try await shoot(filter, size: local.size, scale: scale(d.displayID), source: local)
    }

    static func windows() async throws -> [SCWindow] {
        try await content().windows.filter { $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 1 && $0.frame.height > 1 && $0.owningApplication?.processID != getpid() }
    }
}
