import AppKit
import PDFKit

// MARK: - Einstellungen

struct GuideSettings: Codable {
    var snapPage = true          // Seitenränder und Randlinien
    var snapCenter = true        // Seitenmitte
    var snapObjects = true       // eigene Objekte
    var snapText = true          // Text im PDF (Kanten, Grundlinie, Zeilenabstand)
    var snapContent = true       // Bilder und Linien im PDF
    var snapCustom = true        // eigene Hilfslinien
    var tolerance: CGFloat = 5   // Fangbereich in Bildschirmpunkten
    var marginMM: CGFloat = 20   // Randlinien
    var showRulers = false
    var showGrid = false
    var gridMM: CGFloat = 10
    var snapGrid = false
    var showCustom = true

    static var shared: GuideSettings = {
        if let d = prefs.data(forKey: "hilfslinien"), let s = try? JSONDecoder().decode(GuideSettings.self, from: d) { return s }
        return GuideSettings()
    }() { didSet { if let d = try? JSONEncoder().encode(shared) { prefs.set(d, forKey: "hilfslinien") } } }
}

// MARK: - Fangquellen einer Seite

/// Eine Linie, an der eingerastet werden kann (Seitenkoordinaten)
struct SnapLine {
    enum Kind: String { case page = "Seitenrand", margin = "Rand", center = "Seitenmitte", object = "Objekt", objectCenter = "Objektmitte",
                        text = "Textkante", baseline = "Grundlinie", lineSpacing = "Zeilenabstand", content = "Bild/Linie", custom = "Hilfslinie", grid = "Raster" }
    var kind: Kind
    var value: CGFloat          // x bei vertikal, y bei horizontal
    var vertical: Bool
    var range: ClosedRange<CGFloat>? = nil   // Ausdehnung quer dazu (für die Anzeige), nil = ganze Seite
}

/// Sammelt alle Fanglinien einer Seite. Wird je Seite zwischengespeichert, bis sich etwas ändert.
final class SnapSources {
    let pageIndex: Int
    let generation: Int
    var lines: [SnapLine] = []

