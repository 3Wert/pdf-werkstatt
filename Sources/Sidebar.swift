import AppKit
import PDFKit
import UniformTypeIdentifiers

final class PageTable: NSTableView {
    weak var owner: SidebarController?
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 51 || e.keyCode == 117 { owner?.deleteSelected(nil); return }
        super.keyDown(with: e)
    }
    @objc func delete(_ sender: Any?) { owner?.deleteSelected(sender) }
}

final class PageCell: NSTableCellView {
    let thumb = NSImageView()
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        thumb.imageScaling = .scaleProportionallyDown
        thumb.wantsLayer = true
        thumb.layer?.shadowOpacity = 0.25
        thumb.layer?.shadowRadius = 2
        thumb.layer?.shadowOffset = CGSize(width: 0, height: -1)
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        for v in [thumb, label] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            thumb.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        imageView = thumb
        textField = label
    }
    required init?(coder: NSCoder) { nil }
}

/// Einfache Liste (Hervorhebungen und Notizen, Lesezeichen)
final class ListSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item { var title: String; var detail: String; var page: PDFPage; var annotation: PDFAnnotation? }
    var items: [Item] = []
    var onPick: ((Item) -> Void)?
    var onDelete: ((Item) -> Void)?
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let it = items[row]
        let t = NSTextField(labelWithString: it.title)
        t.font = .systemFont(ofSize: 12, weight: .medium)
        t.lineBreakMode = .byTruncatingTail
        let d = NSTextField(labelWithString: it.detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.lineBreakMode = .byTruncatingTail
        d.maximumNumberOfLines = 2
        let v = NSStackView(views: [t, d])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 1
        v.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        return v
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { items[row].detail.isEmpty ? 26 : 46 }
    func tableViewSelectionDidChange(_ n: Notification) {
        guard let t = n.object as? NSTableView, t.selectedRow >= 0, t.selectedRow < items.count else { return }
        onPick?(items[t.selectedRow])
    }
}

final class ListTable: NSTableView {
    var onDeleteKey: (() -> Void)?
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 51 || e.keyCode == 117 { onDeleteKey?(); return }
        super.keyDown(with: e)
    }
}

/// Inhaltsverzeichnis aus dem PDF
final class OutlineSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var root: PDFOutline?
    var onPick: ((PDFOutline) -> Void)?
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? root)?.numberOfChildren ?? 0
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? root)!.child(at: index)!
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0 }
    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let t = NSTextField(labelWithString: (item as? PDFOutline)?.label ?? "")
        t.lineBreakMode = .byTruncatingTail
        t.font = .systemFont(ofSize: 12)
        return t
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        guard let o = n.object as? NSOutlineView, let it = o.item(atRow: o.selectedRow) as? PDFOutline else { return }
        onPick?(it)
    }
}

/// Zieh-Quelle für Seiten: innerhalb der App die Zeilennummer, nach außen (Finder, Schreibtisch, Mail) eine PDF-Datei
final class PagePromise: NSFilePromiseProvider {
    var rowInfo = ""
    var secondary = false      // bei Mehrfachauswahl schreibt nur der erste Eintrag die (gemeinsame) Datei

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        secondary ? [SidebarController.rowType] : super.writableTypes(for: pasteboard) + [SidebarController.rowType]
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == SidebarController.rowType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == SidebarController.rowType ? rowInfo : super.pasteboardPropertyList(forType: type)
    }
}

