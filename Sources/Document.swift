import AppKit
import PDFKit
import UniformTypeIdentifiers

@objc(WDocument)
final class WDocument: NSDocument {
    var pdf: PDFDocument!
    var password: String?

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

    func pagesChanged() { Log.w("pagesChanged"); controller?.pagesChanged() }

    func insertPage(_ p: PDFPage, at i: Int, action: String? = nil) {
        Log.w("insertPage at \(i) \(action ?? "")")
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
        return DrawMode.full { pdf.dataRepresentation() }
    }

    /// Dokument durch neue Bytes ersetzen (nach direktem Eingriff in den Inhalt). Widerrufbar über die alten Bytes.
    func replaceData(_ new: Data, old: Data, action: String) {
        guard let d = PDFDocument(data: new) else { NSSound.beep(); Log.w("replaceData: PDFKit kann Ergebnis nicht laden"); return }
        hydrate(document: d)
        let idx = controller?.canvas.currentPage.map { pdf.index(for: $0) } ?? 0
        pdf = d
        controller?.documentReplaced(pageIndex: idx)
        undoManager?.registerUndo(withTarget: self) { $0.replaceData(old, old: new, action: action) }
        undoManager?.safeActionName(action)
        updateChangeCount(.changeDone)
        Log.w("replaceData \(action): \(new.count) Bytes, Seite \(idx)")
    }

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
