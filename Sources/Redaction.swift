import AppKit
import PDFKit
import Compression
import CoreGraphics

// Echtes Schwärzen: Der Inhalt unter einer Markierung wird aus der Datei entfernt – Text zeichenweise,
// Bilder pixelweise, Pfade ganz oder beschnitten – und die Datei ohne Altstände neu geschrieben.
// Arbeitet auf PDFKits Sicherausgabe (siehe PDFContent.swift).

struct RedactMark {
    var pageIndex: Int
    var rect: CGRect
    var color: RGBA
}

struct RedactReport {
    var glyphs = 0              // einzeln entfernte Zeichen
    var textElements = 0        // ganz entfernte Textstücke
    var imagesRedacted = 0      // Bilder mit geschwärzten Pixeln neu geschrieben
    var imagesRemoved = 0
    var pathsRemoved = 0
    var pathsClipped = 0
    var formsDissolved = 0
    var pagesRasterized: [Int] = []
    var annotationsRemoved = 0
    var changedZones: [Int: [CGRect]] = [:]   // je Seite: Bereiche, in denen sich die Darstellung ändern darf
    var notes: [String] = []
    var leaks: [String] = []                   // nach der Prüfung noch auffindbarer Text

    var summary: String {
        var parts: [String] = []
        if glyphs > 0 { parts.append("\(glyphs) Zeichen") }
        if textElements > 0 { parts.append("\(textElements) Textstücke") }
        if imagesRedacted > 0 { parts.append("\(imagesRedacted) Bilder geschwärzt") }
        if imagesRemoved > 0 { parts.append("\(imagesRemoved) Bilder entfernt") }
        if pathsRemoved > 0 { parts.append("\(pathsRemoved) Linien/Flächen entfernt") }
        if pathsClipped > 0 { parts.append("\(pathsClipped) Linien/Flächen beschnitten") }
        if annotationsRemoved > 0 { parts.append("\(annotationsRemoved) Anmerkungen gelöscht") }
        if !pagesRasterized.isEmpty { parts.append("Seite \(pagesRasterized.map { String($0 + 1) }.joined(separator: ", ")) als Bild") }
        return parts.isEmpty ? "nichts zu entfernen" : parts.joined(separator: ", ")
    }
}

// MARK: - Schriftmaße

/// Vorschubbreiten einer Schrift, um entfernte Zeichen im TJ-Array durch exakt gleich lange Lücken zu ersetzen.
struct FontMetrics {
    var twoByte = false
    var widths: [Int: Double] = [:]      // Code → Breite in 1/1000 Textraum
    var defaultWidth = 0.0
    var wordSpaceApplies: Bool { !twoByte }

    func width(_ code: Int) -> Double { widths[code] ?? defaultWidth }
    func codes(_ s: [UInt8]) -> [Int] {
        if !twoByte { return s.map { Int($0) } }
        var out: [Int] = []
        var i = 0
        while i + 1 < s.count { out.append(Int(s[i]) << 8 | Int(s[i + 1])); i += 2 }
        if i < s.count { out.append(Int(s[i]) << 8) }
        return out
    }
    func bytes(_ code: Int) -> [UInt8] { twoByte ? [UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)] : [UInt8(code & 0xFF)] }

    init?(font: [String: PDFObj], file f: PDFFile) {
        let sub = f.resolve(font["Subtype"] ?? .null).nameValue ?? ""
        if sub == "Type0" {
            guard f.resolve(font["Encoding"] ?? .null).nameValue == "Identity-H",
                  let dfs = f.resolve(font["DescendantFonts"] ?? .null).arrayValue, let d0 = dfs.first,
                  let cid = f.resolve(d0).dictValue else { return nil }
            twoByte = true
            defaultWidth = f.resolve(cid["DW"] ?? .int(1000)).doubleValue ?? 1000
            if let w = f.resolve(cid["W"] ?? .null).arrayValue {
                var i = 0
                let items = w.map { f.resolve($0) }
                while i < items.count {
                    guard let c = items[i].doubleValue else { break }
                    if i + 1 < items.count, let arr = items[i + 1].arrayValue {
                        for (k, v) in arr.enumerated() { if let d = f.resolve(v).doubleValue { widths[Int(c) + k] = d } }
                        i += 2
                    } else if i + 2 < items.count, let c2 = items[i + 1].doubleValue, let wd = items[i + 2].doubleValue {
                        if c2 >= c, c2 - c < 65536 { for code in Int(c)...Int(c2) { widths[code] = wd } }
                        i += 3
                    } else { break }
                }
            }
            return
        }
        guard ["Type1", "TrueType", "MMType1", "Type3"].contains(sub) else { return nil }
        var scale = 1.0
        if sub == "Type3" {
            guard let m = f.resolve(font["FontMatrix"] ?? .null).arrayValue, m.count == 6, let a = f.resolve(m[0]).doubleValue else { return nil }
            scale = a * 1000
        }
        if let desc = f.resolve(font["FontDescriptor"] ?? .null).dictValue, let mw = f.resolve(desc["MissingWidth"] ?? .null).doubleValue { defaultWidth = mw * scale }
        guard let ws = f.resolve(font["Widths"] ?? .null).arrayValue else {
            // Standard-14 ohne Breiten: nur Courier ist sicher bekannt
            let base = f.resolve(font["BaseFont"] ?? .null).nameValue ?? ""
            if base.hasPrefix("Courier") { defaultWidth = 600; return }
            return nil
        }
        let first = f.resolve(font["FirstChar"] ?? .int(0)).intValue ?? 0
        for (k, v) in ws.enumerated() { if let d = f.resolve(v).doubleValue { widths[first + k] = d * scale } }
    }
}

