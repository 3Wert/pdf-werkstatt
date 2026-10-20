import Foundation
import CommonCrypto

// PDF-Standard-Sicherheitsmechanismus: Lesen (RC4 40/128, AES-128, AES-256 R5/R6) und Schreiben (AES-256 R6).
// Nötig, damit passwortgeschützte Dateien beim Sichern ihren Originalinhalt behalten – PDFKit würde sie neu rendern.

enum PDFCrypt {
    static let pad: [UInt8] = [0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
                               0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A]

    static func md5(_ d: [UInt8]) -> [UInt8] { var o = [UInt8](repeating: 0, count: 16); CC_MD5(d, CC_LONG(d.count), &o); return o }
    static func sha256(_ d: [UInt8]) -> [UInt8] { var o = [UInt8](repeating: 0, count: 32); CC_SHA256(d, CC_LONG(d.count), &o); return o }
    static func sha384(_ d: [UInt8]) -> [UInt8] { var o = [UInt8](repeating: 0, count: 48); CC_SHA384(d, CC_LONG(d.count), &o); return o }
    static func sha512(_ d: [UInt8]) -> [UInt8] { var o = [UInt8](repeating: 0, count: 64); CC_SHA512(d, CC_LONG(d.count), &o); return o }
    static func random(_ n: Int) -> [UInt8] { var o = [UInt8](repeating: 0, count: n); _ = SecRandomCopyBytes(kSecRandomDefault, n, &o); return o }

    static func rc4(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var s = [UInt8](0...255)
        var j = 0
        for i in 0..<256 { j = (j + Int(s[i]) + Int(key[i % max(1, key.count)])) & 0xFF; s.swapAt(i, j) }
        var out = [UInt8](repeating: 0, count: data.count)
        var i = 0; j = 0
        for (k, b) in data.enumerated() {
            i = (i + 1) & 0xFF; j = (j + Int(s[i])) & 0xFF; s.swapAt(i, j)
            out[k] = b ^ s[(Int(s[i]) + Int(s[j])) & 0xFF]
        }
        return out
    }

