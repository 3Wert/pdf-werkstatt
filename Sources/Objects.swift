import AppKit
import PDFKit

/// Zeichenmodus: Auf dem Bildschirm zeichnet die Arbeitsfläche die eigenen Objekte selbst (Overlay).
/// PDFKit zeichnet sie nur innerhalb von `DrawMode.full { }` – beim Sichern, Exportieren, Drucken, für Miniaturen.
/// Thread-lokal, damit PDFKits eigene Render-Threads nie in den Vollmodus geraten (sonst Geisterbilder im Cache).
enum DrawMode {
    private static let key = "pdfw.fullDrawing"
    static var isFull: Bool {
        get { Thread.current.threadDictionary[key] as? Bool ?? false }
        set { Thread.current.threadDictionary[key] = newValue }
    }
    static func full<T>(_ f: () throws -> T) rethrows -> T {
        let old = isFull
        isFull = true
        defer { isFull = old }
        return try f()
    }
    /// Bildschirmdarstellung (Overlay): noch nicht angewendete Schwärzungen zeigen durchscheinend, was darunter liegt
    private static let screenKey = "pdfw.onScreen"
    static var onScreen: Bool {
        get { Thread.current.threadDictionary[screenKey] as? Bool ?? false }
        set { Thread.current.threadDictionary[screenKey] = newValue }
    }
}

/// Schlüssel, unter dem die bearbeitbaren Daten eines Objekts im PDF liegen.
let wKey = PDFAnnotationKey(rawValue: "/PDFWerkstatt")
let pad: CGFloat = 2

enum ObjKind: String, Codable { case text, rect, ellipse, line, arrow, ink, image, cover, pageNumber, roundRect, bubble, star, polygon }

struct RGBA: Codable, Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? NSColor.black
        r = s.redComponent; g = s.greenComponent; b = s.blueComponent; a = s.alphaComponent
    }
    var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

struct ObjModel: Codable, Equatable {
    var id: String = UUID().uuidString   // bleibt über Sichern/Neuladen erhalten – Widerrufen findet das Objekt darüber
    var kind: ObjKind
    var text = ""
    var fontName = "ArialMT"
    var fontSize: CGFloat = 12
    var textColor = RGBA(.black)
    var align = 0
    var autoWidth = true
    var lineHeight: CGFloat? = nil
    var stroke: RGBA? = RGBA(.black)
    var fill: RGBA? = nil
    var lineWidth: CGFloat = 1.5
    var strokes: [[CGPoint]] = []      // normiert 0…1 innerhalb der Bounds
    var image: Data? = nil
    var format = "{n}"
    var startNumber = 1
    var firstPage = 0
    var rot = 0                         // Seitendrehung, bei der Text/Bild aufrecht steht
    var dash = false
    var shadow = false
    var origFont: String? = nil          // Schrift im PDF, falls sie auf dem Mac fehlt
    var redact: Bool? = nil              // Abdeckung ist eine Schwärzungs-Markierung: Inhalt darunter wird beim Anwenden entfernt

    init(kind: ObjKind) { self.kind = kind }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, fontName, fontSize, textColor, align, autoWidth, lineHeight, stroke, fill, lineWidth, strokes, image, format, startNumber, firstPage, rot, dash, shadow, origFont, redact
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decode(ObjKind.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "ArialMT"
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 12
        textColor = try c.decodeIfPresent(RGBA.self, forKey: .textColor) ?? RGBA(.black)
        align = try c.decodeIfPresent(Int.self, forKey: .align) ?? 0
        autoWidth = try c.decodeIfPresent(Bool.self, forKey: .autoWidth) ?? true
        lineHeight = try c.decodeIfPresent(CGFloat.self, forKey: .lineHeight)
        stroke = try c.decodeIfPresent(RGBA.self, forKey: .stroke)
        fill = try c.decodeIfPresent(RGBA.self, forKey: .fill)
        lineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? 1.5
        strokes = try c.decodeIfPresent([[CGPoint]].self, forKey: .strokes) ?? []
        image = try c.decodeIfPresent(Data.self, forKey: .image)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "{n}"
        startNumber = try c.decodeIfPresent(Int.self, forKey: .startNumber) ?? 1
        firstPage = try c.decodeIfPresent(Int.self, forKey: .firstPage) ?? 0
        rot = try c.decodeIfPresent(Int.self, forKey: .rot) ?? 0
        dash = try c.decodeIfPresent(Bool.self, forKey: .dash) ?? false
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
        origFont = try c.decodeIfPresent(String.self, forKey: .origFont)
        redact = try c.decodeIfPresent(Bool.self, forKey: .redact)
    }
    var isRedaction: Bool { kind == .cover && redact == true }