// MARK: - Rasterhilfe

enum RedactRaster {
    /// Rendert Varianten eines Seiteninhalts (gleiche Ressourcen) und liefert deren Bounding-Boxen in Seitenkoordinaten.
    /// `variants[0]` ist die Leer-Referenz.
    static func bounds(file f: PDFFile, pageObj: Int, mediaBox: CGRect, variants: [[UInt8]], scale: CGFloat) -> [CGRect?] {
        let w = Int(ceil(mediaBox.width * scale)), h = Int(ceil(mediaBox.height * scale))
        guard w > 0, h > 0, w * h < 12_000_000, variants.count >= 2,
              let data = f.standalone(pageObj: pageObj, contents: variants, mediaBox: mediaBox),
              let prov = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(prov),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h) else { return Array(repeating: nil, count: variants.count) }
        func raster(_ i: Int) -> [UInt8]? {
            guard let pg = doc.page(at: i + 1) else { return nil }
            ctx.saveGState()
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
            ctx.drawPDFPage(pg)
            ctx.restoreGState()
            return Array(UnsafeBufferPointer(start: buf, count: w * h))
        }
        guard let blank = raster(0) else { return Array(repeating: nil, count: variants.count) }
        var out: [CGRect?] = [nil]
        for k in 1..<variants.count {
            guard let img = raster(k) else { out.append(nil); continue }
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h {
                let row = y * w
                for x in 0..<w where abs(Int(img[row + x]) - Int(blank[row + x])) > 8 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
            if maxX >= minX {
                out.append(CGRect(x: CGFloat(minX) / scale + mediaBox.minX, y: CGFloat(h - 1 - maxY) / scale + mediaBox.minY,
                                  width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale))
            } else { out.append(nil) }
        }
        return out
    }

    /// Unterschied zweier Varianten in Pixeln (und Anzahl nicht-weißer Pixel der ersten) – für den Nachweis, dass sonst nichts verrutscht ist
    static func difference(file f: PDFFile, pageObj: Int, mediaBox: CGRect, a: [UInt8], b: [UInt8], scale: CGFloat) -> (diff: Int, ink: Int)? {
        let w = Int(ceil(mediaBox.width * scale)), h = Int(ceil(mediaBox.height * scale))
        guard w > 0, h > 0, w * h < 12_000_000,
              let data = f.standalone(pageObj: pageObj, contents: [a, b], mediaBox: mediaBox),
              let prov = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(prov) else { return nil }
        var imgs: [[UInt8]] = []
        for i in 1...2 {
            guard let pg = doc.page(at: i),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h) else { return nil }
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
            ctx.drawPDFPage(pg)
            imgs.append(Array(UnsafeBufferPointer(start: buf, count: w * h)))
        }
        var diff = 0, ink = 0
        for i in 0..<(w * h) {
            if abs(Int(imgs[0][i]) - Int(imgs[1][i])) > 24 { diff += 1 }
            if imgs[0][i] < 240 { ink += 1 }
        }
        return (diff, ink)
    }

    /// Ganze Seite (ohne Anmerkungen) als Graubild – für den Vorher/Nachher-Vergleich
    static func pageGray(_ data: Data, pageIndex: Int, scale: CGFloat) -> (px: [UInt8], w: Int, h: Int, box: CGRect)? {
        guard let prov = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(prov), let pg = doc.page(at: pageIndex + 1) else { return nil }
        let box = pg.getBoxRect(.mediaBox)
        let w = Int(ceil(box.width * scale)), h = Int(ceil(box.height * scale))
        guard w > 0, h > 0, w * h < 12_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(pg)
        return (Array(UnsafeBufferPointer(start: buf, count: w * h)), w, h, box)
    }

    static func zlib(_ raw: [UInt8]) -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: max(1024, raw.count + raw.count / 50 + 1024))
        var src = raw
        let n = src.withUnsafeMutableBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                compression_encode_buffer(dp.baseAddress!, dp.count, sp.baseAddress!, sp.count, nil, COMPRESSION_ZLIB)
            }
        }
        var s1: UInt32 = 1, s2: UInt32 = 0
        for b in raw { s1 = (s1 + UInt32(b)) % 65521; s2 = (s2 + s1) % 65521 }
        let adler = s2 << 16 | s1
        var out: [UInt8] = [0x78, 0x9C]
        if n > 0 { out += dst[0..<n] } else { return [] }
        out += [UInt8(adler >> 24 & 0xFF), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
        return out
    }
}