    /// AES (CBC oder ECB), optional ohne Padding
    static func aes(_ key: [UInt8], iv: [UInt8]?, _ data: [UInt8], encrypt: Bool, padding: Bool) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var n = 0
        var opts: CCOptions = 0
        if padding { opts |= CCOptions(kCCOptionPKCS7Padding) }
        if iv == nil { opts |= CCOptions(kCCOptionECBMode) }
        let st = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), opts, key, key.count, iv, data, data.count, &out, out.count, &n)
        guard st == kCCSuccess else { return nil }
        return Array(out[0..<n])
    }

    /// Algorithmus 2.B (R6): Passwort-Hash
    static func hash2B(_ pw: [UInt8], salt: [UInt8], udata: [UInt8]) -> [UInt8] {
        var k = sha256(pw + salt + udata)
        var i = 0
        while true {
            let k1 = [UInt8]((0..<64).flatMap { _ in pw + k + udata })
            guard let e = aes(Array(k[0..<16]), iv: Array(k[16..<32]), k1, encrypt: true, padding: false) else { return k }
            let mod = e[0..<16].reduce(0) { $0 + Int($1) } % 3
            k = mod == 0 ? sha256(e) : mod == 1 ? sha384(e) : sha512(e)
            i += 1
            if i >= 64, Int(e[e.count - 1]) <= i - 32 { break }
        }
        return Array(k[0..<32])
    }

    // MARK: Lesen

    final class Handler {
        enum Method { case none, rc4, aesv2, aesv3 }
        let key: [UInt8]
        let strMethod: Method, stmMethod: Method
        let encryptMetadata: Bool

        /// nil, wenn das Passwort nicht passt
        convenience init?(encrypt d: [String: PDFObj], resolve: (PDFObj) -> PDFObj, id0: [UInt8], password: String) {
            self.init(encrypt: d, resolve: resolve, id0: id0, password: password, tryOwner: true)
        }

        init?(encrypt d: [String: PDFObj], resolve: (PDFObj) -> PDFObj, id0: [UInt8], password: String, tryOwner: Bool) {
            guard resolve(d["Filter"] ?? .null).nameValue == "Standard" else { return nil }
            let v = resolve(d["V"] ?? .int(0)).intValue ?? 0, r = resolve(d["R"] ?? .int(2)).intValue ?? 2
            let length = (resolve(d["Length"] ?? .int(40)).intValue ?? 40) / 8
            func bytes(_ k: String) -> [UInt8] { if case .string(let s) = resolve(d[k] ?? .null) { return s }; return [] }
            let o = bytes("O"), u = bytes("U")
            let p = Int32(truncatingIfNeeded: resolve(d["P"] ?? .int(-1)).intValue ?? -1)
            encryptMetadata = (resolve(d["EncryptMetadata"] ?? .bool(true)).boolValue ?? true)
            var sm = Method.rc4, tm = Method.rc4
            if v >= 4 {
                let cf = resolve(d["CF"] ?? .null).dictValue ?? [:]
                func method(_ name: String) -> Method {
                    guard name != "Identity", let f = resolve(cf[name] ?? .null).dictValue else { return .none }
                    switch resolve(f["CFM"] ?? .null).nameValue { case "AESV2": return .aesv2; case "AESV3": return .aesv3; case "V2": return .rc4; default: return .none }
                }
                sm = method(resolve(d["StmF"] ?? .name("Identity")).nameValue ?? "Identity")
                tm = method(resolve(d["StrF"] ?? .name("Identity")).nameValue ?? "Identity")
            }
            stmMethod = sm; strMethod = tm
            let pw = Array(password.utf8)
            if r >= 5 {
                // AES-256: U = hash(32) + validation salt(8) + key salt(8)
                guard u.count >= 48 else { return nil }
                let vs = Array(u[32..<40]), ks = Array(u[40..<48])
                let h = r == 5 ? PDFCrypt.sha256(pw + vs) : PDFCrypt.hash2B(pw, salt: vs, udata: [])
                var fileKey: [UInt8]? = nil
                if h == Array(u[0..<32]) {
                    let ik = r == 5 ? PDFCrypt.sha256(pw + ks) : PDFCrypt.hash2B(pw, salt: ks, udata: [])
                    fileKey = PDFCrypt.aes(ik, iv: [UInt8](repeating: 0, count: 16), bytes("UE"), encrypt: false, padding: false)
                } else if o.count >= 48 {
                    // vielleicht Besitzer-Passwort
                    let ovs = Array(o[32..<40]), oks = Array(o[40..<48]), u48 = Array(u.prefix(48))
                    let oh = r == 5 ? PDFCrypt.sha256(pw + ovs + u48) : PDFCrypt.hash2B(pw, salt: ovs, udata: u48)
                    if oh == Array(o[0..<32]) {
                        let ik = r == 5 ? PDFCrypt.sha256(pw + oks + u48) : PDFCrypt.hash2B(pw, salt: oks, udata: u48)
                        fileKey = PDFCrypt.aes(ik, iv: [UInt8](repeating: 0, count: 16), bytes("OE"), encrypt: false, padding: false)
                    }
                }
                guard let fk = fileKey, fk.count == 32 else { return nil }
                key = fk
                return
            }
            // R2–R4: Algorithmus 2
            let padded = Array((pw + PDFCrypt.pad).prefix(32))
            var input = padded + o
            let pb = UInt32(bitPattern: p)
            input += [UInt8(pb & 0xFF), UInt8(pb >> 8 & 0xFF), UInt8(pb >> 16 & 0xFF), UInt8(pb >> 24 & 0xFF)]
            input += id0
            if r >= 4, !encryptMetadata { input += [0xFF, 0xFF, 0xFF, 0xFF] }
            var k = PDFCrypt.md5(input)
            let n = r == 2 ? 5 : max(5, min(16, length))
            if r >= 3 { for _ in 0..<50 { k = PDFCrypt.md5(Array(k[0..<n])) } }
            k = Array(k[0..<n])
            // Prüfung über U (Algorithmus 4/5)
            var ok: Bool
            if r == 2 { ok = PDFCrypt.rc4(k, PDFCrypt.pad) == u }
            else {
                var x = PDFCrypt.rc4(k, PDFCrypt.md5(PDFCrypt.pad + id0))
                for i in 1...19 { x = PDFCrypt.rc4(k.map { $0 ^ UInt8(i) }, x) }
                ok = u.count >= 16 && Array(u[0..<16]) == x
            }
            if ProcessInfo.processInfo.environment["PDFW_CRYPT_DEBUG"] != nil { print("Crypt: V\(v) R\(r) n=\(n) id0=\(id0.count)B O=\(o.count)B U=\(u.count)B P=\(p) Benutzerprüfung: \(ok)") }
            if !ok {
                guard tryOwner else { return nil }
                // Besitzer-Passwort: RC4-Schlüssel aus dem Passwort, damit O entschlüsseln → Benutzerpasswort
                var ok2 = PDFCrypt.md5(padded)
                if r >= 3 { for _ in 0..<50 { ok2 = PDFCrypt.md5(ok2) } }
                let okey = Array(ok2[0..<n])
                var userPw = o
                if r == 2 { userPw = PDFCrypt.rc4(okey, o) } else { for i in stride(from: 19, through: 0, by: -1) { userPw = PDFCrypt.rc4(okey.map { $0 ^ UInt8(i) }, userPw) } }
                guard let h = Handler(encrypt: d, resolve: resolve, id0: id0, password: String(decoding: userPw.prefix(32).prefix { $0 != 0 }, as: UTF8.self), tryOwner: false) else { return nil }
                key = h.key; return
            }
            key = k
        }

        private func objectKey(_ num: Int, _ gen: Int, aes: Bool) -> [UInt8] {
            if key.count == 32 { return key }
            var d = key + [UInt8(num & 0xFF), UInt8(num >> 8 & 0xFF), UInt8(num >> 16 & 0xFF), UInt8(gen & 0xFF), UInt8(gen >> 8 & 0xFF)]
            if aes { d += [0x73, 0x41, 0x6C, 0x54] }
            return Array(PDFCrypt.md5(d).prefix(min(16, key.count + 5)))
        }

        func decrypt(_ data: [UInt8], num: Int, gen: Int, method: Method) -> [UInt8] {
            switch method {
            case .none: return data
            case .rc4: return PDFCrypt.rc4(objectKey(num, gen, aes: false), data)
            case .aesv2, .aesv3:
                guard data.count >= 16 else { return [] }
                let k = method == .aesv3 ? key : objectKey(num, gen, aes: true)
                return PDFCrypt.aes(k, iv: Array(data[0..<16]), Array(data[16...]), encrypt: false, padding: true) ?? []
            }
        }

        /// Objekt rekursiv entschlüsseln (Strings und Stream-Daten)
        func decrypt(_ o: PDFObj, num: Int, gen: Int) -> PDFObj {
            switch o {
            case .string(let s): return .string(decrypt(s, num: num, gen: gen, method: strMethod))
            case .array(let a): return .array(a.map { decrypt($0, num: num, gen: gen) })
            case .dict(let d): return .dict(d.mapValues { decrypt($0, num: num, gen: gen) })
            case .stream(let d, let raw):
                let isXref = d["Type"]?.nameValue == "XRef"
                let isMeta = d["Type"]?.nameValue == "Metadata" && !encryptMetadata
                return .stream(d.mapValues { decrypt($0, num: num, gen: gen) }, isXref || isMeta ? raw : decrypt(raw, num: num, gen: gen, method: stmMethod))
            default: return o
            }
        }
    }

    // MARK: Schreiben (AES-256, R6)

    struct Writer {
        let key: [UInt8]
        let encryptDict: PDFObj
        let id: [UInt8]

        init(password: String, ownerPassword: String? = nil, permissions: Int32 = -1) {
            key = PDFCrypt.random(32)
            let pw = Array(password.utf8.prefix(127)), opw = Array((ownerPassword ?? password).utf8.prefix(127))
            let vs = PDFCrypt.random(8), ks = PDFCrypt.random(8)
            let u = PDFCrypt.hash2B(pw, salt: vs, udata: []) + vs + ks
            let ue = PDFCrypt.aes(PDFCrypt.hash2B(pw, salt: ks, udata: []), iv: [UInt8](repeating: 0, count: 16), key, encrypt: true, padding: false) ?? []
            let ovs = PDFCrypt.random(8), oks = PDFCrypt.random(8)
            let o = PDFCrypt.hash2B(opw, salt: ovs, udata: u) + ovs + oks
            let oe = PDFCrypt.aes(PDFCrypt.hash2B(opw, salt: oks, udata: u), iv: [UInt8](repeating: 0, count: 16), key, encrypt: true, padding: false) ?? []
            let pb = UInt32(bitPattern: permissions)
            var perms: [UInt8] = [UInt8(pb & 0xFF), UInt8(pb >> 8 & 0xFF), UInt8(pb >> 16 & 0xFF), UInt8(pb >> 24 & 0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0x54, 0x61, 0x64, 0x62]
            perms += PDFCrypt.random(4)
            let permsEnc = PDFCrypt.aes(key, iv: nil, perms, encrypt: true, padding: false) ?? perms
            id = PDFCrypt.random(16)
            encryptDict = .dict([
                "Filter": .name("Standard"), "V": .int(5), "R": .int(6), "Length": .int(256),
                "CF": .dict(["StdCF": .dict(["CFM": .name("AESV3"), "AuthEvent": .name("DocOpen"), "Length": .int(32)])]),
                "StmF": .name("StdCF"), "StrF": .name("StdCF"),
                "O": .string(o), "U": .string(u), "OE": .string(oe), "UE": .string(ue), "Perms": .string(permsEnc), "P": .int(Int(permissions)),
            ])
        }

        func encrypt(_ data: [UInt8]) -> [UInt8] {
            let iv = PDFCrypt.random(16)
            return iv + (PDFCrypt.aes(key, iv: iv, data, encrypt: true, padding: true) ?? [])
        }

        func encrypt(_ o: PDFObj) -> PDFObj {
            switch o {
            case .string(let s): return .string(encrypt(s))
            case .array(let a): return .array(a.map(encrypt))
            case .dict(let d): return .dict(d.mapValues(encrypt))
            case .stream(let d, let raw): return .stream(d.mapValues(encrypt), encrypt(raw))
            default: return o
            }
        }
    }
}