    var isText: Bool { kind == .text || kind == .pageNumber }
    var isLine: Bool { kind == .line || kind == .arrow }
    var isShape: Bool { [.rect, .ellipse, .roundRect, .bubble, .star, .polygon].contains(kind) }
    var hasStroke: Bool { isShape || isLine || kind == .ink || kind == .text }
    var hasFill: Bool { isShape || kind == .text || kind == .cover }
}

/// Standardwerte für neue Objekte (werden im Inspektor eingestellt, wenn nichts ausgewählt ist).
enum Defaults {
    static var model: ObjModel = load()
    private static func load() -> ObjModel {
        if let d = prefs.data(forKey: "standardStil"), let m = try? JSONDecoder().decode(ObjModel.self, from: d) { return m }
        var m = ObjModel(kind: .rect)
        m.stroke = RGBA(NSColor(srgbRed: 0.82, green: 0.11, blue: 0.11, alpha: 1))
        m.lineWidth = 2
        return m
    }
    static func save() {
        if let d = try? JSONEncoder().encode(model) { prefs.set(d, forKey: "standardStil") }
    }
    static func newModel(_ kind: ObjKind) -> ObjModel {
        var m = ObjModel(kind: kind)
        let s = model
        m.fontName = s.fontName; m.fontSize = s.fontSize; m.textColor = s.textColor; m.align = s.align
        switch kind {
        case .text, .pageNumber: m.stroke = nil; m.fill = nil
        case .rect, .ellipse, .roundRect, .bubble, .star, .polygon:
            m.stroke = s.stroke; m.fill = s.fill; m.lineWidth = s.lineWidth; m.dash = s.dash; m.shadow = s.shadow
        case .line, .arrow: m.stroke = s.stroke ?? RGBA(.black); m.fill = nil; m.lineWidth = s.lineWidth; m.dash = s.dash; m.shadow = s.shadow
        case .ink: m.stroke = s.stroke ?? RGBA(.black); m.fill = nil; m.lineWidth = s.lineWidth; m.shadow = s.shadow
        case .cover: m.stroke = nil; m.fill = RGBA(.white)
        case .image: m.stroke = nil; m.fill = nil
        }
        return m
    }
}

final class WObject: PDFAnnotation {
    var model: ObjModel { didSet { imageCache = nil; sync() } }
    var editing = false
    private var imageCache: NSImage?

    init(model: ObjModel, bounds: CGRect) {
        self.model = model
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        setup()
    }

    // Wird von PDFKit beim Kopieren einer Seite benutzt.
    override init(bounds: CGRect, forType t: PDFAnnotationSubtype, withProperties p: [AnyHashable: Any]?) {
        var m = ObjModel(kind: .rect)
        if let s = (p?[wKey.rawValue] ?? p?[wKey]) as? String, let d = s.data(using: .utf8),
           let dec = try? JSONDecoder().decode(ObjModel.self, from: d) { m = dec }
        model = m
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        setup()
    }

    required init?(coder: NSCoder) { return nil }

    private func setup() {
        setValue(NSNumber(value: 4), forAnnotationKey: .flags)   // druckbar
        sync()
    }

    func sync() {
        if let d = try? JSONEncoder().encode(model), let s = String(data: d, encoding: .utf8) {
            setValue(s as NSString, forAnnotationKey: wKey)
        }
    }

