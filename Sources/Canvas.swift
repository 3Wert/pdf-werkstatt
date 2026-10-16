import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Modus-Werkzeuge. Formen, Text und Notizen werden wie in der Vorschau direkt eingesetzt.
enum Tool: Int, CaseIterable {
    case textSelect, rectSelect, draw, sketch, redact, editText, whiteout, crop

    var title: String {
        switch self {
        case .textSelect: return "Textauswahl"
        case .rectSelect: return "Bereich auswählen"
        case .crop: return "Zuschneiden"
        case .draw: return "Zeichnen"
        case .sketch: return "Skizzieren (Formen werden erkannt)"
        case .redact: return "Schwärzen"
        case .editText: return "Vorhandenen Text bearbeiten"
        case .whiteout: return "Abdecken"
        }
    }
    var symbol: String {
        switch self {
        case .textSelect: return "character.cursor.ibeam"
        case .rectSelect: return "rectangle.dashed"
        case .crop: return "crop"
        case .draw: return "pencil.tip"
        case .sketch: return "scribble.variable"
        case .redact: return "rectangle.inset.filled"
        case .editText: return "character.textbox"
        case .whiteout: return "eraser"
        }
    }
}

/// Hervorheben-Modus (Knopf „Hervorheben“ wie in der Vorschau)
struct HighlightStyle: Equatable {
    var type: PDFAnnotationSubtype
    var color: NSColor
    static let colors: [(String, NSColor)] = [
        ("Gelb", NSColor(srgbRed: 1, green: 0.87, blue: 0.2, alpha: 1)),
        ("Grün", NSColor(srgbRed: 0.55, green: 0.88, blue: 0.4, alpha: 1)),
        ("Blau", NSColor(srgbRed: 0.45, green: 0.72, blue: 1, alpha: 1)),
        ("Rosa", NSColor(srgbRed: 1, green: 0.55, blue: 0.75, alpha: 1)),
        ("Violett", NSColor(srgbRed: 0.75, green: 0.6, blue: 1, alpha: 1)),
    ]
}

final class Overlay: NSView {
    weak var canvas: Canvas?
    override var isFlipped: Bool { superview?.isFlipped ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { canvas?.drawOverlay() }
}

private struct Clip: Codable { var model: ObjModel; var bounds: CGRect }

final class Canvas: PDFView, NSTextViewDelegate {
    weak var wdoc: WDocument?
    var onSelectionChange: ((PDFAnnotation?) -> Void)?
    var onToolChange: ((Tool) -> Void)?
    var onPageContentChange: ((PDFPage) -> Void)?
    var onSearch: ((Int, Int) -> Void)?

    var tool: Tool = .textSelect {
        didSet {
            endEditing()
            if tool != .rectSelect && tool != .crop { marquee = nil }
            if tool != .editText && tool != .rectSelect { contentSel = nil }
            updateCropBar()
            prewarmContent()
            onToolChange?(tool)
            applyToolToExistingSelection()
        }
    }
    var highlight: HighlightStyle? {
        didSet { onToolChange?(tool); if highlight != nil { applyToolToExistingSelection() } }
    }
    var lastHighlight = HighlightStyle(type: .highlight, color: HighlightStyle.colors[0].1)
    private(set) var marquee: (PDFPage, CGRect)? { didSet { overlay.needsDisplay = true; updateCropBar() } }
    let cropBar = CropBar(frame: .zero)
    /// Mehrfachauswahl: erstes Objekt ist das „Hauptobjekt“ (Inspektor, Griffe)
    private(set) var selectedObjects: [PDFAnnotation] = [] {
        didSet { overlay.needsDisplay = true; onSelectionChange?(selected) }
    }
    var selected: PDFAnnotation? { selectedObjects.first }
    var isMulti: Bool { selectedObjects.count > 1 }
    private var objectMarquee: CGRect? { didSet { overlay.needsDisplay = true } }
    var loupe = false { didSet { overlay.needsDisplay = true; if loupe { window?.makeFirstResponder(self) } } }

    // MARK: Direkter Eingriff in den Seiteninhalt

    /// Ausgewählte Inhaltselemente einer Seite (Textstücke, Pfade, Bilder)
    struct ContentSelection {
        var pageIndex: Int
        var model: PageContentModel
        var indices: [Int]
        var element: ContentElement { model.elements[indices[0]] }
        var bounds: CGRect { indices.reduce(CGRect.null) { $0.union(model.elements[$1].bounds) } }
        /// nur Elemente mit gültiger Größe (nicht vermessene oder neben die Seite verschobene fallen raus)
        static func valid(_ ks: [Int], in m: PageContentModel) -> [Int] {
            ks.filter { $0 >= 0 && $0 < m.elements.count && m.elements[$0].bounds.isUsable }
        }
        var canMove: Bool { indices.allSatisfy { model.elements[$0].canMove } }
    }
    private(set) var contentSel: ContentSelection? { didSet { overlay.needsDisplay = true; onSelectionChange?(selected) } }
    private var contentDragOffset: CGVector = .zero
    private var contentUnsupportedShown = false
    /// Inhaltsmodelle je Seite – bleiben gültig, solange sich der Seiteninhalt nicht ändert (Prüfsumme)
    private var contentCache: [Int: PageContentModel] = [:]
    private var prewarming = Set<Int>()

    func clearContentSelection() { contentSel = nil }

    private func contentUnsupported() {
        guard !contentUnsupportedShown, let w = window else { return }
        contentUnsupportedShown = true
        let a = NSAlert()
        a.messageText = "Direktes Bearbeiten für diese Datei nicht möglich"
        a.informativeText = "Der Seiteninhalt lässt sich nicht lesen (z. B. verschlüsselt oder ungewöhnlich kodiert). Text wird stattdessen abgedeckt und neu gesetzt."
        a.beginSheetModal(for: w)
    }

    /// Inhaltsmodell einer Seite – aus dem Zwischenspeicher, wenn der Inhalt unverändert ist
    func contentModel(for page: PDFPage) -> PageContentModel? {
        guard let d = document, let data = wdoc?.currentData() else { return nil }
        let idx = d.index(for: page)
        let t0 = Date()
        guard let f = try? PDFFile(data: data), let m = PageContentModel.load(file: f, pageIndex: idx, reuse: contentCache[idx]) else { contentUnsupported(); return nil }
        if contentCache[idx] !== m { Log.v("Seite \(idx + 1) vermessen: \(m.elements.count) Elemente, \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        contentCache[idx] = m
        return m
    }

    /// Aktuelle Seite schon im Hintergrund vermessen, damit der erste Klick sofort reagiert
    func prewarmContent() {
        guard tool == .editText || tool == .rectSelect, let d = document, let page = currentPage, let data = wdoc?.currentData() else { return }
        let idx = d.index(for: page)
        guard !prewarming.contains(idx) else { return }
        prewarming.insert(idx)
        let reuse = contentCache[idx]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let m = (try? PDFFile(data: data)).flatMap { PageContentModel.load(file: $0, pageIndex: idx, reuse: reuse) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.prewarming.remove(idx)
                if let m { self.contentCache[idx] = m }
            }
        }
    }

    private func applyContent(_ m: PageContentModel, _ edits: [ContentStream.Edit], action: String) -> Bool {
        guard let fresh = wdoc?.currentData(), let out = m.apply(edits, to: fresh) else {
            NSSound.beep(); Log.w("Inhalt ändern fehlgeschlagen (\(action))"); return false
        }
        wdoc?.replaceData(out, old: fresh, action: action)
        return true
    }

    func selectContent(at pp: CGPoint, on page: PDFPage) -> Bool {
        guard let m = contentModel(for: page), let k = m.element(at: pp), let d = document else { contentSel = nil; return false }
        select(nil)
        contentSel = ContentSelection(pageIndex: d.index(for: page), model: m, indices: [k])
        return true
    }

    /// Bereich bearbeiten: alle Inhaltselemente und eigenen Objekte im Rahmen auswählen
    func selectContent(in r: CGRect, on page: PDFPage) {
        guard let d = document else { return }
        let objs = objects(in: convert(r, from: page)).filter { $0.page === page }
        if let m = contentModel(for: page) {
            let ks = m.elements(in: r, share: 0.5)
            let v = ContentSelection.valid(ks, in: m)
            contentSel = v.isEmpty ? nil : ContentSelection(pageIndex: d.index(for: page), model: m, indices: v)
        }
        select(all: objs)
    }

    func removeContentSelection() {
        let objs = selectedObjects
        guard contentSel != nil || !objs.isEmpty else { return }
        let cs = contentSel
        um?.beginUndoGrouping()
        for a in objs { if let p = a.page { remove(a, from: p) } }
        contentSel = nil
        if let cs { _ = applyContent(cs.model, cs.indices.map { .remove($0) }, action: "Inhalt löschen") }
        um?.safeActionName("Inhalt löschen")
        um?.endUndoGrouping()
        if tool == .rectSelect { marquee = nil }
    }

    /// Verschiebt ausgewählten Inhalt und ausgewählte eigene Objekte gemeinsam (Seitenkoordinaten)
    func moveContentSelection(dx: CGFloat, dy: CGFloat) {
        let cs = contentSel
        if let cs, !cs.canMove { NSSound.beep(); return }
        let ids = selectedObjects.map { ident($0) }
        let objPage = selectedObjects.first?.page.flatMap { document?.index(for: $0) } ?? 0
        um?.beginUndoGrouping()
        for a in selectedObjects where canMove(a) { setBounds(a, a.bounds.offsetBy(dx: dx, dy: dy), action: "Bewegen") }
        contentSel = nil
        var ok = true
        if let cs { ok = applyContent(cs.model, cs.indices.map { .move($0, dx, dy) }, action: "Inhalt verschieben") }
        um?.safeActionName("Inhalt verschieben")
        um?.endUndoGrouping()
        if let (p, r) = marquee { marquee = (locatePage(p, index: cs?.pageIndex ?? objPage) ?? p, r.offsetBy(dx: dx, dy: dy)) }
        // Auswahl auf dem neuen Stand wiederherstellen
        guard let d = document else { return }
        if let cs, ok, let p = d.page(at: cs.pageIndex), let m = contentModel(for: p) {
            let ks = m.elements.count == cs.model.elements.count ? cs.indices
                : cs.indices.compactMap { k in let b = cs.model.elements[k].bounds.offsetBy(dx: dx, dy: dy); return m.element(at: CGPoint(x: b.midX, y: b.midY)) }
            let v = ContentSelection.valid(ks, in: m)
            contentSel = v.isEmpty ? nil : ContentSelection(pageIndex: cs.pageIndex, model: m, indices: v)
        }
        let objs = ids.compactMap { id -> PDFAnnotation? in
            for i in 0..<d.pageCount { if let f = d.page(at: i)?.annotations.first(where: { ident($0) == id }) { return f } }
            return nil
        }
        select(all: objs)
    }

    /// Entfernt Text-Inhalt, der überwiegend in den Rechtecken liegt. Gruppen werden bei Bedarf vorher aufgelöst.
    private func removeTextContent(in rects: [CGRect], on page: PDFPage) -> Bool {
        guard let d = document else { return false }
        let idx = d.index(for: page)
        guard var m = contentModel(for: page) else { return false }
        var ks = Set<Int>()
        for r in rects { for k in m.elements(in: r.insetBy(dx: -1, dy: -1)) where m.elements[k].kind == .text { ks.insert(k) } }
        if ks.isEmpty {
            let union = rects.reduce(CGRect.null) { $0.union($1) }
            let forms = m.elements.indices.filter { m.elements[$0].kind == .form && m.elements[$0].bounds.intersects(union) }
            guard !forms.isEmpty, applyContent(m, forms.map { .dissolve($0) }, action: "Gruppe auflösen"),
                  let np = document?.page(at: idx), let nm = contentModel(for: np) else { return false }
            m = nm
            for r in rects { for k in m.elements(in: r.insetBy(dx: -1, dy: -1)) where m.elements[k].kind == .text { ks.insert(k) } }
        }
        guard !ks.isEmpty else { return false }
        return applyContent(m, ks.map { .remove($0) }, action: "Text bearbeiten")
    }

    /// Vor dem Versenden: Inhalt unter Abdeckungen/Schwärzungen wirklich entfernen.
    /// Liefert (entfernt, nur teilweise abgedeckt).
    func removeContentUnderCovers() -> (Int, Int) {
        guard let d = document else { return (0, 0) }
        let covers = SendCheck.covers(d)
        var removed = 0, partial = 0
        um?.beginUndoGrouping()
        for pageIdx in Set(covers.map { $0.0 }).sorted() {
            guard let page = document?.page(at: pageIdx), let m = contentModel(for: page) else { continue }
            let rects = covers.filter { $0.0 == pageIdx }.map { $0.1.insetBy(dx: -0.5, dy: -0.5) }
            var ks: [Int] = []
            for k in m.elements.indices {
                let c = rects.map { m.coverage(k, by: $0) }.max() ?? 0
                if c >= 0.6 { ks.append(k) } else if c > 0.05 { partial += 1 }
            }
            if !ks.isEmpty, applyContent(m, ks.map { .remove($0) }, action: "Inhalt unter Abdeckung entfernen") { removed += ks.count }
        }
        um?.safeActionName("Inhalt unter Abdeckung entfernen")
        um?.endUndoGrouping()
        return (removed, partial)
    }
    private var loupePoint: CGPoint?

    let overlay = Overlay()
    private var editor: NSTextView?
    private var editObj: WObject?
    private var editStart: (ObjModel, CGRect, Bool)?
    private let editorUndo = UndoManager()

    private enum DragMode { case move, resize(Int), endpoint(Int), create, ink, marquee, selectRect, marqueeResize(Int), contentMove, guide(Bool, Int) }
    private struct DragState {
        var mode: DragMode
        var page: PDFPage
        var startView: CGPoint
        var startRect: CGRect
        var startBounds: CGRect
        var startModel: ObjModel?
        var obj: PDFAnnotation?
        var inkPoints: [CGPoint] = []
        var moved = false
        var editOnRelease: CGPoint?
        var others: [(PDFAnnotation, CGRect, ObjModel?)] = []   // weitere ausgewählte Objekte beim Verschieben
    }
    private var drag: DragState?
    private var clickPoint: (PDFPage, CGPoint, CGPoint)?
    /// Fanglinien, die während des Ziehens angezeigt werden (Ansichtskoordinaten)
    struct ShownGuide { var a: CGPoint; var b: CGPoint; var label: String }
    private var guides: [ShownGuide] = []
    private var snapCache: [Int: SnapSources] = [:]
    private var snapSettingsStamp = 0
    var customGuides: [Int: GuideStore.PageGuides] = [:] { didSet { overlay.needsDisplay = true; if let d = wdoc { GuideStore.save(d, customGuides) } } }
    var previewGuide: (Bool, CGPoint)? { didSet { overlay.needsDisplay = true } }
    var onViewChanged: (() -> Void)?
    private var lastCoalesce: (ObjectIdentifier, String, Date)?
    private var pasteOffset: CGFloat = 0
    private var tracking: NSTrackingArea?

    static let objType = NSPasteboard.PasteboardType("de.marlonelsner.pdf-werkstatt.objekt")

    var um: UndoManager? { wdoc?.undoManager }
    override var undoManager: UndoManager? { wdoc?.undoManager }
    private var keyMonitor: Any?

    // Widerrufen/Wiederholen direkt hier, damit PDFKits eigene Verwaltung nicht dazwischenfunkt
    @objc func undo(_ sender: Any?) {
        endEditing()
        guard let u = um, u.canUndo else { NSSound.beep(); return }
        u.undo()
        afterUndo()
    }
    @objc func redo(_ sender: Any?) {
        endEditing()
        guard let u = um, u.canRedo else { NSSound.beep(); return }
        u.redo()
        afterUndo()
    }
    private func afterUndo() {
        let alive = selectedObjects.filter { a in a.page?.annotations.contains { $0 === a } ?? false }
        if alive.count != selectedObjects.count { selectedObjects = alive }
        onSelectionChange?(selected)
        overlay.needsDisplay = true
        if let d = document { for i in 0..<d.pageCount { if let p = d.page(at: i) { annotationsChanged(on: p) } } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        overlay.canvas = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        cropBar.isHidden = true
        cropBar.onCrop = { [weak self] in self?.cropToSelection(nil) }
        cropBar.onCropAll = { [weak self] in self?.cropAllPages(nil) }
        cropBar.onCancel = { [weak self] in self?.marquee = nil }
        addSubview(cropBar)
        autoScales = true
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidChange), name: .PDFViewPageChanged, object: self)
    }
    required init?(coder: NSCoder) { nil }

