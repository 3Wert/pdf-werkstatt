import AppKit
import PDFKit

/// Einfache Formerkennung für das Skizzieren: Linie, Pfeil, Rechteck, Oval. Sonst nil (Strich bleibt Freihand).
enum ShapeRecognizer {
    static func recognize(_ pts: [CGPoint]) -> WObject? {
        guard pts.count >= 6 else { return nil }
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let diag = hypot(box.width, box.height)
        guard diag > 12 else { return nil }
        let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let closed = hypot(pts[0].x - pts[pts.count - 1].x, pts[0].y - pts[pts.count - 1].y) < max(diag * 0.22, 10)
        let simple = simplify(pts, tolerance: max(diag * 0.06, 3))

        if !closed {
            // Linie: fast gerade (Länge ≈ Abstand Anfang–Ende)
            let direct = hypot(pts[pts.count - 1].x - pts[0].x, pts[pts.count - 1].y - pts[0].y)
            if direct > diag * 0.85 && length < direct * 1.12 { return line(from: pts[0], to: pts[pts.count - 1], arrow: false) }
            // Pfeil: Linie, deren letztes Stück zurückknickt (Spitze angedeutet)
            if simple.count >= 3 && simple.count <= 6 {
                let a = simple[0], b = simple[1]
                let shaft = hypot(b.x - a.x, b.y - a.y)
                let rest = simple.dropFirst(1).map { hypot($0.x - b.x, $0.y - b.y) }.max() ?? 0
                if shaft > diag * 0.7, rest < shaft * 0.45 { return line(from: a, to: b, arrow: true) }
            }
            return nil
        }
        // Geschlossen: Rechteck, wenn die Vereinfachung ~4 Ecken hat und die Fläche die Box gut füllt
        let area = polygonArea(pts)
        let boxArea = box.width * box.height
        guard boxArea > 0 else { return nil }
        let fill = area / boxArea
        let corners = simple.count - (hypot(simple[0].x - simple[simple.count - 1].x, simple[0].y - simple[simple.count - 1].y) < diag * 0.1 ? 1 : 0)
        var m: ObjModel
        if corners >= 4 && corners <= 6 && fill > 0.78 { m = Defaults.newModel(.rect) }
        else if fill > 0.62 && fill < 0.9 { m = Defaults.newModel(.ellipse) }
        else { return nil }
        m.fill = nil
        return WObject(model: m, bounds: box)
    }

    private static func line(from a: CGPoint, to b: CGPoint, arrow: Bool) -> WObject {
        var m = Defaults.newModel(arrow ? .arrow : .line)
        let (bounds, n) = WObject.normalize([[a, b]], margin: m.lineWidth + 4)
        m.strokes = n
        return WObject(model: m, bounds: bounds)
    }

    private static func polygonArea(_ p: [CGPoint]) -> CGFloat {
        var a: CGFloat = 0
        for i in 0..<p.count { let j = (i + 1) % p.count; a += p[i].x * p[j].y - p[j].x * p[i].y }
        return abs(a) / 2
    }

    /// Ramer–Douglas–Peucker
    static func simplify(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        let a = pts[0], b = pts[pts.count - 1]
        var maxD: CGFloat = 0, idx = 0
        for i in 1..<(pts.count - 1) {
            let d = distance(pts[i], a, b)
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > tolerance {
            let l = simplify(Array(pts[0...idx]), tolerance: tolerance)
            let r = simplify(Array(pts[idx...]), tolerance: tolerance)
            return Array(l.dropLast()) + r
        }
        return [a, b]
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        if l2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
