import Foundation
import Compression
import CoreGraphics

// Direkter Eingriff in den Seiteninhalt eines PDFs: Elemente (Textstücke, Pfade, Bilder) erkennen,
// löschen oder verschieben. Arbeitet auf der Ausgabe von PDFKit (klassische xref-Tabelle, keine Objektströme).

// MARK: - PDF-Objekte

indirect enum PDFObj {
    case null, bool(Bool), int(Int), real(Double)
    case string([UInt8]), name(String)
    case array([PDFObj]), dict([String: PDFObj])
    case ref(Int, Int)
    case stream([String: PDFObj], [UInt8])     // Wörterbuch + Rohdaten (noch kodiert)
    case op(String)                              // nur in Inhaltsströmen

    var intValue: Int? { if case .int(let i) = self { return i }; if case .real(let r) = self { return Int(r) }; return nil }
    var doubleValue: Double? { if case .int(let i) = self { return Double(i) }; if case .real(let r) = self { return r }; return nil }
    var nameValue: String? { if case .name(let n) = self { return n }; return nil }
    var arrayValue: [PDFObj]? { if case .array(let a) = self { return a }; return nil }
    var dictValue: [String: PDFObj]? {
        if case .dict(let d) = self { return d }
        if case .stream(let d, _) = self { return d }
        return nil
    }
}

enum PDFContentError: Error { case unsupported(String), parse(String) }

// MARK: - Lexer/Parser

struct PDFLexer {
    let b: [UInt8]
    var i: Int

    init(_ bytes: [UInt8], at: Int = 0) { b = bytes; i = at }

    static func isWhite(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }
    static func isDelim(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }
    static func isRegular(_ c: UInt8) -> Bool { !isWhite(c) && !isDelim(c) }

    mutating func skipWhite() {
        while i < b.count {
            if PDFLexer.isWhite(b[i]) { i += 1 }
            else if b[i] == 0x25 { while i < b.count && b[i] != 0x0A && b[i] != 0x0D { i += 1 } }   // Kommentar
            else { break }
        }
    }

    mutating func readToken() -> String? {
        skipWhite()
        guard i < b.count else { return nil }
        let s = i
        if PDFLexer.isRegular(b[i]) { while i < b.count && PDFLexer.isRegular(b[i]) { i += 1 } }
        else { i += 1 }
        return String(decoding: b[s..<i], as: UTF8.self)
    }