// MARK: - Engine

final class Redactor {
    let marks: [RedactMark]
    let forceRaster: Bool
    private(set) var report = RedactReport()
    private var nextObj = 0
    private var newObjects: [(Int, PDFObj)] = []

    init(marks: [RedactMark], forceRaster: Bool = false) { self.marks = marks; self.forceRaster = forceRaster }

    /// Schwärzungen auf einen Dateistand anwenden. `paintBoxes`: Markierungen als Flächen in den Seiteninhalt zeichnen.
    /// Ergebnis ist eine komplett neu geschriebene Datei ohne Altstände.
    func apply(to data: Data, paintBoxes: Bool) -> Data? {
        guard var file = try? PDFFile(data: data) else { report.notes.append("Datei nicht lesbar (verschlüsselt oder xref-Stream)"); return nil }
        var cur = data
        var updates: [Int: (content: [UInt8], extra: [String: PDFObj])] = [:]
        nextObj = file.firstFreeObject + 50      // Reserve: updated() nummeriert Inhaltsströme hinter die neuen Objekte
        let pageIndices = Set(marks.map { $0.pageIndex }).sorted()
        for pageIndex in pageIndices {
            let pageMarks = marks.filter { $0.pageIndex == pageIndex }
            let rects = pageMarks.map { $0.rect.insetBy(dx: -0.3, dy: -0.3) }
            var pages = file.pageObjects()
            guard pageIndex < pages.count, var model = PageContentModel.load(file: file, pageIndex: pageIndex, reuse: nil) else {
                report.notes.append("Seite \(pageIndex + 1): Inhalt nicht lesbar"); return nil
            }
            // 1. Gruppen (Form-XObjects) im Bereich auflösen, damit ihr Inhalt einzeln greifbar ist
            var rounds = 0
            while rounds < 4 {
                let forms = model.elements.indices.filter { k in model.elements[k].kind == .form && rects.contains { model.coverage(k, by: $0) > 0.01 } }
                guard !forms.isEmpty, let d = model.apply(forms.map { .dissolve($0) }, to: cur), let nf = try? PDFFile(data: d),
                      let nm = PageContentModel.load(file: nf, pageIndex: pageIndex, reuse: nil) else { break }
                report.formsDissolved += forms.count
                cur = d; file = nf; model = nm; pages = file.pageObjects()
                rounds += 1
            }
            let pageObj = pages[pageIndex]
            var resources = file.pageResources(pageObj)
            var resChanged = false
            var edits: [ContentStream.Edit] = []
            var needRaster = forceRaster
            var zones = pageMarks.map { $0.rect }
            let color = pageMarks.first?.color ?? RGBA(.black)

            for k in model.elements.indices where !needRaster {
                let e = model.elements[k]
                let cov = rects.map { model.coverage(k, by: $0) }.max() ?? 0
                guard cov > 0.001, e.bounds.isUsable else { continue }
                switch e.kind {
                case .text:
                    switch redactText(k, model: model, file: file, pageObj: pageObj, rects: rects, resources: resources) {
                    case .replaced(let bytes, let n, let removedBoxes):
                        edits.append(.replace(k, bytes)); report.glyphs += n; zones += removedBoxes
                    case .unchanged: break
                    case .removeWhole:
                        if e.canRemove { edits.append(.remove(k)); report.textElements += 1; zones.append(e.bounds) }
                        else { needRaster = true; report.notes.append("Seite \(pageIndex + 1): Textstück „\(e.name)“ ließ sich nicht sicher zerlegen – Seite wird als Bild geschrieben") }
                    }
                case .path:
                    if cov >= 0.98 { edits.append(.remove(k)); report.pathsRemoved += 1; zones.append(e.bounds) }
                    else if let snip = clippedPath(e, stream: model.stream, mediaBox: model.mediaBox, rects: rects) { edits.append(.replace(k, snip)); report.pathsClipped += 1 }
                case .image, .inlineImage, .shading, .form:
                    if cov >= 0.98 { edits.append(.remove(k)); report.imagesRemoved += 1; zones.append(e.bounds); continue }
                    if let (snip, name, obj) = rasterizeElement(k, model: model, file: file, pageObj: pageObj, rects: rects, color: color, resources: resources) {
                        edits.append(.replace(k, snip))
                        var xo = file.resolve(resources["XObject"] ?? .dict([:])).dictValue ?? [:]
                        xo[name] = obj
                        resources["XObject"] = .dict(xo); resChanged = true
                        report.imagesRedacted += 1
                        zones.append(e.bounds.insetBy(dx: -1.5, dy: -1.5))
                    } else { needRaster = true; report.notes.append("Seite \(pageIndex + 1): Bild ließ sich nicht neu schreiben – Seite wird als Bild geschrieben") }
                }
            }

            var content: [UInt8]
            var extra: [String: PDFObj] = [:]
            if needRaster {
                guard let (c, res) = rasterizePage(file: file, pageIndex: pageIndex, mediaBox: model.mediaBox, rects: pageMarks.map { $0.rect }, color: color) else {
                    report.notes.append("Seite \(pageIndex + 1): Rasterung fehlgeschlagen"); return nil
                }
                content = c; extra["Resources"] = .dict(res)
                report.pagesRasterized.append(pageIndex)
                zones = [model.mediaBox]
            } else {
                content = model.stream.render(edits)
                // Nicht mehr gezeichnete XObjects (z. B. das Original eines geschwärzten Bildes) aus den Ressourcen nehmen –
                // sonst bleiben ihre Daten erreichbar und überleben das Kompaktieren
                if var xo = file.resolve(resources["XObject"] ?? .null).dictValue, !xo.isEmpty {
                    let used = Redactor.usedXObjects(content)
                    let before = xo.count
                    xo = xo.filter { used.contains($0.key) }
                    if xo.count != before { resources["XObject"] = .dict(xo); resChanged = true }
                }
                if resChanged { extra["Resources"] = .dict(resources) }
            }
            if paintBoxes {
                content += Array("\n".utf8)
                if !needRaster {
                    if model.stream.endsInText { content += Array("ET\n".utf8) }
                    for _ in 0..<model.stream.openStates { content += Array("Q\n".utf8) }
                }
                for m in pageMarks {
                    let r = m.rect
                    content += Array("q \(fmt(m.color.r)) \(fmt(m.color.g)) \(fmt(m.color.b)) rg \(fmt(r.minX)) \(fmt(r.minY)) \(fmt(r.width)) \(fmt(r.height)) re f Q\n".utf8)
                }
            }
            updates[pageObj] = (content, extra)
            report.changedZones[pageIndex] = zones
        }
        guard let inc = file.updated(pages: updates, newObjects: newObjects), let f2 = try? PDFFile(data: inc), let out = f2.compacted() else {
            report.notes.append("Datei konnte nicht neu geschrieben werden"); return nil
        }
        return out
    }