    static func from(_ a: PDFAnnotation) -> WObject? {
        guard let s = a.value(forAnnotationKey: wKey) as? String, let d = s.data(using: .utf8),
              let m = try? JSONDecoder().decode(ObjModel.self, from: d) else { return nil }
        return WObject(model: m, bounds: a.bounds)
    }

    // MARK: Text

    var textFont: NSFont {
        NSFont(name: model.fontName, size: model.fontSize) ?? NSFont(name: "ArialMT", size: model.fontSize) ?? .systemFont(ofSize: model.fontSize)
    }

    var displayText: String {
        guard model.kind == .pageNumber else { return model.text }
        guard let p = page, let d = p.document else { return model.format.replacingOccurrences(of: "{n}", with: "1").replacingOccurrences(of: "{N}", with: "1") }
        let i = d.index(for: p)
        let n = i - model.firstPage + model.startNumber
        let total = d.pageCount - 1 - model.firstPage + model.startNumber
        return model.format.replacingOccurrences(of: "{n}", with: "\(n)").replacingOccurrences(of: "{N}", with: "\(total)")
    }

    func attributes(scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.alignment = [NSTextAlignment.left, .center, .right][max(0, min(2, model.align))]
        ps.lineBreakMode = .byWordWrapping
        if let lh = model.lineHeight { ps.minimumLineHeight = lh * scale; ps.maximumLineHeight = lh * scale }
        let f = NSFont(descriptor: textFont.fontDescriptor, size: model.fontSize * scale) ?? textFont
        return [.font: f, .foregroundColor: model.textColor.color, .paragraphStyle: ps]
    }

    var naturalLineHeight: CGFloat { model.lineHeight ?? ceil(textFont.ascender - textFont.descender + textFont.leading) }

    var upright: Bool { model.isText || model.kind == .image }
    private var swapped: Bool { upright && (model.rot == 90 || model.rot == 270) }
    /// Größe so, wie man sie sieht (bei gedrehtem Text vertauscht).
    var visualSize: CGSize { swapped ? CGSize(width: bounds.height, height: bounds.width) : bounds.size }

    func textSize(width: CGFloat?) -> CGSize {
        let s = displayText.isEmpty ? " " : displayText
        let maxW = width.map { max(1, $0 - 2 * pad) } ?? 100_000
        let r = (s as NSString).boundingRect(with: CGSize(width: maxW, height: 100_000),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes())
        var h = ceil(r.height)
        if s.hasSuffix("\n") { h += naturalLineHeight }
        return CGSize(width: ceil(r.width) + 2 * pad + 2, height: h + 2 * pad + 1)
    }

    /// Passt die Höhe (und bei Punkttext die Breite) an den Text an. Obere linke Ecke bleibt stehen.
    func fitBounds() {
        guard model.kind == .text else { return }
        let vw = visualSize.width
        let sz = textSize(width: model.autoWidth ? nil : vw)
        let w = model.autoWidth ? max(sz.width, 12) : vw
        let h = max(sz.height, naturalLineHeight + 2 * pad)
        bounds = WObject.anchoredRect(old: bounds, w: w, h: h, rotation: model.rot)
    }

    static func anchoredRect(old b: CGRect, w: CGFloat, h: CGFloat, rotation: Int) -> CGRect {
        switch rotation {
        case 90: return CGRect(x: b.minX, y: b.minY, width: h, height: w)
        case 180: return CGRect(x: b.maxX - w, y: b.minY, width: w, height: h)
        case 270: return CGRect(x: b.maxX - h, y: b.maxY - w, width: h, height: w)
        default: return CGRect(x: b.minX, y: b.maxY - h, width: w, height: h)
        }
    }

    // MARK: Linien

    var absoluteStrokes: [[CGPoint]] { WObject.denormalize(model.strokes, in: bounds) }

    static func denormalize(_ s: [[CGPoint]], in b: CGRect) -> [[CGPoint]] {
        s.map { $0.map { CGPoint(x: b.minX + $0.x * b.width, y: b.minY + $0.y * b.height) } }
    }