    /// Liest ein Objekt. In Inhaltsströmen werden Operatoren als .op geliefert.
    mutating func parseObject(resolveLength: ((PDFObj) -> Int?)? = nil) throws -> PDFObj? {
        skipWhite()
        guard i < b.count else { return nil }
        let c = b[i]
        switch c {
        case 0x2F: // /Name
            i += 1
            let s = i
            while i < b.count && PDFLexer.isRegular(b[i]) { i += 1 }
            var raw = Array(b[s..<i])
            // #xx-Kodierung auflösen
            var out: [UInt8] = []
            var k = 0
            while k < raw.count {
                if raw[k] == 0x23, k + 2 < raw.count, let v = UInt8(String(decoding: raw[(k + 1)...(k + 2)], as: UTF8.self), radix: 16) { out.append(v); k += 3 }
                else { out.append(raw[k]); k += 1 }
            }
            raw = out
            return .name(String(decoding: raw, as: UTF8.self))
        case 0x28: // (string)
            i += 1
            var depth = 1
            var out: [UInt8] = []
            while i < b.count {
                let ch = b[i]
                if ch == 0x5C { // backslash
                    i += 1
                    guard i < b.count else { break }
                    let e = b[i]
                    switch e {
                    case 0x6E: out.append(0x0A); i += 1
                    case 0x72: out.append(0x0D); i += 1
                    case 0x74: out.append(0x09); i += 1
                    case 0x62: out.append(0x08); i += 1
                    case 0x66: out.append(0x0C); i += 1
                    case 0x0A: i += 1
                    case 0x0D: i += 1; if i < b.count && b[i] == 0x0A { i += 1 }
                    case 0x30...0x37:
                        var v = 0, n = 0
                        while n < 3, i < b.count, b[i] >= 0x30, b[i] <= 0x37 { v = v * 8 + Int(b[i] - 0x30); i += 1; n += 1 }
                        out.append(UInt8(v & 0xFF))
                    default: out.append(e); i += 1
                    }
                } else if ch == 0x28 { depth += 1; out.append(ch); i += 1 }
                else if ch == 0x29 { depth -= 1; i += 1; if depth == 0 { break }; out.append(ch) }
                else { out.append(ch); i += 1 }
            }
            return .string(out)
        case 0x3C: // << dict  oder <hex>
            if i + 1 < b.count && b[i + 1] == 0x3C {
                i += 2
                var d: [String: PDFObj] = [:]
                while true {
                    skipWhite()
                    guard i < b.count else { throw PDFContentError.parse("dict") }
                    if b[i] == 0x3E && i + 1 < b.count && b[i + 1] == 0x3E { i += 2; break }
                    guard case .name(let key)? = try parseObject(resolveLength: resolveLength) else { throw PDFContentError.parse("dict key") }
                    guard let val = try parseObject(resolveLength: resolveLength) else { throw PDFContentError.parse("dict value") }
                    d[key] = val
                }
                // Stream?
                let save = i
                skipWhite()
                if i + 6 <= b.count, Array(b[i..<(i + 6)]) == Array("stream".utf8) {
                    i += 6
                    if i < b.count && b[i] == 0x0D { i += 1 }
                    if i < b.count && b[i] == 0x0A { i += 1 }
                    var len = d["Length"]?.intValue
                    if len == nil, let l = d["Length"], let r = resolveLength { len = r(l) }
                    var data: [UInt8]
                    if let len, i + len <= b.count { data = Array(b[i..<(i + len)]); i += len }
                    else {
                        // ohne gültige Länge: bis "endstream" suchen
                        let s = i
                        guard let e = PDFLexer.find(b, Array("endstream".utf8), from: s) else { throw PDFContentError.parse("endstream") }
                        var end = e
                        if end > s && b[end - 1] == 0x0A { end -= 1 }
                        if end > s && b[end - 1] == 0x0D { end -= 1 }
                        data = Array(b[s..<end]); i = e
                    }
                    skipWhite()
                    if i + 9 <= b.count, Array(b[i..<(i + 9)]) == Array("endstream".utf8) { i += 9 }
                    return .stream(d, data)
                }
                i = save
                return .dict(d)
            }
            i += 1
            var hex: [UInt8] = []
            var nib: [UInt8] = []
            while i < b.count && b[i] != 0x3E {
                let ch = b[i]; i += 1
                if PDFLexer.isWhite(ch) { continue }
                guard let v = UInt8(String(UnicodeScalar(ch)), radix: 16) else { continue }
                nib.append(v)
                if nib.count == 2 { hex.append(nib[0] << 4 | nib[1]); nib = [] }
            }
            if nib.count == 1 { hex.append(nib[0] << 4) }
            i += 1
            return .string(hex)
        case 0x5B: // [array]
            i += 1
            var a: [PDFObj] = []
            while true {
                skipWhite()
                guard i < b.count else { throw PDFContentError.parse("array") }
                if b[i] == 0x5D { i += 1; break }
                guard let v = try parseObject(resolveLength: resolveLength) else { throw PDFContentError.parse("array item") }
                a.append(v)
            }
            return .array(a)
        case 0x5D, 0x3E, 0x29, 0x7B, 0x7D:
            i += 1
            return .op(String(UnicodeScalar(c)))   // verirrte Begrenzer als Operator durchreichen
        default:
            guard let tok = readToken() else { return nil }
            if tok == "true" { return .bool(true) }
            if tok == "false" { return .bool(false) }
            if tok == "null" { return .null }
            if let n = Int(tok) {
                // Referenz "n g R"?
                let save = i
                if let g = readToken(), let gi = Int(g), let r = readToken(), r == "R" { return .ref(n, gi) }
                i = save
                return .int(n)
            }
            if let d = Double(tok.hasPrefix(".") ? "0" + tok : tok.replacingOccurrences(of: "-.", with: "-0.")) { return .real(d) }
            return .op(tok)
        }
    }

    static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = max(0, from)
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == needle[0] {
                var ok = true
                for k in 1..<needle.count where hay[i + k] != needle[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    static func findLast(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            var ok = true
            for k in 0..<needle.count where hay[i + k] != needle[k] { ok = false; break }
            if ok { return i }
            i -= 1
        }
        return nil
    }
}

// MARK: - Serialisierung

enum PDFWriter {
    static func serialize(_ o: PDFObj) -> [UInt8] {
        var out: [UInt8] = []
        write(o, into: &out)
        return out
    }

