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
        func lineBounds(_ t: String) -> CGRect? {
            guard let sel = doc.pdf.findString(t, withOptions: []).first else { return nil }
            return sel.bounds(for: page())
        }
        func winPt(_ pp: CGPoint) -> CGPoint { c.convert(c.convert(pp, from: page()), to: nil) }
        func drag(_ a: CGPoint, _ b: CGPoint) {
            for i in 1...5 { w.postEvent(mouse(.leftMouseDragged, w, CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 5, y: a.y + (b.y - a.y) * CGFloat(i) / 5)), atStart: false) }
            w.postEvent(mouse(.leftMouseUp, w, b), atStart: false); w.sendEvent(mouse(.leftMouseDown, w, a))
        }
        var head0 = CGRect.zero
        run([
            { c.go(to: PDFDestination(page: page(), at: CGPoint(x: 0, y: 800)))
              c.insertShape(.rect); (c.selected as? WObject)?.bounds = CGRect(x: 400, y: 700, width: 100, height: 60); c.select(nil)
              note("Vorher: \(text())") },
            { c.tool = .editText
              let r = lineBounds("Rechnungsdatum")!
              let pt = winPt(CGPoint(x: r.midX, y: r.midY))
              w.postEvent(mouse(.leftMouseUp, w, pt), atStart: false); w.sendEvent(mouse(.leftMouseDown, w, pt))
              note("Klick auf Zeile: Inhalt ausgewählt = \(c.contentSel.map { "\($0.element.kind) '\($0.element.name)'" } ?? "nichts")") },
            { key(51, "\u{7f}", w) },
            { note("nach ⌫: \(text())")
              note("Form überlebt: \(page().annotations.contains { ($0 as? WObject)?.model.kind == .rect }), Seiten: \(doc.pdf.pageCount)")
              head0 = lineBounds("Rechnung Nr.")!
              let a = winPt(CGPoint(x: head0.midX, y: head0.midY)), b = winPt(CGPoint(x: head0.midX + 60, y: head0.midY - 40))
              drag(a, b) },
            { let h1 = lineBounds("Rechnung Nr.") ?? .zero
              note("Überschrift gezogen: von \(Int(head0.minX)),\(Int(head0.minY)) nach \(Int(h1.minX)),\(Int(h1.minY)) (erwartet +60, −40); Auswahl wiedergefunden: \(c.contentSel != nil)") },
            { let r = lineBounds("Gesamtbetrag")!; c.go(to: PDFDestination(page: page(), at: CGPoint(x: 0, y: r.maxY + 60))) },
            { // Doppelklick auf „Gesamtbetrag“ → Editor, Original entfernt, keine Abdeckung
              let r = lineBounds("Gesamtbetrag")!
              let pt = winPt(CGPoint(x: r.minX + 10, y: r.midY))
              note("Doppelklick-Ziel: Fenster \(pt), Treffer-Ansicht \(String(describing: w.contentView?.superview?.hitTest(pt).map { type(of: $0) })), Canvas-Fenster \(c.window === w), Canvas-Bounds \(c.bounds)")
              w.postEvent(mouse(.leftMouseUp, w, pt), atStart: false); w.sendEvent(mouse(.leftMouseDown, w, pt))
              w.postEvent(mouse(.leftMouseUp, w, pt, clicks: 2), atStart: false); w.sendEvent(mouse(.leftMouseDown, w, pt, clicks: 2)) },
            { note("Doppelklick: Editor offen \(c.isEditingText), Abdeckungen: \(page().annotations.filter { ($0 as? WObject)?.model.kind == .cover }.count), Originaltext noch im PDF: \(text().contains("Gesamtbetrag"))")
              c.debugReplaceEditorText("Gesamtbetrag netto 1.999,00 €"); c.endEditing()
              note("nach Tippen: Textobjekte: \(page().annotations.compactMap { ($0 as? WObject)?.model.text }.filter { !$0.isEmpty })") },
            { cmdZ(w) }, { cmdZ(w) }, { cmdZ(w) },
            { note("nach 3× ⌘Z: \(text())  Abdeckungen \(page().annotations.filter { ($0 as? WObject)?.model.kind == .cover }.count), Textobjekte \(page().annotations.filter { ($0 as? WObject)?.model.kind == .text }.count), Form da: \(page().annotations.contains { ($0 as? WObject)?.model.kind == .rect })")
              if let img = PDFTools.render(PDFTools.snapshot(doc.pdf).page(at: 0)!, dpi: 60) {
                  try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/ende.png"))
              } },
        ]) { finish(dir) }
    }

    static func finish(_ dir: String) {
        prefs.removePersistentDomain(forName: "de.marlonelsner.pdf-werkstatt.selbsttest")
        try? log.write(toFile: dir + "/ergebnis.txt", atomically: true, encoding: .utf8)
        NSDocumentController.shared.documents.forEach { $0.updateChangeCount(.changeCleared) }
        NSApp.terminate(nil)
    }
}