    init(page: PDFPage, pageIndex: Int, generation: Int, exclude: [PDFAnnotation], content: PageContentModel?, custom: ([CGFloat], [CGFloat]), settings s: GuideSettings) {
        self.pageIndex = pageIndex
        self.generation = generation
        let pb = page.bounds(for: .cropBox)
        let m = s.marginMM * 72 / 25.4
        if s.snapPage {
            lines += [SnapLine(kind: .page, value: pb.minX, vertical: true), SnapLine(kind: .page, value: pb.maxX, vertical: true),
                      SnapLine(kind: .page, value: pb.minY, vertical: false), SnapLine(kind: .page, value: pb.maxY, vertical: false)]
            if m > 0, m * 2 < min(pb.width, pb.height) {
                lines += [SnapLine(kind: .margin, value: pb.minX + m, vertical: true), SnapLine(kind: .margin, value: pb.maxX - m, vertical: true),
                          SnapLine(kind: .margin, value: pb.minY + m, vertical: false), SnapLine(kind: .margin, value: pb.maxY - m, vertical: false)]
            }
        }
        if s.snapCenter {
            lines += [SnapLine(kind: .center, value: pb.midX, vertical: true), SnapLine(kind: .center, value: pb.midY, vertical: false)]
        }
        if s.snapObjects {
            for a in page.annotations where a is WObject && !exclude.contains(where: { $0 === a }) && a.shouldDisplay {
                let b = a.bounds
                lines += [SnapLine(kind: .object, value: b.minX, vertical: true, range: b.minY...b.maxY), SnapLine(kind: .object, value: b.maxX, vertical: true, range: b.minY...b.maxY),
                          SnapLine(kind: .object, value: b.minY, vertical: false, range: b.minX...b.maxX), SnapLine(kind: .object, value: b.maxY, vertical: false, range: b.minX...b.maxX),
                          SnapLine(kind: .objectCenter, value: b.midX, vertical: true, range: b.minY...b.maxY), SnapLine(kind: .objectCenter, value: b.midY, vertical: false, range: b.minX...b.maxX)]
                if let w = a as? WObject, w.model.isText, w.model.rot == 0 {
                    lines.append(SnapLine(kind: .baseline, value: w.firstBaselineY, vertical: false, range: b.minX...b.maxX))
                }
            }
        }
        if s.snapText, PDFTools.normRotation(page.rotation) == 0, let sel = page.selection(for: pb) {
            var baselines: [(CGFloat, CGFloat, CGFloat)] = []   // y, minX, maxX
            for line in sel.selectionsByLine() {
                guard !(line.string ?? "").trimmed.isEmpty else { continue }
                let b = line.bounds(for: page)
                guard b.width > 1, b.height > 1 else { continue }
                var desc: CGFloat = -b.height * 0.22
                if let a = line.attributedString, a.length > 0, let f = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { desc = f.descender }
                let base = b.minY - desc
                lines += [SnapLine(kind: .text, value: b.minX, vertical: true, range: b.minY...b.maxY), SnapLine(kind: .text, value: b.maxX, vertical: true, range: b.minY...b.maxY),
                          SnapLine(kind: .text, value: b.maxY, vertical: false, range: b.minX...b.maxX),
                          SnapLine(kind: .baseline, value: base, vertical: false, range: b.minX...b.maxX)]
                baselines.append((base, b.minX, b.maxX))
            }
            // Zeilenabstand: nächste Grundlinie ober- und unterhalb jeder Zeile im Abstand der Nachbarzeile
            let sorted = baselines.sorted { $0.0 > $1.0 }
            for i in sorted.indices {
                let (y, x0, x1) = sorted[i]
                // kleinster plausibler Abstand zu einer Nachbarzeile (Absatzsprünge zählen nicht)
                var gaps: [CGFloat] = []
                if i + 1 < sorted.count { gaps.append(y - sorted[i + 1].0) }
                if i > 0 { gaps.append(sorted[i - 1].0 - y) }
                guard let g = gaps.filter({ $0 > 2 && $0 < 60 }).min() else { continue }
                for cand in [y - g, y + g] where !sorted.contains(where: { abs($0.0 - cand) < 0.5 }) {
                    lines.append(SnapLine(kind: .lineSpacing, value: cand, vertical: false, range: x0...x1))
                }
            }
        }
        if s.snapContent, let c = content {
            for e in c.elements where (e.kind == .image || e.kind == .path || e.kind == .form || e.kind == .inlineImage) && e.bounds.isUsable && e.bounds.width > 4 && e.bounds.height > 2 {
                let b = e.bounds
                lines += [SnapLine(kind: .content, value: b.minX, vertical: true, range: b.minY...b.maxY), SnapLine(kind: .content, value: b.maxX, vertical: true, range: b.minY...b.maxY),
                          SnapLine(kind: .content, value: b.minY, vertical: false, range: b.minX...b.maxX), SnapLine(kind: .content, value: b.maxY, vertical: false, range: b.minX...b.maxX)]
            }
        }
        if s.snapCustom {
            for x in custom.0 { lines.append(SnapLine(kind: .custom, value: x, vertical: true)) }
            for y in custom.1 { lines.append(SnapLine(kind: .custom, value: y, vertical: false)) }
        }
        if s.snapGrid, s.gridMM > 0 {
            let g = s.gridMM * 72 / 25.4
            var x = pb.minX; while x <= pb.maxX { lines.append(SnapLine(kind: .grid, value: x, vertical: true)); x += g }
            var y = pb.minY; while y <= pb.maxY { lines.append(SnapLine(kind: .grid, value: y, vertical: false)); y += g }
        }
    }

    struct Hit { var line: SnapLine; var delta: CGFloat; var edge: CGFloat }

    /// Bester Treffer für mehrere Kandidatenkanten (Seitenkoordinaten) innerhalb der Toleranz (Seitenpunkte)
    func best(vertical: Bool, candidates: [(CGFloat, Bool)], tolerance: CGFloat) -> Hit? {
        // candidates: (Wert, istGrundlinie) – Grundlinien rasten bevorzugt an Grundlinien/Zeilenabständen
        var hit: Hit? = nil
        for l in lines where l.vertical == vertical {
            for (c, isBase) in candidates {
                let baseKinds: Set<SnapLine.Kind> = [.baseline, .lineSpacing]
                if isBase != baseKinds.contains(l.kind) && !vertical { continue }   // Grundlinie nur an Grundlinie, Kante nur an Kante
                let d = l.value - c
                guard abs(d) <= tolerance else { continue }
                let better = hit == nil || abs(d) < abs(hit!.delta) - 0.01 || (abs(abs(d) - abs(hit!.delta)) <= 0.01 && priority(l.kind) > priority(hit!.line.kind))
                if better { hit = Hit(line: l, delta: d, edge: c) }
            }
        }
        return hit
    }