    /// Namen aller XObjects, die ein Inhaltsstrom mit `Do` zeichnet
    static func usedXObjects(_ content: [UInt8]) -> Set<String> {
        let cs = ContentStream(content)
        var out = Set<String>()
        for (i, t) in cs.tokens.enumerated() where t.op == "Do" && i > 0 {
            if let n = cs.tokens[i - 1].obj.nameValue { out.insert(n) }
        }
        return out
    }

    // MARK: Text zeichenweise

    private enum TextResult { case replaced([UInt8], Int, [CGRect]), unchanged, removeWhole }
    private enum TJItem { case str([UInt8]), adj(Double) }

    private func items(of e: ContentElement, stream: ContentStream) -> (items: [TJItem], op: String, aw: Double, ac: Double)? {
        let toks = stream.tokens
        let op = toks[e.tokens.upperBound - 1].op ?? ""
        let operands = e.tokens.lowerBound..<(e.tokens.upperBound - 1)
        var items: [TJItem] = []
        var aw = 0.0, ac = 0.0
        switch op {
        case "Tj", "'":
            guard operands.count >= 1, case .string(let s) = toks[operands.lowerBound].obj else { return nil }
            items = [.str(s)]
        case "\"":
            guard operands.count >= 3, case .string(let s) = toks[operands.lowerBound + 2].obj else { return nil }
            aw = toks[operands.lowerBound].obj.doubleValue ?? 0; ac = toks[operands.lowerBound + 1].obj.doubleValue ?? 0
            items = [.str(s)]
        case "TJ":
            guard operands.count >= 1, case .array(let a) = toks[operands.lowerBound].obj else { return nil }
            for x in a {
                if case .string(let s) = x { items.append(.str(s)) }
                else if let d = x.doubleValue { items.append(.adj(d)) }
            }
        default: return nil
        }
        return (items, op, aw, ac)
    }

    private func serializeTJ(_ items: [TJItem], prefix: String) -> [UInt8] {
        var out = Array(prefix.utf8)
        out += Array("[".utf8)
        for it in items {
            switch it {
            case .str(let s): out += PDFWriter.serialize(.string(s))
            case .adj(let d): out += Array(" \(fmt(d)) ".utf8)
            }
        }
        out += Array("] TJ".utf8)
        return out
    }

