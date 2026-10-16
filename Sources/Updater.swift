import AppKit
import CryptoKit

/// Update-Prüfung: liest `aktuell.json` aus iCloud Drive (eigene Macs) oder von einer Web-Adresse (Kollegen),
/// lädt die Zip, prüft die Prüfsumme, tauscht die App im Programme-Ordner aus und startet neu.
/// Die alte Version bleibt als „PDF-Werkstatt (alt).app“ liegen, bis das nächste Update kommt.
enum Updater {
    struct Info: Codable {
        var version: String
        var build: String
        var date: String
        var file: String
        var sha256: String
        var notes: [String]
    }

    static let icloudDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Backups/PDFWerkstatt")
    static let webBase = URL(string: "https://3wert.de/pdf-werkstatt/")!
    static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    private static var timer: Timer?
    private static var busy = false

    /// Beim Start (nach 20 s) und dann alle 4 Stunden, nur wenn das Programm aus einem Programme-Ordner läuft
    static func start() {
        if ProcessInfo.processInfo.environment["PDFW_UPDATE_TEST"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { check(manual: true) }; return }
        guard ProcessInfo.processInfo.environment["PDFW_SELFTEST"] == nil, isInstalled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { _ in check(manual: false) }
    }

    static var isInstalled: Bool {
        let p = Bundle.main.bundleURL.path
        return p.hasSuffix(".app") && (p.contains("/Applications/"))
    }

    // MARK: Quelle lesen

    private static func fetch(_ done: @escaping (Info?, URL?, Error?) -> Void) {
        // 1. iCloud Drive
        let local = icloudDir.appendingPathComponent("aktuell.json")
        if let d = try? Data(contentsOf: local), let i = try? JSONDecoder().decode(Info.self, from: d) {
            done(i, icloudDir.appendingPathComponent(i.file), nil); return
        }
        // 2. Web
        var req = URLRequest(url: webBase.appendingPathComponent("aktuell.json"))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { d, resp, err in
            DispatchQueue.main.async {
                guard let d, (resp as? HTTPURLResponse)?.statusCode == 200, let i = try? JSONDecoder().decode(Info.self, from: d) else { done(nil, nil, err); return }
                done(i, webBase.appendingPathComponent(i.file), nil)
            }
        }.resume()
    }

    static func check(manual: Bool) {
        guard !busy else { return }
        fetch { info, zipURL, err in
            guard let info, let zipURL else {
                if manual { alert("Keine Update-Informationen gefunden", err.map { "\($0.localizedDescription)" } ?? "Weder in iCloud Drive noch unter \(webBase.absoluteString) liegt eine aktuell.json.") }
                return
            }
            guard info.build > currentBuild else {
                if manual { alert("PDF-Werkstatt ist aktuell", "Version \(currentVersion) (\(currentBuild)) ist die neueste.") }
                return
            }
            if !manual, prefs.string(forKey: "updateSpaeter") == info.build { return }
            offer(info, zipURL)
        }
    }

    private static func offer(_ info: Info, _ zipURL: URL) {
        let a = NSAlert()
        a.messageText = "Version \(info.version) vom \(info.date) verfügbar"
        let notes = info.notes.isEmpty ? "" : "\n\nWas ist neu:\n" + info.notes.map { "• " + $0 }.joined(separator: "\n")
        a.informativeText = "Installiert ist \(currentVersion) (\(currentBuild)).\(notes)\n\nDie App wird ausgetauscht und neu gestartet. Offene Dokumente werden vorher gesichert."
        a.addButton(withTitle: "Jetzt installieren")
        a.addButton(withTitle: "Später")
        if ProcessInfo.processInfo.environment["PDFW_UPDATE_TEST"] != nil { Log.w("Update-Test: Angebot \(info.version) \(info.build), installiere"); install(info, from: zipURL); return }
        if a.runModal() == .alertFirstButtonReturn { install(info, from: zipURL) }
        else { prefs.set(info.build, forKey: "updateSpaeter") }
    }