    private static func write(_ o: PDFObj, into out: inout [UInt8]) {
        switch o {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .int(let i): out += Array(String(i).utf8)
        case .real(let r):
            var s = String(format: "%.4f", r)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            out += Array(s.utf8)
        case .string(let s):
            out.append(0x3C)
            for c in s { out += Array(String(format: "%02X", c).utf8) }
            out.append(0x3E)
        case .name(let n):
            out.append(0x2F)
            for c in n.utf8 {
                if PDFLexer.isRegular(c) && c != 0x23 && c > 0x20 && c < 0x7F { out.append(c) }
                else { out += Array(String(format: "#%02X", c).utf8) }
            }
        case .array(let a):
            out.append(0x5B)
            for (k, v) in a.enumerated() { if k > 0 { out.append(0x20) }; write(v, into: &out) }
            out.append(0x5D)
        case .dict(let d):
            out += Array("<<".utf8)
            for (k, v) in d.sorted(by: { $0.key < $1.key }) { write(.name(k), into: &out); out.append(0x20); write(v, into: &out); out.append(0x20) }
            out += Array(">>".utf8)
        case .ref(let n, let g): out += Array("\(n) \(g) R".utf8)
        case .stream(let d, let data):
            var dd = d; dd["Length"] = .int(data.count)
            write(.dict(dd), into: &out)
            out += Array("\nstream\n".utf8)
            out += data
            out += Array("\nendstream".utf8)
        case .op(let s): out += Array(s.utf8)
        }
    }
}

// MARK: - Filter

enum PDFFilters {
    static func inflate(_ data: [UInt8]) -> [UInt8]? {
        guard data.count > 2 else { return nil }
        // zlib-Kopf (2 Byte) überspringen – Compression erwartet rohes Deflate
        var src = Array(data.dropFirst(2))
        var cap = max(src.count * 8, 64 * 1024)
        for _ in 0..<6 {
            var dst = [UInt8](repeating: 0, count: cap)
            let n = src.withUnsafeMutableBufferPointer { sp in
                dst.withUnsafeMutableBufferPointer { dp in
                    compression_decode_buffer(dp.baseAddress!, cap, sp.baseAddress!, sp.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n == 0 { return nil }
            if n < cap { return Array(dst[0..<n]) }
            cap *= 4
        }
        return nil
    }

    static func unpredict(_ data: [UInt8], predictor: Int, colors: Int, bpc: Int, columns: Int) -> [UInt8] {
        guard predictor >= 10 else { return data }
        let bpp = max(1, colors * bpc / 8)
        let rowLen = (columns * colors * bpc + 7) / 8
        var out: [UInt8] = []
        var prev = [UInt8](repeating: 0, count: rowLen)
        var i = 0
        while i + 1 + rowLen <= data.count {
            let ft = data[i]; i += 1
            var row = Array(data[i..<(i + rowLen)]); i += rowLen
            for x in 0..<rowLen {
                let a = x >= bpp ? Int(row[x - bpp]) : 0
                let b = Int(prev[x])
                let c = x >= bpp ? Int(prev[x - bpp]) : 0
                switch ft {
                case 1: row[x] = UInt8((Int(row[x]) + a) & 0xFF)
                case 2: row[x] = UInt8((Int(row[x]) + b) & 0xFF)
                case 3: row[x] = UInt8((Int(row[x]) + (a + b) / 2) & 0xFF)
                case 4:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                    row[x] = UInt8((Int(row[x]) + pred) & 0xFF)
                default: break
                }
            }
            out += row
            prev = row
        }
        return out
    }
}

// MARK: - Datei

final class PDFFile {
    let bytes: [UInt8]
    private(set) var offsets: [Int: Int] = [:]          // Objektnummer → Byte-Offset
    private(set) var trailer: [String: PDFObj] = [:]
    private(set) var startXref = 0
    private(set) var maxObj = 0
    private var cache: [Int: PDFObj] = [:]

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard let sx = PDFLexer.findLast(bytes, Array("startxref".utf8)) else { throw PDFContentError.parse("startxref") }
        var lx = PDFLexer(bytes, at: sx + 9)
        guard let t = lx.readToken(), let off = Int(t) else { throw PDFContentError.parse("startxref offset") }
        startXref = off
        var next: Int? = off
        var seen = Set<Int>()
        while let o = next, !seen.contains(o), o < bytes.count {
            seen.insert(o)
            next = try parseXref(at: o)
        }
        if trailer["Encrypt"] != nil { throw PDFContentError.unsupported("verschlüsselt") }
        maxObj = max(maxObj, (trailer["Size"]?.intValue ?? 1) - 1)
    }

    /// Liest eine xref-Tabelle (klassisch). Liefert /Prev.
    private func parseXref(at off: Int) throws -> Int? {
        var lx = PDFLexer(bytes, at: off)
        guard let tok = lx.readToken() else { throw PDFContentError.parse("xref") }
        guard tok == "xref" else { throw PDFContentError.unsupported("xref-Stream") }
        while true {
            lx.skipWhite()
            if lx.i + 7 <= bytes.count, Array(bytes[lx.i..<(lx.i + 7)]) == Array("trailer".utf8) {
                lx.i += 7
                guard case .dict(let d)? = try lx.parseObject() else { throw PDFContentError.parse("trailer") }
                for (k, v) in d where trailer[k] == nil { trailer[k] = v }
                if let xs = d["XRefStm"]?.intValue { _ = xs; throw PDFContentError.unsupported("Hybrid-xref") }
                return d["Prev"]?.intValue
            }
            guard let s = lx.readToken(), let start = Int(s), let c = lx.readToken(), let count = Int(c) else { throw PDFContentError.parse("xref section") }
            lx.skipWhite()
            for k in 0..<count {
                guard let o = lx.readToken(), let g = lx.readToken(), let ty = lx.readToken() else { throw PDFContentError.parse("xref entry") }
                _ = g
                let num = start + k
                if ty == "n", let ov = Int(o), offsets[num] == nil { offsets[num] = ov }
                maxObj = max(maxObj, num)
            }
        }
    }

    func object(_ num: Int) -> PDFObj? {
        if let c = cache[num] { return c }
        guard let off = offsets[num], off < bytes.count else { return nil }
        var lx = PDFLexer(bytes, at: off)
        guard let n = lx.readToken(), Int(n) == num, let _ = lx.readToken(), let o = lx.readToken(), o == "obj" else { return nil }
        let obj = try? lx.parseObject(resolveLength: { [weak self] l in self?.resolve(l).intValue })
        if let obj { cache[num] = obj }
        return obj
    }

    func resolve(_ o: PDFObj) -> PDFObj {
        if case .ref(let n, _) = o { return object(n) ?? .null }
        return o
    }

    func decoded(_ s: PDFObj) -> [UInt8]? {
        guard case .stream(let d, let raw) = s else { return nil }
        var filters: [String] = []
        switch resolve(d["Filter"] ?? .null) {
        case .name(let n): filters = [n]
        case .array(let a): filters = a.compactMap { resolve($0).nameValue }
        default: break
        }
        var data = raw
        var parms: [[String: PDFObj]?] = []
        switch resolve(d["DecodeParms"] ?? .null) {
        case .dict(let p): parms = [p]
        case .array(let a): parms = a.map { resolve($0).dictValue }
        default: parms = []
        }
        for (k, f) in filters.enumerated() {
            switch f {
            case "FlateDecode", "Fl":
                guard let inf = PDFFilters.inflate(data) else { return nil }
                data = inf
                if k < parms.count, let p = parms[k], let pred = resolve(p["Predictor"] ?? .null).intValue, pred > 1 {
                    data = PDFFilters.unpredict(data, predictor: pred, colors: resolve(p["Colors"] ?? .int(1)).intValue ?? 1,
                                               bpc: resolve(p["BitsPerComponent"] ?? .int(8)).intValue ?? 8, columns: resolve(p["Columns"] ?? .int(1)).intValue ?? 1)
                }
            default: return nil      // andere Filter: nicht unterstützt
            }
        }
        return data
    }

    // MARK: Seiten

    /// Objektnummern aller Seiten in Reihenfolge
    func pageObjects() -> [Int] {
        guard let root = trailer["Root"], case .ref(let rn, _) = root, let cat = object(rn)?.dictValue,
              case .ref(let pn, _)? = cat["Pages"] else { return [] }
        var out: [Int] = []
        var seen = Set<Int>()
        func walk(_ n: Int) {
            guard !seen.contains(n), let d = object(n)?.dictValue else { return }
            seen.insert(n)
            let type = resolve(d["Type"] ?? .null).nameValue
            if type == "Page" { out.append(n); return }
            if let kids = resolve(d["Kids"] ?? .null).arrayValue {
                for k in kids { if case .ref(let kn, _) = k { walk(kn) } }
            } else if type != "Pages" { out.append(n) }
        }
        walk(pn)
        return out
    }

    /// Inhalt einer Seite, dekodiert und zusammengefügt
    func content(ofPage num: Int) -> [UInt8]? {
        guard let d = object(num)?.dictValue else { return nil }
        let c = resolve(d["Contents"] ?? .null)
        var parts: [PDFObj] = []
        switch c {
        case .stream: parts = [c]
        case .array(let a): parts = a.map { resolve($0) }
        default: return nil
        }
        var out: [UInt8] = []
        for p in parts {
            guard let dec = decoded(p) else { return nil }
            out += dec
            out.append(0x0A)
        }
        return out
    }

    // MARK: Schreiben (inkrementelle Aktualisierung)

    /// Neue Datei: Seite `num` bekommt den Inhalt `content` (unkomprimiert). Alles andere bleibt.
    func updated(page num: Int, content: [UInt8]) -> Data? {
        guard var pd = object(num)?.dictValue else { return nil }
        let newNum = maxObj + 1
        pd["Contents"] = .ref(newNum, 0)
        var out = bytes
        if out.last != 0x0A { out.append(0x0A) }
        var newOffsets: [(Int, Int)] = []
        func emit(_ n: Int, _ o: PDFObj) {
            newOffsets.append((n, out.count))
            out += Array("\(n) 0 obj\n".utf8)
            out += PDFWriter.serialize(o)
            out += Array("\nendobj\n".utf8)
        }
        emit(newNum, .stream([:], content))
        emit(num, .dict(pd))
        let xrefPos = out.count
        out += Array("xref\n".utf8)
        for (n, off) in newOffsets.sorted(by: { $0.0 < $1.0 }) {
            out += Array("\(n) 1\n".utf8)
            out += Array(String(format: "%010d 00000 n \n", off).utf8)
        }
        var tr: [String: PDFObj] = [:]
        for k in ["Root", "Info", "ID"] { if let v = trailer[k] { tr[k] = v } }
        tr["Size"] = .int(newNum + 1)
        tr["Prev"] = .int(startXref)
        out += Array("trailer\n".utf8)
        out += PDFWriter.serialize(.dict(tr))
        out += Array("\nstartxref\n\(xrefPos)\n%%EOF\n".utf8)
        return Data(out)
    }
}

// MARK: - Inhaltsstrom: Token und Elemente

struct CToken {
    var obj: PDFObj
    var isOp: Bool { if case .op = obj { return true }; return false }
    var op: String? { if case .op(let s) = obj { return s }; return nil }
}

enum ElementKind: String { case text, path, image, form, inlineImage, shading }

struct ContentElement {
    var kind: ElementKind
    var tokens: Range<Int>          // Token-Bereich (Operanden + Operator)
    var inText: Bool
    var canRemove: Bool             // Entfernen verändert keine Nachbarn
    var canMove: Bool
    var textState: TextState?       // Zustand vor dem Element (für Verschieben)
    var bounds: CGRect = .null      // Seitenkoordinaten, später per Rendern bestimmt
    var name: String                // z. B. Bildname oder Textauszug
}

struct TextState {
    var font: PDFObj? = nil, size: Double = 0
    var tc = 0.0, tw = 0.0, tz = 100.0, tl = 0.0, ts = 0.0, tr = 0
    var tlm = CGAffineTransform.identity       // Zeilenmatrix
    func emit() -> [UInt8] {
        var s = ""
        if let f = font, case .name(let n) = f { s += "/\(n) \(fmt(size)) Tf " }
        s += "\(fmt(tc)) Tc \(fmt(tw)) Tw \(fmt(tz)) Tz \(fmt(tl)) TL \(fmt(ts)) Ts \(tr) Tr "
        s += "\(fmt(tlm.a)) \(fmt(tlm.b)) \(fmt(tlm.c)) \(fmt(tlm.d)) \(fmt(tlm.tx)) \(fmt(tlm.ty)) Tm "
        return Array(s.utf8)
    }
}

func fmt(_ d: Double) -> String { String(PDFWriter.serialize(.real(d)).map { Character(UnicodeScalar($0)) }) }
func fmt(_ d: CGFloat) -> String { fmt(Double(d)) }

final class ContentStream {
    private(set) var tokens: [CToken] = []
    private(set) var elements: [ContentElement] = []

    static let paintOps: Set<String> = ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"]
    static let pathOps: Set<String> = ["m", "l", "c", "v", "y", "h", "re"]
    static let showOps: Set<String> = ["Tj", "TJ", "'", "\""]
    static let posOps: Set<String> = ["Td", "TD", "Tm", "T*"]

    init(_ bytes: [UInt8]) {
        tokenize(bytes)
        analyze()
    }

    private func tokenize(_ b: [UInt8]) {
        var lx = PDFLexer(b)
        while true {
            guard let o = (try? lx.parseObject()) ?? nil else { break }
            if case .op("BI") = o {
                // Inline-Bild: bis EI als ein Token einpacken
                let start = lx.i
                var end = start
                while let e = PDFLexer.find(b, Array("EI".utf8), from: end) {
                    let before = e > 0 ? b[e - 1] : 0x20
                    let after = e + 2 < b.count ? b[e + 2] : 0x20
                    if PDFLexer.isWhite(before) && (PDFLexer.isWhite(after) || e + 2 >= b.count) { end = e; break }
                    end = e + 2
                }
                let raw = Array(b[start..<end])
                lx.i = min(b.count, end + 2)
                tokens.append(CToken(obj: .string(raw)))
                tokens.append(CToken(obj: .op("BI")))      // Marker: vorhergehendes String-Token = Rohinhalt
                continue
            }
            tokens.append(CToken(obj: o))
        }
    }

    private func analyze() {
        var inText = false
        var ts = TextState()
        var tsStack: [TextState] = []
        var operandStart = 0
        var pathStart: Int? = nil
        var hasClip = false
        var lastTextOpWasPos = true      // vor dem ersten Tj in BT gilt: Position definiert
        var pendingTextElem: Int? = nil  // Index in elements, canRemove/canMove nach dem nächsten Operator festlegen

        func finishPendingText(nextOp: String) {
            guard let k = pendingTextElem else { return }
            let safe = ContentStream.posOps.contains(nextOp) || nextOp == "ET"
            elements[k].canRemove = safe
            elements[k].canMove = elements[k].canMove && safe
            pendingTextElem = nil
        }

        for (idx, t) in tokens.enumerated() {
            guard let op = t.op else { continue }
            let operands = operandStart..<idx
            defer { operandStart = idx + 1 }
            if inText, pendingTextElem != nil, !["Tf", "Tc", "Tw", "Tz", "TL", "Ts", "Tr", "rg", "RG", "g", "G", "k", "K", "cs", "CS", "sc", "scn", "SC", "SCN", "gs"].contains(op) {
                finishPendingText(nextOp: op)
            }
            switch op {
            case "BT": inText = true; ts.tlm = .identity; lastTextOpWasPos = true
            case "ET": inText = false; pendingTextElem = nil
            case "q": tsStack.append(ts)
            case "Q": if let s = tsStack.popLast() { ts = s }
            case "Tf":
                if operands.count >= 2 { ts.font = tokens[operands.lowerBound].obj; ts.size = tokens[operands.lowerBound + 1].obj.doubleValue ?? 0 }
            case "Tc": ts.tc = num(operands, 0)
            case "Tw": ts.tw = num(operands, 0)
            case "Tz": ts.tz = num(operands, 0)
            case "TL": ts.tl = num(operands, 0)
            case "Ts": ts.ts = num(operands, 0)
            case "Tr": ts.tr = Int(num(operands, 0))
            case "Td": ts.tlm = CGAffineTransform(translationX: num(operands, 0), y: num(operands, 1)).concatenating(ts.tlm); lastTextOpWasPos = true
            case "TD": ts.tl = -num(operands, 1); ts.tlm = CGAffineTransform(translationX: num(operands, 0), y: num(operands, 1)).concatenating(ts.tlm); lastTextOpWasPos = true
            case "Tm":
                if operands.count >= 6 { ts.tlm = CGAffineTransform(a: num(operands, 0), b: num(operands, 1), c: num(operands, 2), d: num(operands, 3), tx: num(operands, 4), ty: num(operands, 5)) }
                lastTextOpWasPos = true
            case "T*": ts.tlm = CGAffineTransform(translationX: 0, y: -ts.tl).concatenating(ts.tlm); lastTextOpWasPos = true
            case "Tj", "TJ", "'", "\"":
                if op == "'" || op == "\"" { ts.tlm = CGAffineTransform(translationX: 0, y: -ts.tl).concatenating(ts.tlm) }
                if op == "\"", operands.count >= 3 { ts.tw = num(operands, 0); ts.tc = num(operands, 1) }
                let txt = textPreview(operands)
                let movable = lastTextOpWasPos && (op == "Tj" || op == "TJ")
                elements.append(ContentElement(kind: .text, tokens: operands.lowerBound..<(idx + 1), inText: inText, canRemove: false, canMove: movable, textState: ts, name: txt))
                pendingTextElem = elements.count - 1
                lastTextOpWasPos = false
            case "W", "W*": hasClip = true
            case _ where ContentStream.pathOps.contains(op):
                if pathStart == nil { pathStart = operands.lowerBound }
            case _ where ContentStream.paintOps.contains(op):
                if let s = pathStart, op != "n" || !hasClip {
                    if op != "n" {
                        elements.append(ContentElement(kind: .path, tokens: s..<(idx + 1), inText: inText, canRemove: true, canMove: !hasClip && !inText, textState: nil, name: "Pfad"))
                    }
                }
                pathStart = nil; hasClip = false
            case "Do":
                let n = tokens[operands.lowerBound].obj.nameValue ?? "?"
                elements.append(ContentElement(kind: .image, tokens: operands.lowerBound..<(idx + 1), inText: inText, canRemove: true, canMove: !inText, textState: nil, name: n))
            case "BI":
                elements.append(ContentElement(kind: .inlineImage, tokens: (idx - 1)..<(idx + 1), inText: inText, canRemove: true, canMove: !inText, textState: nil, name: "Inline-Bild"))
            case "sh":
                elements.append(ContentElement(kind: .shading, tokens: operands.lowerBound..<(idx + 1), inText: inText, canRemove: true, canMove: !inText, textState: nil, name: "Verlauf"))
            default: break
            }
        }
        if pendingTextElem != nil { finishPendingText(nextOp: "ET") }
    }

    private func num(_ r: Range<Int>, _ k: Int) -> Double {
        let i = r.lowerBound + k
        return i < r.upperBound ? (tokens[i].obj.doubleValue ?? 0) : 0
    }

    private func textPreview(_ r: Range<Int>) -> String {
        var bytes: [UInt8] = []
        for i in r {
            switch tokens[i].obj {
            case .string(let s): bytes += s
            case .array(let a): for e in a { if case .string(let s) = e { bytes += s } }
            default: break
            }
        }
        let printable = bytes.filter { $0 >= 0x20 && $0 < 0x7F }
        return printable.count >= bytes.count / 2 ? String(decoding: printable.prefix(40), as: UTF8.self) : "Text (\(bytes.count) Byte)"
    }

    // MARK: Ausgabe

    enum Edit { case remove(Int), move(Int, CGFloat, CGFloat), isolate(Int) }

    /// Erzeugt den Inhaltsstrom mit Änderungen. `isolate(k)`: nur Element k sichtbar (für die Vermessung).
    func render(_ edits: [Edit]) -> [UInt8] {
        var removes = Set<Int>()
        var moves: [Int: (CGFloat, CGFloat)] = [:]
        var isolate: Int? = nil
        for e in edits {
            switch e {
            case .remove(let k): removes.insert(k)
            case .move(let k, let dx, let dy): moves[k] = (dx, dy)
            case .isolate(let k): isolate = k
            }
        }
        if let iso = isolate { for k in elements.indices where k != iso { removes.insert(k) } }

        var byStart: [Int: Int] = [:]
        for (k, e) in elements.enumerated() { byStart[e.tokens.lowerBound] = k }
        var out: [UInt8] = []
        var i = 0
        func emitTokens(_ r: Range<Int>) {
            for t in r {
                if tokens[t].op == "BI", t > 0, case .string(let raw) = tokens[t - 1].obj { out += Array("BI ".utf8); out += raw; out += Array(" EI\n".utf8); continue }
                if t + 1 < tokens.count, tokens[t + 1].op == "BI" { continue }   // Rohdaten werden mit BI ausgegeben
                out += PDFWriter.serialize(tokens[t].obj)
                out.append(tokens[t].isOp ? 0x0A : 0x20)
            }
        }
        while i < tokens.count {
            if let k = byStart[i] {
                let e = elements[k]
                let opTok = tokens[e.tokens.upperBound - 1].op ?? ""
                if removes.contains(k) {
                    switch e.kind {
                    case .text:
                        if e.canRemove {
                            if opTok == "'" || opTok == "\"" {
                                if opTok == "\"" { out += Array("\(fmt(num(e.tokens, 0))) Tw \(fmt(num(e.tokens, 1))) Tc ".utf8) }
                                out += Array("T*\n".utf8)
                            }
                        } else {
                            // unsichtbar zeichnen, Vorschub bleibt erhalten
                            out += Array("3 Tr ".utf8)
                            emitTokens(e.tokens)
                            out += Array("\(e.textState?.tr ?? 0) Tr\n".utf8)
                        }
                    case .path:
                        // Pfad behalten, aber nicht malen (Clipping bleibt gültig)
                        emitTokens(e.tokens.lowerBound..<(e.tokens.upperBound - 1))
                        out += Array("n\n".utf8)
                    default: break
                    }
                } else if let (dx, dy) = moves[k], e.canMove {
                    if e.kind == .text, let st = e.textState {
                        out += Array("ET q 1 0 0 1 \(fmt(dx)) \(fmt(dy)) cm BT ".utf8)
                        out += st.emit()
                        emitTokens(e.tokens)
                        out += Array("ET Q BT ".utf8)
                        out += st.emit()
                        out.append(0x0A)
                    } else {
                        out += Array("q 1 0 0 1 \(fmt(dx)) \(fmt(dy)) cm\n".utf8)
                        emitTokens(e.tokens)
                        out += Array("Q\n".utf8)
                    }
                } else {
                    emitTokens(e.tokens)
                }
                i = e.tokens.upperBound
            } else {
                emitTokens(i..<(i + 1))
                i += 1
            }
        }
        return out
    }
}

// MARK: - Seitenmodell mit Vermessung

final class PageContentModel {
    let file: PDFFile
    let pageObj: Int
    let pageIndex: Int
    let stream: ContentStream
    private(set) var elements: [ContentElement]
    let mediaBox: CGRect

    init?(data: Data, pageIndex: Int) {
        guard let f = try? PDFFile(data: data) else { return nil }
        let pages = f.pageObjects()
        guard pageIndex < pages.count, let c = f.content(ofPage: pages[pageIndex]) else { return nil }
        file = f
        pageObj = pages[pageIndex]
        self.pageIndex = pageIndex
        stream = ContentStream(c)
        elements = stream.elements
        var mb = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let d = f.object(pageObj)?.dictValue, let a = f.resolve(d["MediaBox"] ?? .null).arrayValue, a.count == 4 {
            let v = a.map { f.resolve($0).doubleValue ?? 0 }
            mb = CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
        }
        mediaBox = mb
        measure()
    }

    /// Bestimmt die Bounding-Box jedes Elements durch isoliertes Rendern in niedriger Auflösung.
    private func measure() {
        let scale: CGFloat = 0.5   // 36 dpi
        let w = Int(ceil(mediaBox.width * scale)), h = Int(ceil(mediaBox.height * scale))
        guard w > 0, h > 0, w * h < 4_000_000 else { return }
        func raster(_ content: [UInt8]) -> [UInt8]? {
            guard let data = file.updated(page: pageObj, content: content),
                  let prov = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(prov), let pg = doc.page(at: pageIndex + 1),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
            ctx.drawPDFPage(pg)
            guard let p = ctx.data else { return nil }
            return Array(UnsafeBufferPointer(start: p.bindMemory(to: UInt8.self, capacity: w * h), count: w * h))
        }
        guard let blank = raster(stream.render(elements.indices.map { .remove($0) })) else { return }
        for k in elements.indices {
            guard let img = raster(stream.render([.isolate(k)])) else { continue }
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h {
                let row = y * w
                for x in 0..<w where abs(Int(img[row + x]) - Int(blank[row + x])) > 8 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
            if maxX >= minX {
                // Bitmap-Zeile 0 = oben
                let r = CGRect(x: CGFloat(minX) / scale + mediaBox.minX, y: CGFloat(h - 1 - maxY) / scale + mediaBox.minY,
                               width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
                elements[k].bounds = r.insetBy(dx: -1, dy: -1)
            }
        }
    }

    /// Element unter einem Punkt (Seitenkoordinaten); kleinstes zuerst
    func element(at p: CGPoint) -> Int? {
        var best: Int? = nil
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (k, e) in elements.enumerated() where !e.bounds.isNull && e.bounds.insetBy(dx: -2, dy: -2).contains(p) {
            let a = e.bounds.width * e.bounds.height
            if a < bestArea { bestArea = a; best = k }
        }
        return best
    }

    /// Elemente, deren Box überwiegend innerhalb eines Rechtecks liegt
    func elements(in r: CGRect) -> [Int] {
        elements.indices.filter { k in
            let b = elements[k].bounds
            guard !b.isNull else { return false }
            let i = b.intersection(r)
            return !i.isNull && i.width * i.height > 0.5 * b.width * b.height
        }
    }

    func apply(_ edits: [ContentStream.Edit]) -> Data? {
        file.updated(page: pageObj, content: stream.render(edits))
    }
}
