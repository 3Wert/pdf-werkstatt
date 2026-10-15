import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum FontMatch {
    static let available = Set(NSFontManager.shared.availableFonts)

    static func name(for f: NSFont?) -> String { match(for: f).name }

    /// Name ohne Subset-Präfix („ABCDEF+Calibri-Bold“ → „Calibri-Bold“)
    static func clean(_ n: String) -> String {
        if n.count > 7, Array(n)[6] == "+" { return String(n.dropFirst(7)) }
        return n
    }

    /// Sucht eine installierte Schrift, die der Schrift im PDF möglichst nahe kommt. `exact` = wirklich dieselbe Schrift.
    static func match(for f: NSFont?) -> (name: String, exact: Bool) {
        guard let f else { return ("ArialMT", true) }
        let n = clean(f.fontName)
        let candidates = [n, n.replacingOccurrences(of: ",", with: "-"), n + "MT",
                          n.replacingOccurrences(of: "MT", with: ""), n.replacingOccurrences(of: "PS", with: "")]
        for c in candidates where available.contains(c) { return (c, true) }
        let l = n.lowercased()
        let bold = ["bold", "black", "heavy", "semibold", "demi"].contains { l.contains($0) }
        let italic = l.contains("italic") || l.contains("oblique")
        let mono = ["courier", "mono", "consol"].contains { l.contains($0) }
        let serif = ["times", "serif", "garamond", "georgia", "cambria", "minion", "palatino", "book"].contains { l.contains($0) } && !l.contains("sans")
        let family = mono ? "Courier New" : serif ? "Times New Roman" : (l.contains("helvetica") ? "Helvetica" : "Arial")
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return (NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: 12)?.fontName ?? "ArialMT", false)
    }
}

enum PDFTools {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func normRotation(_ r: Int) -> Int { ((r % 360) + 360) % 360 }

    /// Häufigste Farbe direkt um ein Rechteck herum (Hintergrund hinter Text).
    static func backgroundColor(around r: CGRect, on page: PDFPage) -> NSColor {
        guard let cg = page.pageRef else { return .white }
        let area = r.insetBy(dx: -3, dy: -3)
        let s: CGFloat = 2
        let w = Int(ceil(area.width * s)), h = Int(ceil(area.height * s))
        guard w > 4, h > 4, w < 20000, h < 20000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        ctx.drawPDFPage(cg)
        guard let data = ctx.data else { return .white }
        let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var counts: [Int: (Int, Int, Int, Int)] = [:]
        func sample(_ x: Int, _ y: Int) {
            let i = (y * w + x) * 4
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            let c = counts[key] ?? (0, 0, 0, 0)
            counts[key] = (c.0 + 1, c.1 + r, c.2 + g, c.3 + b)
        }
        for x in 0..<w { for y in [0, 1, h - 2, h - 1] { sample(x, y) } }
        for y in 2..<(h - 2) { for x in [0, 1, w - 2, w - 1] { sample(x, y) } }
        guard let best = counts.values.max(by: { $0.0 < $1.0 }) else { return .white }
        let n = CGFloat(best.0) * 255
        return NSColor(srgbRed: CGFloat(best.1) / n, green: CGFloat(best.2) / n, blue: CGFloat(best.3) / n, alpha: 1)
    }

