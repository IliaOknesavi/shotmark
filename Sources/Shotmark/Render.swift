import AppKit
import CoreImage

@MainActor
enum Render {
    private static let ci = CIContext()

    /// Снимок с разметкой. crop: применить обрезку из состояния.
    /// skip — индекс аннотации, которую не рисовать (её тянут мышью и рисуют поверх отдельно).
    static func image(_ shot: Shot, annotated: Bool = true, crop: Bool = true, skip: Int? = nil) -> CGImage {
        let base = shot.base
        let w = base.width, h = base.height
        guard annotated || shot.state.crop != nil else { return base }
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        if annotated {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            for (i, a) in shot.state.anns.enumerated() where i != skip { draw(a, in: ctx, base: base) }
            NSGraphicsContext.restoreGraphicsState()
        }
        var out = ctx.makeImage()!
        if crop, let c = shot.state.crop {
            let r = c.standardized.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            if !r.isEmpty, let cropped = out.cropping(to: r) { out = cropped }
        }
        return out
    }

    /// Уменьшить так, чтобы длинная сторона была не больше maxSide.
    static func downscale(_ img: CGImage, maxSide: Int) -> CGImage {
        let side = max(img.width, img.height)
        guard maxSide > 0, side > maxSide else { return img }
        let k = Double(maxSide) / Double(side)
        let w = max(1, Int(Double(img.width) * k)), h = max(1, Int(Double(img.height) * k))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func rect(_ a: Ann) -> CGRect {
        guard let p = a.points.first else { return .zero }
        let q = a.points.count > 1 ? a.points[1] : p
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
    }

    /// Рисует аннотацию. ctx перевёрнут (начало слева сверху) и в пикселях снимка;
    /// NSGraphicsContext.current должен указывать на него (для текста).
    static func draw(_ a: Ann, in ctx: CGContext, base: CGImage) {
        guard let p0 = a.points.first else { return }
        let col = color(a.color)
        let w = max(1, a.width ?? 4)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(col.cgColor)
        ctx.setFillColor(col.cgColor)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let p1 = a.points.count > 1 ? a.points[1] : p0
        switch a.type {
        case "line":
            ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
        case "arrow":
            arrow(from: p0, to: p1, width: w, ctx: ctx)
        case "rect":
            if a.fill == true { ctx.fill(rect(a)) } else { ctx.stroke(rect(a)) }
        case "ellipse":
            if a.fill == true { ctx.fillEllipse(in: rect(a)) } else { ctx.strokeEllipse(in: rect(a)) }
        case "pen", "marker":
            if a.type == "marker" {
                ctx.setStrokeColor(col.withAlphaComponent(0.4).cgColor)
                ctx.setLineWidth(w * 4)
                ctx.setBlendMode(.multiply)
            }
            ctx.addLines(between: a.points.count > 1 ? a.points : [p0, p0])
            ctx.strokePath()
        case "text":
            let font = NSFont.boldSystemFont(ofSize: a.size ?? a.defaultSize)
            // сначала обводка, потом заливка поверх: у кириллицы в системном шрифте контуры внутри букв
            // перекрываются, и штрих поверх заливки рисовал бы эти внутренние линии
            let text = (a.text ?? "") as NSString
            text.draw(at: p0, withAttributes: [.font: font, .strokeColor: contrast(col), .strokeWidth: 5])
            text.draw(at: p0, withAttributes: [.font: font, .foregroundColor: col])
        case "callout":
            let (box, font, pad) = calloutBox(a)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: contrast(col)]
            let text = (a.text ?? "") as NSString
            ctx.move(to: CGPoint(x: box.midX, y: box.midY)); ctx.addLine(to: p0); ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: p0.x - w, y: p0.y - w, width: w * 2, height: w * 2))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: pad, cornerHeight: pad, transform: nil))
            ctx.fillPath()
            text.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
        case "step":
            let r = a.size ?? a.defaultSize
            ctx.fillEllipse(in: CGRect(x: p0.x - r, y: p0.y - r, width: r * 2, height: r * 2))
            let font = NSFont.boldSystemFont(ofSize: r * 1.1)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: contrast(col)]
            let s = "\(a.number ?? 1)" as NSString
            let ts = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: p0.x - ts.width / 2, y: p0.y - ts.height / 2), withAttributes: attrs)
        case "blur", "pixelate":
            let r = rect(a).integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
            guard r.width >= 1, r.height >= 1 else { return }
            let H = CGFloat(base.height)
            let ciRect = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
            let src = CIImage(cgImage: base)
            let out: CIImage
            if a.type == "blur" {
                out = src.clampedToExtent().applyingGaussianBlur(sigma: Double(a.size ?? 12))
            } else {
                let f = CIFilter(name: "CIPixellate")!
                f.setValue(src.clampedToExtent(), forKey: kCIInputImageKey)
                f.setValue(max(2, a.size ?? 16), forKey: kCIInputScaleKey)
                f.setValue(CIVector(x: ciRect.minX, y: ciRect.minY), forKey: kCIInputCenterKey)
                out = f.outputImage!
            }
            if let img = ci.createCGImage(out.cropped(to: ciRect), from: ciRect) { drawImage(img, in: r, ctx: ctx) }
        case "loupe":
            let r = a.size ?? a.defaultSize
            let target = a.points.count > 1 ? p1 : p0
            let srcRect = CGRect(x: p0.x - r / 2, y: p0.y - r / 2, width: r, height: r).integral
            let dst = CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)
            if let piece = base.cropping(to: srcRect) {
                ctx.saveGState()
                ctx.addEllipse(in: dst); ctx.clip()
                ctx.interpolationQuality = .none
                drawImage(piece, in: dst, ctx: ctx)
                ctx.restoreGState()
            }
            ctx.strokeEllipse(in: dst)
        default:
            break
        }
    }

    static func calloutBox(_ a: Ann) -> (CGRect, NSFont, CGFloat) {
        let font = NSFont.boldSystemFont(ofSize: a.size ?? a.defaultSize)
        let ts = ((a.text ?? "") as NSString).size(withAttributes: [.font: font])
        let pad = font.pointSize * 0.5
        let p1 = a.points.count > 1 ? a.points[1] : (a.points.first ?? .zero)
        return (CGRect(x: p1.x, y: p1.y, width: ts.width + pad * 2, height: ts.height + pad), font, pad)
    }

    /// Рамка аннотации в пикселях снимка — для выбора мышью и маркеров размера.
    static func bounds(_ a: Ann) -> CGRect {
        guard let p0 = a.points.first else { return .zero }
        let w = max(1, a.width ?? 4)
        switch a.type {
        case "text":
            let font = NSFont.boldSystemFont(ofSize: a.size ?? a.defaultSize)
            return CGRect(origin: p0, size: ((a.text ?? " ") as NSString).size(withAttributes: [.font: font]))
        case "callout":
            return calloutBox(a).0.union(CGRect(x: p0.x - w, y: p0.y - w, width: w * 2, height: w * 2))
        case "step":
            let r = a.size ?? a.defaultSize
            return CGRect(x: p0.x - r, y: p0.y - r, width: r * 2, height: r * 2)
        case "loupe":
            let r = a.size ?? a.defaultSize, t = a.points.count > 1 ? a.points[1] : p0
            return CGRect(x: t.x - r, y: t.y - r, width: r * 2, height: r * 2)
        case "rect", "ellipse", "blur", "pixelate":
            return rect(a)
        default:
            let xs = a.points.map(\.x), ys = a.points.map(\.y)
            let k = a.type == "marker" ? w * 2 : w / 2
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -k, dy: -k)
        }
    }

    static func drawImage(_ img: CGImage, in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    private static func arrow(from p: CGPoint, to q: CGPoint, width w: CGFloat, ctx: CGContext) {
        let dx = q.x - p.x, dy = q.y - p.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let head = min(len, max(12, w * 4))
        let ang = atan2(dy, dx), spread = CGFloat.pi / 7
        let base = CGPoint(x: q.x - cos(ang) * head * 0.8, y: q.y - sin(ang) * head * 0.8)
        ctx.move(to: p); ctx.addLine(to: base); ctx.strokePath()
        ctx.move(to: q)
        ctx.addLine(to: CGPoint(x: q.x - cos(ang - spread) * head, y: q.y - sin(ang - spread) * head))
        ctx.addLine(to: CGPoint(x: q.x - cos(ang + spread) * head, y: q.y - sin(ang + spread) * head))
        ctx.closePath(); ctx.fillPath()
    }

    private static func contrast(_ c: NSColor) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        let lum = 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
        return lum > 0.6 ? .black : .white
    }
}