final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSFilePromiseProviderDelegate {
    private var dragRows = IndexSet()
    private var promises: [Int: PagePromise] = [:]
    private let promiseQueue = OperationQueue()
    weak var wdoc: WDocument?
    weak var canvas: Canvas?
    var onPickAnnotation: ((PDFAnnotation) -> Void)?
    var mode: SidebarMode = .thumbnails { didSet { applyMode() } }
    private let scroll = NSScrollView()
    private let list = ListTable()
    private let listSource = ListSource()
    private let outline = NSOutlineView()
    private let outlineSource = OutlineSource()
    private let emptyLabel = NSTextField(labelWithString: "")
    let table = PageTable()
    private let thumbs = NSCache<PDFPage, NSImage>()
    private var syncing = false
    private var pending = Set<ObjectIdentifier>()
    private var pendingWork: DispatchWorkItem?
    static let rowType = NSPasteboard.PasteboardType("de.marlonelsner.pdf-werkstatt.seite")

    var pdf: PDFDocument? { wdoc?.pdf }

    override func loadView() {
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let col = NSTableColumn(identifier: .init("seite"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 190
        table.style = .sourceList
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.owner = self
        table.registerForDraggedTypes([Self.rowType, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table

        // Liste und Inhaltsverzeichnis
        list.addTableColumn(NSTableColumn(identifier: .init("eintrag")))
        list.headerView = nil
        list.style = .sourceList
        list.dataSource = listSource
        list.delegate = listSource
        list.onDeleteKey = { [weak self] in self?.deleteListItem() }
        listSource.onPick = { [weak self] it in
            self?.canvas?.go(to: it.page)
            if let a = it.annotation { self?.onPickAnnotation?(a) }
        }
        let oc = NSTableColumn(identifier: .init("kapitel"))
        outline.addTableColumn(oc)
        outline.outlineTableColumn = oc
        outline.headerView = nil
        outline.style = .sourceList
        outline.dataSource = outlineSource
        outline.delegate = outlineSource
        outlineSource.onPick = { [weak self] o in
            if let d = o.destination { self?.canvas?.go(to: d) } else if let a = o.action as? PDFActionGoTo { self?.canvas?.go(to: a.destination) }
        }
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll); root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentChanged), name: .NSUndoManagerDidCloseUndoGroup, object: nil)
    }

    private func applyMode() {
        guard isViewLoaded else { return }
        emptyLabel.stringValue = ""
        switch mode {
        case .outline:
            outlineSource.root = pdf?.outlineRoot
            outline.reloadData()
            outline.expandItem(nil, expandChildren: false)
            scroll.documentView = outline
            if (pdf?.outlineRoot?.numberOfChildren ?? 0) == 0 { emptyLabel.stringValue = "Kein Inhaltsverzeichnis" }
        case .annotations, .bookmarks:
            reloadList()
            scroll.documentView = list
        default:
            scroll.documentView = table
            reload()
        }
    }

    @objc private func contentChanged() {
        if mode == .annotations { DispatchQueue.main.async { self.reloadList() } }
    }

    private func reloadList() {
        guard let d = pdf else { return }
        var items: [ListSource.Item] = []
        if mode == .annotations {
            for i in 0..<d.pageCount {
                guard let p = d.page(at: i) else { continue }
                for a in p.annotations {
                    let t = a.type ?? ""
                    if ["Link", "Widget", "Popup"].contains(t) { continue }
                    var title: String, detail = ""
                    if let w = a as? WObject {
                        if w.model.kind == .cover || w.model.kind == .pageNumber { continue }
                        title = w.kindName
                        detail = w.model.kind == .text ? w.model.text : ""
                    } else {
                        switch t {
                        case "Highlight": title = "Hervorhebung"
                        case "Underline": title = "Unterstreichung"
                        case "StrikeOut": title = "Durchstreichung"
                        case "Text": title = "Notiz"
                        case "FreeText": title = "Text"
                        default: title = t
                        }
                        detail = a.contents ?? ""
                        if detail.isEmpty, ["Highlight", "Underline", "StrikeOut"].contains(t) { detail = p.selection(for: a.bounds)?.string ?? "" }
                    }
                    items.append(.init(title: "Seite \(i + 1) · \(title)", detail: detail.trimmed.replacingOccurrences(of: "\n", with: " "), page: p, annotation: a))
                }
            }
            if items.isEmpty { emptyLabel.stringValue = "Keine Hervorhebungen oder Notizen" }
        } else {
            for i in bookmarks where i < d.pageCount {
                if let p = d.page(at: i) {
                    let text = (p.string ?? "").trimmed.split(separator: "\n").first.map(String.init) ?? ""
                    items.append(.init(title: "Seite \(i + 1)", detail: text, page: p, annotation: nil))
                }
            }
            if items.isEmpty { emptyLabel.stringValue = "Keine Lesezeichen\n(⌘D fügt eins hinzu)" }
        }
        listSource.items = items
        list.reloadData()
    }

    // MARK: Lesezeichen

    private var bookmarkKey: String { "lesezeichen:" + (wdoc?.fileURL?.path ?? wdoc?.displayName ?? "") }
    private var bookmarks: [Int] {
        get { prefs.array(forKey: bookmarkKey) as? [Int] ?? [] }
        set { prefs.set(Array(Set(newValue)).sorted(), forKey: bookmarkKey) }
    }

    func addBookmark(_ p: PDFPage) {
        guard let d = pdf else { return }
        bookmarks = bookmarks + [d.index(for: p)]
        if mode == .bookmarks { reloadList() }
    }

    private func deleteListItem() {
        let r = list.selectedRow
        guard r >= 0, r < listSource.items.count, let d = pdf else { return }
        let it = listSource.items[r]
        if mode == .bookmarks {
            let i = d.index(for: it.page)
            bookmarks = bookmarks.filter { $0 != i }
        } else if let a = it.annotation, let p = a.page {
            canvas?.remove(a, from: p, action: "Löschen")
        }
        reloadList()
    }

    // MARK: Daten

    func numberOfRows(in tableView: NSTableView) -> Int { pdf?.pageCount ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("zelle")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? PageCell) ?? {
            let c = PageCell(); c.identifier = id; return c
        }()
        guard let p = pdf?.page(at: row) else { return cell }
        cell.thumb.image = thumbnail(p) ?? Self.placeholder(for: p)
        cell.label.stringValue = p.label.flatMap { $0 != "\(row + 1)" ? "\(row + 1) (\($0))" : nil } ?? "\(row + 1)"
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let p = pdf?.page(at: row) else { return 190 }
        let vs = PDFTools.visualSize(p)
        let w = max(60, table.bounds.width - 20)
        return min(max(w * vs.height / max(vs.width, 1), 60), 400) + 36
    }

    private static let renderQueue = DispatchQueue(label: "miniaturen", qos: .userInitiated)
    private var rendering = Set<ObjectIdentifier>()

    /// Miniatur aus dem Zwischenspeicher; fehlt sie, wird sie im Hintergrund gerendert und die Zeile danach aktualisiert.
    private func thumbnail(_ p: PDFPage) -> NSImage? {
        if let t = thumbs.object(forKey: p) { return t }
        let key = ObjectIdentifier(p)
        guard !rendering.contains(key) else { return nil }
        rendering.insert(key)
        Self.renderQueue.async { [weak self] in
            let t = DrawMode.full { p.thumbnail(of: NSSize(width: 320, height: 420), for: .cropBox) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering.remove(key)
                self.thumbs.setObject(t, forKey: p)
                if let d = self.pdf, let i = Optional(d.index(for: p)), i != NSNotFound, i < self.table.numberOfRows {
                    self.syncing = true
                    self.table.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 0))
                    self.syncing = false
                }
            }
        }
        return nil
    }

    /// Graue Fläche im Seitenformat, bis die Miniatur gerendert ist
    private static var placeholders: [String: NSImage] = [:]
    static func placeholder(for p: PDFPage) -> NSImage {
        let vs = PDFTools.visualSize(p)
        let k = "\(Int(vs.width))x\(Int(vs.height))"
        if let i = placeholders[k] { return i }
        let w: CGFloat = 320, h = w * vs.height / max(vs.width, 1)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in NSColor.white.setFill(); r.fill(); return true }
        placeholders[k] = img
        return img
    }

    func reload() {
        thumbs.removeAllObjects()
        syncing = true
        table.reloadData()
        syncing = false
        pageChanged()
    }

    /// Miniatur einer Seite verzögert neu zeichnen (nicht bei jeder Mausbewegung).
    func refresh(_ p: PDFPage) {
        pending.insert(ObjectIdentifier(p))
        pendingWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let d = self.pdf else { return }
            var rows = IndexSet()
            for i in 0..<d.pageCount {
                if let pg = d.page(at: i), self.pending.contains(ObjectIdentifier(pg)) { self.thumbs.removeObject(forKey: pg); rows.insert(i) }
            }
            self.pending.removeAll()
            self.syncing = true
            self.table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            self.syncing = false
        }
        pendingWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func pageChanged() {
        guard let c = canvas, let p = c.currentPage, let d = pdf else { return }
        let i = d.index(for: p)
        guard i != NSNotFound, i < table.numberOfRows else { return }
        if table.selectedRowIndexes.contains(i) { return }
        syncing = true
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
        syncing = false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let d = pdf else { return }
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        if row >= 0, let p = d.page(at: row) { canvas?.go(to: p) }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
    }

    var selectedPages: [PDFPage] {
        guard let d = pdf else { return [] }
        var rows = table.selectedRowIndexes
        if table.clickedRow >= 0 && !rows.contains(table.clickedRow) { rows = IndexSet(integer: table.clickedRow) }
        if rows.isEmpty, let p = canvas?.currentPage { return [p] }
        return rows.compactMap { d.page(at: $0) }
    }

    // MARK: Ziehen

    var docID: String { wdoc.map { "\(ObjectIdentifier($0).hashValue)" } ?? "" }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let p = PagePromise(fileType: UTType.pdf.identifier, delegate: self)
        p.rowInfo = "\(docID):\(row)"
        p.userInfo = row
        promises[row] = p
        return p
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rows: IndexSet) {
        beginDrag(rows: rows)
    }

    func beginDrag(rows: IndexSet) {
        dragRows = rows
        // Mehrere Seiten → eine gemeinsame Datei, geschrieben vom ersten Eintrag
        for (r, p) in promises { p.secondary = r != rows.first }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        promises.removeAll()
    }

    // MARK: Datei-Versprechen (Ziehen nach außen)

    private var dragPages: [PDFPage] {
        guard let d = pdf else { return [] }
        return dragRows.compactMap { d.page(at: $0) }
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let base = ((wdoc?.displayName ?? "Dokument") as NSString).deletingPathExtension
        let rows = dragRows
        if rows.count <= 1 { return "\(base) – Seite \((rows.first ?? 0) + 1).pdf" }
        let list = rows.map { $0 + 1 }
        let contiguous = list.last! - list.first! + 1 == list.count
        return contiguous ? "\(base) – Seiten \(list.first!)-\(list.last!).pdf" : "\(base) – \(list.count) Seiten.pdf"
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        // Daten auf dem Hauptthread erzeugen (PDFKit), Schreiben darf überall passieren
        DispatchQueue.main.async { [weak self] in
            guard let self, let doc = self.wdoc else { completionHandler(CocoaError(.fileWriteUnknown)); return }
            let out = doc.extract(self.dragPages)
            let ok = out.pageCount > 0 && out.write(to: url)
            Log.w("Seite(n) als Datei gezogen: \(url.lastPathComponent) – \(ok ? "ok" : "FEHLER")")
            completionHandler(ok ? nil : CocoaError(.fileWriteUnknown))
        }
    }

    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

    private func parse(_ items: [NSPasteboardItem]) -> (String, IndexSet) {
        var id = ""; var rows = IndexSet()
        for it in items {
            guard let s = it.string(forType: Self.rowType) else { continue }
            let parts = s.split(separator: ":")
            guard parts.count == 2, let r = Int(parts[1]) else { continue }
            id = String(parts[0]); rows.insert(r)
        }
        return (id, rows)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        if let items = info.draggingPasteboard.pasteboardItems, info.draggingPasteboard.types?.contains(Self.rowType) == true {
            return parse(items).0 == docID ? .move : .copy      // aus einem anderen Fenster: kopieren
        }
        return info.draggingPasteboard.types?.contains(.fileURL) == true ? .copy : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        if let items = pb.pasteboardItems, items.contains(where: { $0.string(forType: Self.rowType) != nil }) {
            let (id, rows) = parse(items)
            if id == docID { wdoc?.movePages(rows, to: row); return true }
            // Seiten aus einem anderen Fenster übernehmen (Kopie, Original bleibt)
            guard let src = NSDocumentController.shared.documents.compactMap({ $0 as? WDocument }).first(where: { "\(ObjectIdentifier($0).hashValue)" == id }),
                  let wd = wdoc else { return false }
            let pages = rows.compactMap { src.pdf.page(at: $0) }
            let copy = src.extract(pages)
            wd.undoManager?.beginUndoGrouping()
            for k in 0..<copy.pageCount {
                guard let pg = copy.page(at: 0) else { break }
                copy.removePage(at: 0)
                wd.insertPage(pg, at: row + k)
            }
            wd.undoManager?.safeActionName("Seiten übernehmen")
            wd.undoManager?.endUndoGrouping()
            return true
        }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var at = row
        wdoc?.undoManager?.beginUndoGrouping()
        for u in urls {
            let before = pdf?.pageCount ?? 0
            if wdoc?.insertPages(from: u, at: at) == true { at += (pdf?.pageCount ?? 0) - before }
        }
        wdoc?.undoManager?.endUndoGrouping()
        return !urls.isEmpty
    }

    // MARK: Kontextmenü

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ t: String, _ s: Selector) { menu.addItem(withTitle: t, action: s, keyEquivalent: "").target = self }
        item("Nach links drehen", #selector(rotateLeft(_:)))
        item("Nach rechts drehen", #selector(rotateRight(_:)))
        menu.addItem(.separator())
        item("Duplizieren", #selector(duplicatePages(_:)))
        item("Leere Seite danach einfügen", #selector(insertBlankAfter(_:)))
        item("Seiten aus Datei einfügen …", #selector(insertFromFile(_:)))
        item("Als eigenes PDF sichern …", #selector(extractPages(_:)))
        menu.addItem(.separator())
        item("Löschen", #selector(deleteSelected(_:)))
    }

    @objc func rotateLeft(_ s: Any?) { wdoc?.rotate(selectedPages, by: -90) }
    @objc func rotateRight(_ s: Any?) { wdoc?.rotate(selectedPages, by: 90) }
    @objc func duplicatePages(_ s: Any?) { wdoc?.duplicate(selectedPages) }
    @objc func deleteSelected(_ s: Any?) { wdoc?.removePages(selectedPages) }

    @objc func insertBlankAfter(_ s: Any?) {
        guard let d = pdf, let last = selectedPages.last else { return }
        wdoc?.insertBlank(at: d.index(for: last) + 1)
    }

    @objc func insertFromFile(_ s: Any?) {
        guard let w = view.window, let d = pdf else { return }
        let after = selectedPages.last.map { d.index(for: $0) + 1 } ?? d.pageCount
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = "PDFs oder Bilder auswählen – die Seiten werden eingefügt."
        panel.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let self else { return }
            var at = after
            self.wdoc?.undoManager?.beginUndoGrouping()
            for u in panel.urls {
                let before = d.pageCount
                if self.wdoc?.insertPages(from: u, at: at) == true { at += d.pageCount - before }
            }
            self.wdoc?.undoManager?.endUndoGrouping()
        }
    }

    @objc func extractPages(_ s: Any?) {
        guard let w = view.window, let doc = wdoc else { return }
        let pages = selectedPages
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = (doc.displayName as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + (pages.count == 1 ? " – Seite \(doc.pdf.index(for: pages[0]) + 1)" : " – Auszug") + ".pdf"
        panel.beginSheetModal(for: w) { r in
            guard r == .OK, let url = panel.url else { return }
            doc.extract(pages).write(to: url)
        }
    }
}
