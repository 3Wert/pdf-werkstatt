import AppKit
import PDFKit
import UniformTypeIdentifiers

struct PageNumberSettings: Codable {
    var position = 1          // 0–2 unten links/mitte/rechts, 3–5 oben, 6 unten außen
    var format = "{n}"
    var start = 1
    var firstPage = 1
    var fontSize: CGFloat = 10
    var margin: CGFloat = 12  // mm
    var fontName = "ArialMT"

    static func load() -> PageNumberSettings {
        guard let d = prefs.data(forKey: "seitenzahlen"),
              let s = try? JSONDecoder().decode(PageNumberSettings.self, from: d) else { return PageNumberSettings() }
        return s
    }
    func save() { if let d = try? JSONEncoder().encode(self) { prefs.set(d, forKey: "seitenzahlen") } }
}

private func grid(_ rows: [[NSView]]) -> NSGridView {
    let g = NSGridView(views: rows)
    g.rowSpacing = 8
    g.columnSpacing = 10
    g.column(at: 0).xPlacement = .trailing
    return g
}

private func lbl(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

private func field(_ v: String, width: CGFloat = 70) -> NSTextField {
    let f = NSTextField(string: v)
    f.widthAnchor.constraint(equalToConstant: width).isActive = true
    return f
}

enum Dialogs {
    static func askPassword(file: String) -> String? {
        let a = NSAlert()
        a.messageText = "„\(file)“ ist mit einem Passwort geschützt."
        a.informativeText = "Bitte Passwort eingeben."
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Öffnen")
        a.addButton(withTitle: "Abbrechen")
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    // MARK: Seitenzahlen

    static func pageNumbers(window: NSWindow, canvas: Canvas) {
        var s = PageNumberSettings.load()
        let a = NSAlert()
        a.messageText = "Seitenzahlen"
        a.informativeText = "Die Zahlen passen sich an, wenn du später Seiten verschiebst, löschst oder einfügst."

        let pos = NSPopUpButton()
        pos.addItems(withTitles: ["Unten links", "Unten mittig", "Unten rechts", "Oben links", "Oben mittig", "Oben rechts", "Unten außen (Buchdruck)"])
        pos.selectItem(at: s.position)
        let fmt = NSComboBox()
        fmt.addItems(withObjectValues: ["{n}", "Seite {n}", "Seite {n} von {N}", "{n} / {N}", "– {n} –"])
        fmt.stringValue = s.format
        fmt.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let start = field("\(s.start)")
        let first = field("\(s.firstPage)")
        let size = field(String(format: "%g", s.fontSize))
        let margin = field(String(format: "%g", s.margin))
        let fonts = ["ArialMT", "Arial-BoldMT", "Helvetica", "TimesNewRomanPSMT", "BebasNeue", "Georgia", "Verdana", "CourierNewPSMT"]
            .filter { NSFont(name: $0, size: 10) != nil }
        let font = NSPopUpButton()
        font.addItems(withTitles: fonts.map { NSFont(name: $0, size: 10)?.displayName ?? $0 })
        if let i = fonts.firstIndex(of: s.fontName) { font.selectItem(at: i) }
        let help = NSTextField(wrappingLabelWithString: "{n} = Seitenzahl, {N} = Gesamtzahl")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor

        let g = grid([
            [lbl("Position:"), pos],
            [lbl("Format:"), fmt],
            [NSGridCell.emptyContentView, help],
            [lbl("Nummerieren ab Seite:"), first],
            [lbl("Erste Zahl:"), start],
            [lbl("Schrift:"), font],
            [lbl("Größe (pt):"), size],
            [lbl("Abstand zum Rand (mm):"), margin],
        ])
        g.frame = NSRect(x: 0, y: 0, width: 400, height: g.fittingSize.height)
        a.accessoryView = g
        a.addButton(withTitle: "Hinzufügen")
        a.addButton(withTitle: "Abbrechen")
        let hasNumbers = canvas.hasPageNumbers
        if hasNumbers { a.addButton(withTitle: "Alle entfernen") }
        a.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn {
                s.position = pos.indexOfSelectedItem
                s.format = fmt.stringValue.isEmpty ? "{n}" : fmt.stringValue
                s.start = Int(start.stringValue) ?? 1
                s.firstPage = max(1, Int(first.stringValue) ?? 1)
                s.fontSize = CGFloat(Double(size.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 10)
                s.margin = CGFloat(Double(margin.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 12)
                if font.indexOfSelectedItem >= 0 { s.fontName = fonts[font.indexOfSelectedItem] }
                s.save()
                canvas.applyPageNumbers(s)
            } else if r == .alertThirdButtonReturn {
                canvas.removePageNumbers()
            }
        }
    }

    // MARK: Unterschrift

    static var signatureDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PDF-Werkstatt/Unterschriften")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // alte Einzel-Unterschrift übernehmen
        let old = dir.deletingLastPathComponent().appendingPathComponent("unterschrift.png")
        if FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir.appendingPathComponent("unterschrift-1.png"))
        }
        return dir
    }

    static var signatures: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: signatureDir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static var signatureURL: URL {
        signatureDir.appendingPathComponent("unterschrift-\(Int(Date().timeIntervalSince1970)).png")
    }

    static func drawSignature(window: NSWindow, done: @escaping (Data) -> Void) {
        let a = NSAlert()
        a.messageText = "Unterschrift"
        a.informativeText = "Mit Maus oder Trackpad unterschreiben. Die Unterschrift wird für später gespeichert."
        let pad = SignaturePad(frame: NSRect(x: 0, y: 0, width: 460, height: 170))
        let clear = NSButton(title: "Neu beginnen", target: pad, action: #selector(SignaturePad.clear))
        clear.controlSize = .small
        let stack = NSStackView(views: [pad, clear])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 200)
        pad.widthAnchor.constraint(equalToConstant: 460).isActive = true
        pad.heightAnchor.constraint(equalToConstant: 170).isActive = true
        a.accessoryView = stack
        a.addButton(withTitle: "Einfügen")
        a.addButton(withTitle: "Abbrechen")
        a.addButton(withTitle: "Aus Bild laden …")
        a.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn, let d = pad.pngData() {
                try? d.write(to: signatureURL)
                done(d)
            } else if r == .alertThirdButtonReturn {
                DispatchQueue.main.async { signatureFromImage(window: window, done: done) }
            }
        }
    }

    static func signatureFromImage(window: NSWindow, done: @escaping (Data) -> Void) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "Foto oder Scan der Unterschrift auf weißem Papier wählen – der Hintergrund wird entfernt."
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let u = p.url, let d = try? Data(contentsOf: u), let clean = PDFTools.removeWhite(d) else { return }
            try? clean.write(to: signatureURL)
            done(clean)
        }
    }

    static func signatureFromCamera(window: NSWindow, done: @escaping (Data) -> Void) {
        CameraSignature.present(on: window) { data in
            guard let clean = PDFTools.removeWhite(data) else { NSSound.beep(); return }
            try? clean.write(to: signatureURL)
            done(clean)
        }
    }

    // MARK: Export

    static func export(window: NSWindow, doc: WDocument) {
        doc.controller?.canvas.endEditing()
        let panel = NSSavePanel()
        let acc = ExportAccessory(panel: panel, base: (doc.displayName as NSString).deletingPathExtension)
        panel.accessoryView = acc.view
        panel.isExtensionHidden = false
        acc.update()
        panel.beginSheetModal(for: window) { r in
            _ = acc
            guard r == .OK, let url = panel.url else { return }
            let pw = acc.password.stringValue
            let pdf = doc.pdf!
            var format = acc.format.indexOfSelectedItem
            if format <= 2 {
                switch SendCheck.run(doc: doc, window: window, verb: "Exportieren") {
                case .cancel: return
                case .rasterize: format = 3
                case .proceed: break
                }
            }
            switch format {
            case 0:
                pdf.dataRepresentation(options: PDFTools.writeOptions(password: pw))
                    .map { try? $0.write(to: url) }
            case 1:
                var o = PDFTools.writeOptions(password: pw)
                o[.saveImagesAsJPEGOption] = true
                o[.optimizeImagesForScreenOption] = true
                PDFTools.snapshot(pdf).write(to: url, withOptions: o)
            case 2:
                PDFDocument(data: PDFTools.flattened(pdf))?.write(to: url, withOptions: PDFTools.writeOptions(password: pw))
            case 3:
                PDFDocument(data: PDFTools.rasterized(pdf, dpi: acc.dpiValue))?.write(to: url, withOptions: PDFTools.writeOptions(password: pw))
            default:
                let snap = PDFTools.snapshot(pdf)
                let idx = doc.controller?.canvas.currentPage.map { pdf.index(for: $0) } ?? 0
                guard let p = snap.page(at: idx), let img = PDFTools.render(p, dpi: acc.dpiValue) else { return }
                let rep = NSBitmapImageRep(cgImage: img)
                let jpeg = format == 5
                try? rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.9] : [:])?.write(to: url)
            }
        }
    }
}