    private func redactText(_ k: Int, model: PageContentModel, file f: PDFFile, pageObj: Int, rects: [CGRect], resources: [String: PDFObj]) -> TextResult {
        let e = model.elements[k]
        guard let st = e.textState, st.tr < 4, st.size != 0, let fontName = st.font?.nameValue,
              let fd = f.fontDict(fontName, resources: resources), let metrics = FontMetrics(font: fd, file: f),
              let parsed = items(of: e, stream: model.stream) else { return .removeWhole }
        let (items, op, aw, ac) = parsed
        let tc = op == "\"" ? ac : st.tc, tw = op == "\"" ? aw : st.tw
        // Zeichenliste: (Item, Code)
        var glyphs: [(item: Int, code: Int)] = []
        for (i, it) in items.enumerated() { if case .str(let s) = it { for c in metrics.codes(s) { glyphs.append((i, c)) } } }
        guard !glyphs.isEmpty else { return .unchanged }
        let prefix = op == "'" ? "T* " : op == "\"" ? "\(fmt(aw)) Tw \(fmt(ac)) Tc T* " : ""

        /// Variante: nur die Zeichen in `visible` sichtbar (für Vermessung immer schwarz und gefüllt), Rest mit Tr 3
        func variant(visible: Set<Int>, forceVisible: Bool) -> [UInt8] {
            var out = Array(prefix.utf8)
            var run: [TJItem] = []
            var runVisible: Bool? = nil
            var g = 0
            func flush() {
                guard !run.isEmpty, let v = runVisible else { return }
                let tr = v ? (forceVisible ? 0 : st.tr) : 3
                out += Array("\(tr) Tr ".utf8)
                if v && forceVisible { out += Array("0 g 0 G ".utf8) }
                out += serializeTJ(run, prefix: "")
                out += Array(" ".utf8)
                run = []
            }
            for it in items {
                switch it {
                case .adj: run.append(it)
                case .str(let s):
                    for c in metrics.codes(s) {
                        let v = visible.contains(g); g += 1
                        if runVisible != nil, runVisible != v { flush() }
                        runVisible = v
                        if case .str(var last)? = run.last, (run.count > 0) { last += metrics.bytes(c); run[run.count - 1] = .str(last) }
                        else { run.append(.str(metrics.bytes(c))) }
                    }
                }
            }
            flush()
            out += Array("\(st.tr) Tr".utf8)
            return out
        }

        // 1. Jedes Zeichen einzeln vermessen
        let scale: CGFloat = 1.5
        var variants = [model.stream.render(model.elements.indices.map { .remove($0) })]
        for g in glyphs.indices { variants.append(model.stream.render([.isolate(k), .replace(k, variant(visible: [g], forceVisible: true))])) }
        let boxes = RedactRaster.bounds(file: f, pageObj: pageObj, mediaBox: model.mediaBox, variants: variants, scale: scale)
        guard boxes.count == glyphs.count + 1 else { return .removeWhole }
        var removed = Set<Int>()
        var removedBoxes: [CGRect] = []
        for g in glyphs.indices {
            guard let b = boxes[g + 1], b.width > 0, b.height > 0 else { continue }
            let hit = rects.contains { r in
                let i = b.intersection(r)
                if i.isNull { return false }
                return i.width * i.height >= 0.2 * b.width * b.height || r.contains(CGPoint(x: b.midX, y: b.midY))
            }
            if hit { removed.insert(g); removedBoxes.append(b) }
        }
        // Zeichen ohne Abdruck (Leerzeichen): entfernen, wenn ein Nachbar mit Abdruck entfernt wird
        for g in glyphs.indices where boxes[g + 1] == nil {
            var prev = g - 1; while prev >= 0, boxes[prev + 1] == nil { prev -= 1 }
            var next = g + 1; while next < glyphs.count, boxes[next + 1] == nil { next += 1 }
            if (prev >= 0 && removed.contains(prev)) || (next < glyphs.count && removed.contains(next)) { removed.insert(g) }
        }
        guard !removed.isEmpty else { return .unchanged }

        // 2. Neues TJ-Array: entfernte Zeichen werden zu Vorschub-Zahlen (Breite + Zeichen-/Wortabstand)
        var newItems: [TJItem] = []
        var buf: [UInt8] = []
        var pendingAdj = 0.0
        func flushBuf() { if !buf.isEmpty { newItems.append(.str(buf)); buf = [] } }
        func flushAdj() { if pendingAdj != 0 { newItems.append(.adj(pendingAdj)); pendingAdj = 0 } }
        var g = 0
        for it in items {
            switch it {
            case .adj(let d): flushBuf(); pendingAdj += d
            case .str(let s):
                for c in metrics.codes(s) {
                    if removed.contains(g) {
                        flushBuf()
                        let space = metrics.wordSpaceApplies && c == 32 ? tw : 0
                        pendingAdj -= metrics.width(c) + (tc + space) * 1000 / st.size
                    } else { flushAdj(); buf += metrics.bytes(c) }
                    g += 1
                }
            }
        }
        flushBuf(); flushAdj()
        let replacement = serializeTJ(newItems, prefix: prefix)

        // 3. Nachweis: Rest steht pixelgenau da, wo er vorher stand
        let kept = Set(glyphs.indices).subtracting(removed)
        let expected = model.stream.render([.isolate(k), .replace(k, variant(visible: kept, forceVisible: false))])
        let actual = model.stream.render([.isolate(k), .replace(k, replacement)])
        if let (diff, ink) = RedactRaster.difference(file: f, pageObj: pageObj, mediaBox: model.mediaBox, a: expected, b: actual, scale: 2) {
            if diff > max(6, ink / 100) {
                Log.w("Schwärzen: Zerlegung von „\(e.name)“ verschiebt Text (\(diff) px) – ganzes Stück entfernen")
                return removed.count == glyphs.count || !e.canRemove ? .removeWhole : .removeWhole
            }
        }
        return .replaced(replacement, removed.count, removedBoxes)
    }

