import AppKit
import UniformTypeIdentifiers

/// Одна аннотация. Координаты — пиксели исходного снимка, начало в левом верхнем углу.
/// points: line/arrow/rect/ellipse/blur/pixelate — [начало, конец]; pen/marker — ломаная;
/// text/step — [точка]; callout — [остриё, левый верхний угол плашки]; loupe — [откуда, куда].
struct Ann: Codable {
    var type: String
    var points: [CGPoint]
    var color: String?
    var width: CGFloat?
    var text: String?
    var number: Int?
    var fill: Bool?
    var size: CGFloat?

    static let types = ["arrow", "line", "rect", "ellipse", "pen", "marker", "text", "callout",
                        "step", "blur", "pixelate", "loupe"]
}

struct DocState: Codable {
    var anns: [Ann] = []
    var crop: CGRect?
}

private struct Meta: Codable {
    var id: String
    var created: Date
    var source: String
    var state: DocState
}

@MainActor
final class Shot {
    let id: String
    let created: Date
    let source: String
    let base: CGImage
    var state = DocState()
    var undoStack: [DocState] = []
    var redoStack: [DocState] = []
    var observers: [ObjectIdentifier: () -> Void] = [:]

    init(id: String, created: Date, source: String, base: CGImage) {
        self.id = id; self.created = created; self.source = source; self.base = base
    }

    var size: CGSize { CGSize(width: base.width, height: base.height) }
    var nextStep: Int { (state.anns.filter { $0.type == "step" }.compactMap(\.number).max() ?? 0) + 1 }

    func apply(_ change: (inout DocState) -> Void) {
        undoStack.append(state)
        redoStack.removeAll()
        change(&state)
        changed()
    }

    @discardableResult func undo() -> Bool {
        guard let prev = undoStack.popLast() else { return false }
        redoStack.append(state); state = prev; changed(); return true
    }

    @discardableResult func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(state); state = next; changed(); return true
    }

    private func changed() {
        Store.shared.saveMeta(self)
        observers.values.forEach { $0() }
    }
}

@MainActor
final class Store {
    static let shared = Store()
    let root: URL
    let shotsDir: URL
    private var cache: [String: Shot] = [:]

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shotmark")
        shotsDir = root.appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
    }

    func imageURL(_ id: String) -> URL { shotsDir.appendingPathComponent("\(id).png") }
    private func metaURL(_ id: String) -> URL { shotsDir.appendingPathComponent("\(id).json") }

    func add(_ image: CGImage, source: String) -> Shot {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var id = f.string(from: Date())
        while cache[id] != nil || FileManager.default.fileExists(atPath: metaURL(id).path) { id += "x" }
        let shot = Shot(id: id, created: Date(), source: source, base: image)
        try? encode(image, as: .png).write(to: imageURL(id))
        cache[id] = shot
        saveMeta(shot)
        return shot
    }

    func saveMeta(_ s: Shot) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(Meta(id: s.id, created: s.created, source: s.source, state: s.state)) {
            try? d.write(to: metaURL(s.id))
        }
    }

    /// Все id, новые первыми.
    func ids() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: shotsDir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted(by: >)
    }

    /// nil или "latest" — последний снимок.
    func get(_ id: String?) -> Shot? {
        guard let id = (id == nil || id == "latest") ? ids().first : id else { return nil }
        if let s = cache[id] { return s }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: metaURL(id)),
              let meta = try? dec.decode(Meta.self, from: data),
              let src = CGImageSourceCreateWithURL(imageURL(id) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let s = Shot(id: id, created: meta.created, source: meta.source, base: img)
        s.state = meta.state
        cache[id] = s
        return s
    }
}

func encode(_ img: CGImage, as type: UTType, quality: Double = 0.9) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
        throw ShotError("не удалось создать кодировщик \(type.identifier)")
    }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw ShotError("не удалось закодировать изображение") }
    return data as Data
}

func loadImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func copyToClipboard(_ img: CGImage) {
    guard let png = try? encode(img, as: .png) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(png, forType: .png)
}

struct ShotError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

func color(_ hex: String?) -> NSColor {
    var s = (hex ?? "#FF3B30").trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return .systemRed }
    let rgba = s.count == 6 ? (v << 8 | 0xFF) : v
    return NSColor(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                   blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
}

func hex(_ c: NSColor) -> String {
    let c = c.usingColorSpace(.sRGB) ?? c
    let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)),
        b = Int(round(c.blueComponent * 255))
    return String(format: "#%02X%02X%02X", r, g, b)
}