    // MARK: Installieren

    private static func install(_ info: Info, from zipURL: URL) {
        busy = true
        // offene, geänderte Dokumente sichern lassen
        let docs = NSDocumentController.shared.documents.filter { $0.isDocumentEdited }
        if !docs.isEmpty {
            let a = NSAlert()
            a.messageText = "\(docs.count) Dokument\(docs.count == 1 ? "" : "e") mit ungesicherten Änderungen"
            a.informativeText = "Vor dem Update bitte sichern. Danach startet die App neu."
            a.addButton(withTitle: "Alle sichern und weiter")
            a.addButton(withTitle: "Abbrechen")
            guard a.runModal() == .alertFirstButtonReturn else { busy = false; return }
            for d in docs { d.save(nil) }
            if NSDocumentController.shared.documents.contains(where: { $0.isDocumentEdited }) { busy = false; return }
        }
        let progress = NSAlert()
        progress.messageText = "Update wird geladen …"
        progress.informativeText = "Version \(info.version)"
        progress.addButton(withTitle: "Abbrechen")
        let win = progress.window
        win.makeKeyAndOrderFront(nil)   // nicht modal, damit der Download laufen kann
        loadZip(zipURL, expected: info.sha256) { data in
            win.orderOut(nil)
            guard let data else { busy = false; alert("Update fehlgeschlagen", "Die Datei konnte nicht geladen werden oder die Prüfsumme stimmt nicht. Vielleicht ist iCloud noch nicht fertig synchronisiert – später noch einmal versuchen."); return }
            do { try swap(zipData: data) } catch { busy = false; alert("Update fehlgeschlagen", error.localizedDescription) }
        }
    }

    /// Lädt die Zip (iCloud: wartet bis zu 60 s auf die Synchronisierung) und prüft die Prüfsumme
    private static func loadZip(_ url: URL, expected: String, _ done: @escaping (Data?) -> Void) {
        if url.isFileURL {
            var tries = 0
            func attempt() {
                tries += 1
                if !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
                if let d = try? Data(contentsOf: url), sha256(d) == expected { done(d); return }
                if tries < 12 { DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: attempt) } else { done(nil) }
            }
            attempt()
        } else {
            URLSession.shared.dataTask(with: url) { d, _, _ in
                DispatchQueue.main.async { done(d.flatMap { sha256($0) == expected ? $0 : nil }) }
            }.resume()
        }
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Entpacken, austauschen, neu starten
    private static func swap(zipData: Data) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("PDFWerkstatt-Update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent("update.zip")
        try zipData.write(to: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, tmp.path]
        try unzip.run(); unzip.waitUntilExit()
        let newApp = tmp.appendingPathComponent("PDF-Werkstatt.app")
        guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/PDFWerkstatt").path) else {
            throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Die Zip enthält keine gültige App."])
        }
        // Keine Quarantäne-Markierung – die App hat die Datei selbst geholt, nicht der Browser
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", newApp.path]
        try? xattr.run(); xattr.waitUntilExit()

        let current = Bundle.main.bundleURL
        let old = current.deletingLastPathComponent().appendingPathComponent("PDF-Werkstatt (alt).app")
        try? fm.removeItem(at: old)
        try fm.moveItem(at: current, to: old)
        do { try fm.moveItem(at: newApp, to: current) }
        catch { try? fm.moveItem(at: old, to: current); throw error }   // zurückrollen
        try? fm.removeItem(at: tmp)
        Log.w("Update installiert, Neustart")
        // Neustart: nach dem Beenden die neue App öffnen
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; open \"\(current.path)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    private static func alert(_ title: String, _ text: String) {
        Log.w("Update: \(title) – \(text)")
        if ProcessInfo.processInfo.environment["PDFW_UPDATE_TEST"] != nil { NSApp.terminate(nil); return }
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}