    private func priority(_ k: SnapLine.Kind) -> Int {
        switch k { case .custom: return 9; case .baseline: return 8; case .lineSpacing: return 7; case .text: return 6; case .object: return 5
                   case .objectCenter: return 4; case .content: return 3; case .margin: return 2; case .center: return 2; case .page: return 1; case .grid: return 0 }
    }
}

extension WObject {
    /// Abstand von der Oberkante des Rahmens zur ersten Textgrundlinie – hängt nur von Schrift und Zeilenhöhe ab, nicht von der Lage
    var baselineFromTop: CGFloat {
        let f = textFont
        let lh = model.lineHeight ?? ceil(f.ascender - f.descender + f.leading)
        return pad + (model.lineHeight != nil ? (lh - (lh - f.ascender + f.descender) / 2) : f.ascender)
    }
    /// y der ersten Textgrundlinie (nur für ungedrehten Text sinnvoll)
    var firstBaselineY: CGFloat { bounds.maxY - baselineFromTop }
}

// MARK: - Eigene Hilfslinien je Dokument

enum GuideStore {
    struct PageGuides: Codable { var x: [CGFloat] = []; var y: [CGFloat] = [] }
    private static func key(_ doc: WDocument) -> String { "hilfslinien:" + (doc.fileURL?.path ?? doc.displayName ?? "") }
    static func load(_ doc: WDocument) -> [Int: PageGuides] {
        guard let d = prefs.data(forKey: key(doc)), let m = try? JSONDecoder().decode([Int: PageGuides].self, from: d) else { return [:] }
        return m
    }
    static func save(_ doc: WDocument, _ m: [Int: PageGuides]) {
        if let d = try? JSONEncoder().encode(m) { prefs.set(d, forKey: key(doc)) }
    }
}

// MARK: - Lineal

final class RulerView: NSView {
    weak var canvas: Canvas?
    let horizontal: Bool
    static let thickness: CGFloat = 18

    init(horizontal: Bool) {
        self.horizontal = horizontal
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill(); bounds.fill()
        NSColor.separatorColor.setFill()
        if horizontal { NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill() }
        else { NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill() }
        guard let c = canvas, let page = c.currentPage else { return }
        let pb = page.bounds(for: .cropBox)
        let vs = PDFTools.visualSize(page)
        // Nullpunkt oben links der sichtbaren Seite
        let topLeftPage = PDFTools.visualToPage(CGRect(x: 0, y: vs.height, width: 0, height: 0), page: page).origin
        let o = convert(c.convert(topLeftPage, from: page), from: c)
        let onePt = convert(c.convert(CGPoint(x: pb.minX + 1, y: pb.minY), from: page), from: c).x - convert(c.convert(CGPoint(x: pb.minX, y: pb.minY), from: page), from: c).x
        let scale = abs(onePt)       // Bildschirmpunkte je PDF-Punkt
        guard scale > 0.01 else { return }
        let mm = 72 / 25.4 * scale   // Bildschirmpunkte je mm
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.secondaryLabelColor]
        let lengthMM = (horizontal ? vs.width : vs.height) * 25.4 / 72
        let step: CGFloat = mm < 2 ? 50 : mm < 4 ? 20 : 10
        var k: CGFloat = 0
        NSColor.tertiaryLabelColor.setFill()
        while k <= lengthMM {
            let pos = (horizontal ? o.x : o.y) + k * mm
            let major = k.truncatingRemainder(dividingBy: step) == 0
            let len: CGFloat = major ? 8 : (k.truncatingRemainder(dividingBy: 5) == 0 ? 5 : 3)
            if horizontal {
                if pos >= 0 && pos <= bounds.width {
                    NSRect(x: pos, y: bounds.maxY - len, width: 1, height: len).fill()
                    if major { ("\(Int(k))" as NSString).draw(at: CGPoint(x: pos + 2, y: 1), withAttributes: attrs) }
                }
            } else if pos >= 0 && pos <= bounds.height {
                NSRect(x: bounds.maxX - len, y: pos, width: len, height: 1).fill()
                if major {
                    NSGraphicsContext.saveGraphicsState()
                    let t = NSAffineTransform(); t.translateX(by: 2, yBy: pos - 2); t.rotate(byDegrees: 90)
                    t.concat()
                    ("\(Int(k))" as NSString).draw(at: .zero, withAttributes: attrs)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            k += mm < 4 ? 5 : 1
        }
    }

    /// Ziehen aus dem Lineal legt eine Hilfslinie an
    override func mouseDown(with e: NSEvent) {
        guard let c = canvas, let w = window else { return }
        c.previewGuide = nil
        var last = e
        while true {
            guard let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            last = ev
            let vp = c.convert(ev.locationInWindow, from: nil)
            c.previewGuide = (horizontal, vp)
            if ev.type == .leftMouseUp { break }
        }
        c.previewGuide = nil
        let vp = c.convert(last.locationInWindow, from: nil)
        c.addCustomGuide(horizontal: horizontal, atView: vp)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: horizontal ? .resizeUpDown : .resizeLeftRight)
    }
}

