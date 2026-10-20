import AppKit
import PDFKit
import Vision

// Texterkennung (OCR) mit Apple Vision: Die Seite wird gerendert, erkannter Text als unsichtbare Textebene (3 Tr)
// wortgenau über das Bild gelegt. Danach ist die Seite durchsuchbar, kopierbar und für „Suchen und schwärzen“ erreichbar.
// Läuft ohne Internet; Deutsch und Englisch.

struct OCRWord {
    var text: String
    var rect: CGRect          // Seitenkoordinaten (unrotiert, wie der Inhaltsstrom)
    var confidence: Float
}

struct OCRReport {
    var pages: [Int] = []
    var words = 0
    var skipped: [Int] = []   // Seiten mit vorhandenem Text (übersprungen)
    var notes: [String] = []
    var summary: String {
        var s = pages.isEmpty ? "keine Seite erkannt" : "\(words) Wörter auf \(pages.count) Seite\(pages.count == 1 ? "" : "n")"
        if !skipped.isEmpty { s += ", \(skipped.count) Seite\(skipped.count == 1 ? "" : "n") mit vorhandenem Text übersprungen" }
        return s
    }
}

enum OCR {
    static let fontName = "PDFWROCR"
    static let dpi: CGFloat = 300

    /// Seite erkennen. Liefert Wörter in Seitenkoordinaten und die Drehung (0/90/180/270), in der der Text aufrecht stand.
    static func recognize(data: Data, pageIndex: Int) -> ([OCRWord], Int)? {
        guard let prov = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(prov), let pg = doc.page(at: pageIndex + 1) else { return nil }
        let box = pg.getBoxRect(.mediaBox)
        let rot = ((pg.rotationAngle % 360) + 360) % 360
        let upright = rot == 90 || rot == 270 ? CGSize(width: box.height, height: box.width) : box.size
        var scale = dpi / 72
        while upright.width * scale * upright.height * scale > 30_000_000 { scale *= 0.8 }
        let w = Int(ceil(upright.width * scale)), h = Int(ceil(upright.height * scale))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Abbildung Seite → Bild inkl. /Rotate, damit die Schrift aufrecht steht. getDrawingTransform vergrößert nie,
        // deshalb erst skalieren und die Drehung in Punkten berechnen.
        let rotT = pg.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: upright.width, height: upright.height), rotate: 0, preserveAspectRatio: true)
        let t = rotT.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        ctx.concatenate(t)
        ctx.drawPDFPage(pg)
        guard let img = ctx.makeImage() else { return nil }
        if ProcessInfo.processInfo.environment["PDFW_OCR_DEBUG"] != nil {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/ocr-debug-\(pageIndex + 1).png"))
            print("OCR-Debug: Bild \(w)×\(h), Transform \(t)")
        }
        let inv = t.inverted()

        // Erkennung; steht der Text seitlich (Handy-Foto quer), die Drehung mit den meisten Wörtern nehmen
        var best: [OCRWord] = []
        var bestCount = -1
        var bestTurn = 0
        for turn in [0, 90, 270, 180] {
            let (image, map) = rotated(img, by: turn)
            let found = run(on: image, width: w, height: h, map: map, inv: inv)
            Log.v("OCR Seite \(pageIndex + 1), Drehung \(turn)°: \(found.count) Wörter")
            if ProcessInfo.processInfo.environment["PDFW_OCR_DEBUG"] != nil { print("OCR-Debug: Drehung \(turn)°: \(found.count) Wörter: \(found.prefix(12).map { $0.text }.joined(separator: " "))") }
            if found.count > bestCount { best = found; bestCount = found.count; bestTurn = turn }
            if turn == 0, found.count >= 25 { break }      // aufrecht und genug Text – keine weiteren Drehungen
        }
        return (best, bestTurn)
    }

    /// Bild um 0/90/180/270° drehen; `map` bildet Punkte des gedrehten Bilds (Pixel) auf das Original (Pixel) ab
    private static func rotated(_ img: CGImage, by deg: Int) -> (CGImage, CGAffineTransform) {
        guard deg != 0 else { return (img, .identity) }
        let w = img.width, h = img.height
        let swap = deg == 90 || deg == 270
        let nw = swap ? h : w, nh = swap ? w : h
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return (img, .identity) }
        // Zeichnen: gedrehtes Bild = Original um deg° im Uhrzeigersinn gedreht
        var t = CGAffineTransform.identity
        switch deg {
        case 90:  t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(nh))
        case 180: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(nw), ty: CGFloat(nh))
        case 270: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(nw), ty: 0)
        default: break
        }
        ctx.concatenate(t)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return (img, .identity) }
        return (out, t.inverted())     // Punkt im gedrehten Bild → Original
    }

    private static func run(on img: CGImage, width w: Int, height h: Int, map: CGAffineTransform, inv: CGAffineTransform) -> [OCRWord] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["de-DE", "en-US"]
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        do { try handler.perform([req]) } catch { Log.w("OCR: Vision-Fehler \(error)"); return [] }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        var words: [OCRWord] = []
        var noBox = 0
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let s = cand.string
            var i = s.startIndex
            while i < s.endIndex {
                while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
                guard i < s.endIndex else { break }
                var j = i
                while j < s.endIndex, !s[j].isWhitespace { j = s.index(after: j) }
                let word = String(s[i..<j])
                var corners: [CGPoint]? = nil
                if let b = try? cand.boundingBox(for: i..<j) {
                    corners = [b.topLeft, b.topRight, b.bottomLeft, b.bottomRight]
                } else {
                    // Kein Wortkasten (kommt bei Vision vor): Anteil am Zeilenkasten nach Zeichenposition
                    noBox += 1
                    let total = max(1, s.count)
                    let a = CGFloat(s.distance(from: s.startIndex, to: i)) / CGFloat(total), e = CGFloat(s.distance(from: s.startIndex, to: j)) / CGFloat(total)
                    let bb = obs.boundingBox
                    corners = [CGPoint(x: bb.minX + a * bb.width, y: bb.maxY), CGPoint(x: bb.minX + e * bb.width, y: bb.maxY),
                               CGPoint(x: bb.minX + a * bb.width, y: bb.minY), CGPoint(x: bb.minX + e * bb.width, y: bb.minY)]
                }
                if let corners {
                    // Vision: normierte Koordinaten (Ursprung unten links) im gedrehten Bild → Originalbild (Pixel, Ursprung unten links) → Seite
                    let q = corners.map { CGPoint(x: $0.x * iw, y: $0.y * ih).applying(map).applying(inv) }
                    let xs = q.map { $0.x }, ys = q.map { $0.y }
                    let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                    if r.width > 0.3, r.height > 0.3 { words.append(OCRWord(text: word, rect: r, confidence: cand.confidence)) }
                }
                i = j
            }
        }
        if noBox > 0 { Log.v("OCR: \(noBox) Wörter ohne Wortkasten – anteilig verortet") }
        _ = w; _ = h
        return words
    }

    /// Unsichtbare Textebene als Inhaltsstrom-Anhang (Helvetica, WinAnsi, horizontal auf die Wortbreite skaliert)
    static func layer(for words: [OCRWord], rotation: Int) -> [UInt8] {
        guard !words.isEmpty, let widths = FontMetrics.standard14Widths(base: "Helvetica", encoding: "WinAnsiEncoding") else { return [] }
        var out = Array("\nq BT 3 Tr\n".utf8)
        let rot = ((rotation % 360) + 360) % 360
        for wd in words {
            guard let bytes = wd.text.data(using: .windowsCP1252, allowLossyConversion: true), !bytes.isEmpty else { continue }
            let textWidth = bytes.reduce(0.0) { $0 + (widths[Int($1)] ?? 556) } / 1000   // in em (ohne das Leerzeichen)
            guard textWidth > 0 else { continue }
            // Zeilenhöhe des Worts ≈ Schriftgröße (Ober- + Unterlänge); Grundlinie ≈ 22 % über der Unterkante
            let r = wd.rect
            let along = rot == 90 || rot == 270 ? r.height : r.width       // Laufrichtung des Texts auf der unrotierten Seite
            let across = rot == 90 || rot == 270 ? r.width : r.height
            let size = max(1, across)
            let sx = along / (textWidth * size)
            var m: CGAffineTransform
            switch rot {
            case 90:  m = CGAffineTransform(a: 0, b: size * sx, c: -size, d: 0, tx: r.maxX - 0.22 * across, ty: r.minY)
            case 180: m = CGAffineTransform(a: -size * sx, b: 0, c: 0, d: -size, tx: r.maxX, ty: r.maxY - 0.22 * across)
            case 270: m = CGAffineTransform(a: 0, b: -size * sx, c: size, d: 0, tx: r.minX + 0.22 * across, ty: r.maxY)
            default:  m = CGAffineTransform(a: size * sx, b: 0, c: 0, d: size, tx: r.minX, ty: r.minY + 0.22 * across)
            }
            out += Array("/\(fontName) 1 Tf \(fmt(m.a)) \(fmt(m.b)) \(fmt(m.c)) \(fmt(m.d)) \(fmt(m.tx)) \(fmt(m.ty)) Tm ".utf8)
            out += PDFWriter.serialize(.string([UInt8](bytes) + [0x20]))   // Leerzeichen: PDFKit trennt die Wörter sonst nicht
            out += Array(" Tj\n".utf8)
        }
        out += Array("ET Q\n".utf8)
        return out
    }

    /// Bilddrehung (im Uhrzeigersinn, bis der Text aufrecht steht) → entsprechender /Rotate-Wert für die Textrichtung
    static func turnToPageRotation(_ turn: Int) -> Int { (360 - turn) % 360 }

    static func fontObject() -> PDFObj {
        .dict(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"), "Encoding": .name("WinAnsiEncoding")])
    }

    /// Seiten, die Text erhalten sollen: ohne eigene Textebene (oder alle, wenn `onlyWithoutText` aus)
    static func candidatePages(_ pdf: PDFDocument, onlyWithoutText: Bool, only: [Int]? = nil) -> (todo: [Int], skipped: [Int]) {
        var todo: [Int] = [], skipped: [Int] = []
        for i in (only ?? Array(0..<pdf.pageCount)) {
            guard let p = pdf.page(at: i) else { continue }
            let hasText = !(p.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasText && onlyWithoutText { skipped.append(i) } else { todo.append(i) }
        }
        return (todo, skipped)
    }

    /// Sieht das Dokument wie ein Scan aus? (keine Seite mit Text, mindestens eine Seite zeichnet ein Bild)
    static func looksScanned(_ data: Data, pdf: PDFDocument) -> Bool {
        guard pdf.pageCount > 0, candidatePages(pdf, onlyWithoutText: true).todo.count == pdf.pageCount else { return false }
        guard let f = try? PDFFile(data: data) else { return false }
        let pages = f.pageObjects()
        for n in pages.prefix(3) {
            if let c = f.content(ofPage: n), c.count < 4000, ContentStream(c).elements.contains(where: { $0.kind == .image }) { return true }
        }
        return false
    }

    /// Textebene in die Datei schreiben: Inhalt anhängen, Schrift in die Ressourcen. `progress` wird je Seite gerufen.
    static func apply(to data: Data, pages: [Int], progress: ((Int, Int) -> Void)? = nil) -> (Data, OCRReport)? {
        guard let f = try? PDFFile(data: data) else { return nil }
        let objs = f.pageObjects()
        var report = OCRReport()
        var updates: [Int: (content: [UInt8], extra: [String: PDFObj])] = [:]
        let fontNum = f.firstFreeObject
        var newObjects: [(Int, PDFObj)] = [(fontNum, fontObject())]
        for (k, i) in pages.enumerated() {
            progress?(k, pages.count)
            guard i < objs.count, let content = f.content(ofPage: objs[i]) else { continue }
            guard let (words, turn) = recognize(data: data, pageIndex: i) else { report.notes.append("Seite \(i + 1): Erkennung fehlgeschlagen"); continue }
            guard !words.isEmpty else { continue }
            // Textrichtung auf der unrotierten Seite: Seitendrehung plus die Drehung, in der Vision den Text aufrecht sah
            let pageRot = f.resolve(f.pageDict(objs[i])?["Rotate"] ?? .int(0)).intValue ?? 0
            let rotation = ((pageRot + OCR.turnToPageRotation(turn)) % 360 + 360) % 360
            if turn != 0 { report.notes.append("Seite \(i + 1): Text stand um \(turn)° gedreht") }
            let cs = ContentStream(content)
            var out = content
            if cs.endsInText { out += Array("\nET".utf8) }
            for _ in 0..<cs.openStates { out += Array("\nQ".utf8) }
            // Textebene in Seitenkoordinaten – eine CTM außerhalb aller Klammern (Skia) herausrechnen
            let det = cs.endCTM.a * cs.endCTM.d - cs.endCTM.b * cs.endCTM.c
            if det != 0, cs.endCTM != .identity {
                let inv = cs.endCTM.inverted()
                out += Array("\nq \(fmt(inv.a)) \(fmt(inv.b)) \(fmt(inv.c)) \(fmt(inv.d)) \(fmt(inv.tx)) \(fmt(inv.ty)) cm".utf8)
                out += layer(for: words, rotation: rotation)
                out += Array("Q\n".utf8)
            } else {
                out += layer(for: words, rotation: rotation)
            }
            var res = f.pageResources(objs[i])
            var fonts = f.resolve(res["Font"] ?? .dict([:])).dictValue ?? [:]
            fonts[fontName] = .ref(fontNum, 0)
            res["Font"] = .dict(fonts)
            updates[objs[i]] = (out, ["Resources": .dict(res)])
            report.pages.append(i); report.words += words.count
        }
        progress?(pages.count, pages.count)
        guard !updates.isEmpty else { return (data, report) }
        guard let inc = f.updated(pages: updates, newObjects: newObjects), let f2 = try? PDFFile(data: inc), let out = f2.compacted() else { return nil }
        _ = newObjects
        newObjects = []
        return (out, report)
    }
}

/// PDFW_OCR_TEST=<Ordner>: Texterkennung auf allen PDFs ohne Textebene, Prüfung von Lage und Durchsuchbarkeit, danach Schwärzen eines Treffers.
enum OCRTest {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["PDFW_OCR_TEST"] else { return }
        var ok = true
        var lines: [String] = []
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".pdf") && !$0.contains(".ocr") && !$0.contains(".ge") }.sorted()
        try? FileManager.default.createDirectory(atPath: dir + "/Ergebnisse", withIntermediateDirectories: true)
        for name in files {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            let wd = WDocument()
            guard let raw = try? Data(contentsOf: url), (try? wd.read(from: raw, ofType: "com.adobe.pdf")) != nil, let fresh = wd.currentData() else { lines.append("FEHL \(name): nicht ladbar"); ok = false; continue }
            let (todo, skipped) = OCR.candidatePages(wd.pdf, onlyWithoutText: true)
            guard !todo.isEmpty else { lines.append("--   \(name): alle \(skipped.count) Seiten haben schon Text"); continue }
            let t0 = Date()
            guard let (out, rep) = OCR.apply(to: fresh, pages: Array(todo.prefix(3))), let doc = PDFDocument(data: out) else { lines.append("FEHL \(name): OCR fehlgeschlagen"); ok = false; continue }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            var problems: [String] = []
            // Darstellung unverändert?
            var diff = 0
            for i in rep.pages.prefix(2) {
                if let a = RedactRaster.pageGray(fresh, pageIndex: i, scale: 1), let b = RedactRaster.pageGray(out, pageIndex: i, scale: 1), a.w == b.w, a.h == b.h {
                    for k in 0..<(a.w * a.h) where abs(Int(a.px[k]) - Int(b.px[k])) > 40 { diff += 1 }
                }
            }
            if diff > 0 { problems.append("Darstellung verändert: \(diff) px") }
            // Lage: jedes Wort muss dort liegen, wo das Bild dunkle Pixel hat
            var misplaced = 0, checked = 0
            let text = (doc.page(at: rep.pages.first ?? 0)?.string ?? "")
            if let p = doc.page(at: rep.pages.first ?? 0), let gray = RedactRaster.pageGray(fresh, pageIndex: rep.pages.first ?? 0, scale: 2) {
                let sample = text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= 4 }.prefix(25)
                for wdx in sample {
                    guard let sel = doc.findString(wdx, withOptions: []).first(where: { $0.pages.contains(p) }) else { continue }
                    let r = sel.bounds(for: p); checked += 1
                    var ink = 0, total = 0
                    let x0 = max(0, Int((r.minX - gray.box.minX) * 2)), x1 = min(gray.w - 1, Int((r.maxX - gray.box.minX) * 2))
                    let y0 = max(0, Int((gray.box.maxY - r.maxY) * 2)), y1 = min(gray.h - 1, Int((gray.box.maxY - r.minY) * 2))
                    if x1 > x0, y1 > y0 { for y in y0...y1 { for x in x0...x1 { total += 1; if gray.px[y * gray.w + x] < 160 { ink += 1 } } } }
                    if total == 0 || Double(ink) / Double(total) < 0.04 { misplaced += 1 }
                }
            }
            if checked > 0, misplaced > checked / 5 { problems.append("\(misplaced) von \(checked) Wörtern liegen nicht über Tinte") }
            // Schwärzen eines erkannten Worts
            var redactNote = ""
            if let p = doc.page(at: rep.pages.first ?? 0), let word = text.split(whereSeparator: { $0.isWhitespace }).map(String.init).first(where: { $0.count >= 6 && $0.allSatisfy { $0.isLetter } }),
               let sel = doc.findString(word, withOptions: []).first(where: { $0.pages.contains(p) }) {
                let mark = RedactMark(pageIndex: rep.pages.first ?? 0, rect: sel.bounds(for: p).insetBy(dx: -0.5, dy: -0.5), color: RGBA(.black))
                let red = Redactor(marks: [mark])
                if let r2 = red.apply(to: out, paintBoxes: true), let d2 = PDFDocument(data: r2) {
                    let still = !(d2.page(at: mark.pageIndex)?.selection(for: mark.rect.insetBy(dx: 1, dy: 1))?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
                    redactNote = " · Schwärzen „\(word)“: \(red.report.summary)\(still ? " ⚠️ noch auffindbar" : ", weg")"
                    if still { problems.append("Schwärzen nach OCR unvollständig") }
                    try? r2.write(to: URL(fileURLWithPath: dir).appendingPathComponent("Ergebnisse").appendingPathComponent((name as NSString).deletingPathExtension + ".ocr.geschwaerzt.pdf"))
                } else { problems.append("Schwärzen nach OCR fehlgeschlagen") }
            }
            try? out.write(to: URL(fileURLWithPath: dir).appendingPathComponent("Ergebnisse").appendingPathComponent((name as NSString).deletingPathExtension + ".ocr.pdf"))
            if !problems.isEmpty { ok = false }
            lines.append("\(problems.isEmpty ? "OK  " : "FEHL") \(name): \(rep.summary), \(ms) ms, \(out.count / 1024) KB, Darstellung \(diff) px, Lage \(checked - misplaced)/\(checked)\(redactNote)" + (problems.isEmpty ? "" : " ⚠️ " + problems.joined(separator: "; ")) + " · Text: „\(text.prefix(90).replacingOccurrences(of: "\n", with: " "))“")
        }
        let t = lines.joined(separator: "\n"); print(t)
        try? t.write(toFile: dir + "/Ergebnisse/ocr-ergebnis.txt", atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }
}