    // MARK: Pfade

    private func clippedPath(_ e: ContentElement, stream: ContentStream, mediaBox: CGRect, rects: [CGRect]) -> [UInt8]? {
        guard !e.inText, (e.ctm.a * e.ctm.d - e.ctm.b * e.ctm.c) != 0 else { return nil }
        for t in e.tokens { if let op = stream.tokens[t].op, op == "W" || op == "W*" { return nil } }
        let inv = e.ctm.inverted(), c = e.ctm
        func cm(_ m: CGAffineTransform) -> String { "\(fmt(m.a)) \(fmt(m.b)) \(fmt(m.c)) \(fmt(m.d)) \(fmt(m.tx)) \(fmt(m.ty)) cm " }
        var out = Array(("q " + cm(inv) + "\(fmt(mediaBox.minX - 10)) \(fmt(mediaBox.minY - 10)) \(fmt(mediaBox.width + 20)) \(fmt(mediaBox.height + 20)) re ").utf8)
        for r in rects { out += Array("\(fmt(r.minX)) \(fmt(r.minY)) \(fmt(r.width)) \(fmt(r.height)) re ".utf8) }
        out += Array(("W* n " + cm(c) + "\n").utf8)
        for t in e.tokens { out += PDFWriter.serialize(stream.tokens[t].obj); out.append(stream.tokens[t].isOp ? 0x0A : 0x20) }
        out += Array("Q".utf8)
        return out
    }

    // MARK: Bilder

