import AppKit
import PDFKit

// MARK: Kontaktbogen (alle Seiten als Raster)

final class ContactSheet: NSScrollView {
    var onPick: ((PDFPage) -> Void)?
    private let grid = FlippedView()
    private weak var doc: PDFDocument?

    final class FlippedView: NSView { override var isFlipped: Bool { true } }

    final class Tile: NSView {
        let page: PDFPage
        var onPick: ((PDFPage) -> Void)?
        private let image = NSImageView()
        private let label = NSTextField(labelWithString: "")
        init(page: PDFPage, number: Int) {
            self.page = page
            super.init(frame: .zero)
            image.image = DrawMode.full { page.thumbnail(of: NSSize(width: 360, height: 460), for: .cropBox) }
            image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true
            image.layer?.shadowOpacity = 0.25; image.layer?.shadowRadius = 3; image.layer?.shadowOffset = CGSize(width: 0, height: -1)
            label.stringValue = "\(number)"
            label.alignment = .center
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            addSubview(image); addSubview(label)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override func layout() {
            image.frame = NSRect(x: 6, y: 6, width: bounds.width - 12, height: bounds.height - 30)
            label.frame = NSRect(x: 0, y: bounds.height - 20, width: bounds.width, height: 16)
        }
        override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { onPick?(page) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        backgroundColor = .underPageBackgroundColor
        drawsBackground = true
        documentView = grid
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(relayout), name: NSView.frameDidChangeNotification, object: self)
    }
    required init?(coder: NSCoder) { nil }

    func reload(_ d: PDFDocument?) {
        doc = d
        grid.subviews.forEach { $0.removeFromSuperview() }
        guard let d else { return }
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            let t = Tile(page: p, number: i + 1)
            t.onPick = { [weak self] p in self?.onPick?(p) }
            grid.addSubview(t)
        }
        relayout()
    }

    @objc private func relayout() {
        let w = contentSize.width
        let tileW: CGFloat = 170, tileH: CGFloat = 230, gap: CGFloat = 16
        let cols = max(1, Int((w - gap) / (tileW + gap)))
        let x0 = (w - CGFloat(cols) * (tileW + gap) + gap) / 2
        for (i, v) in grid.subviews.enumerated() {
            v.frame = NSRect(x: x0 + CGFloat(i % cols) * (tileW + gap), y: gap + CGFloat(i / cols) * (tileH + gap), width: tileW, height: tileH)
        }
        let rows = (grid.subviews.count + cols - 1) / cols
        grid.frame = NSRect(x: 0, y: 0, width: w, height: max(contentSize.height, gap + CGFloat(rows) * (tileH + gap)))
    }
}

// MARK: Informationen (Werkzeuge › Informationen einblenden)

final class InfoPanel: NSPanel {
    private weak var doc: WDocument?
    private let fields: [(PDFDocumentAttribute, String)] = [(.titleAttribute, "Titel"), (.authorAttribute, "Autor"),
                                                             (.subjectAttribute, "Thema"), (.keywordsAttribute, "Schlüsselwörter")]
    private var edits: [PDFDocumentAttribute: NSTextField] = [:]
    private let facts = NSTextField(wrappingLabelWithString: "")

    init(doc: WDocument) {
        self.doc = doc
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320), styleMask: [.titled, .closable, .utilityWindow, .resizable],
                   backing: .buffered, defer: false)
        title = "Informationen – \(doc.displayName ?? "")"
        isFloatingPanel = true
        hidesOnDeactivate = true
        var rows: [[NSView]] = []
        for (k, t) in fields {
            let f = NSTextField()
            f.target = self; f.action = #selector(changed(_:))
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            edits[k] = f
            rows.append([NSTextField(labelWithString: t + ":"), f])
        }
        let g = NSGridView(views: rows)
        g.column(at: 0).xPlacement = .trailing
        g.rowSpacing = 6
        facts.font = .systemFont(ofSize: 11)
        facts.textColor = .secondaryLabelColor
        let v = NSStackView(views: [g, NSBox.separatorLine(), facts])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 12
        v.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        contentView = v
        center()
    }

    func refresh() {
        guard let d = doc, let pdf = d.pdf else { return }
        let attrs = pdf.documentAttributes ?? [:]
        for (k, _) in fields { edits[k]?.stringValue = (attrs[k] as? String) ?? ((attrs[k] as? [String])?.joined(separator: ", ") ?? "") }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short; df.locale = Locale(identifier: "de_DE")
        var lines: [String] = []
        if let u = d.fileURL {
            lines.append("Datei: \(u.path)")
            if let s = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                lines.append("Größe: " + ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))
            }
        }
        lines.append("Seiten: \(pdf.pageCount)")
        if let p = pdf.page(at: 0) {
            let b = p.bounds(for: .cropBox)
            lines.append(String(format: "Seitengröße: %.0f × %.0f mm", b.width * 25.4 / 72, b.height * 25.4 / 72))
        }
        if let c = attrs[PDFDocumentAttribute.creatorAttribute] as? String { lines.append("Programm: \(c)") }
        if let c = attrs[PDFDocumentAttribute.producerAttribute] as? String { lines.append("Erzeugt mit: \(c)") }
        if let c = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date { lines.append("Erstellt: " + df.string(from: c)) }
        if let c = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date { lines.append("Geändert: " + df.string(from: c)) }
        lines.append("PDF-Version: \(pdf.majorVersion).\(pdf.minorVersion)")
        lines.append("Verschlüsselt: " + (pdf.isEncrypted || d.password != nil ? "ja" : "nein"))
        facts.stringValue = lines.joined(separator: "\n")
    }

    @objc private func changed(_ f: NSTextField) {
        guard let d = doc, let pdf = d.pdf, let key = edits.first(where: { $0.value === f })?.key else { return }
        var attrs = pdf.documentAttributes ?? [:]
        let old = attrs[key]
        if key == .keywordsAttribute {
            attrs[key] = f.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else { attrs[key] = f.stringValue }
        pdf.documentAttributes = attrs
        d.undoManager?.registerUndo(withTarget: pdf) { p in
            var a = p.documentAttributes ?? [:]; a[key] = old; p.documentAttributes = a
        }
        d.undoManager?.safeActionName("Informationen")
    }
}

// MARK: Diashow

final class Slideshow: NSWindow {
    private static var current: Slideshow?
    private let view = SlideView()

    final class SlideView: PDFView {
        override func keyDown(with e: NSEvent) {
            switch e.keyCode {
            case 53: (window as? Slideshow)?.stop()
            case 124, 125, 49, 121: goToNextPage(nil)
            case 123, 126, 116: goToPreviousPage(nil)
            default: super.keyDown(with: e)
            }
        }
        override func mouseDown(with e: NSEvent) { goToNextPage(nil) }
    }

    static func start(_ d: PDFDocument, at page: PDFPage?) {
        guard let screen = NSScreen.main else { return }
        let w = Slideshow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .black
        w.view.document = d
        w.view.displayMode = .singlePage
        w.view.autoScales = true
        w.view.displaysPageBreaks = false
        w.view.backgroundColor = .black
        w.contentView = w.view
        if let page { w.view.go(to: page) }
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(w.view)
        NSCursor.setHiddenUntilMouseMoves(true)
        current = w
    }

    override var canBecomeKey: Bool { true }

    func stop() {
        orderOut(nil)
        Slideshow.current = nil
    }
}
