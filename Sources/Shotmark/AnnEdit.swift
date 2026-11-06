import AppKit

/// Правка готовых аннотаций мышью: маркеры, перемещение, изменение размера.
extension Ann {
    /// Размер по умолчанию, если size не задан: кегль текста, радиус шага или лупы, сила размытия, размер пикселя.
    var defaultSize: CGFloat {
        let w = width ?? 4
        switch type {
        case "step": return max(14, w * 4)
        case "loupe": return 80
        case "blur": return 12
        case "pixelate": return 16
        default: return 14 + w * 3
        }
    }

    var isSegment: Bool { type == "line" || type == "arrow" }

    func translated(by d: CGVector) -> Ann {
        var a = self
        if type == "loupe" {
            // лупа двигает только место показа: что увеличено, остаётся на месте
            let t = points.count > 1 ? points[1] : points[0]
            a.points = [points[0], CGPoint(x: t.x + d.dx, y: t.y + d.dy)]
        } else {
            a.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        }
        return a
    }

    /// Маркеры: у линии и стрелки — концы, у остальных — углы рамки (по часовой с левого верхнего).
    @MainActor func handles() -> [CGPoint] {
        if isSegment, points.count > 1 { return [points[0], points[1]] }
        let b = Render.bounds(self)
        return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
    }

    /// Тянем маркер k в точку p.
    @MainActor func resized(handle k: Int, to p: CGPoint) -> Ann {
        var a = self
        if isSegment, points.count > 1 {
            a.points[k] = p
            return a
        }
        let old = Render.bounds(self)
        let fixed = handles()[(k + 2) % 4]
        let new = CGRect(x: min(fixed.x, p.x), y: min(fixed.y, p.y), width: max(4, abs(p.x - fixed.x)), height: max(4, abs(p.y - fixed.y)))
        guard old.width > 0, old.height > 0 else { return a }
        switch type {
        case "loupe":
            let r = max(10, min(new.width, new.height) / 2)
            a.size = r
            a.points = [points[0], CGPoint(x: new.midX, y: new.midY)]
            return a
        case "text", "callout", "step":
            // текст и шаги растут целиком: кегль и радиус по высоте рамки
            let k = new.height / old.height
            a.size = max(6, (size ?? defaultSize) * k)
        default:
            break
        }
        let sx = new.width / old.width, sy = new.height / old.height
        a.points = points.map { CGPoint(x: new.minX + ($0.x - old.minX) * sx, y: new.minY + ($0.y - old.minY) * sy) }
        return a
    }
}