    /// Bild (oder Verlauf/Gruppe) neu rastern: so, wie es auf der Seite erscheint, mit geschwärzten Pixeln. Liefert Ersatz-Snippet, Ressourcenname und Objektreferenz.
    private func rasterizeElement(_ k: Int, model: PageContentModel, file f: PDFFile, pageObj: Int, rects: [CGRect], color: RGBA, resources: [String: PDFObj]) -> ([UInt8], String, PDFObj)? {
        let e = model.elements[k]
        guard (e.ctm.a * e.ctm.d - e.ctm.b * e.ctm.c) != 0 else { return nil }
        let inv = e.ctm.inverted()
        let iso = model.stream.render([.isolate(k)])
        let blank = model.stream.render(model.elements.indices.map { .remove($0) })
        guard let b = RedactRaster.bounds(file: f, pageObj: pageObj, mediaBox: model.mediaBox, variants: [blank, iso], scale: 2)[1], b.width > 0.5, b.height > 0.5 else { return nil }
        // Auflösung: native Bildauflösung, 72…600 dpi
        var dpi: CGFloat = 300
        var wasJPEG = false
        if e.kind == .image, let xo = f.resolve(resources["XObject"] ?? .null).dictValue, let img = f.resolve(xo[e.name] ?? .null).dictValue {
            if let pw = f.resolve(img["Width"] ?? .null).doubleValue, pw > 0 { dpi = CGFloat(pw) / b.width * 72 }
            let filt = f.resolve(img["Filter"] ?? .null)
            wasJPEG = filt.nameValue == "DCTDecode" || (filt.arrayValue?.contains { f.resolve($0).nameValue == "DCTDecode" } ?? false)
        }
        dpi = min(600, max(72, dpi))
        var scale = dpi / 72
        while b.width * scale * b.height * scale > 30_000_000 { scale *= 0.8 }
        let w = Int(ceil(b.width * scale)), h = Int(ceil(b.height * scale))
        guard w > 0, h > 0,
              let data = f.standalone(pageObj: pageObj, contents: [iso], mediaBox: model.mediaBox),
              let prov = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(prov), let pg = doc.page(at: 1),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / b.width, y: CGFloat(h) / b.height)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        ctx.drawPDFPage(pg)
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
        for r in rects { ctx.fill(r) }
        // Deckend?
        var opaque = true
        for i in stride(from: 3, to: w * h * 4, by: 4) where px[i] != 255 { opaque = false; break }
        let n = nextObj; nextObj += 1
        var dict: [String: PDFObj] = ["Type": .name("XObject"), "Subtype": .name("Image"), "Width": .int(w), "Height": .int(h),
                                      "ColorSpace": .name("DeviceRGB"), "BitsPerComponent": .int(8)]
        var payload: [UInt8]
        if opaque && (wasJPEG || w * h > 400_000) {
            guard let cg = ctx.makeImage(), let jpg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else { return nil }
            payload = [UInt8](jpg); dict["Filter"] = .name("DCTDecode")
        } else {
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            var alpha = [UInt8](repeating: 0, count: w * h)
            for i in 0..<(w * h) {
                let a = px[i * 4 + 3]
                alpha[i] = a
                if a == 0 || a == 255 { rgb[i * 3] = px[i * 4]; rgb[i * 3 + 1] = px[i * 4 + 1]; rgb[i * 3 + 2] = px[i * 4 + 2] }
                else { for c in 0..<3 { rgb[i * 3 + c] = UInt8(min(255, Int(px[i * 4 + c]) * 255 / Int(a))) } }
            }
            payload = RedactRaster.zlib(rgb); dict["Filter"] = .name("FlateDecode")
            guard !payload.isEmpty else { return nil }
            if !opaque {
                let sm = nextObj; nextObj += 1
                let smData = RedactRaster.zlib(alpha)
                guard !smData.isEmpty else { return nil }
                newObjects.append((sm, .stream(["Type": .name("XObject"), "Subtype": .name("Image"), "Width": .int(w), "Height": .int(h),
                                                "ColorSpace": .name("DeviceGray"), "BitsPerComponent": .int(8), "Filter": .name("FlateDecode")], smData)))
                dict["SMask"] = .ref(sm, 0)
            }
        }
        newObjects.append((n, .stream(dict, payload)))
        let name = "PDFWR\(n)"
        // Das Snippet steht an der Stelle des alten Elements – dort gilt dessen CTM. Erst zurück in Seitenkoordinaten, dann platzieren.
        let m = CGAffineTransform(a: b.width, b: 0, c: 0, d: b.height, tx: b.minX, ty: b.minY).concatenating(inv)
        let snip = Array("q \(fmt(m.a)) \(fmt(m.b)) \(fmt(m.c)) \(fmt(m.d)) \(fmt(m.tx)) \(fmt(m.ty)) cm /\(name) Do Q".utf8)
        return (snip, name, .ref(n, 0))
    }

    /// Letzte Stufe: ganze Seite als Bild (300 dpi) mit geschwärzten Flächen
    private func rasterizePage(file f: PDFFile, pageIndex: Int, mediaBox: CGRect, rects: [CGRect], color: RGBA) -> ([UInt8], [String: PDFObj])? {
        guard let prov = CGDataProvider(data: Data(f.bytes) as CFData), let doc = CGPDFDocument(prov), let pg = doc.page(at: pageIndex + 1) else { return nil }
        var scale: CGFloat = 300 / 72
        while mediaBox.width * scale * mediaBox.height * scale > 40_000_000 { scale *= 0.8 }
        let w = Int(ceil(mediaBox.width * scale)), h = Int(ceil(mediaBox.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
        ctx.drawPDFPage(pg)
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
        for r in rects { ctx.fill(r) }
        guard let cg = ctx.makeImage(), let jpg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        let n = nextObj; nextObj += 1
        newObjects.append((n, .stream(["Type": .name("XObject"), "Subtype": .name("Image"), "Width": .int(w), "Height": .int(h), "ColorSpace": .name("DeviceRGB"),
                                       "BitsPerComponent": .int(8), "Filter": .name("DCTDecode")], [UInt8](jpg))))
        let name = "PDFWRpage"
        let content = Array("q \(fmt(mediaBox.width)) 0 0 \(fmt(mediaBox.height)) \(fmt(mediaBox.minX)) \(fmt(mediaBox.minY)) cm /\(name) Do Q\n".utf8)
        return (content, ["ProcSet": .array([.name("PDF"), .name("ImageC")]), "XObject": .dict([name: .ref(n, 0)])])
    }

    // MARK: Prüfung

    /// Vorher/Nachher-Vergleich der Darstellung außerhalb der geänderten Zonen (72 dpi). Liefert abweichende Pixel je Seite.
    func checkAppearance(before: Data, after: Data) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for (pageIndex, zones) in report.changedZones {
            guard let a = RedactRaster.pageGray(before, pageIndex: pageIndex, scale: 1), let b = RedactRaster.pageGray(after, pageIndex: pageIndex, scale: 1),
                  a.w == b.w, a.h == b.h else { continue }
            let box = a.box
            var diff = 0
            for y in 0..<a.h {
                for x in 0..<a.w where abs(Int(a.px[y * a.w + x]) - Int(b.px[y * a.w + x])) > 40 {
                    let p = CGPoint(x: CGFloat(x) + 0.5 + box.minX, y: CGFloat(a.h - 1 - y) + 0.5 + box.minY)
                    if !zones.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(p) }) { diff += 1 }
                }
            }
            out[pageIndex] = diff
        }
        return out
    }
}

// MARK: - Suchen und schwärzen

