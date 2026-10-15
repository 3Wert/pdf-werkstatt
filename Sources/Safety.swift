import AppKit
import PDFKit

/// Ablage für große Widerrufen-Zustände (komplette PDF-Stände nach Inhalts-Eingriffen) auf der Platte statt im Speicher
enum UndoStore {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PDF-Werkstatt/Widerrufen")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func save(_ data: Data) -> URL? {
        let u = dir.appendingPathComponent(UUID().uuidString + ".pdf")
        return (try? data.write(to: u)) != nil ? u : nil
    }
    static func load(_ u: URL) -> Data? { try? Data(contentsOf: u) }
    /// Beim Start: Reste der letzten Sitzung löschen
    static func purge() { (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.forEach { try? FileManager.default.removeItem(at: $0) } }
}

/// Automatische Sicherheitskopien ungesicherter Dokumente und Wiederherstellung nach einem Absturz.
/// Das Original wird nie angefasst – wiederhergestellte Dokumente öffnen als „(wiederhergestellt)“ ohne Dateipfad.
enum Recovery {
    static let dir: URL = {
        let base = prefs === UserDefaults.standard ? "PDF-Werkstatt/Wiederherstellung" : "PDF-Werkstatt/Wiederherstellung-Test"
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(base)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    struct Entry: Codable { var name: String; var original: String?; var date: Date }

    static func write(id: String, data: Data, name: String, original: URL?) {
        let pdf = dir.appendingPathComponent(id + ".pdf"), meta = dir.appendingPathComponent(id + ".json")
        do {
            try data.write(to: pdf, options: .atomic)
            try JSONEncoder().encode(Entry(name: name, original: original?.path, date: Date())).write(to: meta, options: .atomic)
        } catch { Log.w("Wiederherstellung schreiben fehlgeschlagen: \(error)") }
    }

    static func remove(id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".pdf"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".json"))
    }

    static func pending() -> [(String, Entry)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { u in
            let id = u.deletingPathExtension().lastPathComponent
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(id + ".pdf").path),
                  let d = try? Data(contentsOf: u), let e = try? JSONDecoder().decode(Entry.self, from: d) else { return nil }
            return (id, e)
        }.sorted { $0.1.date < $1.1.date }
    }

    /// Beim Start fragen. Liefert true, wenn Dokumente geöffnet wurden.
    @discardableResult
    static func offerRestore() -> Bool {
        let list = pending()
        guard !list.isEmpty else { return false }
        let df = DateFormatter(); df.locale = Locale(identifier: "de_DE"); df.dateStyle = .short; df.timeStyle = .short
        let a = NSAlert()
        a.messageText = list.count == 1 ? "Ungesicherte Änderungen gefunden" : "\(list.count) Dokumente mit ungesicherten Änderungen gefunden"
        a.informativeText = "PDF-Werkstatt wurde nicht ordnungsgemäß beendet.\n\n" +
            list.map { "• \($0.1.name) – Stand \(df.string(from: $0.1.date))" }.joined(separator: "\n") +
            "\n\nDie Dokumente öffnen als Kopie. Das Original bleibt unverändert."
        a.addButton(withTitle: "Wiederherstellen")
        a.addButton(withTitle: "Verwerfen")
        let r = a.runModal()
        for (id, e) in list {
            if r == .alertFirstButtonReturn, let d = try? Data(contentsOf: dir.appendingPathComponent(id + ".pdf")), let pdf = PDFDocument(data: d) {
                WDocument.openNew(with: pdf, name: (e.name as NSString).deletingPathExtension + " (wiederhergestellt)")
            }
            remove(id: id)
        }
        return r == .alertFirstButtonReturn
    }
}

/// Prüfung vor dem Versenden: abgedeckte/geschwärzte Stellen enthalten den Inhalt darunter noch.
enum SendCheck {
    enum Result { case proceed, cancel, rasterize }

    static func covers(_ d: PDFDocument) -> [(Int, CGRect)] {
        var out: [(Int, CGRect)] = []
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            for case let w as WObject in p.annotations where w.model.kind == .cover { out.append((i, w.bounds)) }
        }
        return out
    }

    /// Fragt nach und entfernt auf Wunsch den Inhalt unter den Abdeckungen wirklich.
    static func run(doc: WDocument, window: NSWindow, verb: String) -> Result {
        let cv = covers(doc.pdf)
        guard !cv.isEmpty, let canvas = doc.controller?.canvas else { return .proceed }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = cv.count == 1 ? "Eine Stelle ist nur abgedeckt" : "\(cv.count) Stellen sind nur abgedeckt"
        a.informativeText = "Unter „Abdecken“ und „Schwärzen“ steckt der ursprüngliche Inhalt noch in der Datei und lässt sich herauskopieren. Soll er vor dem \(verb) wirklich entfernt werden?"
        a.addButton(withTitle: "Darunter entfernen")
        a.addButton(withTitle: "Trotzdem \(verb)")
        a.addButton(withTitle: "Abbrechen")
        let r = a.runModal()
        if r == .alertThirdButtonReturn { return .cancel }
        if r == .alertSecondButtonReturn { return .proceed }
        let (removed, partial) = canvas.removeContentUnderCovers()
        Log.w("SendCheck: entfernt \(removed), teilweise \(partial)")
        guard partial > 0 else { return .proceed }
        let b = NSAlert()
        b.alertStyle = .warning
        b.messageText = "\(removed) Elemente entfernt, \(partial) nur teilweise abgedeckt"
        b.informativeText = "Teilweise abgedeckte Textzeilen bleiben erhalten, damit sichtbarer Text nicht verschwindet. Ganz sicher ist nur ein Bild-PDF – dann ist nichts mehr kopierbar."
        b.addButton(withTitle: "Als Bild-PDF \(verb)")
        b.addButton(withTitle: "So \(verb)")
        b.addButton(withTitle: "Abbrechen")
        let r2 = b.runModal()
        if r2 == .alertFirstButtonReturn { return .rasterize }
        if r2 == .alertThirdButtonReturn { return .cancel }
        return .proceed
    }
}
