import AppKit
import PDFKit
import UniformTypeIdentifiers

@objc(WDocument)
final class WDocument: NSDocument {
    var pdf: PDFDocument! { didSet { generation += 1 } }
    var password: String?

    /// Zählt jede Änderung – Grundlage für Zwischenspeicher (Bytes, Inhaltsmodelle) und Sicherheitskopien
    private(set) var generation = 0
    private var cachedData: (Int, Data)?
    private var recoveryGeneration = -1
    private var recoveryTimer: Timer?
    let recoveryID = UUID().uuidString
    func touch() { generation += 1 }

    override class var autosavesInPlace: Bool { false }
    override class var readableTypes: [String] { ["com.adobe.pdf"] }
    override class var writableTypes: [String] { ["com.adobe.pdf"] }
    override class func isNativeType(_ type: String) -> Bool { true }

    var controller: MainWindowController? { windowControllers.first as? MainWindowController }

    override func makeWindowControllers() {
        if pdf == nil {
            pdf = PDFDocument()
            pdf.insert(PDFTools.blankPage(size: PDFTools.a4), at: 0)
        }
        addWindowController(MainWindowController(document: self))
        if let um = undoManager {
            for n in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(changed), name: n, object: um)
            }
        }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.writeRecovery() }
    }

    @objc private func changed() { generation += 1 }

    /// Sicherheitskopie, wenn sich seit der letzten etwas geändert hat
    func writeRecovery() {
        guard isDocumentEdited, generation != recoveryGeneration, controller?.canvas.isEditingText != true,
              let data = DrawMode.full({ pdf.dataRepresentation() }) else { return }
        recoveryGeneration = generation
        Recovery.write(id: recoveryID, data: data, name: displayName ?? "Dokument", original: fileURL)
        Log.v("Sicherheitskopie geschrieben (\(data.count) Bytes)")
    }

    override func save(to url: URL, ofType typeName: String, for op: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: op) { [weak self] err in
            if err == nil, let self, op != .autosaveElsewhereOperation { Recovery.remove(id: self.recoveryID); self.recoveryGeneration = self.generation }
            completionHandler(err)
        }
    }

    override func close() {
        recoveryTimer?.invalidate()
        Recovery.remove(id: recoveryID)
        super.close()
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let d = PDFDocument(data: data) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        }
        if d.isLocked {
            var ok = false
            let name = fileURL?.lastPathComponent ?? "Dokument"
            while !ok {
                guard let pw = Dialogs.askPassword(file: name) else {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                }
                ok = d.unlock(withPassword: pw)
                if ok { password = pw }
            }
        }
        hydrate(document: d)
        pdf = d
    }

    override func data(ofType typeName: String) throws -> Data {
        controller?.canvas.endEditing()
        guard let data = DrawMode.full({ pdf.dataRepresentation(options: PDFTools.writeOptions(password: password)) }) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        return data
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        controller?.canvas.endEditing()
        let snap = PDFTools.snapshot(pdf)
        guard let op = snap.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        return op
    }

    // MARK: Seiten (mit Widerrufen)

    func pagesChanged() { generation += 1; Log.v("pagesChanged"); controller?.pagesChanged() }

    func insertPage(_ p: PDFPage, at i: Int, action: String? = nil) {
        Log.v("insertPage at \(i) \(action ?? "")")
        let idx = max(0, min(i, pdf.pageCount))
        pdf.insert(p, at: idx)
        hydrate(page: p)
        undoManager?.registerUndo(withTarget: self) { $0.removePage(p, action: action) }
        if let action { undoManager?.safeActionName(action) }
        pagesChanged()
    }

    func removePage(_ p: PDFPage, action: String? = nil) {
        let i = pdf.index(for: p)
        guard i != NSNotFound, pdf.pageCount > 1 else { NSSound.beep(); return }
        pdf.removePage(at: i)
        undoManager?.registerUndo(withTarget: self) { $0.insertPage(p, at: i, action: action) }
        if let action { undoManager?.safeActionName(action) }
        pagesChanged()
    }

    func removePages(_ pages: [PDFPage]) {
        guard pages.count < pdf.pageCount else {
            NSSound.beep()
            return
        }
        undoManager?.beginUndoGrouping()
        pages.forEach { removePage($0) }
        undoManager?.safeActionName(pages.count == 1 ? "Seite löschen" : "Seiten löschen")
        undoManager?.endUndoGrouping()
    }

    func setPageOrder(_ order: [PDFPage], action: String = "Seiten verschieben") {
        let old = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
        guard old.count == order.count else { return }
        for (i, p) in order.enumerated() {
            let cur = pdf.index(for: p)
            if cur != i, cur != NSNotFound { pdf.removePage(at: cur); pdf.insert(p, at: i) }
        }
        undoManager?.registerUndo(withTarget: self) { $0.setPageOrder(old, action: action) }
        undoManager?.safeActionName(action)
        pagesChanged()
    }

    func movePages(_ idx: IndexSet, to dest: Int) {
        var order = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
        let moving = idx.compactMap { $0 < order.count ? order[$0] : nil }
        let before = idx.filter { $0 < dest }.count
        order.removeAll { p in moving.contains { $0 === p } }
        order.insert(contentsOf: moving, at: max(0, min(dest - before, order.count)))
        setPageOrder(order)
    }

    func rotate(_ pages: [PDFPage], by deg: Int) {
        for p in pages { p.rotation = PDFTools.normRotation(p.rotation + deg) }
        undoManager?.registerUndo(withTarget: self) { $0.rotate(pages, by: -deg) }
        undoManager?.safeActionName(deg < 0 ? "Nach links drehen" : "Nach rechts drehen")
        pagesChanged()
    }

    func duplicate(_ pages: [PDFPage]) {
        let snap = PDFTools.snapshot(pdf)
        undoManager?.beginUndoGrouping()
        for p in pages.reversed() {
            let i = pdf.index(for: p)
            guard let copy = snap.page(at: i) else { continue }
            insertPage(copy, at: i + 1)
            for case let w as WObject in copy.annotations { var m = w.model; m.id = UUID().uuidString; w.model = m }
        }
        undoManager?.safeActionName("Seite duplizieren")
        undoManager?.endUndoGrouping()
    }

    func insertBlank(at i: Int) {
        let ref = pdf.page(at: max(0, min(i - 1, pdf.pageCount - 1)))
        let size = ref.map { PDFTools.visualSize($0) } ?? PDFTools.a4
        insertPage(PDFTools.blankPage(size: size), at: i, action: "Leere Seite")
    }

    @discardableResult
    func insertPages(from url: URL, at i: Int) -> Bool {
        if let t = UTType(filenameExtension: url.pathExtension), t.conforms(to: .image),
           let img = NSImage(contentsOf: url), let p = PDFPage(image: img) {
            insertPage(p, at: i, action: "Bild als Seite")
            return true
        }
        guard let other = PDFDocument(url: url) else { NSSound.beep(); return false }
        if other.isLocked {
            guard let pw = Dialogs.askPassword(file: url.lastPathComponent), other.unlock(withPassword: pw) else { return false }
        }
        undoManager?.beginUndoGrouping()
        let pages = (0..<other.pageCount).compactMap { other.page(at: $0) }
        for (k, p) in pages.enumerated() {
            other.removePage(at: 0)
            insertPage(p, at: i + k)
        }
        undoManager?.safeActionName("Seiten einfügen")
        undoManager?.endUndoGrouping()
        return true
    }

    func extract(_ pages: [PDFPage]) -> PDFDocument {
        let snap = PDFTools.snapshot(pdf)
        let out = PDFDocument()
        for p in pages {
            let i = pdf.index(for: p)
            if let c = snap.page(at: i) { out.insert(c, at: out.pageCount) }
        }
        return out
    }

    /// Aktueller Stand als Bytes (inkl. aller eigenen Objekte) – Grundlage für Eingriffe in den Seiteninhalt
    func currentData() -> Data? {
        controller?.canvas.endEditing()
        if let (g, d) = cachedData, g == generation { return d }
        guard let d = DrawMode.full({ pdf.dataRepresentation() }) else { return nil }
        cachedData = (generation, d)
        return d
    }

    /// Dokument durch neue Bytes ersetzen (nach direktem Eingriff in den Inhalt). Widerrufbar über die alten Bytes.
    func replaceData(_ new: Data, old: Data, action: String) {
        guard let d = PDFDocument(data: new) else { NSSound.beep(); Log.w("replaceData: PDFKit kann Ergebnis nicht laden"); return }
        hydrate(document: d)
        let idx = controller?.canvas.currentPage.map { pdf.index(for: $0) } ?? 0
        pdf = d
        controller?.documentReplaced(pageIndex: idx)
        // Alter Stand auf die Platte statt in den Speicher (bei 20 MB und zehn Schritten sonst 200 MB)
        if let oldURL = UndoStore.save(old) {
            undoManager?.registerUndo(withTarget: self) { doc in
                guard let o = UndoStore.load(oldURL) else { NSSound.beep(); return }
                doc.replaceData(o, old: new, action: action)
            }
        } else {
            undoManager?.registerUndo(withTarget: self) { $0.replaceData(old, old: new, action: action) }
        }
        undoManager?.safeActionName(action)
        updateChangeCount(.changeDone)
        Log.w("replaceData \(action): \(new.count) Bytes, Seite \(idx)")
    }

    /// Dokument ohne Widerrufen-Eintrag auf einen Stand zurücksetzen (nach einem fehlgeschlagenen Eingriff)
    func restore(_ data: Data) {
        guard let d = PDFDocument(data: data) else { return }
        hydrate(document: d)
        let idx = controller?.canvas.currentPage.map { pdf.index(for: $0) } ?? 0
        pdf = d
        controller?.documentReplaced(pageIndex: idx)
    }

    // MARK: Sichern mit offenen Schwärzungen

    /// true = weitermachen, false = abgebrochen
    private func confirmPendingRedactions() -> Bool {
        guard let c = controller else { return true }
        let red = c.canvas.coverMarks(redact: true)
        guard !red.isEmpty else { return true }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = red.count == 1 ? "Eine Schwärzung ist noch nicht angewendet" : "\(red.count) Schwärzungen sind noch nicht angewendet"
        a.informativeText = "Beim Sichern bleiben sie Markierungen: Der Inhalt darunter steht weiter in der Datei. Angewendet werden sie endgültig entfernt."
        a.addButton(withTitle: "Anwenden und sichern")
        a.addButton(withTitle: "Nur Markierungen sichern")
        a.addButton(withTitle: "Abbrechen")
        switch a.runModal() {
        case .alertFirstButtonReturn: return c.applyRedactions(confirm: false)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    override func save(_ sender: Any?) { if confirmPendingRedactions() { super.save(sender) } }
    override func saveAs(_ sender: Any?) { if confirmPendingRedactions() { super.saveAs(sender) } }

    static func openNew(with pdf: PDFDocument, name: String? = nil) {
        let d = WDocument()
        hydrate(document: pdf)
        d.pdf = pdf
        NSDocumentController.shared.addDocument(d)
        d.makeWindowControllers()
        d.showWindows()
        d.updateChangeCount(.changeDone)
        if let name { d.displayName = name }
    }
}