    override var document: PDFDocument? {
        didSet { bringOverlayToFront(); observeScrolling() }
    }

    private func bringOverlayToFront() {
        overlay.removeFromSuperview()
        overlay.frame = bounds
        addSubview(overlay)
        cropBar.removeFromSuperview()
        addSubview(cropBar)
    }

    private var observedClip: NSClipView?
    private func observeScrolling() {
        guard let sv = subviews.compactMap({ $0 as? NSScrollView }).first ?? documentView?.enclosingScrollView else { return }
        let clip = sv.contentView
        guard clip !== observedClip else { return }
        if let old = observedClip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old) }
        observedClip = clip
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w, w.isKeyWindow, w.attachedSheet == nil else { return e }
                let fr = w.firstResponder
                if fr is NSText { return e }                       // Text wird gerade getippt
                let mine = fr === w || fr == nil || ((fr as? NSView)?.isDescendant(of: self) ?? false)
                guard mine else { return e }
                if e.modifierFlags.intersection([.command, .control, .option]).isEmpty, self.handleKey(e) { return nil }
                return e
            }
        }
        bringOverlayToFront(); observeScrolling()
    }

    @objc private func pageDidChange() { prewarmContent(); onViewChanged?() }

    @objc private func scrolled() { positionEditor(); positionCropBar(); overlay.needsDisplay = true; onViewChanged?() }
    @objc private func scaleChanged() { styleEditor(); positionCropBar(); overlay.needsDisplay = true; onViewChanged?() }

    // MARK: Zuschneiden

    private func updateCropBar() {
        guard tool == .crop, let (_, r) = marquee, r.width > 2, r.height > 2, drag == nil else { cropBar.isHidden = true; return }
        cropBar.setSize(r.size)
        cropBar.isHidden = false
        positionCropBar()
    }

    private func positionCropBar() {
        guard !cropBar.isHidden, let (page, r) = marquee else { return }
        let vr = convert(r, from: page)
        let size = cropBar.fittingSize
        var x = vr.maxX - size.width
        var y = isFlipped ? vr.maxY + 8 : vr.minY - size.height - 8
        x = max(8, min(x, bounds.width - size.width - 8))
        if isFlipped { if y + size.height > bounds.height - 8 { y = vr.minY - size.height - 8 } }
        else if y < 8 { y = vr.maxY + 8 }
        y = max(8, min(y, bounds.height - size.height - 8))
        cropBar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Griffe des Zuschneide-Rahmens (Ecken und Kanten) in Ansichtskoordinaten
    private func marqueeHandle(at vp: CGPoint) -> Int? {
        guard tool == .crop, let (page, r) = marquee else { return nil }
        let v = convert(r, from: page)
        let xs = [v.minX, v.midX, v.maxX], ys = [v.minY, v.midY, v.maxY]
        let pts: [(Int, CGPoint)] = [(0, CGPoint(x: xs[0], y: ys[0])), (1, CGPoint(x: xs[1], y: ys[0])), (2, CGPoint(x: xs[2], y: ys[0])),
                                     (3, CGPoint(x: xs[2], y: ys[1])), (4, CGPoint(x: xs[2], y: ys[2])), (5, CGPoint(x: xs[1], y: ys[2])),
                                     (6, CGPoint(x: xs[0], y: ys[2])), (7, CGPoint(x: xs[0], y: ys[1]))]
        return pts.first { abs($0.1.x - vp.x) <= 7 && abs($0.1.y - vp.y) <= 7 }?.0
    }

    @objc func cropAllPages(_ sender: Any?) {
        guard let (page, r) = marquee, let d = document else { NSSound.beep(); return }
        um?.beginUndoGrouping()
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            let rr = r.intersection(p.bounds(for: .mediaBox))
            if rr.width > 1 && rr.height > 1 { setCrop(p, rr) }
        }
        um?.safeActionName("Alle Seiten zuschneiden")
        um?.endUndoGrouping()
        _ = page
        marquee = nil
        tool = .textSelect
    }

    /// Zuschnitt aufheben: Seite wieder in voller Größe
    func removeCrop(_ pages: [PDFPage]) {
        um?.beginUndoGrouping()
        for p in pages { setCrop(p, p.bounds(for: .mediaBox)) }
        um?.safeActionName("Zuschnitt aufheben")
        um?.endUndoGrouping()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    // MARK: Auswahl

    func select(_ a: PDFAnnotation?) {
        let n: [PDFAnnotation] = a.map { [$0] } ?? []
        if !same(n) { selectedObjects = n }
    }
    func select(all: [PDFAnnotation]) { if !same(all) { selectedObjects = all } }
    func toggleSelect(_ a: PDFAnnotation) {
        if selectedObjects.contains(where: { $0 === a }) { selectedObjects.removeAll { $0 === a } } else { selectedObjects.append(a) }
    }
    func isSelected(_ a: PDFAnnotation) -> Bool { selectedObjects.contains { $0 === a } }
    private func same(_ n: [PDFAnnotation]) -> Bool {
        n.count == selectedObjects.count && zip(n, selectedObjects).allSatisfy { $0 === $1 }
    }
    /// Alle ausgewählten eigenen Objekte
    var selectedWObjects: [WObject] { selectedObjects.compactMap { $0 as? WObject } }

    private var selRect: CGRect? {
        guard let a = selected, let p = a.page else { return nil }
        return convert(a.bounds, from: p)
    }

    private func isEditableNative(_ a: PDFAnnotation) -> Bool {
        ["Square", "Circle", "Line", "Ink", "FreeText", "Highlight", "Underline", "StrikeOut", "Squiggly", "Stamp"].contains(a.type ?? "")
    }

    private func canResize(_ a: PDFAnnotation) -> Bool {
        if let w = a as? WObject { return w.model.kind != .pageNumber }
        return ["Square", "Circle", "FreeText", "Stamp"].contains(a.type ?? "")
    }

    private func canMove(_ a: PDFAnnotation) -> Bool {
        if a is WObject { return true }
        return !["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(a.type ?? "")
    }

    func objectAt(_ vp: CGPoint, includeMarkup: Bool = true) -> (PDFAnnotation, PDFPage)? {
        guard let page = page(for: vp, nearest: false) else { return nil }
        let markup = ["Highlight", "Underline", "StrikeOut", "Squiggly"]
        let pp = convert(vp, to: page)
        let tol = 4 / max(scaleFactor, 0.1)
        for a in page.annotations.reversed() {
            if let w = a as? WObject {
                if w.hit(pp, tolerance: tol) { return (a, page) }
                continue
            }
            guard isEditableNative(a), a.shouldDisplay else { continue }
            if !includeMarkup, markup.contains(a.type ?? "") { continue }
            if a.bounds.insetBy(dx: -tol, dy: -tol).contains(pp) { return (a, page) }
        }
        return nil
    }

    private func handlePoints() -> [(Int, CGPoint)] {
        guard editor == nil, !isMulti, let a = selected, let r = selRect, let p = a.page else { return [] }
        if let w = a as? WObject, w.model.isLine {
            return (w.absoluteStrokes.first ?? []).enumerated().map { ($0.offset + 100, convert($0.element, from: p)) }
        }
        guard canResize(a) else { return [] }
        let xs = [r.minX, r.midX, r.maxX], ys = [r.minY, r.midY, r.maxY]
        let all: [(Int, CGPoint)] = [(0, CGPoint(x: xs[0], y: ys[0])), (1, CGPoint(x: xs[1], y: ys[0])), (2, CGPoint(x: xs[2], y: ys[0])),
                                     (3, CGPoint(x: xs[2], y: ys[1])), (4, CGPoint(x: xs[2], y: ys[2])), (5, CGPoint(x: xs[1], y: ys[2])),
                                     (6, CGPoint(x: xs[0], y: ys[2])), (7, CGPoint(x: xs[0], y: ys[1]))]
        if let w = a as? WObject, w.model.kind == .text { return all.filter { $0.0 == 3 || $0.0 == 7 } }
        return all
    }

    private func handleAt(_ vp: CGPoint) -> Int? {
        handlePoints().first { abs($0.1.x - vp.x) <= 6 && abs($0.1.y - vp.y) <= 6 }?.0
    }

    // MARK: Änderungen mit Widerrufen

    static let idKey = PDFAnnotationKey(rawValue: "/PDFWerkstattID")

    func ident(_ a: PDFAnnotation) -> String {
        if let w = a as? WObject { return w.model.id }
        if let s = a.value(forAnnotationKey: Canvas.idKey) as? String { return s }
        let s = UUID().uuidString
        a.setValue(s as NSString, forAnnotationKey: Canvas.idKey)
        return s
    }

    /// Objekt im *aktuellen* Dokument wiederfinden (nach Inhalts-Eingriffen sind alle Instanzen neu)
    func locate(_ a: PDFAnnotation, pageIndex: Int) -> (PDFAnnotation, PDFPage)? {
        guard let d = document else { return nil }
        if let p = a.page, p.document === d, p.annotations.contains(where: { $0 === a }) { return (a, p) }
        let id = ident(a)
        if let p = d.page(at: pageIndex), let f = p.annotations.first(where: { ($0 as? WObject)?.model.id == id || ($0.value(forAnnotationKey: Canvas.idKey) as? String) == id }) { return (f, p) }
        for i in 0..<d.pageCount {
            if let p = d.page(at: i), let f = p.annotations.first(where: { ($0 as? WObject)?.model.id == id || ($0.value(forAnnotationKey: Canvas.idKey) as? String) == id }) { return (f, p) }
        }
        return nil
    }

    func locatePage(_ p: PDFPage, index: Int) -> PDFPage? {
        guard let d = document else { return nil }
        if p.document === d { return p }
        return d.page(at: min(index, d.pageCount - 1))
    }

    /// Alle internen Ansichten komplett neu zeichnen (nach dem Entfernen von Objekten nötig).
    func forceRedraw() {
        func mark(_ v: NSView) {
            v.needsDisplay = true
            v.layer?.setNeedsDisplay()
            v.layer?.sublayers?.forEach { $0.setNeedsDisplay() }
            v.subviews.forEach(mark)
        }
        mark(self)
    }

    /// Zwingt die internen Seitenansichten von PDFKit, einen Bereich neu zu zeichnen.
    func redraw(_ rectInView: CGRect) {
        setNeedsDisplay(rectInView)
        func mark(_ v: NSView) {
            let r = v.convert(rectInView, from: self)
            if r.intersects(v.bounds) { v.setNeedsDisplay(r) }
            v.subviews.forEach(mark)
        }
        subviews.forEach(mark)
    }

    func refresh(_ a: PDFAnnotation?) {
        wdoc?.touch()
        snapCache.removeAll()
        overlay.needsDisplay = true
        guard let a, let p = a.page else { return }
        annotationsChanged(on: p)
        overlay.needsDisplay = true
        onPageContentChange?(p)
    }

    func add(_ a: PDFAnnotation, to p: PDFPage, action: String? = nil) {
        a.shouldDisplay = true
        Log.v("add \(action ?? "") \((a as? WObject)?.model.kind.rawValue ?? (a.type ?? "?")) pageDoc=\(p.document === document) idx=\(document?.index(for: p) ?? -1)")
        _ = ident(a)
        p.addAnnotation(a)
        refresh(a)
        redraw(convert(a.bounds.insetBy(dx: -12, dy: -12), from: p))
        let idx = document?.index(for: p) ?? 0
        um?.registerUndo(withTarget: self) { c in if let (x, px) = c.locate(a, pageIndex: idx) { c.remove(x, from: px) } }
        if let action { um?.safeActionName(action) }
    }

    func remove(_ a: PDFAnnotation, from p: PDFPage, action: String? = nil) {
        Log.v("remove \(action ?? "") vorher: [\(Log.describe(p))]")
        defer { Log.v("remove nachher: [\(Log.describe(p))] docIndex=\(document?.index(for: p) ?? -1) pageDoc=\(p.document === document)") }
        if isSelected(a) { selectedObjects.removeAll { $0 === a } }
        if editObj === a { endEditing() }
        // Bereich merken, bevor das Objekt weg ist – danach kennt PDFKit die Stelle nicht mehr
        wdoc?.touch()
        let dirty = convert(a.bounds.insetBy(dx: -12, dy: -12), from: p)
        // 1. erst unsichtbar machen – so bekommt PDFKit die Änderung noch mit, solange das Objekt existiert
        a.shouldDisplay = false
        annotationsChanged(on: p)
        // 2. dann entfernen
        p.removeAnnotation(a)
        annotationsChanged(on: p)
        // 3. Anmerkungsdarstellung der Seite einmal aus- und einschalten, Seitenansichten neu zeichnen
        p.displaysAnnotations = false
        p.displaysAnnotations = true
        forceRedraw()
        redraw(dirty)
        overlay.needsDisplay = true
        onPageContentChange?(p)
        let idx = document?.index(for: p) ?? 0
        um?.registerUndo(withTarget: self) { c in if let px = c.locatePage(p, index: idx) { c.add(a, to: px) } }
        if let action { um?.safeActionName(action) }
    }

    func setBounds(_ a: PDFAnnotation, _ b: CGRect, action: String? = nil) {
        let old = a.bounds
        a.bounds = b
        refresh(a)
        let idx = a.page.flatMap { document?.index(for: $0) } ?? 0
        um?.registerUndo(withTarget: self) { c in if let (x, _) = c.locate(a, pageIndex: idx) { c.setBounds(x, old, action: action) } }
        if let action { um?.safeActionName(action) }
        if a === selected { onSelectionChange?(a) }
    }

    func setModel(_ w: WObject, _ m: ObjModel, bounds b: CGRect? = nil, action: String? = nil, coalesce: String? = nil) {
        let oldM = w.model, oldB = w.bounds
        w.model = m
        if let b { w.bounds = b } else { w.fitBounds() }
        refresh(w)
        if w === selected { onSelectionChange?(w) }
        if let key = coalesce, let last = lastCoalesce, last.0 == ObjectIdentifier(w), last.1 == key, Date().timeIntervalSince(last.2) < 1.5 {
            lastCoalesce = (ObjectIdentifier(w), key, Date())
            return
        }
        lastCoalesce = coalesce.map { (ObjectIdentifier(w), $0, Date()) }
        let idx = w.page.flatMap { document?.index(for: $0) } ?? 0
        um?.registerUndo(withTarget: self) { c in if let (x, _) = c.locate(w, pageIndex: idx), let xw = x as? WObject { c.setModel(xw, oldM, bounds: oldB, action: action) } }
        if let action { um?.safeActionName(action) }
    }

    func setColor(_ a: PDFAnnotation, _ c: NSColor) {
        let old = a.color
        a.color = c
        refresh(a)
        let idx = a.page.flatMap { document?.index(for: $0) } ?? 0
        um?.registerUndo(withTarget: self) { cv in if let (x, _) = cv.locate(a, pageIndex: idx) { cv.setColor(x, old) } }
        um?.safeActionName("Farbe")
    }

    func setOrder(_ order: [PDFAnnotation], on p: PDFPage) {
        let old = p.annotations.filter { $0.type != "Widget" }
        wdoc?.touch()
        old.forEach { p.removeAnnotation($0) }
        order.forEach { p.addAnnotation($0) }
        annotationsChanged(on: p)
        forceRedraw()
        onPageContentChange?(p)
        overlay.needsDisplay = true
        let idx = document?.index(for: p) ?? 0
        um?.registerUndo(withTarget: self) { c in
            guard let px = c.locatePage(p, index: idx) else { return }
            c.setOrder(old.compactMap { c.locate($0, pageIndex: idx)?.0 }, on: px)
        }
        um?.safeActionName("Anordnen")
    }

    @objc func bringToFront(_ sender: Any?) {
        guard let p = selected?.page else { return }
        let sel = selectedObjects.filter { $0.page === p }
        let o = p.annotations.filter { a in a.type != "Widget" && !sel.contains(where: { $0 === a }) } + sel
        setOrder(o, on: p)
    }

    @objc func sendToBack(_ sender: Any?) {
        guard let p = selected?.page else { return }
        let sel = selectedObjects.filter { $0.page === p }
        let o = sel + p.annotations.filter { a in a.type != "Widget" && !sel.contains(where: { $0 === a }) }
        setOrder(o, on: p)
    }

    /// Eine Ebene nach vorne (+1) oder hinten (−1): ausgewählte Objekte tauschen mit dem nächsten Nachbarn
    private func step(_ dir: Int) {
        guard let p = selected?.page else { return }
        var o = p.annotations.filter { $0.type != "Widget" }
        let idx = o.indices.filter { i in selectedObjects.contains { $0 === o[i] } }
        guard !idx.isEmpty else { return }
        if dir > 0 {
            for i in idx.reversed() where i + 1 < o.count && !idx.contains(i + 1) { o.swapAt(i, i + 1) }
        } else {
            for i in idx where i > 0 && !idx.contains(i - 1) { o.swapAt(i, i - 1) }
        }
        setOrder(o, on: p)
    }

    @objc func bringForward(_ sender: Any?) { step(1) }
    @objc func sendBackward(_ sender: Any?) { step(-1) }

    /// Reihenfolge-Info für die Anzeige: Position des Hauptobjekts von hinten (1) bis vorne (n)
    var layerInfo: (Int, Int)? {
        guard let a = selected, let p = a.page else { return nil }
        let o = p.annotations.filter { $0.type != "Widget" && ($0 is WObject || isEditableNative($0)) }
        guard let i = o.firstIndex(where: { $0 === a }) else { return nil }
        return (i + 1, o.count)
    }

    // MARK: Maus

    private func viewPoint(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        handleMouseDown(e)
        if drag != nil { trackDrag() }
    }

    /// Eigene Mausschleife: PDFKit schickt Ziehen/Loslassen sonst an interne Ansichten.
    private func trackDrag() {
        guard let w = window else { return }
        while drag != nil {
            guard let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if ev.type == .leftMouseUp { mouseUp(with: ev); break }
            mouseDragged(with: ev)
            autoscroll(with: ev)
        }
    }

    private func handleMouseDown(_ e: NSEvent) {
        if let pg = page(for: viewPoint(e), nearest: false) {
            Log.v("mouseDown tool=\(tool) hit=\(String(describing: objectAt(viewPoint(e)).map { ($0.0 as? WObject)?.model.kind.rawValue ?? $0.0.type ?? "?" })) page=[\(Log.describe(pg))]")
        }
        if let tv = editor, tv.frame.contains(viewPoint(e)) {
            window?.makeFirstResponder(tv)
            tv.mouseDown(with: e)
            return
        }
        if editor != nil {
            let finished = editObj
            endEditing()
            // Klick neben das Textfeld beendet nur das Tippen
            if tool == .textSelect {
                if let f = finished, f.page != nil { select(f) }
                return
            }
        }
        window?.makeFirstResponder(self)
        let vp = viewPoint(e)

        // Griffe des ausgewählten Objekts funktionieren mit jedem Werkzeug
        if let h = handleAt(vp), let a = selected, let p = a.page, let r = selRect {
            drag = DragState(mode: h >= 100 ? .endpoint(h - 100) : .resize(h), page: p, startView: vp, startRect: r,
                             startBounds: a.bounds, startModel: (a as? WObject)?.model, obj: a)
            return
        }
        guard let page = page(for: vp, nearest: true) else { super.mouseDown(with: e); return }
        let pp = convert(vp, to: page)

        // Eigene Hilfslinie anfassen (verschieben; außerhalb der Seite loslassen löscht sie)
        if tool == .textSelect || tool == .editText, let (horizontal, i, gp) = customGuide(at: vp) {
            drag = DragState(mode: .guide(horizontal, i), page: gp, startView: vp, startRect: .zero, startBounds: .zero, startModel: nil, obj: nil)
            return
        }

        // Formularfelder (Widgets) bedient PDFKit selbst
        if tool == .textSelect || tool == .editText, let f = page.annotation(at: pp), f.type == "Widget" {
            select(nil)
            super.mouseDown(with: e)
            return
        }

        // Objekte sind wie in der Vorschau immer anklickbar und verschiebbar
        if tool == .textSelect || tool == .editText || tool == .rectSelect, let (a, p) = objectAt(vp, includeMarkup: tool == .rectSelect) {
            marquee = nil
            if e.modifierFlags.contains(.shift) { toggleSelect(a); return }
            let wasSelected = isSelected(a)
            if !wasSelected { select(a) }
            if !isMulti, let w = a as? WObject, w.model.kind == .text, e.clickCount == 2 || wasSelected || tool == .editText {
                startMove(w, page: p, vp: vp, editOnRelease: true); return
            }
            if canMove(a) { startMove(a, page: p, vp: vp, editOnRelease: false) }
            return
        }

        switch tool {
        case .editText:
            select(nil)
            // Doppelklick auf Text: in bearbeitbaren Text verwandeln (Original wird aus dem PDF entfernt)
            if e.clickCount >= 2, let line = page.selectionForLine(at: pp), !(line.string ?? "").trimmed.isEmpty,
               line.bounds(for: page).insetBy(dx: -2, dy: -2).contains(pp) {
                contentSel = nil
                convertToEditable(line, page: page, caretAt: vp)
                return
            }
            // Einfacher Klick: Inhaltselement auswählen, Ziehen verschiebt es
            if selectContent(at: pp, on: page), let cs = contentSel {
                drag = DragState(mode: .contentMove, page: page, startView: vp, startRect: convert(cs.bounds, from: page),
                                 startBounds: cs.bounds, startModel: nil, obj: nil)
                contentDragOffset = .zero
                return
            }
            trackTextSelection(e, page: page, pp: pp, vp: vp)

        case .textSelect:
            select(nil)
            contentSel = nil
            // Auf leerer Fläche (oder mit ⌥) wird ein Auswahlrahmen für Objekte aufgezogen, sonst Text ausgewählt
            if highlight == nil, e.modifierFlags.contains(.option) || !hasText(at: pp, on: page) {
                drag = DragState(mode: .selectRect, page: page, startView: vp, startRect: .zero, startBounds: .zero, startModel: nil, obj: nil)
                return
            }
            trackTextSelection(e, page: page, pp: pp, vp: vp)

        case .rectSelect:
            if let (mp, mr) = marquee, mp === page, mr.contains(pp), contentSel != nil || !selectedObjects.isEmpty {
                drag = DragState(mode: .contentMove, page: page, startView: vp, startRect: convert(mr, from: page), startBounds: mr, startModel: nil, obj: nil)
                contentDragOffset = .zero
                return
            }
            select(nil)
            contentSel = nil
            marquee = nil
            drag = DragState(mode: .marquee, page: page, startView: vp, startRect: .zero, startBounds: .zero, startModel: nil, obj: nil)

        case .crop:
            select(nil)
            if let h = marqueeHandle(at: vp), let (mp, mr) = marquee {
                drag = DragState(mode: .marqueeResize(h), page: mp, startView: vp, startRect: convert(mr, from: mp), startBounds: mr, startModel: nil, obj: nil)
                return
            }
            marquee = nil
            drag = DragState(mode: .marquee, page: page, startView: vp, startRect: .zero, startBounds: .zero, startModel: nil, obj: nil)

        case .redact, .whiteout:
            select(nil)
            var m = Defaults.newModel(.cover)
            m.fill = RGBA(tool == .redact ? .black : .white)
            let w = WObject(model: m, bounds: CGRect(origin: pp, size: CGSize(width: 1, height: 1)))
            page.addAnnotation(w)
            drag = DragState(mode: .create, page: page, startView: vp, startRect: .zero, startBounds: w.bounds, startModel: nil, obj: w)

        case .draw, .sketch:
            select(nil)
            drag = DragState(mode: .ink, page: page, startView: vp, startRect: .zero, startBounds: .zero, startModel: nil, obj: nil, inkPoints: [pp])
        }
    }

    // MARK: Einsetzen wie in der Vorschau (Form erscheint in der Mitte, ausgewählt)

    func insertShape(_ kind: ObjKind) {
        endEditing()
        guard let page = currentPage else { return }
        let c = visibleCenter(on: page)
        let m = Defaults.newModel(kind)
        let w: WObject
        if kind == .line || kind == .arrow {
            w = WObject(model: m, bounds: .zero)
            (w.bounds, w.model.strokes) = WObject.normalize([[CGPoint(x: c.x - 60, y: c.y), CGPoint(x: c.x + 60, y: c.y)]], margin: m.lineWidth + 4)
        } else {
            let size = kind == .star || kind == .polygon ? CGSize(width: 90, height: 90) : CGSize(width: 130, height: 80)
            w = WObject(model: m, bounds: CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height))
        }
        add(w, to: page, action: w.kindName)
        tool = .textSelect
        select(w)
        window?.makeFirstResponder(self)
    }

    func insertText(note: Bool = false) {
        endEditing()
        guard let page = currentPage else { return }
        var m = Defaults.newModel(.text)
        m.rot = PDFTools.normRotation(page.rotation)
        m.text = note ? "" : "Text"
        if note {
            m.fill = RGBA(NSColor(srgbRed: 1, green: 0.93, blue: 0.55, alpha: 1))
            m.autoWidth = false
            m.textColor = RGBA(.black)
            m.shadow = true
        }
        let c = visibleCenter(on: page)
        let w = WObject(model: m, bounds: CGRect(x: c.x - (note ? 85 : 20), y: c.y + 10, width: note ? 170 : 40, height: 20))
        w.fitBounds()
        page.addAnnotation(w)
        tool = .textSelect
        beginEditing(w, isNew: true, caretAt: nil)
        editor?.selectAll(nil)
    }

    /// Rechteckige Auswahl: Inhalt als Bild kopieren
    func copyMarquee() -> Bool {
        guard let (page, r) = marquee, let d = document else { return false }
        let snap = PDFTools.snapshot(d)
        guard let sp = snap.page(at: d.index(for: page)) else { return false }
        let old = sp.bounds(for: .cropBox)
        sp.setBounds(r, for: .cropBox)
        let img = PDFTools.render(sp, dpi: 200)
        sp.setBounds(old, for: .cropBox)
        guard let img else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: img, size: NSSize(width: r.width, height: r.height))])
        return true
    }

    /// Werkzeuge › Beschneiden
    @objc func cropToSelection(_ sender: Any?) {
        guard let (page, r) = marquee else { tool = .crop; return }   // ohne Rahmen: Werkzeug einschalten
        setCrop(page, r.intersection(page.bounds(for: .mediaBox)))
        marquee = nil
        tool = .textSelect
    }

    func setCrop(_ page: PDFPage, _ r: CGRect) {
        wdoc?.touch()
        let old = page.bounds(for: .cropBox)
        page.setBounds(r, for: .cropBox)
        um?.registerUndo(withTarget: self) { $0.setCrop(page, old) }
        um?.safeActionName("Beschneiden")
        layoutDocumentView()
        wdoc?.pagesChanged()
    }

    private func hasText(at pp: CGPoint, on page: PDFPage) -> Bool {
        guard let w = page.selectionForWord(at: pp), !(w.string ?? "").trimmed.isEmpty else { return false }
        return w.bounds(for: page).insetBy(dx: -3, dy: -3).contains(pp)
    }

    /// Ziehen = verschieben (alle ausgewählten), nur Klicken = Text bearbeiten
    private func startMove(_ a: PDFAnnotation, page p: PDFPage, vp: CGPoint, editOnRelease: Bool) {
        if !isSelected(a) { select(a) }
        let others = selectedObjects.filter { $0 !== a && canMove($0) && $0.page != nil }.map { ($0, $0.bounds, ($0 as? WObject)?.model) }
        drag = DragState(mode: .move, page: p, startView: vp, startRect: convert(a.bounds, from: p),
                         startBounds: a.bounds, startModel: (a as? WObject)?.model, obj: a,
                         editOnRelease: editOnRelease ? vp : nil, others: others)
    }

    /// Textauswahl mit eigener Mausschleife – PDFKit gibt Ziehen und Loslassen sonst nicht an uns weiter.
    private func trackTextSelection(_ e: NSEvent, page: PDFPage, pp: CGPoint, vp: CGPoint) {
        guard let w = window, let d = document else { return }
        clickPoint = (page, pp, vp)
        var sel: PDFSelection?
        if e.clickCount == 2 { sel = page.selectionForWord(at: pp) }
        else if e.clickCount >= 3 { sel = page.selectionForLine(at: pp) }
        setCurrentSelection(sel, animate: false)
        var moved = false
        while true {
            guard let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if ev.type == .leftMouseUp { break }
            let v = convert(ev.locationInWindow, from: nil)
            if !moved && hypot(v.x - vp.x, v.y - vp.y) < 3 { continue }
            moved = true
            autoscroll(with: ev)
            guard let p2 = self.page(for: v, nearest: true) else { continue }
            let pt2 = convert(v, to: p2)
            let s = p2 === page ? page.selection(from: pp, to: pt2) : d.selection(from: page, at: pp, to: p2, at: pt2)
            setCurrentSelection(s, animate: false)
        }
        if !moved, e.clickCount == 1, tool == .textSelect, highlight == nil {
            // Link öffnen, sonst nur Auswahl aufheben
            if let a = page.annotation(at: pp), a.type == "Link" {
                if let u = a.url ?? (a.action as? PDFActionURL)?.url { NSWorkspace.shared.open(u) }
                else if let dst = a.destination ?? (a.action as? PDFActionGoTo)?.destination { go(to: dst) }
            }
        }
        finishTextAction()
    }

    override func mouseDragged(with e: NSEvent) {
        guard var d = drag else { super.mouseDragged(with: e); return }
        let vp = viewPoint(e)
        let dx = vp.x - d.startView.x, dy = vp.y - d.startView.y
        if !d.moved && hypot(dx, dy) < 2 { return }
        d.moved = true
        guides = []
        let shift = e.modifierFlags.contains(.shift)
        switch d.mode {
        case .move:
            var ddx = dx, ddy = dy
            if shift { if abs(dx) > abs(dy) { ddy = 0 } else { ddx = 0 } }
            var r = d.startRect.offsetBy(dx: ddx, dy: ddy)
            if !e.modifierFlags.contains(.command) {
                var bl: CGFloat? = nil
                var inset: CGFloat = 0
                if let w = d.obj as? WObject, w.model.isText, w.model.rot == 0 { bl = d.startBounds.maxY - w.firstBaselineY; inset = pad }
                r = snap(r, page: d.page, exclude: [d.obj].compactMap { $0 } + d.others.map { $0.0 }, baselineFromTop: bl, textInset: inset)
            }
            d.obj?.bounds = convert(r, to: d.page)
            if let w = d.obj as? WObject, w.model.isText { Log.v("mouseDragged: bounds=\(w.bounds) Grundlinie \(w.firstBaselineY)") }
            let mdx = r.minX - d.startRect.minX, mdy = r.minY - d.startRect.minY
            for (o, b0, _) in d.others {
                guard let op = o.page else { continue }
                o.bounds = convert(convert(b0, from: op).offsetBy(dx: mdx, dy: mdy), to: op)
                annotationsChanged(on: op)
            }
        case .resize(let h):
            let isImage = (d.obj as? WObject)?.model.kind == .image
            let r = resized(d.startRect, handle: h, dx: dx, dy: dy, keepAspect: isImage ? !shift : shift)
            let nb = convert(r, to: d.page)
            if let w = d.obj as? WObject, w.model.kind == .text {
                w.model.autoWidth = false
                w.bounds = nb
                w.fitBounds()
            } else { d.obj?.bounds = nb }
        case .endpoint(let i):
            guard let w = d.obj as? WObject, let sm = d.startModel else { break }
            var pts = WObject.denormalize(sm.strokes, in: d.startBounds).first ?? []
            guard i < pts.count else { break }
            var np = convert(vp, to: d.page)
            if shift { np = constrain45(from: pts[1 - i], to: np) }
            pts[i] = np
            let (b, n) = WObject.normalize([pts], margin: sm.lineWidth + 4)
            var m = sm; m.strokes = n
            w.model = m; w.bounds = b
        case .create:
            guard let w = d.obj as? WObject else { break }
            let p0 = convert(d.startView, to: d.page)
            var p1 = convert(vp, to: d.page)
            if w.model.isLine {
                if shift { p1 = constrain45(from: p0, to: p1) }
                let (b, n) = WObject.normalize([[p0, p1]], margin: w.model.lineWidth + 4)
                w.model.strokes = n; w.bounds = b
            } else {
                var r = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
                if shift {
                    let s = max(r.width, r.height)
                    r = CGRect(x: p1.x < p0.x ? p0.x - s : p0.x, y: p1.y < p0.y ? p0.y - s : p0.y, width: s, height: s)
                }
                w.bounds = r
            }
        case .ink:
            d.inkPoints.append(convert(vp, to: d.page))
        case .marquee:
            let p0 = convert(d.startView, to: d.page), p1 = convert(vp, to: d.page)
            marquee = (d.page, CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)))
        case .selectRect:
            let r = CGRect(x: min(d.startView.x, vp.x), y: min(d.startView.y, vp.y), width: abs(dx), height: abs(dy))
            objectMarquee = r
            select(all: objects(in: r))
        case .marqueeResize(let h):
            let r = resized(d.startRect, handle: h, dx: dx, dy: dy, keepAspect: shift)
            marquee = (d.page, convert(r, to: d.page).intersection(d.page.bounds(for: .mediaBox)))
        case .guide(let horizontal, let i):
            guard let doc = document else { break }
            let idx = doc.index(for: d.page)
            var g = customGuides[idx] ?? GuideStore.PageGuides()
            let pp = convert(vp, to: d.page)
            if horizontal, i < g.y.count { g.y[i] = pp.y } else if !horizontal, i < g.x.count { g.x[i] = pp.x }
            customGuides[idx] = g
        case .contentMove:
            guard contentSel?.canMove ?? true else { break }
            var ddx = dx, ddy = dy
            if shift { if abs(dx) > abs(dy) { ddy = 0 } else { ddx = 0 } }
            let p0 = convert(d.startView, to: d.page), p1 = convert(CGPoint(x: d.startView.x + ddx, y: d.startView.y + ddy), to: d.page)
            var off = CGVector(dx: p1.x - p0.x, dy: p1.y - p0.y)
            if !e.modifierFlags.contains(.command), let cs = contentSel, cs.bounds.isUsable {
                off = snapOffset(bounds: cs.bounds, page: d.page, dx: off.dx, dy: off.dy, isText: cs.indices.count == 1 && cs.element.kind == .text)
            }
            contentDragOffset = off
        }
        drag = d
        if let o = d.obj { annotationsChanged(on: d.page); _ = o }
        overlay.needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let d = drag {
            drag = nil
            finishDrag(d)
            return
        }
        super.mouseUp(with: e)
    }

    private func finishDrag(_ d: DragState) {
        guides = []
        switch d.mode {
        case .move, .resize, .endpoint:
            if !d.moved, let c = d.editOnRelease, let w = d.obj as? WObject { beginEditing(w, isNew: false, caretAt: c); break }
            guard let a = d.obj, d.moved else { break }
            let name: String
            if case .move = d.mode { name = "Bewegen" } else { name = "Größe ändern" }
            um?.beginUndoGrouping()
            if let w = a as? WObject, let sm = d.startModel {
                let nm = w.model, nb = w.bounds
                w.model = sm; w.bounds = d.startBounds
                setModel(w, nm, bounds: nb, action: name)
                Log.v("finishDrag: nb=\(nb) nachher=\(w.bounds) Grundlinie \(w.firstBaselineY)")
            } else {
                let nb = a.bounds
                a.bounds = d.startBounds
                setBounds(a, nb, action: name)
            }
            for (o, b0, m0) in d.others {
                let nb = o.bounds
                o.bounds = b0
                if let w = o as? WObject, let m0 { setModel(w, m0, bounds: nb, action: name) } else { setBounds(o, nb, action: name) }
            }
            um?.safeActionName(name)
            um?.endUndoGrouping()
        case .create:
            guard let w = d.obj as? WObject else { break }
            d.page.removeAnnotation(w)
            let tooSmall = w.model.isLine ? (w.bounds.width < 10 && w.bounds.height < 10) : (w.bounds.width < 3 || w.bounds.height < 3)
            if tooSmall { annotationsChanged(on: d.page); break }
            if w.model.kind == .cover && tool == .whiteout {
                w.model.fill = RGBA(PDFTools.backgroundColor(around: w.bounds, on: d.page))
            }
            add(w, to: d.page, action: tool.title)
            tool = .textSelect          // wie in der Vorschau: nach der Form zurück zur Auswahl
            select(w)
        case .marquee:
            if !d.moved { marquee = nil }
            if tool == .rectSelect, let (p, r) = marquee { selectContent(in: r, on: p) }
            updateCropBar()
        case .marqueeResize:
            updateCropBar()
        case .selectRect:
            objectMarquee = nil
        case .guide(let horizontal, let i):
            // außerhalb der Seite losgelassen → Hilfslinie löschen
            guard let doc = document else { break }
            let idx = doc.index(for: d.page)
            var g = customGuides[idx] ?? GuideStore.PageGuides()
            let pb = d.page.bounds(for: .cropBox).insetBy(dx: -10, dy: -10)
            if horizontal, i < g.y.count, !(pb.minY...pb.maxY).contains(g.y[i]) { g.y.remove(at: i) }
            if !horizontal, i < g.x.count, !(pb.minX...pb.maxX).contains(g.x[i]) { g.x.remove(at: i) }
            customGuides[idx] = g
            guideSettingsChanged()
        case .contentMove:
            let off = contentDragOffset
            contentDragOffset = .zero
            if d.moved, abs(off.dx) + abs(off.dy) >= 0.5 { moveContentSelection(dx: off.dx, dy: off.dy) }
        case .ink:
            guard d.inkPoints.count > 1 else { break }
            if tool == .sketch, let w = ShapeRecognizer.recognize(d.inkPoints) {
                add(w, to: d.page, action: "Skizzieren")
                select(w)
                break
            }
            var m = Defaults.newModel(.ink)
            let (b, n) = WObject.normalize([d.inkPoints], margin: m.lineWidth + 2)
            m.strokes = n
            let w = WObject(model: m, bounds: b)
            add(w, to: d.page, action: "Zeichnen")
        }
        overlay.needsDisplay = true
    }

    /// Alle verschiebbaren Objekte, die einen Rahmen (in Ansichtskoordinaten) berühren
    private func objects(in r: CGRect) -> [PDFAnnotation] {
        guard let d = document else { return [] }
        var out: [PDFAnnotation] = []
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            guard convert(p.bounds(for: .cropBox), from: p).intersects(r) else { continue }
            for a in p.annotations where (a is WObject || (isEditableNative(a) && canMove(a))) && a.shouldDisplay {
                if convert(a.bounds, from: p).intersects(r) { out.append(a) }
            }
        }
        return out
    }

    private func constrain45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let ang = atan2(b.y - a.y, b.x - a.x)
        let step = CGFloat.pi / 4
        let r = (ang / step).rounded() * step
        let len = hypot(b.x - a.x, b.y - a.y)
        return CGPoint(x: a.x + len * cos(r), y: a.y + len * sin(r))
    }

    private func resized(_ r0: CGRect, handle h: Int, dx: CGFloat, dy: CGFloat, keepAspect: Bool) -> CGRect {
        var minX = r0.minX, maxX = r0.maxX, minY = r0.minY, maxY = r0.maxY
        let left = [0, 6, 7].contains(h), right = [2, 3, 4].contains(h)
        let low = [0, 1, 2].contains(h), high = [4, 5, 6].contains(h)
        if left { minX = min(minX + dx, maxX - 4) }
        if right { maxX = max(maxX + dx, minX + 4) }
        if low { minY = min(minY + dy, maxY - 4) }
        if high { maxY = max(maxY + dy, minY + 4) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if keepAspect, r0.width > 0, r0.height > 0, (left || right), (low || high) {
            let ratio = r0.width / r0.height
            if r.width / r.height > ratio {
                let w = r.height * ratio
                if left { r.origin.x = maxX - w }
                r.size.width = w
            } else {
                let hh = r.width / ratio
                if low { r.origin.y = maxY - hh }
                r.size.height = hh
            }
        }
        return r
    }

    // MARK: Einrasten (Hilfslinien)

    func guideSettingsChanged() { snapSettingsStamp += 1; snapCache.removeAll(); overlay.needsDisplay = true }

    private func snapSources(for page: PDFPage, exclude: [PDFAnnotation]) -> SnapSources? {
        guard let d = document else { return nil }
        let idx = d.index(for: page)
        let gen = (wdoc?.generation ?? 0) * 1000 + snapSettingsStamp
        if let c = snapCache[idx], c.generation == gen, exclude.isEmpty { return c }
        let cg = customGuides[idx] ?? GuideStore.PageGuides()
        let src = SnapSources(page: page, pageIndex: idx, generation: gen, exclude: exclude, content: contentCache[idx],
                              custom: (cg.x, cg.y), settings: GuideSettings.shared)
        if exclude.isEmpty { snapCache[idx] = src }
        return src
    }

    /// Rechteck (Ansichtskoordinaten) auf der Seite einrasten.
    /// `textInset`: bei Textfeldern rastet die Textkante (Rahmen minus Innenabstand) ein, `baselineFromTop` die Grundlinie.
    private func snap(_ r: CGRect, page: PDFPage, exclude: [PDFAnnotation], baselineFromTop: CGFloat? = nil, textInset: CGFloat = 0) -> CGRect {
        guard let src = snapSources(for: page, exclude: exclude) else { return r }
        let pr = convert(r, to: page)
        let tol = GuideSettings.shared.tolerance / max(scaleFactor, 0.01)
        let xs: [(CGFloat, Bool)] = [(pr.minX + textInset, false), (pr.midX, false), (pr.maxX - textInset, false)]
        var out = pr
        let hx = src.best(vertical: true, candidates: xs, tolerance: tol)
        // Grundlinie hat Vorrang vor Rahmenkanten
        var hy: SnapSources.Hit? = nil
        if let bl = baselineFromTop {
            hy = src.best(vertical: false, candidates: [(pr.maxY - bl, true)], tolerance: tol)
            let cand = pr.maxY - bl
            let near: [CGFloat] = src.lines.filter { $0.kind == .baseline || $0.kind == .lineSpacing }.map { $0.value }.sorted { abs($0 - cand) < abs($1 - cand) }
            let hitText: String = hy.map { "\($0.line.kind.rawValue) \($0.line.value)" } ?? "keiner"
            Log.v("snap Grundlinie: Kandidat \(cand), Toleranz \(tol), Treffer \(hitText), nächste: \(Array(near.prefix(3)))")
        }
        if hy == nil { hy = src.best(vertical: false, candidates: [(pr.minY, false), (pr.midY, false), (pr.maxY, false)], tolerance: tol) }
        if let h = hx { out.origin.x += h.delta }
        if let h = hy { out.origin.y += h.delta }
        showGuides([hx, hy].compactMap { $0 }, page: page, around: out)
        return convert(out, from: page)
    }

    private func showGuides(_ hits: [SnapSources.Hit], page: PDFPage, around out: CGRect) {
        let pb = page.bounds(for: .cropBox)
        for h in hits {
            let l = h.line
            let a: CGPoint, b: CGPoint
            if l.vertical { a = CGPoint(x: l.value, y: l.range?.lowerBound ?? pb.minY); b = CGPoint(x: l.value, y: l.range?.upperBound ?? pb.maxY) }
            else { a = CGPoint(x: l.range?.lowerBound ?? pb.minX, y: l.value); b = CGPoint(x: l.range?.upperBound ?? pb.maxX, y: l.value) }
            var va = convert(a, from: page), vb = convert(b, from: page)
            let vo = convert(out, from: page)
            if l.vertical { va.y = min(va.y, vo.minY); vb.y = max(vb.y, vo.maxY) } else { va.x = min(va.x, vo.minX); vb.x = max(vb.x, vo.maxX) }
            guides.append(ShownGuide(a: va, b: vb, label: l.kind.rawValue))
        }
    }

    /// Verschiebung (Seitenpunkte) für PDF-Inhalt einrasten. Bei Text zählen die exakten Zeilenmaße (Kanten, Grundlinie).
    private func snapOffset(bounds: CGRect, page: PDFPage, dx: CGFloat, dy: CGFloat, isText: Bool) -> CGVector {
        guard let src = snapSources(for: page, exclude: []) else { return CGVector(dx: dx, dy: dy) }
        let tol = GuideSettings.shared.tolerance / max(scaleFactor, 0.01)
        var rect = bounds
        var baseline: CGFloat? = nil
        if isText, let line = page.selectionForLine(at: CGPoint(x: bounds.midX, y: bounds.midY)), !(line.string ?? "").trimmed.isEmpty {
            let lb = line.bounds(for: page)
            if lb.width > 1 { rect = lb }
            var desc: CGFloat = -lb.height * 0.22
            if let a = line.attributedString, a.length > 0, let f = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { desc = f.descender }
            baseline = lb.minY - desc
        }
        let moved = rect.offsetBy(dx: dx, dy: dy)
        let hx = src.best(vertical: true, candidates: [(moved.minX, false), (moved.midX, false), (moved.maxX, false)], tolerance: tol)
        var hy: SnapSources.Hit? = nil
        if let bl = baseline { hy = src.best(vertical: false, candidates: [(bl + dy, true)], tolerance: tol) }
        if hy == nil { hy = src.best(vertical: false, candidates: [(moved.minY, false), (moved.midY, false), (moved.maxY, false)], tolerance: tol) }
        var out = CGVector(dx: dx, dy: dy)
        if let h = hx { out.dx += h.delta }
        if let h = hy { out.dy += h.delta }
        showGuides([hx, hy].compactMap { $0 }, page: page, around: rect.offsetBy(dx: out.dx, dy: out.dy))
        return out
    }

    // MARK: Eigene Hilfslinien

    func addCustomGuide(horizontal: Bool, atView vp: CGPoint) {
        guard let d = document, let page = page(for: vp, nearest: true) else { return }
        let pp = convert(vp, to: page)
        let pb = page.bounds(for: .cropBox)
        guard pb.insetBy(dx: -20, dy: -20).contains(pp) else { return }
        let idx = d.index(for: page)
        var g = customGuides[idx] ?? GuideStore.PageGuides()
        if horizontal { g.y.append(pp.y) } else { g.x.append(pp.x) }
        customGuides[idx] = g
        guideSettingsChanged()
    }

    func clearCustomGuides(pageOnly: Bool) {
        if pageOnly, let d = document, let p = currentPage { customGuides[d.index(for: p)] = nil } else { customGuides = [:] }
        guideSettingsChanged()
    }

    /// Eigene Hilfslinie nahe einem Punkt (Ansichtskoordinaten): (horizontal, Index)
    private func customGuide(at vp: CGPoint) -> (Bool, Int, PDFPage)? {
        guard GuideSettings.shared.showCustom, let d = document, let page = page(for: vp, nearest: false) else { return nil }
        let g = customGuides[d.index(for: page)] ?? GuideStore.PageGuides()
        for (i, x) in g.x.enumerated() { if abs(convert(CGPoint(x: x, y: 0), from: page).x - vp.x) <= 4 { return (false, i, page) } }
        for (i, y) in g.y.enumerated() { if abs(convert(CGPoint(x: 0, y: y), from: page).y - vp.y) <= 4 { return (true, i, page) } }
        return nil
    }

    override func mouseMoved(with e: NSEvent) {
        super.mouseMoved(with: e)
        let vp = viewPoint(e)
        if loupe { loupePoint = vp; overlay.needsDisplay = true }
        if handleAt(vp) != nil { NSCursor.crosshair.set(); return }
        if let (h, _, _) = customGuide(at: vp) { (h ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set(); return }
        if let (a, _) = objectAt(vp), canMove(a) { NSCursor.openHand.set(); return }
        switch tool {
        case .rectSelect, .draw, .sketch, .whiteout, .redact: NSCursor.crosshair.set()
        case .crop: if marqueeHandle(at: vp) != nil { NSCursor.crosshair.set() } else { NSCursor.crosshair.set() }
        case .editText: if page(for: vp, nearest: false) != nil { NSCursor.arrow.set() }
        default: break
        }
    }

    // MARK: Textauswahl → Markieren / Bearbeiten

    private func applyToolToExistingSelection() {
        guard let sel = currentSelection, !(sel.string ?? "").trimmed.isEmpty else { return }
        if tool == .textSelect, highlight != nil { addMarkup(sel); clearSelection() }
        else if tool == .editText, let p = sel.pages.first { convertToEditable(sel, page: p, caretAt: nil); clearSelection() }
    }

    private func finishTextAction() {
        let sel = currentSelection
        let hasSel = !(sel?.string ?? "").trimmed.isEmpty
        if tool == .textSelect, highlight != nil {
            if hasSel, let sel { addMarkup(sel); clearSelection() }
        } else if tool == .editText {
            if hasSel, let sel, let p = sel.pages.first {
                convertToEditable(sel, page: p, caretAt: nil); clearSelection()
            } else if let (page, pp, vp) = clickPoint, let line = page.selectionForLine(at: pp),
                      line.bounds(for: page).insetBy(dx: -2, dy: -2).contains(pp), !(line.string ?? "").trimmed.isEmpty {
                clearSelection()
                convertToEditable(line, page: page, caretAt: vp)
            }
        }
        clickPoint = nil
    }

    private func addMarkup(_ sel: PDFSelection) {
        guard let hs = highlight else { return }
        let type = hs.type
        let typeName = String(type.rawValue.dropFirst())
        // Liegt schon eine Hervorhebung gleicher Art unter der Auswahl? Dann wird sie entfernt.
        var existing: [(PDFAnnotation, PDFPage)] = []
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                for a in page.annotations where a.type == typeName && !(a is WObject) {
                    let i = a.bounds.intersection(b)
                    guard !i.isNull else { continue }
                    let smaller = min(a.bounds.width * a.bounds.height, b.width * b.height)
                    if smaller > 0, i.width * i.height > 0.4 * smaller, !existing.contains(where: { $0.0 === a }) { existing.append((a, page)) }
                }
            }
        }
        if !existing.isEmpty {
            um?.beginUndoGrouping()
            existing.forEach { remove($0.0, from: $0.1) }
            um?.safeActionName("Hervorhebung entfernen")
            um?.endUndoGrouping()
            return
        }
        um?.beginUndoGrouping()
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 0.5, b.height > 0.5 else { continue }
                let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
                a.color = type == .highlight ? hs.color.withAlphaComponent(0.6) : hs.color
                a.quadrilateralPoints = [NSValue(point: NSPoint(x: 0, y: b.height)), NSValue(point: NSPoint(x: b.width, y: b.height)),
                                         NSValue(point: .zero), NSValue(point: NSPoint(x: b.width, y: 0))]
                add(a, to: page)
            }
        }
        um?.safeActionName(type == .highlight ? "Hervorheben" : type == .underline ? "Unterstreichen" : "Durchstreichen")
        um?.endUndoGrouping()
    }

    /// Vorhandenen PDF-Text in bearbeitbaren Text verwandeln: Original abdecken, neuen Text exakt darüber setzen.
    func convertToEditable(_ sel: PDFSelection, page: PDFPage, caretAt: CGPoint?) {
        let lines = sel.selectionsByLine().filter { $0.pages.contains(page) && !($0.string ?? "").trimmed.isEmpty }
        guard let first = lines.first else { return }
        let rects = lines.map { $0.bounds(for: page) }
        let attr = first.attributedString
        let srcFont = (attr?.length ?? 0) > 0 ? attr?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        let srcColor = ((attr?.length ?? 0) > 0 ? attr?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil) ?? .black

        var m = ObjModel(kind: .text)
        m.stroke = nil; m.fill = nil
        let fm = FontMatch.match(for: srcFont)
        m.fontName = fm.name
        if !fm.exact, let sf = srcFont { m.origFont = FontMatch.clean(sf.fontName) }
        var size = srcFont?.pointSize ?? 0
        if size < 2 || size > 400 { size = (rects[0].height / 1.15).rounded() }
        m.fontSize = size
        m.textColor = RGBA(srcColor)
        m.text = lines.map { ($0.string ?? "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")
        m.autoWidth = lines.count == 1
        if lines.count > 1 {
            let lh = (rects[0].minY - rects[rects.count - 1].minY) / CGFloat(lines.count - 1)
            if lh > size * 0.8 && lh < size * 3 { m.lineHeight = lh }
        }
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let tw = WObject(model: m, bounds: .zero)
        let f = tw.textFont
        let top: CGFloat = m.lineHeight.map { rects[0].minY + $0 + pad } ?? (rects[0].minY - f.descender + f.ascender + pad)
        let rot = PDFTools.normRotation(page.rotation)
        if rot == 0 {
            tw.bounds = CGRect(x: union.minX - pad, y: top - 10, width: union.width + 2 * pad + 2, height: 10)
            tw.fitBounds()
            if !m.autoWidth { tw.bounds.size.width = max(tw.bounds.width, union.width + 2 * pad + 2) }
        } else {
            // gedrehte Seite: Text aufrecht wie auf dem Bildschirm, obere linke Ecke der Zeile (sichtbar) bleibt stehen
            var mm = tw.model; mm.rot = rot; tw.model = mm
            let swapped = rot == 90 || rot == 270
            let visW = (swapped ? union.height : union.width) + 2 * pad + 2
            tw.bounds = union.insetBy(dx: -pad, dy: -pad)
            if !mm.autoWidth { tw.bounds = WObject.anchoredRect(old: tw.bounds, w: visW, h: 10, rotation: rot) }
            tw.fitBounds()
        }

        um?.beginUndoGrouping()
        let pageIdx = document?.index(for: page) ?? 0
        var target = page
        if removeTextContent(in: rects, on: page), let d = document, let np = d.page(at: pageIdx) {
            target = np          // Dokument wurde ersetzt – neue Seite verwenden
        } else {
            // Rückfall: abdecken
            let bg = PDFTools.backgroundColor(around: union, on: page)
            for r in rects {
                var c = ObjModel(kind: .cover); c.stroke = nil; c.fill = RGBA(bg)
                add(WObject(model: c, bounds: r.insetBy(dx: -1, dy: -0.5)), to: page)
            }
        }
        add(tw, to: target)
        um?.safeActionName("Text bearbeiten")
        um?.endUndoGrouping()
        beginEditing(tw, isNew: false, caretAt: caretAt)
    }

    // MARK: Text direkt bearbeiten

    func beginEditing(_ w: WObject, isNew: Bool, caretAt: CGPoint?) {
        endEditing()
        guard w.page != nil else { return }
        select(w)
        editObj = w
        editStart = (w.model, w.bounds, isNew)
        let tv = NSTextView(frame: .zero)
        tv.delegate = self
        tv.isRichText = false
        tv.allowsUndo = true
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = false
        tv.string = w.model.text
        editor = tv
        styleEditor()
        addSubview(tv)
        w.editing = true
        refresh(w)
        window?.makeFirstResponder(tv)
        if let c = caretAt {
            let local = tv.convert(c, from: self)
            let i = tv.characterIndexForInsertion(at: local)
            tv.setSelectedRange(NSRange(location: min(i, (tv.string as NSString).length), length: 0))
        } else {
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        overlay.needsDisplay = true
    }

    private func styleEditor() {
        guard let tv = editor, let w = editObj else { return }
        let s = scaleFactor
        let attrs = w.attributes(scale: s)
        tv.font = attrs[.font] as? NSFont
        tv.textColor = w.model.textColor.color
        tv.insertionPointColor = w.model.textColor.color
        tv.defaultParagraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle
        tv.typingAttributes = attrs
        if let ts = tv.textStorage { ts.setAttributes(attrs, range: NSRange(location: 0, length: ts.length)) }
        tv.textContainerInset = NSSize(width: pad * s, height: pad * s)
        if let f = w.model.fill { tv.drawsBackground = true; tv.backgroundColor = f.color } else { tv.drawsBackground = false }
        if w.model.autoWidth {
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: 1_000_000, height: 1_000_000)
            tv.isHorizontallyResizable = false
        } else {
            tv.textContainer?.widthTracksTextView = true
            tv.isHorizontallyResizable = false
        }
        positionEditor()
    }

    private func positionEditor() {
        guard let tv = editor, let w = editObj, let p = w.page else { return }
        var r = convert(w.bounds, from: p)
        if w.model.autoWidth { r.size.width += 6 * scaleFactor }
        r.size.height += 2
        tv.frame = r
        if !w.model.autoWidth { tv.textContainer?.containerSize = NSSize(width: r.width - 2 * pad * scaleFactor, height: 1_000_000) }
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = editor, let w = editObj else { return }
        w.model.text = tv.string
        w.fitBounds()
        positionEditor()
        overlay.needsDisplay = true
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(cancelOperation(_:)) { endEditing(); return true }
        return false
    }

    var isEditingText: Bool { editor != nil }

    func endEditing() {
        guard let tv = editor, let w = editObj, let (oldM, oldB, isNew) = editStart else { return }
        editor = nil; editObj = nil; editStart = nil
        editorUndo.removeAllActions()
        tv.removeFromSuperview()
        w.editing = false
        guard let page = w.page else { return }
        let empty = tv.string.trimmed.isEmpty
        if isNew {
            page.removeAnnotation(w)
            if empty { if selected === w { select(nil) }; annotationsChanged(on: page) }
            else {
                add(w, to: page, action: (w.model.fill != nil && !w.model.autoWidth) ? "Notiz" : "Text")
                // danach direkt verschiebbar/löschbar
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.editor == nil else { return }
                    self.select(w)
                }
            }
        } else if empty {
            let cur = w.model, curB = w.bounds
            w.model = oldM; w.bounds = oldB
            _ = (cur, curB)
            remove(w, from: page, action: "Text löschen")
        } else if w.model != oldM || w.bounds != oldB {
            let nm = w.model, nb = w.bounds
            w.model = oldM; w.bounds = oldB
            setModel(w, nm, bounds: nb, action: "Text bearbeiten")
        } else { refresh(w) }
        if window?.firstResponder == nil || window?.firstResponder === tv { window?.makeFirstResponder(self) }
        overlay.needsDisplay = true
    }

    // MARK: Tastatur

    override func keyDown(with e: NSEvent) {
        if !handleKey(e) { super.keyDown(with: e) }
    }

    /// Tastatur für Objekte. Läuft zusätzlich über einen Fenster-Monitor, weil PDFKit Tasten selbst schluckt.
    @discardableResult
    func handleKey(_ e: NSEvent) -> Bool {
        Log.v("key \(e.keyCode) fr=\(String(describing: window?.firstResponder.map { type(of: $0) })) sel=\((selected as? WObject)?.model.kind.rawValue ?? selected?.type ?? "nil") selPage=\(selected?.page != nil)")
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if tool == .rectSelect, contentSel != nil || (!selectedObjects.isEmpty && marquee != nil), [51, 117].contains(e.keyCode) {
            removeContentSelection(); return true
        }
        if let cs = contentSel {
            switch e.keyCode {
            case 51, 117: removeContentSelection(); return true
            case 123, 124, 125, 126:
                guard cs.canMove else { NSSound.beep(); return true }
                let st: CGFloat = flags.contains(.shift) ? 10 : 1
                let v = e.keyCode == 123 ? CGVector(dx: -st, dy: 0) : e.keyCode == 124 ? CGVector(dx: st, dy: 0) : e.keyCode == 126 ? CGVector(dx: 0, dy: st) : CGVector(dx: 0, dy: -st)
                moveContentSelection(dx: v.dx, dy: v.dy); return true
            case 53: contentSel = nil; return true
            default: break
            }
        }
        if !selectedObjects.isEmpty {
            switch e.keyCode {
            case 51, 117: deleteSelection("Löschen"); return true
            case 123, 124, 125, 126:
                let step: CGFloat = (flags.contains(.shift) ? 10 : 1) * scaleFactor
                let up: CGFloat = isFlipped ? -1 : 1
                let d: CGVector = e.keyCode == 123 ? CGVector(dx: -step, dy: 0) : e.keyCode == 124 ? CGVector(dx: step, dy: 0)
                    : e.keyCode == 126 ? CGVector(dx: 0, dy: step * up) : CGVector(dx: 0, dy: -step * up)
                um?.beginUndoGrouping()
                for a in selectedObjects where canMove(a) {
                    guard let p = a.page else { continue }
                    let r = convert(a.bounds, from: p).offsetBy(dx: d.dx, dy: d.dy)
                    setBounds(a, convert(r, to: p), action: "Bewegen")
                }
                um?.safeActionName("Bewegen")
                um?.endUndoGrouping()
                return true
            case 36, 76:
                if !isMulti, let w = selected as? WObject, w.model.kind == .text { beginEditing(w, isNew: false, caretAt: nil); return true }
            default: break
            }
        }
        if tool == .crop, marquee != nil, e.keyCode == 36 || e.keyCode == 76 { cropToSelection(nil); return true }
        // Lupe: Taste ´ (oder ` ) schaltet um
        if let ch = e.charactersIgnoringModifiers, ch == "´" || ch == "`" || ch == "^" {
            loupe.toggle()
            if loupe, let w = window { loupePoint = convert(w.mouseLocationOutsideOfEventStream, from: nil) }
            return true
        }
        if e.keyCode == 53, loupe { loupe = false; return true }
        // Esc, in dieser Reihenfolge: 1. Textfeld schließen (macht das Textfeld selbst) 2. Auswahl aufheben 3. Werkzeug zurück
        if e.keyCode == 53 {
            if !selectedObjects.isEmpty { select(nil); return true }
            if marquee != nil { marquee = nil; return true }
            if tool != .textSelect || highlight != nil { tool = .textSelect; highlight = nil; return true }
            return false
        }
        _ = flags
        return false
    }

    // MARK: Stil (Rahmenfarbe, Füllfarbe, Formstil, Textstil)

    enum ColorTarget { case stroke, fill }

    /// Aktueller Stil zur Anzeige in der Markierungsleiste: ausgewähltes Objekt oder Standard
    var styleModel: ObjModel {
        if let w = selected as? WObject { return w.model }
        var m = Defaults.model
        if let a = selected {
            m.stroke = RGBA(a.color)
            m.fill = a.interiorColor.map(RGBA.init)
        }
        return m
    }

    private func change(_ action: String, coalesce: String? = nil, _ f: (inout ObjModel) -> Void) {
        endEditing()
        let ws = selectedWObjects
        if ws.count > 1 { um?.beginUndoGrouping() }
        for w in ws {
            if w.model.kind == .pageNumber { applyToAllPageNumbers(f) }
            else {
                var m = w.model; f(&m)
                setModel(w, m, bounds: w.model.kind == .text ? nil : w.bounds, action: action, coalesce: ws.count > 1 ? nil : coalesce)
            }
        }
        if ws.count > 1 { um?.safeActionName(action)
 um?.endUndoGrouping() }
        f(&Defaults.model)
        Defaults.save()
        onSelectionChange?(selected)
    }

    func applyColor(_ c: NSColor?, to target: ColorTarget) {
        let rgba = c.map(RGBA.init)
        if let a = selected, !(a is WObject) {
            switch target {
            case .stroke: if let c { setColor(a, c) }
            case .fill: setInterior(a, c)
            }
            if target == .stroke, let rgba { Defaults.model.stroke = rgba } else if target == .fill { Defaults.model.fill = rgba }
            Defaults.save(); onSelectionChange?(a); return
        }
        change(target == .stroke ? "Rahmenfarbe" : "Füllfarbe", coalesce: target == .stroke ? "stroke" : "fill") { m in
            switch target {
            case .stroke:
                if m.kind == .cover { if let rgba { m.fill = rgba } } else { m.stroke = rgba }
            case .fill:
                if m.kind == .cover { if let rgba { m.fill = rgba } }
                else if m.hasFill || m.kind == .rect { m.fill = rgba }
            }
        }
    }

    func applyLineStyle(width: CGFloat? = nil, dash: Bool? = nil, shadow: Bool? = nil, arrow: Bool? = nil) {
        change("Formstil") { m in
            if let width { m.lineWidth = width }
            if let dash { m.dash = dash }
            if let shadow { m.shadow = shadow }
            if let arrow, m.isLine { m.kind = arrow ? .arrow : .line }
        }
        if let width, let a = selected, !(a is WObject) {
            let b = a.border ?? PDFBorder(); b.lineWidth = width; a.border = b; refresh(a)
        }
    }

    func applyTextStyle(_ f: @escaping (inout ObjModel) -> Void) {
        if let a = selected, !(a is WObject), a.type == "FreeText" {
            var m = Defaults.model
            m.fontName = a.font?.fontName ?? m.fontName; m.fontSize = a.font?.pointSize ?? m.fontSize
            m.textColor = RGBA(a.fontColor ?? .black)
            f(&m)
            a.font = NSFont(name: m.fontName, size: m.fontSize); a.fontColor = m.textColor.color
            refresh(a)
            wdoc?.updateChangeCount(.changeDone)
            return
        }
        change("Textstil", coalesce: "text", f)
    }

    func setInterior(_ a: PDFAnnotation, _ c: NSColor?) {
        let old = a.interiorColor
        a.interiorColor = c
        refresh(a)
        let idx = a.page.flatMap { document?.index(for: $0) } ?? 0
        um?.registerUndo(withTarget: self) { cv in if let (x, _) = cv.locate(a, pageIndex: idx) { cv.setInterior(x, old) } }
        um?.safeActionName("Füllfarbe")
    }

    /// Farbe einer vorhandenen Hervorhebung ändern, sonst Farbe für neue Hervorhebungen
    func setHighlightColor(_ c: NSColor) {
        if let a = selected, a.type == "Highlight" { setColor(a, c.withAlphaComponent(0.6)) }
    }

    // MARK: Zwischenablage

    override func copy(_ sender: Any?) {
        if selected == nil, copyMarquee() { return }
        let ws = selectedWObjects
        guard let w = ws.first else { super.copy(sender); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let d = try? JSONEncoder().encode(ws.map { Clip(model: $0.model, bounds: $0.bounds) }) { pb.setData(d, forType: Self.objType) }
        if ws.count == 1, w.model.kind == .text { pb.setString(w.model.text, forType: .string) }
        if ws.count == 1, w.model.kind == .image, let d = w.model.image, let img = NSImage(data: d) { pb.writeObjects([img]) }
        pasteOffset = 0
    }

    func deleteSelection(_ action: String) {
        let list = selectedObjects
        guard !list.isEmpty else { return }
        um?.beginUndoGrouping()
        for a in list { if let p = a.page { remove(a, from: p) } }
        um?.safeActionName(action)
        um?.endUndoGrouping()
    }

    @objc func cut(_ sender: Any?) {
        guard !selectedObjects.isEmpty else { return }
        copy(sender)
        deleteSelection("Ausschneiden")
    }

    @objc func delete(_ sender: Any?) { deleteSelection("Löschen") }

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard let page = currentPage else { return }
        if let d = pb.data(forType: Self.objType),
           let clips = (try? JSONDecoder().decode([Clip].self, from: d)) ?? (try? JSONDecoder().decode(Clip.self, from: d)).map({ [$0] }) {
            pasteOffset += 12
            um?.beginUndoGrouping()
            let ws = clips.map { cl -> WObject in var m = cl.model; m.id = UUID().uuidString; return WObject(model: m, bounds: cl.bounds.offsetBy(dx: pasteOffset, dy: -pasteOffset)) }
            ws.forEach { add($0, to: page) }
            um?.safeActionName("Einsetzen")
            um?.endUndoGrouping()
            tool = .textSelect; select(all: ws)
        } else if let types = pb.types, types.contains(.png) || types.contains(.tiff),
                  let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            insertImage(data, at: nil)
        } else if let s = pb.string(forType: .string), !s.trimmed.isEmpty {
            var m = Defaults.newModel(.text)
            m.text = s
            m.rot = PDFTools.normRotation(page.rotation)
            m.autoWidth = !s.contains("\n") && s.count < 80
            let c = visibleCenter(on: page)
            let w = WObject(model: m, bounds: CGRect(x: c.x - 100, y: c.y, width: 200, height: 10))
            page.addAnnotation(w); w.fitBounds(); page.removeAnnotation(w)
            add(w, to: page, action: "Einsetzen"); select(w); tool = .textSelect
        }
    }

    @objc func duplicateObject(_ sender: Any?) {
        let ws = selectedWObjects.filter { $0.page != nil }
        guard !ws.isEmpty else { return }
        um?.beginUndoGrouping()
        let copies = ws.map { w -> WObject in
            var m = w.model; m.id = UUID().uuidString
            let c = WObject(model: m, bounds: w.bounds.offsetBy(dx: 12, dy: -12))
            add(c, to: w.page!)
            return c
        }
        um?.safeActionName("Duplizieren")
        um?.endUndoGrouping()
        select(all: copies)
    }

    @objc func editSelectedText(_ sender: Any?) {
        if let w = selected as? WObject, w.model.kind == .text { beginEditing(w, isNew: false, caretAt: nil) }
    }

    @objc func editComment(_ sender: Any?) {
        guard let a = selected, let w = window else { return }
        let alert = NSAlert()
        alert.messageText = "Kommentar"
        alert.informativeText = "Wird in Acrobat und der Vorschau als Anmerkung angezeigt."
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        tv.string = a.contents ?? ""
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        let sc = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        sc.documentView = tv; sc.hasVerticalScroller = true; sc.borderType = .bezelBorder
        tv.autoresizingMask = [.width]
        alert.accessoryView = sc
        alert.addButton(withTitle: "Sichern"); alert.addButton(withTitle: "Abbrechen")
        if !(a.contents ?? "").isEmpty { alert.addButton(withTitle: "Kommentar entfernen") }
        alert.window.initialFirstResponder = tv
        alert.beginSheetModal(for: w) { [weak self] r in
            guard let self else { return }
            if r == .alertFirstButtonReturn { self.setComment(a, tv.string.trimmed.isEmpty ? nil : tv.string) }
            else if r == .alertThirdButtonReturn { self.setComment(a, nil) }
        }
    }

    func setComment(_ a: PDFAnnotation, _ text: String?) {
        let old = a.contents
        a.contents = text
        if text != nil, (a.userName ?? "").isEmpty { a.userName = NSFullUserName() }
        a.modificationDate = Date()
        refresh(a)
        wdoc?.updateChangeCount(.changeDone)
        let idx = a.page.flatMap { document?.index(for: $0) } ?? 0
        um?.registerUndo(withTarget: self) { cv in if let (x, _) = cv.locate(a, pageIndex: idx) { cv.setComment(x, old) } }
        um?.safeActionName("Kommentar")
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        let vp = viewPoint(e)
        guard let (a, _) = objectAt(vp, includeMarkup: true) else { return super.menu(for: e) }
        if !isSelected(a) { select(a) }
        let m = NSMenu()
        let isMarkup = ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(a.type ?? "")
        if isMarkup || (a as? WObject)?.model.kind == .text || (a as? WObject)?.model.kind == .image || (a as? WObject)?.model.isShape == true {
            let has = !(a.contents ?? "").isEmpty
            m.addItem(withTitle: has ? "Kommentar bearbeiten …" : "Kommentar hinzufügen …", action: #selector(editComment(_:)), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        if let w = a as? WObject, w.model.kind == .text {
            m.addItem(withTitle: "Text bearbeiten", action: #selector(editSelectedText(_:)), keyEquivalent: "").target = self
        }
        if a is WObject {
            m.addItem(withTitle: "Kopieren", action: #selector(copy(_:)), keyEquivalent: "").target = self
            m.addItem(withTitle: "Duplizieren", action: #selector(duplicateObject(_:)), keyEquivalent: "").target = self
        }
        let arrange = NSMenuItem(title: "Anordnen", action: nil, keyEquivalent: "")
        if let (i, n) = layerInfo { arrange.title = "Anordnen (Ebene \(i) von \(n))" }
        let am = NSMenu()
        am.addItem(withTitle: "Ganz nach vorne", action: #selector(bringToFront(_:)), keyEquivalent: "").target = self
        am.addItem(withTitle: "Eine Ebene nach vorne", action: #selector(bringForward(_:)), keyEquivalent: "").target = self
        am.addItem(withTitle: "Eine Ebene nach hinten", action: #selector(sendBackward(_:)), keyEquivalent: "").target = self
        am.addItem(withTitle: "Ganz nach hinten", action: #selector(sendToBack(_:)), keyEquivalent: "").target = self
        arrange.submenu = am
        m.addItem(arrange)
        m.addItem(.separator())
        m.addItem(withTitle: "Löschen", action: #selector(delete(_:)), keyEquivalent: "").target = self
        return m
    }

    // MARK: Bilder

    func visibleCenter(on page: PDFPage) -> CGPoint {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        if self.page(for: c, nearest: false) === page { return convert(c, to: page) }
        let b = page.bounds(for: .cropBox)
        return CGPoint(x: b.midX, y: b.midY)
    }

    func insertImage(_ data: Data, at vp: CGPoint?, width: CGFloat? = nil, action: String = "Bild einfügen") {
        guard let (d, px) = PDFTools.prepareImage(data) else { NSSound.beep(); return }
        let page: PDFPage
        let center: CGPoint
        if let vp, let p = self.page(for: vp, nearest: true) { page = p; center = convert(vp, to: p) }
        else if let p = currentPage { page = p; center = visibleCenter(on: p) }
        else { return }
        let vs = PDFTools.visualSize(page)
        var w = width ?? min(px.width * 72 / 144, vs.width * 0.5)
        if w < 20 { w = 20 }
        let h = w * px.height / max(px.width, 1)
        var m = Defaults.newModel(.image)
        m.image = d
        m.rot = PDFTools.normRotation(page.rotation)
        let swap = m.rot == 90 || m.rot == 270
        let size = swap ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        let o = WObject(model: m, bounds: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        add(o, to: page, action: action)
        tool = .textSelect
        select(o)
        window?.makeFirstResponder(self)
    }

    // MARK: Ziehen & Ablegen

    private func droppedURLs(_ s: NSDraggingInfo) -> [URL] {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).contains { u in
            guard let t = UTType(filenameExtension: u.pathExtension) else { return false }
            return t.conforms(to: .image) || t.conforms(to: .pdf)
        } ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let vp = convert(sender.draggingLocation, from: nil)
        var done = false
        for u in droppedURLs(sender) {
            guard let t = UTType(filenameExtension: u.pathExtension) else { continue }
            if t.conforms(to: .pdf) {
                let after = page(for: vp, nearest: true).flatMap { document?.index(for: $0) } ?? ((document?.pageCount ?? 1) - 1)
                wdoc?.insertPages(from: u, at: after + 1)
                done = true
            } else if t.conforms(to: .image), let d = try? Data(contentsOf: u) {
                insertImage(d, at: vp)
                done = true
            }
        }
        return done
    }

    // MARK: Seitenzahlen

    var hasPageNumbers: Bool {
        guard let d = document else { return false }
        for i in 0..<d.pageCount { if d.page(at: i)?.annotations.contains(where: { ($0 as? WObject)?.model.kind == .pageNumber }) == true { return true } }
        return false
    }

    func removePageNumbers(grouped: Bool = true) {
        guard let d = document else { return }
        if grouped { um?.beginUndoGrouping() }
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            for a in p.annotations where (a as? WObject)?.model.kind == .pageNumber { remove(a, from: p) }
        }
        if grouped { um?.safeActionName("Seitenzahlen entfernen")
 um?.endUndoGrouping() }
    }

    func applyPageNumbers(_ s: PageNumberSettings) {
        guard let d = document else { return }
        endEditing()
        um?.beginUndoGrouping()
        removePageNumbers(grouped: false)
        let first = max(0, s.firstPage - 1)
        let marginPt = s.margin * 72 / 25.4
        if first < d.pageCount {
            for i in first..<d.pageCount {
                guard let p = d.page(at: i) else { continue }
                var m = ObjModel(kind: .pageNumber)
                m.stroke = nil; m.fill = nil
                m.format = s.format; m.startNumber = s.start; m.firstPage = first
                m.fontName = s.fontName; m.fontSize = s.fontSize
                m.autoWidth = false
                m.rot = PDFTools.normRotation(p.rotation)
                let n = i - first + s.start
                var horiz = s.position % 3          // 0 links, 1 mitte, 2 rechts
                if s.position == 6 { horiz = n % 2 == 1 ? 2 : 0 }
                let top = s.position >= 3 && s.position <= 5
                m.align = horiz
                let tmp = WObject(model: m, bounds: .zero)
                let h = ceil(tmp.textFont.ascender - tmp.textFont.descender + tmp.textFont.leading) + 2 * pad + 1
                let vs = PDFTools.visualSize(p)
                let bw = min(240, vs.width - 2 * marginPt)
                let x: CGFloat = horiz == 0 ? marginPt : horiz == 1 ? (vs.width - bw) / 2 : vs.width - marginPt - bw
                let y: CGFloat = top ? vs.height - marginPt - h : marginPt
                let vr = CGRect(x: x - (horiz == 0 ? pad : horiz == 2 ? -pad : 0), y: y, width: bw, height: h)
                add(WObject(model: m, bounds: PDFTools.visualToPage(vr, page: p)), to: p)
            }
        }
        um?.safeActionName("Seitenzahlen")
        um?.endUndoGrouping()
    }

    /// Änderungen an einer Seitenzahl gelten für alle Seitenzahlen.
    func applyToAllPageNumbers(_ change: (inout ObjModel) -> Void) {
        guard let d = document else { return }
        um?.beginUndoGrouping()
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            for case let w as WObject in p.annotations where w.model.kind == .pageNumber {
                var m = w.model; change(&m)
                setModel(w, m, bounds: w.bounds, action: "Seitenzahlen")
            }
        }
        um?.safeActionName("Seitenzahlen")
        um?.endUndoGrouping()
    }

    // MARK: Suche

    private var searchResults: [PDFSelection] = []
    private var searchIndex = 0
    private var searchTerm = ""

    func search(_ term: String, backwards: Bool = false) {
        guard let d = document else { return }
        if term.isEmpty {
            searchResults = []; searchTerm = ""; highlightedSelections = nil; onSearch?(0, 0); return
        }
        if term != searchTerm {
            searchTerm = term
            searchResults = d.findString(term, withOptions: [.caseInsensitive, .diacriticInsensitive])
            searchResults.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.6) }
            highlightedSelections = searchResults
            searchIndex = backwards ? max(0, searchResults.count - 1) : 0
        } else if !searchResults.isEmpty {
            searchIndex = (searchIndex + (backwards ? -1 : 1) + searchResults.count) % searchResults.count
        }
        onSearch?(searchResults.isEmpty ? 0 : searchIndex + 1, searchResults.count)
        guard !searchResults.isEmpty else { NSSound.beep(); return }
        let s = searchResults[searchIndex]
        setCurrentSelection(s, animate: true)
        scrollSelectionToVisible(nil)
    }

    // MARK: Zoom mit ⌘-Scrollrad und Doppeltipp (Trackpad)

    override func scrollWheel(with e: NSEvent) {
        guard e.modifierFlags.contains(.command) else { super.scrollWheel(with: e); return }
        let delta = e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        zoom(by: 1 + max(-0.3, min(0.3, delta)), at: viewPoint(e))
    }

    override func smartMagnify(with e: NSEvent) {
        if autoScales { zoom(by: 2, at: viewPoint(e)) } else { autoScales = true }
    }

    func zoom(by f: CGFloat, at vp: CGPoint) {
        guard let page = page(for: vp, nearest: true), let clip = documentView?.enclosingScrollView?.contentView else { return }
        let pp = convert(vp, to: page)
        autoScales = false
        scaleFactor = max(0.2, min(8, scaleFactor * f))
        // Punkt unter dem Zeiger bleibt an Ort und Stelle
        let nv = convert(pp, from: page)
        let a = clip.convert(vp, from: self), b = clip.convert(nv, from: self)
        clip.scroll(to: CGPoint(x: clip.bounds.minX + b.x - a.x, y: clip.bounds.minY + b.y - a.y))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        overlay.needsDisplay = true
    }

    // MARK: Overlay

    private func drawLoupe() {
        guard loupe, let p = loupePoint, let page = page(for: p, nearest: false), let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = CGSize(width: 300, height: 180)
        let r = CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 10; sh.shadowOffset = NSSize(width: 0, height: -3); sh.shadowColor = NSColor.black.withAlphaComponent(0.4); sh.set()
        NSColor.white.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let pp = convert(p, to: page)
        let s = scaleFactor * 2.5
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: s, y: overlay.isFlipped ? -s : s)
        // Seitendrehung berücksichtigen: Punkt unter dem Zeiger bleibt in der Mitte
        let rot = PDFTools.normRotation(page.rotation)
        ctx.rotate(by: -CGFloat(rot) * .pi / 180)
        ctx.translateBy(x: -pp.x, y: -pp.y)
        DrawMode.full { page.draw(with: .cropBox, to: ctx) }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.35).setStroke(); path.lineWidth = 1; path.stroke()
    }

    /// Zeichnet alle eigenen Objekte der sichtbaren Seiten – unabhängig von PDFKits Zwischenspeichern.
    private func drawObjects() {
        guard let d = document, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let visible = overlay.bounds
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            let pr = convert(p.bounds(for: .cropBox), from: p)
            guard pr.intersects(visible) else { continue }
            let anns = p.annotations
            if !anns.contains(where: { $0 is WObject }) { continue }
            // Abbildung Seite → Ansicht (Zoom, Drehung, Lage) aus drei Punkten
            let o = convert(CGPoint.zero, from: p), x = convert(CGPoint(x: 1, y: 0), from: p), y = convert(CGPoint(x: 0, y: 1), from: p)
            let t = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
            ctx.saveGState()
            ctx.clip(to: pr)
            ctx.concatenate(t)
            // In Datei-Reihenfolge: eigene Objekte zeichnen; fremde Anmerkungen (Hervorhebungen), die in der Datei darüber
            // liegen, dort nachzeichnen, wo ein deckendes eigenes Objekt sie sonst verbergen würde
            var opaque: [CGRect] = []
            for a in anns {
                if let w = a as? WObject {
                    guard !w.editing, w.shouldDisplay else { continue }
                    DrawMode.full { w.draw(with: .cropBox, in: ctx) }
                    if w.model.fill != nil || w.model.kind == .image || w.model.kind == .cover { opaque.append(w.bounds) }
                } else if !opaque.isEmpty, a.shouldDisplay, !["Widget", "Link", "Popup"].contains(a.type ?? "") {
                    let hits = opaque.compactMap { r -> CGRect? in let i = r.intersection(a.bounds); return (i.isNull || i.isEmpty) ? nil : i }
                    guard !hits.isEmpty else { continue }
                    ctx.saveGState(); ctx.clip(to: hits); a.draw(with: .cropBox, in: ctx); ctx.restoreGState()
                }
            }
            ctx.restoreGState()
        }
    }

    /// Raster, eigene Hilfslinien und die Vorschau beim Ziehen aus dem Lineal
    private func drawStaticGuides() {
        let st = GuideSettings.shared
        guard let d = document else { return }
        let visible = overlay.bounds
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            let pb = p.bounds(for: .cropBox)
            let pr = convert(pb, from: p)
            guard pr.intersects(visible) else { continue }
            if st.showGrid, st.gridMM > 0 {
                let g = st.gridMM * 72 / 25.4
                guard g * scaleFactor >= 4 else { continue }
                NSColor.systemBlue.withAlphaComponent(0.12).setStroke()
                let path = NSBezierPath(); path.lineWidth = 0.5
                var x = pb.minX; while x <= pb.maxX { let a = convert(CGPoint(x: x, y: pb.minY), from: p), b = convert(CGPoint(x: x, y: pb.maxY), from: p); path.move(to: a); path.line(to: b); x += g }
                var y = pb.minY; while y <= pb.maxY { let a = convert(CGPoint(x: pb.minX, y: y), from: p), b = convert(CGPoint(x: pb.maxX, y: y), from: p); path.move(to: a); path.line(to: b); y += g }
                path.stroke()
            }
            if st.showCustom, let cg = customGuides[i] {
                NSColor.systemCyan.setStroke()
                let path = NSBezierPath(); path.lineWidth = 1
                for x in cg.x { path.move(to: convert(CGPoint(x: x, y: pb.minY), from: p)); path.line(to: convert(CGPoint(x: x, y: pb.maxY), from: p)) }
                for y in cg.y { path.move(to: convert(CGPoint(x: pb.minX, y: y), from: p)); path.line(to: convert(CGPoint(x: pb.maxX, y: y), from: p)) }
                path.stroke()
            }
        }
        if let (horizontal, vp) = previewGuide {
            NSColor.systemCyan.withAlphaComponent(0.7).setStroke()
            let path = NSBezierPath(); path.lineWidth = 1; path.setLineDash([4, 3], count: 2, phase: 0)
            if horizontal { path.move(to: CGPoint(x: 0, y: vp.y)); path.line(to: CGPoint(x: bounds.width, y: vp.y)) }
            else { path.move(to: CGPoint(x: vp.x, y: 0)); path.line(to: CGPoint(x: vp.x, y: bounds.height)) }
            path.stroke()
        }
    }

    func drawOverlay() {
        drawObjects()
        defer { drawLoupe() }
        let accent = NSColor.controlAccentColor
        drawStaticGuides()
        for g in guides {
            NSColor.systemPink.setStroke()
            let p = NSBezierPath(); p.move(to: g.a); p.line(to: g.b); p.lineWidth = 1; p.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.white]
            let sz = (g.label as NSString).size(withAttributes: attrs)
            let vertical = abs(g.a.x - g.b.x) < 0.5
            let box = vertical ? CGRect(x: g.a.x + 4, y: min(g.a.y, g.b.y) + 4, width: sz.width + 8, height: sz.height + 2)
                               : CGRect(x: min(g.a.x, g.b.x) + 4, y: g.a.y + 4, width: sz.width + 8, height: sz.height + 2)
            if box.isUsable { NSColor.systemPink.setFill(); NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill(); (g.label as NSString).draw(at: CGPoint(x: box.minX + 4, y: box.minY + 1), withAttributes: attrs) }
        }
        if let d = drag, case .ink = d.mode, d.inkPoints.count > 1 {
            let p = NSBezierPath()
            p.move(to: convert(d.inkPoints[0], from: d.page))
            d.inkPoints.dropFirst().forEach { p.line(to: convert($0, from: d.page)) }
            (Defaults.model.stroke?.color ?? .black).setStroke()
            p.lineWidth = Defaults.model.lineWidth * scaleFactor
            p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.stroke()
        }
        if tool == .crop, let (page, r) = marquee, r.isUsable {
            let vr = convert(r, from: page)
            let pr = convert(page.bounds(for: .cropBox), from: page)
            let dim = NSBezierPath(rect: pr)
            dim.appendRect(vr)
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill(); dim.fill()
            NSColor.white.setStroke()
            let f = NSBezierPath(rect: vr.insetBy(dx: 0.5, dy: 0.5)); f.lineWidth = 1; f.stroke()
            let xs = [vr.minX, vr.midX, vr.maxX], ys = [vr.minY, vr.midY, vr.maxY]
            for x in xs { for y in ys where !(x == vr.midX && y == vr.midY) {
                let hr = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
                NSColor.white.setFill(); hr.fill()
                let b = NSBezierPath(rect: hr); b.lineWidth = 1; NSColor.black.withAlphaComponent(0.6).setStroke(); b.stroke()
            } }
        } else if let (page, r) = marquee, r.isUsable {
            let vr = convert(r, from: page)
            NSColor.black.withAlphaComponent(0.06).setFill(); vr.fill()
            let p = NSBezierPath(rect: vr.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1; p.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke(); p.stroke()
            p.setLineDash([4, 3], count: 2, phase: 3.5)
            NSColor.black.setStroke(); p.stroke()
        }
        if let om = objectMarquee, om.isUsable {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); om.fill()
            let p = NSBezierPath(rect: om.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1
            NSColor.controlAccentColor.setStroke(); p.stroke()
        }
        if let cs = contentSel, let d = document, let p = d.page(at: cs.pageIndex), cs.bounds.isUsable {
            let b = cs.bounds
            let vr = convert(b, from: p)
            let col = NSColor(srgbRed: 0.85, green: 0.45, blue: 0.05, alpha: 1)
            if cs.indices.count > 1 {
                col.withAlphaComponent(0.6).setStroke()
                for k in cs.indices where cs.model.elements[k].bounds.isUsable { let r = NSBezierPath(rect: convert(cs.model.elements[k].bounds, from: p)); r.lineWidth = 0.5; r.stroke() }
            }
            col.setStroke()
            let f = NSBezierPath(rect: vr.insetBy(dx: -1, dy: -1)); f.lineWidth = 1.5
            if !cs.canMove { f.setLineDash([2, 3], count: 2, phase: 0) }
            f.stroke()
            if contentDragOffset != .zero, contentDragOffset.dx.isFinite, contentDragOffset.dy.isFinite {
                let gv = convert(b.offsetBy(dx: contentDragOffset.dx, dy: contentDragOffset.dy), from: p)
                col.withAlphaComponent(0.15).setFill(); gv.fill()
                let g = NSBezierPath(rect: gv); g.lineWidth = 1; g.setLineDash([4, 3], count: 2, phase: 0); g.stroke()
            }
            // Beschriftung
            let kind = cs.indices.count > 1 ? "\(cs.indices.count) Elemente"
                : (["text": "Text", "path": "Pfad", "image": "Bild", "form": "Gruppe", "inlineImage": "Bild", "shading": "Verlauf"][cs.element.kind.rawValue] ?? "")
            let txt = (kind + (cs.canMove ? " – Ziehen verschiebt, ⌫ löscht" : " – ⌫ löscht (nicht alles verschiebbar)")) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
            let sz = txt.size(withAttributes: attrs)
            let y = isFlipped ? vr.minY - sz.height - 8 : vr.maxY + 6
            let box = CGRect(x: vr.minX, y: y, width: sz.width + 12, height: sz.height + 4)
            col.setFill(); if box.isUsable { NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill() }
            txt.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attrs)
        }
        // Rahmen der weiteren ausgewählten Objekte
        for a in selectedObjects.dropFirst() {
            guard let p = a.page else { continue }
            let rr = convert(a.bounds, from: p).insetBy(dx: -0.5, dy: -0.5)
            accent.setStroke()
            let f = NSBezierPath(rect: rr); f.lineWidth = 1; f.stroke()
        }
        guard let r = selRect, r.isUsable else { return }
        accent.setStroke()
        let frame = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        frame.lineWidth = 1
        if editor != nil || (selected as? WObject)?.model.isLine == true { frame.setLineDash([3, 3], count: 2, phase: 0) }
        frame.stroke()
        for (_, pt) in handlePoints() {
            let hr = CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)
            NSColor.white.setFill(); hr.fill()
            let b = NSBezierPath(rect: hr); b.lineWidth = 1; accent.setStroke(); b.stroke()
        }
        // Hinweis, wenn die Schrift des PDFs auf dem Mac fehlt
        if !isMulti, let w = selected as? WObject, let o = w.model.origFont {
            let ersatz = NSFont(name: w.model.fontName, size: 12)?.displayName ?? w.model.fontName
            let txt = "Ersatzschrift: \(ersatz) – im PDF: \(o)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
            let sz = txt.size(withAttributes: attrs)
            let flipped = isFlipped
            let y = flipped ? r.minY - sz.height - 8 : r.maxY + 6
            let box = CGRect(x: r.minX, y: y, width: sz.width + 12, height: sz.height + 4)
            NSColor(srgbRed: 0.85, green: 0.45, blue: 0.05, alpha: 0.95).setFill()
            if box.isUsable { NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill() }
            txt.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attrs)
        }
    }
}
