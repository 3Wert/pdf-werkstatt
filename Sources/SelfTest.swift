import AppKit
import PDFKit
import CoreImage
import IOSurface

extension Canvas {
    func debugReplaceEditorText(_ s: String) {
        guard let tv = subviews.compactMap({ $0 as? NSTextView }).first else { return }
        tv.string = s
        textDidChange(Notification(name: NSText.didChangeNotification))
    }
}

/// Selbsttest: PDFW_SELFTEST=<Ordner> – bearbeitet das erste Dokument per Skript, macht Fensterbilder und speichert.
enum SelfTest {
    static func runIfRequested() {
        if let dir = ProcessInfo.processInfo.environment["PDFW_REDACT_UITEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { redactUI(dir) }
            return
        }
        guard let dir = ProcessInfo.processInfo.environment["PDFW_SELFTEST"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { step(dir) }
    }

    /// PDFW_REDACT_UITEST=<Ordner> datei.pdf – Schwärzen über die Oberfläche: markieren, anwenden, Abdeckung leeren, widerrufen, sichern
    static func redactUI(_ dir: String) {
        guard let doc = NSDocumentController.shared.documents.first as? WDocument, let wc = doc.controller, let w = wc.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        let c = wc.canvas
        func page() -> PDFPage { doc.pdf.page(at: 0)! }
        func found(_ t: String) -> Bool { !doc.pdf.findString(t, withOptions: [.caseInsensitive]).isEmpty }
        func closeSheet() { if let s = w.attachedSheet { w.endSheet(s) } }
        run([
            { c.go(to: PDFDestination(page: page(), at: CGPoint(x: 0, y: 800)))
              var hits = RedactPatterns.find(in: doc.pdf, pattern: #"DE89\s?3704\s?0044\s?0532\s?0130\s?00"#, isRegex: true, caseSensitive: false)
              hits += RedactPatterns.find(in: doc.pdf, pattern: "Mustermann", isRegex: false, caseSensitive: false)
              for h in hits { guard let p = doc.pdf.page(at: h.page) else { continue }
                  var m = Defaults.newModel(.cover); m.fill = RGBA(.black); m.redact = true
                  c.add(WObject(model: m, bounds: h.rect), to: p, action: "Schwärzen") }
              note("Markiert: \(c.coverMarks(redact: true).count) Schwärzungen aus \(hits.count) Treffern") },
            { c.overlay.display(); shot(wc, dir + "/schwaerzen-1-markiert.png")
              // dazu eine weiße Abdeckung über den Betrag
              if let sel = doc.pdf.findString("1.234,56", withOptions: []).first, let p = sel.pages.first {
                  var m = Defaults.newModel(.cover); m.fill = RGBA(.white)
                  c.add(WObject(model: m, bounds: sel.bounds(for: p).insetBy(dx: -1, dy: -1)), to: p, action: "Abdecken") }
              note("Abdeckungen (weiß): \(c.coverMarks(redact: false).count)") },
            { let ok = wc.applyRedactions(confirm: false); note("Anwenden: \(ok ? "ok" : "FEHLER")") },
            { closeSheet(); c.overlay.display(); shot(wc, dir + "/schwaerzen-2-angewendet.png")
              note("nach Anwenden: Schwärzungen \(c.coverMarks(redact: true).count) (0 erwartet), Abdeckungen \(c.coverMarks(redact: false).count) (1 erwartet), 'Mustermann' auffindbar: \(found("Mustermann")) (false erwartet), 'DE89' auffindbar: \(found("DE89")) (false erwartet), 'Leverkusen' auffindbar: \(found("Leverkusen")) (true erwartet)") },
            { let white = c.coverMarks(redact: false)
              let rep = c.applyRedaction(white, paint: false, removeAnnots: false, action: "Inhalt unter Abdeckung entfernen")
              note("Abdeckung geleert: \(rep?.summary ?? "FEHLER") · Abdeckung noch da: \(c.coverMarks(redact: false).count) (1 erwartet) · '1.234,56' auffindbar: \(found("1.234,56")) (false erwartet) · 'zahlbar' auffindbar: \(found("zahlbar")) (true erwartet)") },
            { w.makeFirstResponder(c); note("vor Widerrufen: canUndo=\(doc.undoManager?.canUndo ?? false) „\(doc.undoManager?.undoMenuItemTitle ?? "")“ Gruppen offen: \(doc.undoManager?.groupingLevel ?? -1)")
              doc.undoManager?.undo() },
            { note("nach 1. Widerrufen: „\(doc.undoManager?.undoMenuItemTitle ?? "")“ Abdeckung: \(c.coverMarks(redact: false).count), '1.234,56': \(found("1.234,56"))")
              doc.undoManager?.undo() },
            { c.overlay.display(); shot(wc, dir + "/schwaerzen-3-widerrufen.png")
              note("nach 2× Widerrufen: Schwärzungen \(c.coverMarks(redact: true).count) (3 erwartet), 'Mustermann' auffindbar: \(found("Mustermann")) (true erwartet), '1.234,56': \(found("1.234,56")) (true erwartet)") },
            { let ok = wc.applyRedactions(confirm: false); note("erneut anwenden: \(ok ? "ok" : "FEHLER")") },
            { closeSheet()
              guard let data = try? doc.data(ofType: "com.adobe.pdf"), let d = PDFDocument(data: data) else { note("Sichern: FEHLER"); return }
              let eof = data.ranges(of: "%%EOF".data(using: .utf8)!).count
              try? data.write(to: URL(fileURLWithPath: dir + "/schwaerzen-gesichert.pdf"))
              note("gesichert: \(data.count / 1024) KB, EOF=\(eof) (1 erwartet), 'Mustermann' auffindbar: \(!d.findString("Mustermann", withOptions: []).isEmpty) (false erwartet), 'DE89': \(!d.findString("DE89", withOptions: []).isEmpty) (false erwartet), Seiten: \(d.pageCount)") },
        ]) { finish(dir) }
    }

    static func shot(_ wc: MainWindowController, _ path: String) {
        guard let v = wc.window?.contentView?.superview ?? wc.window?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static var log = ""
    static func note(_ s: String) { log += s + "\n" }

    static func mouse(_ t: NSEvent.EventType, _ w: NSWindow, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// Echtes Ziehen über das Fenster: Ereignisse in die Warteschlange, Mausklick über sendEvent
    static func dragObject(_ c: Canvas, _ a: PDFAnnotation, by d: CGVector) {
        guard let w = c.window, let p = a.page else { return }
        let v = c.convert(CGPoint(x: a.bounds.midX, y: a.bounds.midY), from: p)
        let start = c.convert(v, to: nil)
        for i in 1...5 {
            w.postEvent(mouse(.leftMouseDragged, w, CGPoint(x: start.x + d.dx * CGFloat(i) / 5, y: start.y + d.dy * CGFloat(i) / 5)), atStart: false)
        }
        w.postEvent(mouse(.leftMouseUp, w, CGPoint(x: start.x + d.dx, y: start.y + d.dy)), atStart: false)
        let hv = w.contentView?.superview?.hitTest(start)
        note("Treffer beim Ziehen: \(String(describing: hv.map { type(of: $0) }))")
        w.sendEvent(mouse(.leftMouseDown, w, start))
    }

    static func key(_ code: UInt16, _ chars: String, _ w: NSWindow) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
        NSApp.postEvent(e, atStart: false)
    }

    static func typeKeys(_ text: String, _ w: NSWindow) {
        for ch in text {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: w.windowNumber, context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch),
                                     isARepeat: false, keyCode: 0)!
            w.sendEvent(e)
        }
    }

    static func pixels(_ wc: MainWindowController) -> [UInt8] {
        let v = wc.canvas
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return [] }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let d = rep.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(start: d, count: rep.bytesPerRow * rep.pixelsHigh))
    }
    static func diff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) } }

    static func dump(_ v: NSView, _ depth: Int = 0, into out: inout [String]) {
        let l = v.layer
        let subl = l?.sublayers?.count ?? 0
        out.append(String(repeating: "  ", count: depth) + "\(type(of: v)) frame=\(Int(v.frame.minX)),\(Int(v.frame.minY)) \(Int(v.frame.width))x\(Int(v.frame.height)) layer=\(l.map { String(describing: type(of: $0)) } ?? "-") sublayers=\(subl) contents=\(l?.contents != nil)")
        if let ls = l?.sublayers {
            for sl in ls where sl.delegate == nil || !(sl.delegate is NSView) {
                out.append(String(repeating: "  ", count: depth + 1) + "· Layer \(type(of: sl)) frame=\(Int(sl.frame.minX)),\(Int(sl.frame.minY)) \(Int(sl.frame.width))x\(Int(sl.frame.height)) contents=\(sl.contents != nil) subl=\(sl.sublayers?.count ?? 0)")
                for s2 in sl.sublayers ?? [] { out.append(String(repeating: "  ", count: depth + 2) + "·· \(type(of: s2)) frame=\(Int(s2.frame.minX)),\(Int(s2.frame.minY)) \(Int(s2.frame.width))x\(Int(s2.frame.height)) contents=\(s2.contents != nil)") }
            }
        }
        for sv in v.subviews { dump(sv, depth + 1, into: &out) }
    }

    /// Liest die gerenderten Bilder aus den Ebenen der Seitenansicht – das ist, was wirklich auf dem Bildschirm steht.
    static func pageLayerImages(_ v: NSView) -> [CGImage] {
        var out: [CGImage] = []
        func walk(_ l: CALayer) {
            if let c = l.contents {
                if CFGetTypeID(c as CFTypeRef) == CGImage.typeID { out.append(c as! CGImage) }
                else if CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() {
                    let ci = CIImage(ioSurface: c as! IOSurface)
                    if let cg = CIContext().createCGImage(ci, from: ci.extent) { out.append(cg) }
                }
            }
            l.sublayers?.forEach(walk)
        }
        func views(_ v: NSView) {
            if String(describing: type(of: v)) == "PDFPageView", let l = v.layer { walk(l) }
            v.subviews.forEach(views)
        }
        views(v)
        return out
    }
    static func save(_ imgs: [CGImage], _ base: String) {
        for (i, im) in imgs.enumerated() {
            try? NSBitmapImageRep(cgImage: im).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "_\(i).png"))
        }
    }

    /// Jeder Schritt läuft wie eine eigene Benutzeraktion: eigene Widerrufen-Gruppe, danach Ereignisschleife laufen lassen.
    static func run(_ steps: [() -> Void], then done: @escaping () -> Void) {
        var i = 0
        func next() {
            guard i < steps.count else { done(); return }
            let st = steps[i]; i += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { st(); next() }
        }
        next()
    }

    static func popoverButton(_ title: String? = nil, id: String? = nil) -> NSButton? {
        for win in NSApp.windows.reversed() where win.className.contains("Popover") && win.isVisible {
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, (id != nil && b.identifier?.rawValue == id) || (title != nil && b.title == title) { return b }
                for sv in v.subviews { if let f = find(sv) { return f } }
                return nil
            }
            if let cv = win.contentView, let b = find(cv) { return b }
        }
        return nil
    }

    static func cmdZ(_ w: NSWindow) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        NSApp.postEvent(e, atStart: false)
    }

    static func step(_ dir: String) {
        guard let doc = NSDocumentController.shared.documents.first as? WDocument, let wc = doc.controller, let w = wc.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        let c = wc.canvas
        func page() -> PDFPage { doc.pdf.page(at: 0)! }
        func lb(_ t: String) -> CGRect? { doc.pdf.findString(t, withOptions: []).first.map { $0.bounds(for: $0.pages.first!) } }
        func baseline(_ t: String) -> CGFloat {
            let sel = doc.pdf.findString(t, withOptions: []).first!
            let f = sel.attributedString!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            return sel.bounds(for: page()).minY - f.descender
        }
        var t1: WObject!, t2: WObject!
        GuideSettings.shared = GuideSettings()   // Standardwerte
        GuideSettings.shared.tolerance = 14      // Test: 3 pt Abstand bei 4× Zoom = 12 px
        func find(_ text: String) -> WObject? { page().annotations.compactMap { $0 as? WObject }.first { $0.model.text == text } }
        run([
            { c.go(to: PDFDestination(page: page(), at: CGPoint(x: 0, y: 760))) },
            { // Textfeld mit derselben Schrift wie die Zeile "Rechnungsdatum" anlegen, versetzt platzieren
              var m = Defaults.newModel(.text); m.text = "Rechnungsdatum: 16.10.2026"; m.fontName = "ArialMT"; m.fontSize = 11
              t1 = WObject(model: m, bounds: CGRect(x: 300, y: 600, width: 10, height: 10)); c.add(t1, to: page(), action: "Text"); t1.fitBounds()
              let target = lb("Rechnungsdatum")!
              // nach links/oben in die Nähe der PDF-Zeile ziehen: 3 pt daneben, 3 pt zu hoch
              let goalX = target.minX - pad + 3, goalBase = baseline("Rechnungsdatum") + 3
              let dx = goalX - t1.bounds.minX, dy = goalBase - t1.firstBaselineY
              let s = c.scaleFactor
              dragObject(c, t1, by: CGVector(dx: dx * s, dy: (c.isFlipped ? -dy : dy) * s))
              note("Feld 1 an PDF-Zeile: linke Kante Δ \(String(format: "%.2f", t1.bounds.minX + pad - target.minX)) pt, Grundlinie Δ \(String(format: "%.2f", t1.firstBaselineY - baseline("Rechnungsdatum"))) pt (beide ≈ 0 = eingerastet)") },
            { // zweites Feld darunter: Zeilenabstand der PDF-Zeilen "Sehr geehrte"/"für die" ist der Maßstab
              let g1 = baseline("Sehr geehrte"), g2 = baseline("für die Hausmeister")
              let spacing = g1 - g2
              var m = Defaults.newModel(.text); m.text = "Zweite Zeile"; m.fontName = "ArialMT"; m.fontSize = 11
              t2 = WObject(model: m, bounds: CGRect(x: 300, y: 500, width: 10, height: 10)); c.add(t2, to: page(), action: "Text"); t2.fitBounds()
              let lbLeist = lb("Leistungszeitraum")!
              let g3 = baseline("Leistungszeitraum")
              let goalBase = g3 - spacing + 2.5        // eine Zeile unter der letzten Brieftextzeile, 2,5 pt daneben
              let dx = (lbLeist.minX - pad + 2) - t2.bounds.minX, dy = goalBase - t2.firstBaselineY
              let s = c.scaleFactor
              dragObject(c, t2, by: CGVector(dx: dx * s, dy: (c.isFlipped ? -dy : dy) * s))
              note("Feld 2 unter den Brieftext: Grundlinie Δ zum Zeilenabstand \(String(format: "%.2f", t2.firstBaselineY - (g3 - spacing))) pt, linke Kante Δ \(String(format: "%.2f", t2.bounds.minX + pad - lbLeist.minX)) pt") },
            { // PDF-Inhalt verschieben: Überschrift rastet mit linker Kante an "Rechnungsdatum" ein
              c.tool = .editText
              let r = lb("Rechnung Nr.")!
              _ = c.selectContent(at: CGPoint(x: r.midX, y: r.midY), on: page())
              let before = c.contentSel!.bounds
              let line = lb("Rechnung Nr.")!                     // exakte Zeilenmaße als Bezug
              let target = lb("Rechnungsdatum")!
              let a = c.convert(c.convert(CGPoint(x: before.midX, y: before.midY), from: page()), to: nil)
              let s = c.scaleFactor
              let b = CGPoint(x: a.x + (target.minX - line.minX + 3) * s, y: a.y)
              for i in 1...5 { w.postEvent(mouse(.leftMouseDragged, w, CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 5, y: a.y)), atStart: false) }
              w.postEvent(mouse(.leftMouseUp, w, b), atStart: false); w.sendEvent(mouse(.leftMouseDown, w, a))
              let after = lb("Rechnung Nr.")!
              note("PDF-Inhalt verschoben: linke Kante Δ zu 'Rechnungsdatum' \(String(format: "%.2f", after.minX - target.minX)) pt (≈ 0 = eingerastet)") },
            { // Eigene Hilfslinie bei x = 400 anlegen, Feld 1 darauf ziehen (3 pt daneben loslassen)
              c.tool = .textSelect
              t1 = find("Rechnungsdatum: 16.10.2026")      // nach dem Inhalts-Eingriff sind alle Objekte neue Instanzen
              c.addCustomGuide(horizontal: false, atView: c.convert(CGPoint(x: 400, y: 500), from: page()))
              let dx = (400 + 3) - (t1.bounds.minX + pad)      // Textkante 3 pt neben der Hilfslinie
              dragObject(c, t1, by: CGVector(dx: dx * c.scaleFactor, dy: 0))
              note("Eigene Hilfslinie x=400: Textkante \(String(format: "%.2f", t1.bounds.minX + pad)) (400 = eingerastet), gespeichert: \(c.customGuides[0]?.x ?? [])") },
            { // ⌘ gedrückt → kein Einrasten
              let a = c.convert(c.convert(CGPoint(x: t1.bounds.midX, y: t1.bounds.midY), from: page()), to: nil)
              let b = CGPoint(x: a.x - 3 * c.scaleFactor, y: a.y)
              let down = NSEvent.mouseEvent(with: .leftMouseDown, location: a, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
              for i in 1...4 { w.postEvent(NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 4, y: a.y), modifierFlags: [.command], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false) }
              w.postEvent(mouse(.leftMouseUp, w, b), atStart: false); w.sendEvent(down)
              note("mit ⌘ gezogen: Textkante \(String(format: "%.2f", t1.bounds.minX + pad)) (≈ 397 = nicht eingerastet)") },
            { GuideSettings.shared.showRulers = true; GuideSettings.shared.showGrid = true; wc.applyGuideSettings(); c.overlay.display()
              note("Lineale und Raster an, gezeichnet ohne Absturz") },
            { GuideSettings.shared = GuideSettings(); wc.applyGuideSettings() },
        ]) { finish(dir) }
    }

    static func finish(_ dir: String) {
        prefs.removePersistentDomain(forName: "de.marlonelsner.pdf-werkstatt.selbsttest")
        try? log.write(toFile: dir + "/ergebnis.txt", atomically: true, encoding: .utf8)
        NSDocumentController.shared.documents.forEach { $0.updateChangeCount(.changeCleared) }
        NSApp.terminate(nil)
    }
}
