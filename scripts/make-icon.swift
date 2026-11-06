// Готовит иконку приложения из сгенерированной картинки на белом фоне:
// находит фиолетовую плашку, вырезает её, кладёт в сетку macOS (824 из 1024) с прозрачными углами.
// usage: swift scripts/make-icon.swift assets/icon-src.png assets/icon-1024.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: make-icon.swift <src.png> <out.png>")
}
let w = src.width, h = src.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)

// граница плашки: пиксели, где синий заметно больше зелёного (фиолетовый), а не белый фон и не серая тень
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
        if b - g > 60 && b > 120 && r < 200 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
assert(maxX > minX && maxY > minY, "плашка не найдена")
// буфер CGContext идёт сверху вниз, а координаты отрисовки — снизу вверх
let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1).insetBy(dx: 3, dy: 3)
let plate = src.cropping(to: box)!

let out = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let dst = CGRect(x: 100, y: 100, width: 824, height: 824)
out.saveGState()
out.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
out.addPath(CGPath(roundedRect: dst, cornerWidth: 185, cornerHeight: 185, transform: nil))
out.setFillColor(NSColor.black.cgColor)
out.fillPath()
out.restoreGState()
out.addPath(CGPath(roundedRect: dst, cornerWidth: 185, cornerHeight: 185, transform: nil))
out.clip()
out.interpolationQuality = .high
out.draw(plate, in: dst.insetBy(dx: -4, dy: -4))

let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("плашка \(Int(box.width))×\(Int(box.height)) из \(w)×\(h) → \(args[2])")