final class ExportAccessory: NSObject {
    let view: NSView
    let format = NSPopUpButton()
    let password = NSSecureTextField()
    let dpi = NSPopUpButton()
    static let dpis: [CGFloat] = [150, 200, 300, 400, 600]
    var dpiValue: CGFloat { Self.dpis[max(0, dpi.indexOfSelectedItem)] }
    private weak var panel: NSSavePanel?
    private let base: String

    init(panel: NSSavePanel, base: String) {
        self.panel = panel
        self.base = base
        format.addItems(withTitles: ["PDF",
                                     "PDF – Dateigröße reduzieren",
                                     "PDF – flach (Objekte fest im Inhalt)",
                                     "PDF – als Bild (abgedeckter Text ist wirklich weg)",
                                     "PNG – aktuelle Seite",
                                     "JPEG – aktuelle Seite"])
        password.placeholderString = "optional"
        password.widthAnchor.constraint(equalToConstant: 200).isActive = true
        dpi.addItems(withTitles: ["150 dpi – Bildschirm/Mail", "200 dpi", "300 dpi – Druck", "400 dpi", "600 dpi – sehr groß"])
        dpi.selectItem(at: Self.dpis.firstIndex(of: CGFloat(prefs.integer(forKey: "exportDpi") == 0 ? 300 : prefs.integer(forKey: "exportDpi"))) ?? 2)
        let g = grid([[lbl("Format:"), format], [lbl("Auflösung:"), dpi], [lbl("Passwort:"), password]])
        g.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 110))
        v.addSubview(g)
        NSLayoutConstraint.activate([g.centerXAnchor.constraint(equalTo: v.centerXAnchor), g.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        view = v
        super.init()
        format.target = self
        format.action = #selector(update)
        dpi.target = self
        dpi.action = #selector(dpiChanged)
    }

    @objc func dpiChanged() { prefs.set(Int(dpiValue), forKey: "exportDpi") }

    @objc func update() {
        let i = format.indexOfSelectedItem
        let ext = i == 4 ? "png" : i == 5 ? "jpg" : "pdf"
        panel?.allowedContentTypes = [i == 4 ? .png : i == 5 ? .jpeg : .pdf]
        password.isEnabled = i <= 3
        dpi.isEnabled = i >= 3
        let suffix = i == 1 ? " (klein)" : i == 2 ? " (flach)" : i == 3 ? " (Bild)" : ""
        panel?.nameFieldStringValue = base + suffix + "." + ext
    }
}

