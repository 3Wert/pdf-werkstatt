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

/// Prüfung vor dem Versenden: Schwärzungen anwenden, Abdeckungen auf Wunsch leeren.
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

    static func run(doc: WDocument, window: NSWindow, verb: String) -> Result {
        guard let canvas = doc.controller?.canvas else { return .proceed }
        let red = canvas.coverMarks(redact: true)
        if !red.isEmpty {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = red.count == 1 ? "Eine Schwärzung ist noch nicht angewendet" : "\(red.count) Schwärzungen sind noch nicht angewendet"
            a.informativeText = "Die markierten Stellen sind bisher nur abgedeckt – der Inhalt darunter steht noch in der Datei und lässt sich herauskopieren."
            a.addButton(withTitle: "Anwenden und \(verb)")
            a.addButton(withTitle: "Nur abdecken und \(verb)")
            a.addButton(withTitle: "Abbrechen")
            switch a.runModal() {
            case .alertThirdButtonReturn: return .cancel
            case .alertFirstButtonReturn:
                guard let rep = canvas.applyRedaction(red, paint: true, removeAnnots: true, action: "Schwärzungen anwenden") else {
                    return failed(verb: verb)
                }
                if !rep.leaks.isEmpty { return failed(verb: verb) }
            default: break
            }
        }
        let white = canvas.coverMarks(redact: false)
        guard !white.isEmpty else { return .proceed }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = white.count == 1 ? "Eine Stelle ist nur abgedeckt" : "\(white.count) Stellen sind nur abgedeckt"
        a.informativeText = "Unter „Abdecken“ steckt der ursprüngliche Inhalt noch in der Datei und lässt sich herauskopieren. Soll er vor dem \(verb) wirklich entfernt werden?"
        a.addButton(withTitle: "Darunter entfernen")
        a.addButton(withTitle: "Trotzdem \(verb)")
        a.addButton(withTitle: "Abbrechen")
        switch a.runModal() {
        case .alertThirdButtonReturn: return .cancel
        case .alertSecondButtonReturn: return .proceed
        default:
            guard let rep = canvas.applyRedaction(white, paint: false, removeAnnots: false, action: "Inhalt unter Abdeckung entfernen"), rep.leaks.isEmpty else {
                return failed(verb: verb)
            }
            return .proceed
        }
    }

    private static func failed(verb: String) -> Result {
        let b = NSAlert()
        b.alertStyle = .warning
        b.messageText = "Der Inhalt ließ sich nicht sicher entfernen"
        b.informativeText = "Ganz sicher ist ein Bild-PDF – dann ist nichts mehr kopierbar."
        b.addButton(withTitle: "Als Bild-PDF \(verb)")
        b.addButton(withTitle: "Abbrechen")
        return b.runModal() == .alertFirstButtonReturn ? .rasterize : .cancel
    }
}