enum RedactPatterns {
    static let presets: [(String, String)] = [
        ("Eigener Text", ""),
        ("IBAN", #"\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){2,7}(?:\s?[A-Z0-9]{1,4})?\b"#),
        ("E-Mail-Adressen", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
        ("Telefonnummern", #"(?<![\d\w])(?:\+\d{2}\s?|0)\d{2,5}[\s/\-]?\d{3,}(?:[\s\-]?\d{2,})*"#),
        ("Datumsangaben", #"\b\d{1,2}\.\s?\d{1,2}\.\s?\d{2,4}\b"#),
    ]

    /// Findet Treffer im Dokument und liefert je Treffer die Zeilenrechtecke in Seitenkoordinaten.
    static func find(in doc: PDFDocument, pattern: String, isRegex: Bool, caseSensitive: Bool) -> [(page: Int, rect: CGRect, text: String)] {
        var out: [(Int, CGRect, String)] = []
        let pat = isRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        guard !pat.isEmpty, let re = try? NSRegularExpression(pattern: pat, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i), let s = p.string, !s.isEmpty else { continue }
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                guard let sel = p.selection(for: m.range) else { continue }
                for line in sel.selectionsByLine() {
                    let r = line.bounds(for: p)
                    guard r.isUsable, r.width > 0.5, r.height > 0.5 else { continue }
                    out.append((i, r.insetBy(dx: -0.5, dy: -0.5), ns.substring(with: m.range)))
                }
            }
        }
        return out
    }
}

// MARK: - Selbsttest ohne Fenster

/// PDFW_REDACT_TEST=<Ordner mit PDFs>: schwärzt IBAN/„Mustermann“ (bzw. ein festes Rechteck bei reinen Scans),
/// prüft Text und Darstellung und schreibt Ergebnisse als *.geschwaerzt.pdf. Beendet die App mit 0/1.
enum RedactTest {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["PDFW_REDACT_TEST"] else { return }
        var ok = true
        var lines: [String] = []
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".pdf") && !$0.contains(".geschwaerzt") }.sorted()
        for name in files {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard let doc = PDFDocument(url: url), let fresh = doc.dataRepresentation() else { lines.append("\(name): nicht ladbar"); ok = false; continue }
            let normalized = PDFDocument(data: fresh)!
            var marks: [RedactMark] = []
            for (pattern, regex) in [(#"DE89\s?3704\s?0044\s?0532\s?0130\s?00"#, true), ("Mustermann", false), ("geheim123", false)] {
                for hit in RedactPatterns.find(in: normalized, pattern: pattern, isRegex: regex, caseSensitive: false) {
                    marks.append(RedactMark(pageIndex: hit.page, rect: hit.rect, color: RGBA(.black)))
                }
            }
            if name.contains("chrome") { marks.append(RedactMark(pageIndex: 0, rect: CGRect(x: 100, y: 505, width: 60, height: 30), color: RGBA(.black))) }   // Teil des eingebetteten Scan-Bilds
            if marks.isEmpty, let p = normalized.page(at: 0) {   // reiner Scan: festes Rechteck über der ersten Zeile
                let b = p.bounds(for: .mediaBox)
                marks.append(RedactMark(pageIndex: 0, rect: CGRect(x: b.minX + 54, y: b.maxY - 92, width: 380, height: 24), color: RGBA(.black)))
            }
            let t0 = Date()
            let red = Redactor(marks: marks)
            guard let out = red.apply(to: fresh, paintBoxes: true), let outDoc = PDFDocument(data: out) else {
                lines.append("\(name): FEHLER – \(red.report.notes.joined(separator: "; "))"); ok = false; continue
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            var leaks: [String] = []
            for m in marks {
                if let p = outDoc.page(at: m.pageIndex), let s = p.selection(for: m.rect.insetBy(dx: 1, dy: 1))?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { leaks.append("S\(m.pageIndex + 1): „\(s)“") }
            }
            for t in ["DE89", "0532 0130", "Mustermann", "geheim123"] where !outDoc.findString(t, withOptions: [.caseInsensitive]).isEmpty { leaks.append("„\(t)“ noch auffindbar") }
            let eofs = out.ranges(of: "%%EOF".data(using: .utf8)!).count
            let diffs = red.checkAppearance(before: fresh, after: out)
            let diffText = diffs.map { "S\($0.key + 1): \($0.value) px" }.joined(separator: ", ")
            let outURL = url.deletingPathExtension().appendingPathExtension("geschwaerzt.pdf")
            try? out.write(to: outURL)
            // Bild der ersten geschwärzten Seite
            if let p = outDoc.page(at: marks.first?.pageIndex ?? 0), let img = PDFTools.render(p, dpi: 100) {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url.deletingPathExtension().appendingPathExtension("geschwaerzt.png"))
            }
            let good = leaks.isEmpty && eofs == 1 && diffs.values.allSatisfy { $0 < 60 }
            if !good { ok = false }
            lines.append("\(good ? "OK  " : "FEHL") \(name): \(marks.count) Markierungen, \(red.report.summary), \(ms) ms, \(out.count / 1024) KB, EOF=\(eofs), Abweichung außerhalb: \(diffText.isEmpty ? "–" : diffText)"
                         + (leaks.isEmpty ? "" : " ⚠️ " + leaks.joined(separator: "; ")) + (red.report.notes.isEmpty ? "" : " · " + red.report.notes.joined(separator: "; ")))
        }
        let text = lines.joined(separator: "\n")
        print(text)
        try? text.write(toFile: dir + "/schwaerzen-ergebnis.txt", atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }
}