final class SignaturePad: NSView {
    private var strokes: [[CGPoint]] = []

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let base = NSBezierPath()
        base.move(to: CGPoint(x: 30, y: 45)); base.line(to: CGPoint(x: bounds.maxX - 30, y: 45))
        NSColor.tertiaryLabelColor.setStroke(); base.lineWidth = 1; base.stroke()
        path(scale: 1, offset: .zero).stroke()
    }

    private func path(scale: CGFloat, offset: CGPoint) -> NSBezierPath {
        let p = NSBezierPath()
        for s in strokes where !s.isEmpty {
            let pts = s.map { CGPoint(x: ($0.x - offset.x) * scale, y: ($0.y - offset.y) * scale) }
            p.move(to: pts[0])
            if pts.count == 1 { p.line(to: CGPoint(x: pts[0].x + 0.5, y: pts[0].y)) }
            for i in 1..<max(1, pts.count) {
                let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                p.curve(to: mid, controlPoint1: pts[i - 1], controlPoint2: pts[i - 1])
            }
            if let l = pts.last { p.line(to: l) }
        }
        p.lineWidth = 2.2 * scale
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        NSColor(srgbRed: 0.05, green: 0.1, blue: 0.35, alpha: 1).setStroke()
        return p
    }

    override func mouseDown(with e: NSEvent) { strokes.append([convert(e.locationInWindow, from: nil)]); needsDisplay = true }
    override func mouseDragged(with e: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(e.locationInWindow, from: nil)); needsDisplay = true
    }

    @objc func clear() { strokes = []; needsDisplay = true }

    func pngData() -> Data? {
        let all = strokes.flatMap { $0 }
        guard let f = all.first else { return nil }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in all { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let m: CGFloat = 4, s: CGFloat = 4
        let w = Int((maxX - minX + 2 * m) * s), h = Int((maxY - minY + 2 * m) * s)
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        path(scale: s, offset: CGPoint(x: minX - m, y: minY - m)).stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