extension PDFObj {
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
}


import PDFKit

/// PDFW_CRYPT_TEST=<Ordner> PDFW_PW=<Passwort>: verschlüsselte PDFs lesen, über WDocument sichern (AES-256), zurücklesen;
/// unverschlüsselte Eingaben werden zusätzlich mit dem eigenen Schreiber verschlüsselt (Type3 bleibt erhalten) und ebenso geprüft.
/// Dazu Metadaten-Entfernung beim Schwärzen.
enum CryptTest {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["PDFW_CRYPT_TEST"] else { return }
        let pw = ProcessInfo.processInfo.environment["PDFW_PW"] ?? "geheim"
        var ok = true
        var lines: [String] = []
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".pdf") && !$0.contains(".gesichert") && !$0.contains(".geschwaerzt") && !$0.contains(".r6") }.sorted()
        let resDir = URL(fileURLWithPath: dir).appendingPathComponent("Ergebnisse")
        try? FileManager.default.createDirectory(at: resDir, withIntermediateDirectories: true)
        for name in files {
            guard let raw = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name)) else { lines.append("FEHL \(name): nicht lesbar"); ok = false; continue }
            if !check(name: name, raw: raw, pw: pw, resDir: resDir, lines: &lines) { ok = false }
            // Unverschlüsselt → mit eigenem Schreiber verschlüsseln und denselben Test fahren
            if let f = try? PDFFile(data: raw), !f.isEncrypted, let enc = f.compacted(encrypt: PDFCrypt.Writer(password: pw)) {
                let n2 = (name as NSString).deletingPathExtension + ".r6.pdf"
                try? enc.write(to: resDir.appendingPathComponent(n2))
                if let locked = PDFDocument(data: enc), locked.isLocked, locked.unlock(withPassword: pw) {
                    let fonts = enc.ranges(of: "/Type /Font".data(using: .utf8)!).count
                    lines.append("     \(n2): eigene AES-256-Datei, PDFKit öffnet sie mit Passwort, \(fonts) Schriftobjekte (unverschlüsselt: \(raw.ranges(of: "/Type /Font".data(using: .utf8)!).count + raw.ranges(of: "/Type/Font".data(using: .utf8)!).count))")
                    if !check(name: n2, raw: enc, pw: pw, resDir: resDir, lines: &lines, reference: raw) { ok = false }
                } else { lines.append("FEHL \(n2): PDFKit kann die eigene AES-256-Datei nicht öffnen"); ok = false }
            }
        }
        let t = lines.joined(separator: "\n"); print(t)
        try? t.write(toFile: dir + "/Ergebnisse/crypt-ergebnis.txt", atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }

    /// Eine Datei prüfen. `reference`: unverschlüsselte Fassung für den Textvergleich.
    static func check(name: String, raw: Data, pw: String, resDir: URL, lines: inout [String], reference: Data? = nil) -> Bool {
        var problems: [String] = []
        var kind = "unverschlüsselt"
        do {
            let f = try PDFFile(data: raw, password: pw)
            if f.isEncrypted {
                kind = "verschlüsselt"
                let pages = f.pageObjects()
                if pages.isEmpty || f.content(ofPage: pages[0]) == nil { problems.append("Parser: Seiteninhalt nach Entschlüsselung unlesbar") }
                if (try? PDFFile(data: raw, password: "falsch")) != nil { problems.append("Parser akzeptiert falsches Passwort") }
            }
        } catch { problems.append("Parser: \(error)") }
        let wd = WDocument()
        guard (try? wd.read(from: raw, ofType: "com.adobe.pdf")) != nil, let saved = try? wd.data(ofType: "com.adobe.pdf") else { lines.append("FEHL \(name): öffnen/sichern fehlgeschlagen"); return false }
        let outDoc = PDFDocument(data: saved)
        let before = PDFDocument(data: reference ?? raw); _ = before?.unlock(withPassword: pw)
        if wd.password != nil {
            guard let od = outDoc, od.isLocked else { lines.append("FEHL \(name): gesichert, aber nicht gesperrt"); return false }
            if !od.unlock(withPassword: pw) { problems.append("gesicherte Datei lässt sich mit dem Passwort nicht öffnen") }
            if let od2 = PDFDocument(data: saved), od2.unlock(withPassword: "falsch") { problems.append("falsches Passwort öffnet die gesicherte Datei") }
            if saved.range(of: "/AESV3".data(using: .utf8)!) == nil { problems.append("keine AES-256-Verschlüsselung in der Ausgabe") }
            if (try? PDFFile(data: saved, password: pw)) == nil { problems.append("eigene Ausgabe nicht mit eigenem Parser lesbar") }
        }
        if let b = before, let a = outDoc {
            for i in 0..<min(b.pageCount, a.pageCount, 2) {
                let tb = (b.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), ta = (a.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !tb.isEmpty, ta.count < tb.count * 9 / 10 { problems.append("Seite \(i + 1): Text verloren (\(tb.count) → \(ta.count))") }
                if let ia = PDFTools.render(b.page(at: i)!, dpi: 72), let ib = PDFTools.render(a.page(at: i)!, dpi: 72), ia.width == ib.width, ia.height == ib.height,
                   let da = ia.dataProvider?.data as Data?, let db = ib.dataProvider?.data as Data? {
                    var diff = 0
                    da.withUnsafeBytes { pa in db.withUnsafeBytes { pb in for k in stride(from: 0, to: min(pa.count, pb.count), by: 4) where abs(Int(pa[k]) - Int(pb[k])) > 40 { diff += 1 } } }
                    if diff > 80 { problems.append("Seite \(i + 1): Darstellung weicht ab (\(diff) px)") }
                }
            }
        }
        try? saved.write(to: resDir.appendingPathComponent((name as NSString).deletingPathExtension + ".gesichert.pdf"))
        if let fresh = wd.currentData(), let p0 = PDFDocument(data: fresh)?.page(at: 0) {
            let b = p0.bounds(for: .mediaBox)
            var red = Redactor(marks: [RedactMark(pageIndex: 0, rect: CGRect(x: b.minX + 50, y: b.midY, width: 150, height: 20), color: RGBA(.black))])
            red.stripMetadata = true
            if let r = red.apply(to: fresh, paintBoxes: true), let rd = PDFDocument(data: r) {
                let title = (rd.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? ""
                let author = (rd.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String) ?? ""
                let hasXMP = r.range(of: "/Metadata".data(using: .utf8)!) != nil
                if !title.isEmpty || !author.isEmpty || hasXMP { problems.append("Metadaten nicht entfernt (Titel „\(title)“, Autor „\(author)“, XMP \(hasXMP))") }
                lines.append("     \(name): Schwärzen + Metadaten weg – \(red.report.summary)" + (red.report.notes.isEmpty ? "" : " · " + red.report.notes.joined(separator: "; ")))
            } else { problems.append("Schwärzen fehlgeschlagen") }
        }
        lines.append("\(problems.isEmpty ? "OK  " : "FEHL") \(name) (\(kind)): \(raw.count / 1024) → \(saved.count / 1024) KB" + (problems.isEmpty ? "" : " ⚠️ " + problems.joined(separator: "; ")))
        return problems.isEmpty
    }
}
