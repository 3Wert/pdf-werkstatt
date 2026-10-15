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
        guard let dir = ProcessInfo.processInfo.environment["PDFW_SELFTEST"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { step(dir) }
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
        func text() -> String { (page().string ?? "").replacingOccurrences(of: "\n", with: " | ") }
        func lb(_ t: String) -> CGRect? { doc.pdf.findString(t, withOptions: []).first.map { $0.bounds(for: $0.pages.first!) } }
        func winPt(_ pp: CGPoint) -> CGPoint { c.convert(c.convert(pp, from: page()), to: nil) }
        func drag(_ a: CGPoint, _ b: CGPoint) {
            for i in 1...5 { w.postEvent(mouse(.leftMouseDragged, w, CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 5, y: a.y + (b.y - a.y) * CGFloat(i) / 5)), atStart: false) }
            w.postEvent(mouse(.leftMouseUp, w, b), atStart: false); w.sendEvent(mouse(.leftMouseDown, w, a))
        }
        func screenColor(_ pp: CGPoint) -> String {
            let rep = c.bitmapImageRepForCachingDisplay(in: c.bounds)!; c.cacheDisplay(in: c.bounds, to: rep)
            let v = c.convert(pp, from: page())
            let px = Int(v.x * CGFloat(rep.pixelsWide) / c.bounds.width), py = Int((c.isFlipped ? v.y : c.bounds.height - v.y) * CGFloat(rep.pixelsHigh) / c.bounds.height)
            return rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)?.hexString ?? "?"
        }
        var t0 = Date()
        run([
            { c.go(to: PDFDestination(page: page(), at: CGPoint(x: 0, y: 820))) },
            // 1. Zwischenspeicher der Bytes
            { t0 = Date(); _ = doc.currentData(); let a = Date().timeIntervalSince(t0); t0 = Date(); _ = doc.currentData(); let b = Date().timeIntervalSince(t0)
              note("currentData: 1. Aufruf \(Int(a * 1000)) ms, 2. Aufruf \(String(format: "%.2f", b * 1000)) ms (Zwischenspeicher)") },
            // 2. Vorab-Vermessung beim Werkzeugwechsel
            { c.tool = .editText },
            { t0 = Date()
              let r = lb("Rechnungsdatum")!
              _ = c.selectContent(at: CGPoint(x: r.midX, y: r.midY), on: page())
              note("Klick nach Vorab-Vermessung: \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000)) ms, ausgewählt: \(c.contentSel?.element.name ?? "nichts")"); c.clearContentSelection() },
            // 3. Bereich auswählen: drei Brieftext-Zeilen
            { c.tool = .rectSelect
              let r1 = lb("Sehr geehrte")!, r3 = lb("Leistungszeitraum")!
              let u = r1.union(r3).insetBy(dx: -6, dy: -4)
              let x2 = u.maxX + 140
              drag(winPt(CGPoint(x: u.minX, y: u.maxY)), winPt(CGPoint(x: x2, y: u.minY))) },
            { note("Bereich: \(c.contentSel?.indices.count ?? 0) Elemente ausgewählt") },
            { guard let (_, mr) = c.marquee else { note("FEHLER kein Rahmen"); return }
              let before = lb("Sehr geehrte")!
              drag(winPt(CGPoint(x: mr.midX, y: mr.midY)), winPt(CGPoint(x: mr.midX + 40, y: mr.midY - 60)))
              let after = lb("Sehr geehrte") ?? .zero
              note("Bereich verschoben: Δx \(Int(after.minX - before.minX)), Δy \(Int(after.minY - before.minY)) (erwartet 40/−60), noch ausgewählt: \(c.contentSel?.indices.count ?? 0)") },
            { key(51, "\u{7f}", w) },
            { note("Bereich ⌫: 'Sehr geehrte' noch da: \(text().contains("Sehr geehrte")), 'Leistungszeitraum' noch da: \(text().contains("Leistungszeitraum"))") },
            { cmdZ(w) },
            { cmdZ(w) },
            { note("2× ⌘Z: Text zurück: \(text().contains("Sehr geehrte")), an alter Stelle: \(Int(lb("Sehr geehrte")?.minY ?? 0))") },
            // 4. Abdecken → vor dem Versenden wirklich entfernen
            { c.tool = .textSelect
              let r = lb("Rechnungsdatum: 12.10.2025")!
              var m = Defaults.newModel(.cover); m.fill = RGBA(.white)
              c.add(WObject(model: m, bounds: r.insetBy(dx: -2, dy: -2)), to: page(), action: "Abdecken")
              let g = lb("Gesamtbetrag")!
              c.add(WObject(model: m, bounds: CGRect(x: g.minX, y: g.minY, width: g.width * 0.3, height: g.height)), to: page(), action: "Abdecken")
              note("Abdeckungen: \(SendCheck.covers(doc.pdf).count), Text im PDF noch da: \(text().contains("Rechnungsdatum"))") },
            { let (r, part) = c.removeContentUnderCovers()
              note("Unter Abdeckung entfernt: \(r), teilweise: \(part); 'Rechnungsdatum' noch im PDF: \(text().contains("Rechnungsdatum")), 'Gesamtbetrag' noch da (nur teilweise abgedeckt): \(text().contains("Gesamtbetrag")), Abdeckungen erhalten: \(SendCheck.covers(doc.pdf).count)") },
            // 5. Ebenen auf dem Bildschirm: rotes Rechteck, darüber Hervorhebung
            { let r = lb("Sehr geehrte")!
              var m = Defaults.newModel(.rect); m.fill = RGBA(NSColor(hex: "9FCFFF")); m.stroke = nil
              c.add(WObject(model: m, bounds: r.insetBy(dx: -4, dy: -4)), to: page(), action: "Rechteck")
              let ohne = screenColor(CGPoint(x: r.maxX - 3, y: r.midY))
              let h = PDFAnnotation(bounds: r, forType: .highlight, withProperties: nil); h.color = NSColor(hex: "FFD60A").withAlphaComponent(0.6)
              h.quadrilateralPoints = [NSValue(point: NSPoint(x: 0, y: r.height)), NSValue(point: NSPoint(x: r.width, y: r.height)), NSValue(point: .zero), NSValue(point: NSPoint(x: r.width, y: 0))]
              c.add(h, to: page(), action: "Hervorheben")
              let pt = CGPoint(x: r.maxX - 3, y: r.midY)
              note("Bildschirm: Rechteck allein \(ohne), mit Hervorhebung darüber \(screenColor(pt)) (muss sich unterscheiden)") },
            // 6. Gedrehte Seite
            { doc.rotate([page()], by: 90) },
            { c.tool = .editText
              let r = lb("Leistungszeitraum")!
              let ok = c.selectContent(at: CGPoint(x: r.midX, y: r.midY), on: page())
              note("gedrehte Seite: Element gewählt: \(ok) (\(c.contentSel?.element.name ?? "-"))")
              let b0 = r
              c.moveContentSelection(dx: 0, dy: -30)
              let b1 = lb("Leistungszeitraum") ?? .zero
              note("gedrehte Seite verschoben: Δy \(Int(b1.minY - b0.minY)) (erwartet −30)") },
            { if let sel = page().selectionForLine(at: CGPoint(x: (lb("Leistungszeitraum") ?? .zero).midX, y: (lb("Leistungszeitraum") ?? .zero).midY)) {
                  c.clearContentSelection()
                  c.convertToEditable(sel, page: page(), caretAt: nil)
              }
              let t = page().annotations.compactMap { $0 as? WObject }.first { $0.model.kind == .text && $0.model.text.contains("Leistungszeitraum") }
              note("Text bearbeiten auf gedrehter Seite: Editor \(c.isEditingText), Drehung im Objekt \(t?.model.rot ?? -1), Original entfernt: \(!text().contains("Leistungszeitraum"))")
              c.endEditing() },
            // 7. Sicherheitskopie
            { doc.writeRecovery()
              let p = Recovery.pending()
              note("Sicherheitskopie: \(p.count) Eintrag, Name '\(p.first?.1.name ?? "-")', Datei \(((try? FileManager.default.attributesOfItem(atPath: Recovery.dir.appendingPathComponent(doc.recoveryID + ".pdf").path))?[.size] as? Int ?? 0) / 1024) KB")
              let undoFiles = (try? FileManager.default.contentsOfDirectory(atPath: UndoStore.dir.path))?.count ?? 0
              note("Widerrufen-Stände auf der Platte: \(undoFiles) Dateien") },
            // 8. Werkzeugleiste bei 1280 pt Breite (13-Zoll-MacBook)
            { w.setContentSize(NSSize(width: 1280, height: 800)) },
            { let all = w.toolbar?.items.map { $0.label } ?? []
              let vis = Set((w.toolbar?.visibleItems ?? []).map { $0.label })
              note("Werkzeugleiste bei 1280 pt: \(vis.count) von \(all.count) sichtbar; im »-Menü: \(all.filter { !vis.contains($0) && !$0.isEmpty })")
              w.setContentSize(NSSize(width: 1500, height: 900)) },
            { let all = w.toolbar?.items.map { $0.label } ?? []
              let vis = Set((w.toolbar?.visibleItems ?? []).map { $0.label })
              note("bei 1500 pt: im »-Menü: \(all.filter { !vis.contains($0) && !$0.isEmpty })") },
        ]) {
            if let img = PDFTools.render(PDFTools.snapshot(doc.pdf).page(at: 0)!, dpi: 60) {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/ende.png"))
            }
            doc.close()
            note("nach Schließen: Sicherheitskopien übrig: \(Recovery.pending().count)")
            finish(dir)
        }
    }

    static func finish(_ dir: String) {
        prefs.removePersistentDomain(forName: "de.marlonelsner.pdf-werkstatt.selbsttest")
        try? log.write(toFile: dir + "/ergebnis.txt", atomically: true, encoding: .utf8)
        NSDocumentController.shared.documents.forEach { $0.updateChangeCount(.changeCleared) }
        NSApp.terminate(nil)
    }
}