    /// Rechteck in „sichtbaren“ Seitenkoordinaten (wie auf dem Bildschirm) → PDF-Seitenkoordinaten.
    static func visualToPage(_ r: CGRect, page: PDFPage) -> CGRect {
        let c = page.bounds(for: .cropBox)
        let W = c.width, H = c.height
        let rot = normRotation(page.rotation)
        func m(_ p: CGPoint) -> CGPoint {
            switch rot {
            case 90: return CGPoint(x: W - p.y, y: p.x)
            case 180: return CGPoint(x: W - p.x, y: H - p.y)
            case 270: return CGPoint(x: p.y, y: H - p.x)
            default: return p
            }
        }
        let a = m(CGPoint(x: r.minX, y: r.minY)), b = m(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x) + c.minX, y: min(a.y, b.y) + c.minY, width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func visualSize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox).size
        let r = normRotation(page.rotation)
        return (r == 90 || r == 270) ? CGSize(width: b.height, height: b.width) : b
    }

    static func blankPage(size: CGSize) -> PDFPage {
        let data = NSMutableData()
        var mb = CGRect(origin: .zero, size: size)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &mb, nil)!
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        return PDFDocument(data: data as Data)!.page(at: 0)!
    }

    static let a4 = CGSize(width: 595.28, height: 841.89)

    /// Bilddaten für ein Bildobjekt: gedreht nach EXIF, höchstens 2400 px, JPEG oder PNG (bei Transparenz).
    static func prepareImage(_ data: Data, maxPixels: Int = 2400) -> (Data, CGSize)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return encode(img)
    }

    static func encode(_ img: CGImage) -> (Data, CGSize)? {
        let alpha = img.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let rep = NSBitmapImageRep(cgImage: img)
        let out = hasAlpha ? rep.representation(using: .png, properties: [:])
                           : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
        guard let out else { return nil }
        return (out, CGSize(width: img.width, height: img.height))
    }

    /// Macht helle Pixel durchsichtig und schneidet auf den Inhalt zu (für eingescannte Unterschriften).
    static func removeWhite(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 2000] as CFDictionary) else { return nil }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(p[i]), g = Double(p[i + 1]), b = Double(p[i + 2])
                let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
                let a = max(0, min(1, (0.82 - lum) / 0.3))
                // dunkles Blau/Schwarz behalten, Farbe auf Deckkraft vormultiplizieren
                p[i] = UInt8(r * a); p[i + 1] = UInt8(g * a); p[i + 2] = UInt8(b * a); p[i + 3] = UInt8(a * 255)
                if a > 0.1 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX > minX, maxY > minY, let full = ctx.makeImage() else { return nil }
        // Zeile 0 im Speicher = oben
        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1).insetBy(dx: -4, dy: -4)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cut = full.cropping(to: crop) else { return nil }
        return NSBitmapImageRep(cgImage: cut).representation(using: .png, properties: [:])
    }

    // MARK: Export

    /// Seite als Bitmap (mit allen Objekten), aufrecht wie angezeigt.
    static func render(_ p: PDFPage, dpi: CGFloat) -> CGImage? { DrawMode.full { renderFull(p, dpi: dpi) } }

    private static func renderFull(_ p: PDFPage, dpi: CGFloat) -> CGImage? {
        let vs = visualSize(p)
        let s = dpi / 72
        let w = Int(vs.width * s), h = Int(vs.height * s)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        p.draw(with: .cropBox, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Alle Objekte fest in den Seiteninhalt schreiben (bleibt Vektor/Text).
    /// Gespeicherter Zwischenstand: PDFKit zeichnet eigene Objekte auf gedrehten Seiten nur aus der gespeicherten Form richtig.
    static func snapshot(_ d: PDFDocument) -> PDFDocument {
        DrawMode.full {
            if let data = d.dataRepresentation(), let s = PDFDocument(data: data) { return s }
            return d
        }
    }

    static func flattened(_ src: PDFDocument) -> Data { DrawMode.full { flattenedFull(src) } }

    private static func flattenedFull(_ src: PDFDocument) -> Data {
        let d = snapshot(src)
        let out = NSMutableData()
        var mb = CGRect.zero
        let ctx = CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: &mb, nil)!
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            var box = CGRect(origin: .zero, size: visualSize(p))
            ctx.beginPage(mediaBox: &box)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            p.draw(with: .cropBox, to: ctx)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPage()
        }
        ctx.closePDF()
        return out as Data
    }

    /// Jede Seite als Bild – verdeckter Text ist danach wirklich weg.
    static func rasterized(_ src: PDFDocument, dpi: CGFloat = 200) -> Data { DrawMode.full { rasterizedFull(src, dpi: dpi) } }

    private static func rasterizedFull(_ src: PDFDocument, dpi: CGFloat) -> Data {
        let d = snapshot(src)
        let out = NSMutableData()
        var mb = CGRect.zero
        let ctx = CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: &mb, nil)!
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i), let img = render(p, dpi: dpi) else { continue }
            var box = CGRect(origin: .zero, size: visualSize(p))
            ctx.beginPage(mediaBox: &box)
            if let jpg = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
               let prov = CGDataProvider(data: jpg as CFData),
               let j = CGImage(jpegDataProviderSource: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                ctx.draw(j, in: box)
            } else { ctx.draw(img, in: box) }
            ctx.endPage()
        }
        ctx.closePDF()
        return out as Data
    }

    static func writeOptions(password: String?) -> [PDFDocumentWriteOption: Any] {
        guard let pw = password, !pw.isEmpty else { return [:] }
        return [.userPasswordOption: pw, .ownerPasswordOption: pw]
    }
}
