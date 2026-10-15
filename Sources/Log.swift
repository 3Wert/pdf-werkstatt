import AppKit
import PDFKit

/// Einstellungen: im Selbsttest ein eigener Namensraum, damit Marlons Werte unberührt bleiben
let prefs: UserDefaults = ProcessInfo.processInfo.environment["PDFW_SELFTEST"] != nil
    ? UserDefaults(suiteName: "de.marlonelsner.pdf-werkstatt.selbsttest")! : .standard

/// Protokoll in ~/Library/Logs/PDF-Werkstatt.log (Hilfe › Protokoll anzeigen)
enum Log {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/PDF-Werkstatt.log")
    private static let df: DateFormatter = { let d = DateFormatter(); d.dateFormat = "HH:mm:ss.SSS"; return d }()

    /// Ausführliches Protokoll (jede Taste, jeder Klick) – Hilfe › Protokoll ausführlich
    static var verbose: Bool { prefs.bool(forKey: "protokollAusfuehrlich") || ProcessInfo.processInfo.environment["PDFW_SELFTEST"] != nil }
    static func v(_ s: @autoclosure () -> String) { if verbose { w(s()) } }

    /// Beim Start: über 2 MB → auf das letzte halbe MB kürzen
    static func trim() {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), let size = a[.size] as? Int, size > 2_000_000,
              let d = try? Data(contentsOf: url) else { return }
        var tail = d.suffix(500_000)
        if let nl = tail.firstIndex(of: 0x0A) { tail = tail[(nl + 1)...] }
        try? (Data("… gekürzt …\n".utf8) + tail).write(to: url)
    }

    static func w(_ s: String) {
        let line = df.string(from: Date()) + "  " + s + "\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    static func describe(_ p: PDFPage) -> String {
        p.annotations.map { a in
            let w = a as? WObject
            let b = a.bounds
            return "\(w?.model.kind.rawValue ?? (a.type ?? "?"))@\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))"
        }.joined(separator: " | ")
    }
}

extension UndoManager {
    /// `setActionName` wirft auf macOS 26 eine Ausnahme, wenn keine Gruppe offen ist – das ließ Ziehvorgänge halb fertig zurück.
    func safeActionName(_ s: String) { if groupingLevel > 0 { setActionName(s) } }
}