    static func normalize(_ s: [[CGPoint]], margin: CGFloat) -> (CGRect, [[CGPoint]]) {
        let all = s.flatMap { $0 }
        guard let f = all.first else { return (.zero, s) }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in all { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let b = CGRect(x: minX - margin, y: minY - margin, width: maxX - minX + 2 * margin, height: maxY - minY + 2 * margin)
        let n = s.map { $0.map { CGPoint(x: ($0.x - b.minX) / b.width, y: ($0.y - b.minY) / b.height) } }
        return (b, n)
    }

    func hit(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        switch model.kind {
        case .line, .arrow, .ink:
            let tt = t + model.lineWidth / 2 + 2
            for s in absoluteStrokes {
                if s.count == 1, hypot(s[0].x - p.x, s[0].y - p.y) < tt { return true }
                for i in 1..<max(1, s.count) where distance(p, s[i - 1], s[i]) < tt { return true }
            }
            return false
        default:
            return bounds.insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        var t = l2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2 : 0
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Zeichnen

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        if editing { return }
        guard DrawMode.isFull else { return }      // auf dem Bildschirm zeichnet das Overlay
        context.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        var r = bounds
        if upright && model.rot != 0 {
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.rotate(by: CGFloat(model.rot) * .pi / 180)
            let vs = visualSize
            r = CGRect(x: -vs.width / 2, y: -vs.height / 2, width: vs.width, height: vs.height)
        }
        render(in: r)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private func render(in r: CGRect) {
        let lw = model.lineWidth
        switch model.kind {
        case .text, .pageNumber:
            if let f = model.fill { f.color.setFill(); r.fill() }
            if let s = model.stroke, lw > 0 {
                s.color.setStroke()
                let p = NSBezierPath(rect: r.insetBy(dx: lw / 2, dy: lw / 2)); p.lineWidth = lw; p.stroke()
            }
            (displayText as NSString).draw(in: r.insetBy(dx: pad, dy: pad), withAttributes: attributes())
        case .cover:
            if model.isRedaction && DrawMode.onScreen {
                // Markierung, noch nicht angewendet: Inhalt bleibt erkennbar, roter Rand
                (model.fill ?? RGBA(.black)).color.withAlphaComponent(0.35).setFill(); r.fill()
                NSColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1).setStroke()
                let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
            } else {
                (model.fill ?? RGBA(.white)).color.setFill(); r.fill()
            }
        case .rect, .ellipse, .roundRect, .bubble, .star, .polygon:
            let rr = r.insetBy(dx: lw / 2 + (model.shadow ? 3 : 0), dy: lw / 2 + (model.shadow ? 3 : 0))
            let p = WObject.shapePath(model.kind, in: rr)
            applyShadow()
            if let f = model.fill { f.color.setFill(); p.fill() }
            if let s = model.stroke, lw > 0 {
                if model.fill != nil { NSShadow().set() }
                s.color.setStroke(); p.lineWidth = lw; p.lineJoinStyle = .round; applyDash(p); p.stroke()
            }
        case .line, .arrow:
            guard let pts = absoluteStrokes.first, pts.count >= 2, let s = model.stroke else { return }
            applyShadow()
            var a = pts[0], b = pts[pts.count - 1]
            s.color.setStroke(); s.color.setFill()
            if model.kind == .arrow {
                let ang = atan2(b.y - a.y, b.x - a.x)
                let len = max(9, lw * 4)
                let tip = b
                let head = NSBezierPath()
                head.move(to: tip)
                head.line(to: CGPoint(x: tip.x - len * cos(ang - 0.42), y: tip.y - len * sin(ang - 0.42)))
                head.line(to: CGPoint(x: tip.x - len * cos(ang + 0.42), y: tip.y - len * sin(ang + 0.42)))
                head.close(); head.fill()
                b = CGPoint(x: tip.x - len * 0.75 * cos(ang), y: tip.y - len * 0.75 * sin(ang))
                if hypot(b.x - a.x, b.y - a.y) < 1 { a = b }
            }
            let p = NSBezierPath(); p.move(to: a); p.line(to: b)
            p.lineWidth = lw; p.lineCapStyle = .round; applyDash(p); p.stroke()
        case .ink:
            guard let s = model.stroke else { return }
            applyShadow()
            s.color.setStroke()
            for pts in absoluteStrokes where !pts.isEmpty {
                let p = NSBezierPath()
                p.move(to: pts[0])
                if pts.count < 3 { pts.dropFirst().forEach { p.line(to: $0) } } else {
                    for i in 1..<(pts.count - 1) {
                        let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                        p.curve(to: mid, controlPoint1: pts[i], controlPoint2: pts[i])
                    }
                    p.line(to: pts[pts.count - 1])
                }
                p.lineWidth = lw; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
            }
        case .image:
            if imageCache == nil, let d = model.image { imageCache = NSImage(data: d) }
            imageCache?.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    private func applyDash(_ p: NSBezierPath) {
        if model.dash { let l = max(2, model.lineWidth * 3); p.setLineDash([l, l * 0.7], count: 2, phase: 0) }
    }

    private func applyShadow() {
        guard model.shadow else { return }
        let sh = NSShadow()
        sh.shadowOffset = NSSize(width: 1.5, height: -1.5)
        sh.shadowBlurRadius = 3
        sh.shadowColor = NSColor.black.withAlphaComponent(0.45)
        sh.set()
    }

    static func shapePath(_ k: ObjKind, in r: CGRect) -> NSBezierPath {
        switch k {
        case .ellipse: return NSBezierPath(ovalIn: r)
        case .roundRect:
            let rad = min(r.width, r.height) * 0.18
            return NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
        case .bubble:
            let body = CGRect(x: r.minX, y: r.minY + r.height * 0.22, width: r.width, height: r.height * 0.78)
            let rad = min(body.width, body.height) * 0.22
            let p = NSBezierPath(roundedRect: body, xRadius: rad, yRadius: rad)
            let tail = NSBezierPath()
            tail.move(to: CGPoint(x: body.minX + body.width * 0.18, y: body.minY + 1))
            tail.line(to: CGPoint(x: r.minX + r.width * 0.1, y: r.minY))
            tail.line(to: CGPoint(x: body.minX + body.width * 0.38, y: body.minY + 1))
            tail.close()
            p.append(tail)
            p.windingRule = .nonZero
            return p
        case .star, .polygon:
            let n = k == .star ? 10 : 6
            let c = CGPoint(x: r.midX, y: r.midY)
            let p = NSBezierPath()
            for i in 0..<n {
                let a = CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(n)
                let f: CGFloat = (k == .star && i % 2 == 1) ? 0.42 : 1
                let pt = CGPoint(x: c.x + cos(a) * r.width / 2 * f, y: c.y + sin(a) * r.height / 2 * f)
                i == 0 ? p.move(to: pt) : p.line(to: pt)
            }
            p.close()
            return p
        default: return NSBezierPath(rect: r)
        }
    }

    var kindName: String {
        switch model.kind {
        case .text: return "Text"
        case .rect: return "Rechteck"
        case .ellipse: return "Ellipse"
        case .line: return "Linie"
        case .arrow: return "Pfeil"
        case .ink: return "Freihand"
        case .image: return "Bild"
        case .cover: return "Abdeckung"
        case .pageNumber: return "Seitenzahl"
        case .roundRect: return "Abgerundetes Rechteck"
        case .bubble: return "Sprechblase"
        case .star: return "Stern"
        case .polygon: return "Vieleck"
        }
    }
}

/// Ersetzt gespeicherte Werkstatt-Objekte einer Seite durch bearbeitbare Objekte.
func hydrate(page: PDFPage) {
    for a in page.annotations where !(a is WObject) {
        if let w = WObject.from(a) { page.removeAnnotation(a); page.addAnnotation(w) }
    }
}

func hydrate(document d: PDFDocument) {
    for i in 0..<d.pageCount { if let p = d.page(at: i) { hydrate(page: p) } }
}
