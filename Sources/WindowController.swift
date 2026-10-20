import AppKit
import PDFKit
import UniformTypeIdentifiers

extension NSToolbarItem.Identifier {
    static let sidebarMenu = Self("darstellung")
    static let modes = Self("werkzeuge")
    static let shapes = Self("formen")
    static let textBox = Self("text")
    static let note = Self("notiz")
    static let signature = Self("unterschrift")
    static let image = Self("bild")
    static let pageNumbers = Self("seitenzahlen")
    static let lineStyle = Self("formstil")
    static let strokeColor = Self("rahmenfarbe")
    static let fillColor = Self("fuellfarbe")
    static let textStyle = Self("textstil")
    static let highlight = Self("hervorheben")
    static let rotate = Self("drehen")
    static let zoom = Self("zoom")
    static let share = Self("teilen")
    static let search = Self("suche")
    static let insertGroup = Self("einsetzen")
    static let styleGroup = Self("stil")
}

enum SidebarMode: Int { case none = 0, thumbnails, outline, annotations, bookmarks, contactSheet }

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, NSSearchFieldDelegate,
                                  NSSharingServicePickerToolbarItemDelegate, NSMenuDelegate {
    let canvas = Canvas(frame: .zero)
    let sidebar = SidebarController()
    let inspector = InspectorController()
    private var split: NSSplitViewController!
    private var sideItem: NSSplitViewItem!
    private var inspItem: NSSplitViewItem!
    private let contactSheet = ContactSheet()
    private var searchItem: NSSearchToolbarItem?
    private var highlightItem: NSMenuToolbarItem?
    private var modeGroup: NSToolbarItemGroup?
    private var strokeItem: NSToolbarItem?
    private var fillItem: NSToolbarItem?
    private var styleGroupItem: NSToolbarItemGroup?
    private var shareButton: NSButton?
    private var sharePicker: NSSharingServicePicker?
    private var infoPanel: InfoPanel?
    private let rulerTop = RulerView(horizontal: true)
    private let rulerLeft = RulerView(horizontal: false)
    private var popover: NSPopover?
    private(set) var sidebarMode: SidebarMode = .thumbnails
    var wdoc: WDocument? { document as? WDocument }

    /// Reihenfolge in der Werkzeuggruppe
    private let modes: [Tool] = [.textSelect, .rectSelect, .crop, .editText, .whiteout, .draw, .sketch, .redact]

    init(document doc: WDocument) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.minSize = NSSize(width: 760, height: 460)
        w.toolbarStyle = .unified
        super.init(window: w)
        w.delegate = self
        shouldCascadeWindows = true

        canvas.wdoc = doc
        sidebar.wdoc = doc
        sidebar.canvas = canvas
        inspector.canvas = canvas

        let content = NSView()
        for v in [canvas, contactSheet] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                         v.topAnchor.constraint(equalTo: content.topAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        }
        contactSheet.isHidden = true
        for r in [rulerTop, rulerLeft] { r.canvas = canvas; r.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(r) }
        NSLayoutConstraint.activate([
            rulerTop.topAnchor.constraint(equalTo: content.topAnchor), rulerTop.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: RulerView.thickness),
            rulerTop.trailingAnchor.constraint(equalTo: content.trailingAnchor), rulerTop.heightAnchor.constraint(equalToConstant: RulerView.thickness),
            rulerLeft.topAnchor.constraint(equalTo: content.topAnchor, constant: RulerView.thickness), rulerLeft.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rulerLeft.bottomAnchor.constraint(equalTo: content.bottomAnchor), rulerLeft.widthAnchor.constraint(equalToConstant: RulerView.thickness),
        ])
        let centerVC = NSViewController()
        centerVC.view = content
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        split = NSSplitViewController()
        sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 130
        sideItem.maximumThickness = 340
        sideItem.canCollapse = true
        inspItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspItem.minimumThickness = 240
        inspItem.maximumThickness = 320
        inspItem.canCollapse = true
        inspItem.isCollapsed = true
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: centerVC))
        split.addSplitViewItem(inspItem)
        w.contentViewController = split
        w.setContentSize(NSSize(width: 1320, height: 880))

        let tb = NSToolbar(identifier: "PDFWerkstattToolbar5")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = true
        w.toolbar = tb

        canvas.document = doc.pdf
        canvas.customGuides = GuideStore.load(doc)
        canvas.onViewChanged = { [weak self] in self?.rulerTop.needsDisplay = true; self?.rulerLeft.needsDisplay = true }
        applyGuideSettings()
        canvas.onToolChange = { [weak self] _ in self?.toolStateChanged() }
        canvas.onSelectionChange = { [weak self] a in
            self?.inspector.show(a)
            self?.refreshStyleItems()
        }
        canvas.onPageContentChange = { [weak self] p in self?.sidebar.refresh(p) }
        canvas.onSearch = { [weak self] i, n in
            self?.searchItem?.searchField.placeholderString = n > 0 ? "\(i) von \(n)" : "Suchen"
        }
        contactSheet.onPick = { [weak self] p in
            self?.setSidebarMode(.thumbnails)
            self?.canvas.go(to: p)
        }
        sidebar.onPickAnnotation = { [weak self] a in self?.canvas.select(a) }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: canvas)
        sidebar.reload()
        updatePageLabel()
        w.setFrameAutosaveName("PDFWerkstattFenster")
        w.makeFirstResponder(canvas)
    }
    required init?(coder: NSCoder) { nil }

    /// Nach einem Eingriff in den Seiteninhalt: neues PDFDocument einhängen, Seite/Zoom/Position behalten
    /// Nach dem Öffnen: Scan ohne Textebene → einmal anbieten
    func offerOCRIfScanned() {
        guard let d = wdoc, d.scanCandidate, let w = window, ProcessInfo.processInfo.environment["PDFW_SELFTEST"] == nil, ProcessInfo.processInfo.environment["PDFW_REDACT_UITEST"] == nil, ProcessInfo.processInfo.environment["PDFW_OCR_UITEST"] == nil, ProcessInfo.processInfo.environment["PDFW_COMPLEX_UITEST"] == nil, ProcessInfo.processInfo.environment["PDFW_EDIT_UITEST"] == nil else { return }
        d.scanCandidate = false
        let a = NSAlert()
        a.messageText = "Gescanntes Dokument ohne Textebene"
        a.informativeText = "Soll der Text erkannt werden? Danach ist das Dokument durchsuchbar und kopierbar, und „Suchen und schwärzen“ findet die Stellen. Die Darstellung ändert sich nicht."
        a.addButton(withTitle: "Text erkennen")
        a.addButton(withTitle: "Später")
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn, let pdf = d.pdf else { return }
            self.runOCR(pages: OCR.candidatePages(pdf, onlyWithoutText: true).todo)
        }
    }

    func documentReplaced(pageIndex: Int) {
        guard let d = wdoc?.pdf else { return }
        let scale = canvas.scaleFactor, auto = canvas.autoScales
        let dest = canvas.currentDestination
        canvas.clearContentSelection()
        canvas.document = d
        canvas.autoScales = auto
        if !auto { canvas.scaleFactor = scale }
        if let p = d.page(at: min(pageIndex, d.pageCount - 1)) {
            if let dest { canvas.go(to: PDFDestination(page: p, at: dest.point)) } else { canvas.go(to: p) }
        }
        sidebar.reload()
        if !contactSheet.isHidden { contactSheet.reload(d) }
        updatePageLabel()
        canvas.overlay.needsDisplay = true
    }

    func pagesChanged() {
        canvas.layoutDocumentView()
        canvas.overlay.needsDisplay = true
        sidebar.reload()
        if !contactSheet.isHidden { contactSheet.reload(canvas.document) }
        updatePageLabel()
    }

    @objc private func pageChanged() {
        sidebar.pageChanged()
        updatePageLabel()
    }

    private func updatePageLabel() {
        guard let d = canvas.document else { return }
        let i = canvas.currentPage.map { d.index(for: $0) + 1 } ?? 1
        window?.subtitle = "Seite \(i) von \(d.pageCount)"
    }

    private func toolStateChanged() {
        if let g = modeGroup, let i = modes.firstIndex(of: canvas.tool) { g.selectedIndex = i }
        if let it = highlightItem {
            let c = canvas.highlight?.color ?? canvas.lastHighlight.color
            let sym = canvas.highlight?.type == .underline ? "underline" : canvas.highlight?.type == .strikeOut ? "strikethrough" : "highlighter"
            let base = NSImage(systemSymbolName: sym, accessibilityDescription: "Hervorheben")!
            it.image = canvas.highlight != nil ? (base.withSymbolConfiguration(.init(paletteColors: [c])) ?? base) : base
        }
        refreshStyleItems()
    }

    private func refreshStyleItems() {
        let m = canvas.styleModel
        let stroke = m.kind == .cover ? m.fill?.color : m.stroke?.color
        strokeItem?.image = swatchImage(stroke ?? (canvas.selected == nil ? Defaults.model.stroke?.color : nil), filled: false, size: 18)
        fillItem?.image = swatchImage(m.fill?.color, filled: true, size: 18)
    }

    func windowWillClose(_ notification: Notification) { canvas.endEditing(); infoPanel?.close() }

    /// Widerrufen aus jeder Ecke des Fensters (Seitenleiste, Suche …) landet bei der Arbeitsfläche
    @objc func undo(_ s: Any?) { canvas.undo(s) }
    @objc func redo(_ s: Any?) { canvas.redo(s) }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { wdoc?.undoManager }

    // MARK: Werkzeugleiste – eine Reihe, immer sichtbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarMenu, .sidebarTrackingSeparator, .modes, .shapes, .signature, .insertGroup,
         .styleGroup, .flexibleSpace, .highlight, .rotate, .zoom, .share, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.textBox, .note, .image, .pageNumbers, .lineStyle, .strokeColor, .fillColor, .textStyle, .print, .toggleInspector]
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector, tip: String? = nil) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        it.label = label
        it.paletteLabel = label
        it.toolTip = tip ?? label
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        it.target = self
        it.action = action
        it.isBordered = true
        return it
    }

    private func menuItem(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, menu: NSMenu, action: Selector?) -> NSMenuToolbarItem {
        let it = NSMenuToolbarItem(itemIdentifier: id)
        it.label = label
        it.paletteLabel = label
        it.toolTip = label
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        it.menu = menu
        it.showsIndicator = true
        if let action { it.target = self; it.action = action }
        return it
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .sidebarMenu:
            return menuItem(id, "Seitenleiste", "sidebar.left", menu: sidebarModeMenu(), action: #selector(toggleSidebarButton(_:)))
        case .modes:
            let tips = ["Textauswahl", "Bereich auswählen – Rahmen ziehen: ⌫ löscht alles darin, Ziehen verschiebt, ⌘C kopiert als Bild",
                        "Zuschneiden – Rahmen aufziehen, Enter schneidet zu",
                        "PDF-Inhalt bearbeiten – Klick wählt Text/Bild/Linie (⌫ löscht, Ziehen verschiebt), Doppelklick ändert Text",
                        "Abdecken – Rechteck über den Bereich ziehen", "Zeichnen (Freihand)",
                        "Skizzieren – Linie, Pfeil, Rechteck, Oval werden erkannt", "Schwärzen – Rechteck ziehen, danach Werkzeuge › Schwärzungen anwenden"]
            let g = NSToolbarItemGroup(itemIdentifier: id, images: modes.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! },
                                       selectionMode: .selectOne, labels: modes.map { $0.title }, target: self, action: #selector(modePicked(_:)))
            g.label = "Werkzeug"
            g.controlRepresentation = .expanded
            g.visibilityPriority = .high
            for (i, sub) in g.subitems.enumerated() { sub.toolTip = tips[i] }
            g.selectedIndex = 0
            modeGroup = g
            return g
        case .insertGroup:
            // Fällt bei schmalem Fenster automatisch zu einem Menü zusammen
            let g = NSToolbarItemGroup(itemIdentifier: id)
            g.subitems = [button(.textBox, "Text", "character.textbox", #selector(insertTextBox(_:)), tip: "Neues Textfeld"),
                          button(.note, "Notiz", "note.text", #selector(insertNote(_:))),
                          button(.image, "Bild", "photo", #selector(insertImage(_:)), tip: "Bild einfügen …"),
                          button(.pageNumbers, "Seitenzahlen", "number", #selector(pageNumbers(_:)), tip: "Seitenzahlen …")]
            g.label = "Einsetzen"
            g.paletteLabel = "Einsetzen"
            g.controlRepresentation = .automatic
            return g
        case .styleGroup:
            let g = NSToolbarItemGroup(itemIdentifier: id)
            let st = button(.strokeColor, "Rahmenfarbe", "square", #selector(strokeColorPopover(_:)))
            let fi = button(.fillColor, "Füllfarbe", "square.fill", #selector(fillColorPopover(_:)))
            strokeItem = st; fillItem = fi
            g.subitems = [button(.lineStyle, "Formstil", "line.3.horizontal", #selector(lineStylePopover(_:)), tip: "Linienstärke, gestrichelt, Schatten"),
                          st, fi,
                          button(.textStyle, "Textstil", "textformat", #selector(textStylePopover(_:)), tip: "Schrift, Größe, Textfarbe")]
            g.label = "Stil"
            g.paletteLabel = "Stil"
            g.controlRepresentation = .automatic
            styleGroupItem = g
            refreshStyleItems()
            return g
        case .shapes:
            return menuItem(id, "Formen", "square.on.circle", menu: shapesMenu(), action: nil)
        case .textBox:
            return button(id, "Text", "character.textbox", #selector(insertTextBox(_:)), tip: "Neues Textfeld")
        case .note:
            return button(id, "Notiz", "note.text", #selector(insertNote(_:)))
        case .signature:
            let m = NSMenu()
            m.delegate = self
            return menuItem(id, "Unterschrift", "signature", menu: m, action: nil)
        case .image:
            return button(id, "Bild", "photo", #selector(insertImage(_:)), tip: "Bild einfügen …")
        case .pageNumbers:
            return button(id, "Seitenzahlen", "number", #selector(pageNumbers(_:)), tip: "Seitenzahlen …")
        case .lineStyle:
            return button(id, "Formstil", "line.3.horizontal", #selector(lineStylePopover(_:)), tip: "Linienstärke, gestrichelt, Schatten")
        case .strokeColor:
            let it = button(id, "Rahmenfarbe", "square", #selector(strokeColorPopover(_:)))
            strokeItem = it
            refreshStyleItems()
            return it
        case .fillColor:
            let it = button(id, "Füllfarbe", "square.fill", #selector(fillColorPopover(_:)))
            fillItem = it
            refreshStyleItems()
            return it
        case .textStyle:
            return button(id, "Textstil", "textformat", #selector(textStylePopover(_:)), tip: "Schrift, Größe, Textfarbe")
        case .highlight:
            let it = menuItem(id, "Hervorheben", "highlighter", menu: highlightMenu(), action: #selector(toggleHighlight(_:)))
            it.visibilityPriority = .high
            highlightItem = it
            return it
        case .rotate:
            let it = button(id, "Drehen", "rotate.left", #selector(rotateLeft(_:)), tip: "Seite nach links drehen (⌥-Klick: rechts)")
            it.visibilityPriority = .low
            return it
        case .zoom:
            let g = NSToolbarItemGroup(itemIdentifier: id, images: [
                NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Verkleinern")!,
                NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Vergrößern")!,
            ], selectionMode: .momentary, labels: ["Verkleinern", "Vergrößern"], target: self, action: #selector(zoomGroup(_:)))
            g.label = "Zoomen"
            g.visibilityPriority = .low
            return g
        case .share:
            // eigener Knopf: vor dem Teilen auf nur abgedeckte Stellen prüfen
            let it = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Teilen")!, target: self, action: #selector(shareClicked(_:)))
            b.bezelStyle = .toolbar
            b.toolTip = "Teilen"
            shareButton = b
            it.view = b
            it.label = "Teilen"
            it.paletteLabel = "Teilen"
            it.visibilityPriority = .low
            return it
        case .search:
            let it = NSSearchToolbarItem(itemIdentifier: id)
            it.searchField.placeholderString = "Suchen"
            it.searchField.delegate = self
            it.searchField.target = self
            it.searchField.action = #selector(searchEntered(_:))
            it.searchField.sendsWholeSearchString = true
            it.preferredWidthForSearchField = 160
            it.visibilityPriority = .high
            searchItem = it
            return it
        default:
            return nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for i in signatureMenu().items { menu.addItem(i.copy() as! NSMenuItem) }
    }

    @objc func modePicked(_ g: NSToolbarItemGroup) {
        guard g.selectedIndex >= 0, g.selectedIndex < modes.count else { return }
        canvas.tool = modes[g.selectedIndex]
        canvas.window?.makeFirstResponder(canvas)
    }

    private func shapesMenu() -> NSMenu {
        let m = NSMenu()
        let items: [(String, String, ObjKind)] = [("Linie", "line.diagonal", .line), ("Pfeil", "arrow.up.right", .arrow),
            ("Rechteck", "rectangle", .rect), ("Abgerundetes Rechteck", "rectangle.roundedtop", .roundRect),
            ("Oval", "oval", .ellipse), ("Sprechblase", "bubble.left", .bubble), ("Stern", "star", .star), ("Vieleck", "hexagon", .polygon)]
        for (t, sym, k) in items {
            let i = NSMenuItem(title: t, action: #selector(insertShapeMenu(_:)), keyEquivalent: "")
            i.image = NSImage(systemSymbolName: sym, accessibilityDescription: t)
            i.representedObject = k.rawValue
            i.target = self
            m.addItem(i)
        }
        return m
    }

    // MARK: Popover an Werkzeugleisten-Knöpfen

    private func show(_ vc: NSViewController, at item: NSToolbarItem) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        // Unterpunkte einer Gruppe haben keinen eigenen Platz in der Leiste – an der Gruppe verankern
        let anchor: NSToolbarItem = (window?.toolbar?.items.contains { $0 === item } == true) ? item : (styleGroupItem ?? item)
        p.show(relativeTo: anchor)
        popover = p
    }

    @objc func lineStylePopover(_ it: NSToolbarItem) { show(LineStylePopover(canvas: canvas), at: it) }
    @objc func textStylePopover(_ it: NSToolbarItem) { show(TextStylePopover(canvas: canvas), at: it) }
    @objc func strokeColorPopover(_ it: NSToolbarItem) {
        let vc = ColorPopover(allowsNone: true)
        let m = canvas.styleModel
        vc.currentColor = (m.kind == .cover ? m.fill : m.stroke)?.color
        vc.onPick = { [weak self] c in self?.canvas.applyColor(c, to: .stroke); self?.refreshStyleItems() }
        show(vc, at: it)
    }
    @objc func fillColorPopover(_ it: NSToolbarItem) {
        let vc = ColorPopover(allowsNone: true)
        vc.currentColor = canvas.styleModel.fill?.color
        vc.onPick = { [weak self] c in self?.canvas.applyColor(c, to: .fill); self?.refreshStyleItems() }
        show(vc, at: it)
    }

    // MARK: Schwärzen

    @objc func applyRedactions(_ s: Any?) { _ = applyRedactions(confirm: true) }

    /// Alle Schwärzungs-Markierungen anwenden. Liefert true, wenn angewendet wurde.
    @discardableResult
    func applyRedactions(confirm: Bool) -> Bool {
        guard let w = window else { return false }
        canvas.endEditing()
        let marks = canvas.coverMarks(redact: true)
        if marks.isEmpty {
            let a = NSAlert()
            a.messageText = "Keine Schwärzungen markiert"
            a.informativeText = "Mit dem Werkzeug „Schwärzen“ Rechtecke über die Stellen ziehen oder Werkzeuge › Suchen und schwärzen … benutzen. Danach hier anwenden."
            a.runModal()
            return false
        }
        if confirm {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = marks.count == 1 ? "Eine Schwärzung anwenden?" : "\(marks.count) Schwärzungen anwenden?"
            a.informativeText = "Der Inhalt darunter wird endgültig aus der Datei entfernt: Text zeichenweise, Bilder pixelweise, Anmerkungen im Bereich. Die Datei wird ohne Altstände neu geschrieben. Widerrufen geht, solange das Dokument geöffnet ist."
            let meta = NSButton(checkboxWithTitle: "Metadaten entfernen (Titel, Autor, Programm, Zeiten, XMP)", target: nil, action: nil)
            meta.state = (prefs.object(forKey: "schwaerzenMetadaten") as? Bool ?? true) ? .on : .off
            meta.frame = NSRect(x: 0, y: 0, width: 420, height: 20)
            a.accessoryView = meta
            a.addButton(withTitle: "Anwenden")
            a.addButton(withTitle: "Abbrechen")
            guard a.runModal() == .alertFirstButtonReturn else { return false }
            prefs.set(meta.state == .on, forKey: "schwaerzenMetadaten")
        }
        let t0 = Date()
        guard let rep = canvas.applyRedaction(marks, paint: true, removeAnnots: true, action: "Schwärzungen anwenden") else {
            let a = NSAlert()
            a.alertStyle = .critical
            a.messageText = "Schwärzen nicht möglich"
            a.informativeText = "Diese Datei lässt sich nicht direkt bearbeiten (verschlüsselt oder ungewöhnlich aufgebaut). Sicher ist der Export als Bild-PDF (Ablage › Exportieren)."
            a.runModal()
            return false
        }
        let a = NSAlert()
        a.alertStyle = rep.leaks.isEmpty ? .informational : .critical
        a.messageText = rep.leaks.isEmpty ? (marks.count == 1 ? "Schwärzung angewendet" : "\(marks.count) Schwärzungen angewendet") : "Text noch auffindbar"
        var lines = ["Entfernt: \(rep.summary)."]
        if rep.leaks.isEmpty { lines.append("Prüfung sauber – kein Text mehr auffindbar, Datei ohne Altstände.") }
        else { lines.append("⚠️ " + rep.leaks.joined(separator: "; ") + " – bitte als Bild-PDF exportieren.") }
        let important = rep.notes.filter { !$0.hasPrefix("Metadaten entfernt") }
        if !important.isEmpty { lines.append(important.joined(separator: "\n")) }
        if rep.notes.contains(where: { $0.hasPrefix("Metadaten entfernt") }) { lines.append("Metadaten entfernt.") }
        a.informativeText = lines.joined(separator: "\n")
        Log.w("Schwärzen: \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        a.beginSheetModal(for: w)
        return rep.leaks.isEmpty
    }

    // MARK: Texterkennung

    @objc func recognizeText(_ s: Any?) { Dialogs.ocr(window: window!, controller: self, auto: false) }

    /// OCR auf Seiten ausführen (mit Fortschritt), Ergebnis widerrufbar einsetzen
    func runOCR(pages: [Int], completion: ((OCRReport?) -> Void)? = nil) {
        guard let d = wdoc, let w = window else { return }
        canvas.endEditing()
        d.touch()
        guard let fresh = d.currentData() else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "Text wird erkannt …")
        label.frame = NSRect(x: 20, y: 52, width: 320, height: 20)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 24, width: 320, height: 18))
        bar.minValue = 0; bar.maxValue = Double(pages.count); bar.isIndeterminate = false
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(bar)
        w.beginSheet(panel)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = OCR.apply(to: fresh, pages: pages) { k, n in
                DispatchQueue.main.async { bar.doubleValue = Double(k); label.stringValue = "Seite \(min(k + 1, n)) von \(n) …" }
            }
            DispatchQueue.main.async {
                w.endSheet(panel)
                guard let (out, rep) = result else {
                    let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Texterkennung nicht möglich"
                    a.informativeText = "Diese Datei lässt sich nicht direkt bearbeiten (verschlüsselt oder ungewöhnlich aufgebaut)."
                    a.beginSheetModal(for: w); completion?(nil); return
                }
                if !rep.pages.isEmpty { d.replaceData(out, old: fresh, action: "Text erkennen") }
                let a = NSAlert()
                a.messageText = rep.pages.isEmpty ? "Kein Text erkannt" : "Text erkannt"
                a.informativeText = rep.summary + "." + (rep.notes.isEmpty ? "" : "\n" + rep.notes.joined(separator: "\n")) + (rep.pages.isEmpty ? "" : "\nJetzt durchsuchbar, kopierbar, schwärzbar.")
                a.beginSheetModal(for: w)
                completion?(rep)
            }
        }
    }

    @objc func searchAndRedact(_ s: Any?) {
        guard let w = window else { return }
        Dialogs.searchAndRedact(window: w, controller: self)
    }

    // MARK: Teilen

    @objc func shareClicked(_ b: NSButton) {
        guard let d = wdoc, let w = window else { return }
        canvas.endEditing()
        var items: [Any]
        switch SendCheck.run(doc: d, window: w, verb: "Teilen") {
        case .cancel: return
        case .rasterize:
            let u = shareURL.deletingPathExtension().appendingPathExtension("pdf")
            guard let doc = PDFDocument(data: PDFTools.rasterized(d.pdf, dpi: CGFloat(prefs.integer(forKey: "exportDpi") == 0 ? 300 : prefs.integer(forKey: "exportDpi")))) else { return }
            doc.write(to: u)
            items = [u]
        case .proceed:
            if let u = d.fileURL, !d.isDocumentEdited { items = [u] }
            else { if let data = try? d.data(ofType: "com.adobe.pdf") { try? data.write(to: shareURL) }; items = [shareURL] }
        }
        let p = NSSharingServicePicker(items: items)
        sharePicker = p
        p.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    private var shareURL: URL {
        let name = ((wdoc?.displayName ?? "Dokument") as NSString).deletingPathExtension + ".pdf"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PDF-Werkstatt-Teilen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Wird von AppKit laufend zur Prüfung aufgerufen – darf nichts verändern.
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        guard let d = wdoc else { return [] }
        if let u = d.fileURL, !d.isDocumentEdited { return [u] }
        return [shareURL]
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                              proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        if let d = wdoc, d.isDocumentEdited || d.fileURL == nil, let data = try? d.data(ofType: "com.adobe.pdf") {
            try? data.write(to: shareURL)
        }
        return proposed
    }

    // MARK: Seitenleiste

    private func sidebarModeMenu() -> NSMenu {
        let m = NSMenu()
        let titles: [(String, SidebarMode)] = [("Nur Inhalt", .none), ("Miniaturen", .thumbnails), ("Inhaltsverzeichnis", .outline),
                                               ("Hervorhebungen und Notizen", .annotations), ("Lesezeichen", .bookmarks), ("Kontaktbogen", .contactSheet)]
        for (t, mode) in titles {
            let i = NSMenuItem(title: t, action: #selector(sidebarModePicked(_:)), keyEquivalent: "")
            i.tag = mode.rawValue
            i.target = self
            m.addItem(i)
        }
        return m
    }

    @objc func sidebarModePicked(_ i: NSMenuItem) {
        setSidebarMode(SidebarMode(rawValue: i.tag) ?? .thumbnails)
    }

    func setSidebarMode(_ m: SidebarMode) {
        sidebarMode = m
        contactSheet.isHidden = m != .contactSheet
        canvas.isHidden = m == .contactSheet
        if m == .contactSheet { contactSheet.reload(canvas.document) }
        switch m {
        case .none, .contactSheet:
            sideItem.animator().isCollapsed = true
        default:
            sidebar.mode = m
            sideItem.animator().isCollapsed = false
        }
    }

    @objc func toggleSidebarButton(_ s: Any?) {
        if sideItem.isCollapsed { setSidebarMode(sidebar.mode == .none ? .thumbnails : sidebar.mode) } else { setSidebarMode(.none) }
    }

    @objc func toggleInspector(_ s: Any?) { inspItem.animator().isCollapsed.toggle() }

    // MARK: Hilfslinien

    func applyGuideSettings() {
        let st = GuideSettings.shared
        rulerTop.isHidden = !st.showRulers
        rulerLeft.isHidden = !st.showRulers
        rulerTop.needsDisplay = true; rulerLeft.needsDisplay = true
        canvas.guideSettingsChanged()
    }
    @objc func guideSettings(_ s: Any?) {
        guard let w = window else { return }
        GuideDialog.show(window: w) { [weak self] in self?.applyGuideSettings() }
    }
    @objc func toggleRulers(_ s: Any?) { GuideSettings.shared.showRulers.toggle(); applyGuideSettings() }
    @objc func toggleGrid(_ s: Any?) { GuideSettings.shared.showGrid.toggle(); applyGuideSettings() }
    @objc func clearGuidesPage(_ s: Any?) { canvas.clearCustomGuides(pageOnly: true) }
    @objc func clearGuidesAll(_ s: Any?) { canvas.clearCustomGuides(pageOnly: false) }

    // MARK: Hervorheben

    private func highlightMenu() -> NSMenu {
        let m = NSMenu()
        for (i, (name, c)) in HighlightStyle.colors.enumerated() {
            let it = NSMenuItem(title: name, action: #selector(highlightPicked(_:)), keyEquivalent: "")
            it.image = swatchImage(c, filled: true)
            it.tag = i
            it.target = self
            m.addItem(it)
        }
        m.addItem(.separator())
        let u = NSMenuItem(title: "Unterstreichen", action: #selector(highlightPicked(_:)), keyEquivalent: "")
        u.tag = 100; u.target = self; u.image = NSImage(systemSymbolName: "underline", accessibilityDescription: nil)
        let s = NSMenuItem(title: "Durchstreichen", action: #selector(highlightPicked(_:)), keyEquivalent: "")
        s.tag = 101; s.target = self; s.image = NSImage(systemSymbolName: "strikethrough", accessibilityDescription: nil)
        m.addItem(u); m.addItem(s)
        return m
    }

    @objc func highlightPicked(_ i: NSMenuItem) {
        var h: HighlightStyle
        if i.tag < HighlightStyle.colors.count {
            h = HighlightStyle(type: .highlight, color: HighlightStyle.colors[i.tag].1)
            canvas.setHighlightColor(h.color)
        } else {
            h = HighlightStyle(type: i.tag == 100 ? .underline : .strikeOut, color: NSColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        }
        canvas.lastHighlight = h
        canvas.tool = .textSelect
        canvas.highlight = h
    }

    @objc func toggleHighlight(_ s: Any?) {
        canvas.tool = .textSelect
        canvas.highlight = canvas.highlight == nil ? canvas.lastHighlight : nil
    }

    // MARK: Aktionen

    @objc func zoomGroup(_ g: NSToolbarItemGroup) { g.selectedIndex == 0 ? canvas.zoomOut(nil) : canvas.zoomIn(nil) }
    @objc func zoomIn(_ s: Any?) { canvas.zoomIn(s) }
    @objc func zoomOut(_ s: Any?) { canvas.zoomOut(s) }
    @objc func zoomToFit(_ s: Any?) { canvas.autoScales = true }
    @objc func actualSize(_ s: Any?) { canvas.autoScales = false; canvas.scaleFactor = 1 }

    @objc func setDisplayMode(_ s: NSMenuItem) {
        canvas.displayMode = PDFDisplayMode(rawValue: s.tag) ?? .singlePageContinuous
    }

    @objc func selectTool(_ s: NSMenuItem) {
        guard let t = Tool(rawValue: s.tag) else { return }
        canvas.tool = t
        window?.makeFirstResponder(canvas)
    }

    @objc func insertShapeMenu(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let k = ObjKind(rawValue: raw) else { return }
        canvas.insertShape(k)
    }
    @objc func insertTextBox(_ s: Any?) { canvas.insertText() }
    @objc func insertNote(_ s: Any?) { canvas.insertText(note: true) }
    @objc func cropToSelection(_ s: Any?) { canvas.cropToSelection(s) }
    @objc func removeCrop(_ s: Any?) { canvas.removeCrop(sidebar.selectedPages) }

    @objc func rotateLeft(_ s: Any?) {
        let right = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        wdoc?.rotate(sidebar.selectedPages, by: right ? 90 : -90)
    }
    @objc func rotateRight(_ s: Any?) { wdoc?.rotate(sidebar.selectedPages, by: 90) }
    @objc func deletePages(_ s: Any?) { sidebar.deleteSelected(s) }
    @objc func duplicatePages(_ s: Any?) { sidebar.duplicatePages(s) }
    @objc func insertBlankPage(_ s: Any?) { sidebar.insertBlankAfter(s) }
    @objc func insertPagesFromFile(_ s: Any?) { sidebar.insertFromFile(s) }
    @objc func extractPages(_ s: Any?) { sidebar.extractPages(s) }
    @objc func nextPage(_ s: Any?) { canvas.goToNextPage(s) }
    @objc func previousPage(_ s: Any?) { canvas.goToPreviousPage(s) }
    @objc func firstPage(_ s: Any?) { canvas.goToFirstPage(s) }
    @objc func lastPage(_ s: Any?) { canvas.goToLastPage(s) }
    @objc func goBackInHistory(_ s: Any?) { if canvas.canGoBack { canvas.goBack(s) } }
    @objc func goForwardInHistory(_ s: Any?) { if canvas.canGoForward { canvas.goForward(s) } }

    @objc func goToPageDialog(_ s: Any?) {
        guard let w = window, let d = canvas.document else { return }
        let a = NSAlert()
        a.messageText = "Gehe zu Seite"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        f.placeholderString = "1 – \(d.pageCount)"
        a.accessoryView = f
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Abbrechen")
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let n = Int(f.stringValue), n >= 1, n <= d.pageCount, let p = d.page(at: n - 1) else { return }
            self?.canvas.go(to: p)
        }
    }

    @objc func showInfo(_ s: Any?) {
        guard let d = wdoc else { return }
        if infoPanel == nil { infoPanel = InfoPanel(doc: d) }
        infoPanel?.refresh()
        infoPanel?.makeKeyAndOrderFront(nil)
    }

    @objc func startSlideshow(_ s: Any?) {
        guard let d = canvas.document else { return }
        let snap = PDFTools.snapshot(d)
        let idx = canvas.currentPage.map { d.index(for: $0) } ?? 0
        Slideshow.start(snap, at: snap.page(at: idx))
    }

    @objc func addBookmark(_ s: Any?) {
        guard let p = canvas.currentPage else { return }
        sidebar.addBookmark(p)
        setSidebarMode(.bookmarks)
    }

    @objc func pageNumbers(_ s: Any?) {
        guard let w = window else { return }
        canvas.endEditing()
        Dialogs.pageNumbers(window: w, canvas: canvas)
    }

    @objc func insertImage(_ s: Any?) {
        guard let w = window else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let self else { return }
            for u in p.urls { if let d = try? Data(contentsOf: u) { self.canvas.insertImage(d, at: nil) } }
        }
    }

    // MARK: Unterschrift

    func signatureMenu() -> NSMenu {
        let m = NSMenu()
        let sigs = Dialogs.signatures
        if sigs.isEmpty {
            let i = NSMenuItem(title: "Noch keine Unterschrift gespeichert", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        for u in sigs {
            let i = NSMenuItem(title: "", action: #selector(insertSignatureFile(_:)), keyEquivalent: "")
            if let img = NSImage(contentsOf: u) {
                let h: CGFloat = 36
                img.size = NSSize(width: min(200, h * img.size.width / max(img.size.height, 1)), height: h)
                i.image = img
            }
            i.representedObject = u
            i.target = self
            m.addItem(i)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Unterschrift mit Trackpad erstellen …", action: #selector(newSignature(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Unterschrift aus Bild erstellen …", action: #selector(signatureFromImage(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Unterschrift mit Kamera erstellen …", action: #selector(signatureFromCamera(_:)), keyEquivalent: "").target = self
        if !sigs.isEmpty {
            let del = NSMenuItem(title: "Unterschrift löschen", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (k, u) in sigs.enumerated() {
                let i = NSMenuItem(title: "Unterschrift \(k + 1)", action: #selector(deleteSignature(_:)), keyEquivalent: "")
                i.representedObject = u
                i.target = self
                if let img = NSImage(contentsOf: u) {
                    img.size = NSSize(width: min(120, 24 * img.size.width / max(img.size.height, 1)), height: 24)
                    i.image = img
                }
                sub.addItem(i)
            }
            del.submenu = sub
            m.addItem(del)
        }
        return m
    }

    private func placeSignature(_ d: Data) { canvas.insertImage(d, at: nil, width: 150, action: "Unterschrift") }

    @objc func insertSignatureFile(_ i: NSMenuItem) {
        if let u = i.representedObject as? URL, let d = try? Data(contentsOf: u) { placeSignature(d) }
    }
    @objc func deleteSignature(_ i: NSMenuItem) {
        if let u = i.representedObject as? URL { try? FileManager.default.removeItem(at: u) }
    }
    @objc func insertSavedSignature(_ s: Any?) {
        if let u = Dialogs.signatures.first, let d = try? Data(contentsOf: u) { placeSignature(d) } else { newSignature(s) }
    }
    @objc func newSignature(_ s: Any?) {
        guard let w = window else { return }
        Dialogs.drawSignature(window: w) { [weak self] d in self?.placeSignature(d) }
    }
    @objc func signatureFromCamera(_ s: Any?) {
        guard let w = window else { return }
        Dialogs.signatureFromCamera(window: w) { [weak self] d in self?.placeSignature(d) }
    }
    @objc func toggleLoupe(_ s: Any?) { canvas.loupe.toggle() }
    @objc func editComment(_ s: Any?) { canvas.editComment(s) }
    @objc func signatureFromImage(_ s: Any?) {
        guard let w = window else { return }
        Dialogs.signatureFromImage(window: w) { [weak self] d in self?.placeSignature(d) }
    }

    // MARK: Export, Suche

    @objc func exportDocument(_ s: Any?) {
        guard let w = window, let d = wdoc else { return }
        Dialogs.export(window: w, doc: d)
    }

    @objc func performFindPanelAction(_ s: Any?) {
        guard let it = searchItem else { return }
        it.beginSearchInteraction()
        window?.makeFirstResponder(it.searchField)
    }

    @objc func findNext(_ s: Any?) { canvas.search(searchItem?.searchField.stringValue ?? "") }
    @objc func findPrevious(_ s: Any?) { canvas.search(searchItem?.searchField.stringValue ?? "", backwards: true) }

    @objc func searchEntered(_ f: NSSearchField) {
        let back = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        canvas.search(f.stringValue, backwards: back)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            (control as? NSSearchField)?.stringValue = ""
            canvas.search("")
            window?.makeFirstResponder(canvas)
            return true
        }
        return false
    }

    /// Cmd-D: Objekt duplizieren, sonst Lesezeichen (wie in der Vorschau)
    @objc func duplicateObject(_ s: Any?) {
        if canvas.selected is WObject { canvas.duplicateObject(s) } else { addBookmark(s) }
    }
}