// MARK: - Einstellfenster

enum GuideDialog {
    static func show(window: NSWindow, done: @escaping () -> Void) {
        var s = GuideSettings.shared
        let a = NSAlert()
        a.messageText = "Hilfslinien"
        a.informativeText = "Objekte rasten beim Verschieben ein. ⌘ gedrückt halten schaltet das Einrasten vorübergehend aus."
        func cb(_ t: String, _ v: Bool) -> NSButton { let b = NSButton(checkboxWithTitle: t, target: nil, action: nil); b.state = v ? .on : .off; return b }
        let cPage = cb("Seitenränder und Randlinien", s.snapPage), cCenter = cb("Seitenmitte", s.snapCenter), cObj = cb("Eigene Objekte", s.snapObjects)
        let cText = cb("Text im PDF: Kanten, Grundlinie, Zeilenabstand", s.snapText), cCont = cb("Bilder und Linien im PDF", s.snapContent)
        let cCustom = cb("Eigene Hilfslinien", s.snapCustom), cGridSnap = cb("Raster", s.snapGrid)
        let cRulers = cb("Lineale anzeigen (Hilfslinien aus dem Lineal ziehen)", s.showRulers), cGrid = cb("Raster anzeigen", s.showGrid), cShowCustom = cb("Eigene Hilfslinien anzeigen", s.showCustom)
        func field(_ v: CGFloat) -> NSTextField { let f = NSTextField(string: String(format: "%g", v)); f.widthAnchor.constraint(equalToConstant: 60).isActive = true; return f }
        let tol = field(s.tolerance), margin = field(s.marginMM), grid = field(s.gridMM)
        func lbl(_ t: String) -> NSTextField { NSTextField(labelWithString: t) }
        let head1 = lbl("Einrasten an:"); head1.font = .boldSystemFont(ofSize: 12)
        let head2 = lbl("Anzeige:"); head2.font = .boldSystemFont(ofSize: 12)
        let row1 = NSStackView(views: [lbl("Fangbereich (Punkte):"), tol, lbl("   Randlinien (mm):"), margin, lbl("   Raster (mm):"), grid])
        let v = NSStackView(views: [head1, cPage, cCenter, cObj, cText, cCont, cCustom, cGridSnap, head2, cRulers, cGrid, cShowCustom, row1])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 6
        v.frame = NSRect(x: 0, y: 0, width: 440, height: 330)
        a.accessoryView = v
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Abbrechen")
        a.beginSheetModal(for: window) { r in
            guard r == .alertFirstButtonReturn else { return }
            s.snapPage = cPage.state == .on; s.snapCenter = cCenter.state == .on; s.snapObjects = cObj.state == .on
            s.snapText = cText.state == .on; s.snapContent = cCont.state == .on; s.snapCustom = cCustom.state == .on; s.snapGrid = cGridSnap.state == .on
            s.showRulers = cRulers.state == .on; s.showGrid = cGrid.state == .on; s.showCustom = cShowCustom.state == .on
            s.tolerance = CGFloat(Double(tol.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 5)
            s.marginMM = CGFloat(Double(margin.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 20)
            s.gridMM = max(1, CGFloat(Double(grid.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 10))
            GuideSettings.shared = s
            done()
        }
    }
}
