import AppKit
import PDFKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.trim()
        Log.w("--- Start \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "") ---")
        UndoStore.purge()
        RedactTest.runIfRequested()
        Updater.start()
        SelfTest.runIfRequested()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if ProcessInfo.processInfo.environment["PDFW_SELFTEST"] == nil, ProcessInfo.processInfo.environment["PDFW_UPDATE_TEST"] == nil { Recovery.offerRestore() }
            if NSDocumentController.shared.documents.isEmpty { NSDocumentController.shared.openDocument(nil) }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    @objc func showLog(_ s: Any?) { NSWorkspace.shared.open(Log.url) }
    @objc func checkUpdates(_ s: Any?) { Updater.check(manual: true) }
    @objc func toggleVerboseLog(_ s: NSMenuItem) {
        prefs.set(!prefs.bool(forKey: "protokollAusfuehrlich"), forKey: "protokollAusfuehrlich")
    }

    func validateMenuItem(_ m: NSMenuItem) -> Bool {
        if m.action == #selector(toggleVerboseLog(_:)) { m.state = prefs.bool(forKey: "protokollAusfuehrlich") ? .on : .off }
        return true
    }

    @objc func clearLog(_ s: Any?) { try? "".write(to: Log.url, atomically: true, encoding: .utf8) }

    @objc func mergePDFs(_ s: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .image]
        p.allowsMultipleSelection = true
        p.message = "Dateien in der gewünschten Reihenfolge auswählen (Reihenfolge lässt sich danach per Ziehen ändern)."
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let out = PDFDocument()
        for u in p.urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if let t = UTType(filenameExtension: u.pathExtension), t.conforms(to: .image) {
                if let img = NSImage(contentsOf: u), let pg = PDFPage(image: img) { out.insert(pg, at: out.pageCount) }
                continue
            }
            guard let d = PDFDocument(url: u) else { continue }
            if d.isLocked { guard let pw = Dialogs.askPassword(file: u.lastPathComponent), d.unlock(withPassword: pw) else { continue } }
            while d.pageCount > 0, let pg = d.page(at: 0) { d.removePage(at: 0); out.insert(pg, at: out.pageCount) }
        }
        guard out.pageCount > 0 else { NSSound.beep(); return }
        WDocument.openNew(with: out, name: "Zusammengefügt")
    }

    @objc func newFromClipboard(_ s: Any?) {
        let pb = NSPasteboard.general
        let out = PDFDocument()
        if let d = pb.data(forType: .pdf), let pdf = PDFDocument(data: d) {
            while pdf.pageCount > 0, let pg = pdf.page(at: 0) { pdf.removePage(at: 0); out.insert(pg, at: out.pageCount) }
        } else if let img = NSImage(pasteboard: pb), let pg = PDFPage(image: img) {
            out.insert(pg, at: 0)
        }
        guard out.pageCount > 0 else { NSSound.beep(); return }
        WDocument.openNew(with: out, name: "Aus Zwischenablage")
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return m
        }
        func add(_ m: NSMenu, _ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            m.addItem(i)
        }

        let app = sub("PDF-Werkstatt")
        add(app, "Über PDF-Werkstatt", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "PDF-Werkstatt ausblenden", #selector(NSApplication.hide(_:)), "h")
        add(app, "Andere ausblenden", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Alle einblenden", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "PDF-Werkstatt beenden", #selector(NSApplication.terminate(_:)), "q")

        let file = sub("Ablage")
        add(file, "Neu", #selector(NSDocumentController.newDocument(_:)), "n")
        add(file, "Neu aus Zwischenablage", #selector(newFromClipboard(_:)), "n", [.command, .option])
        add(file, "Öffnen …", #selector(NSDocumentController.openDocument(_:)), "o")
        let recentItem = NSMenuItem(title: "Benutzte Dokumente", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Benutzte Dokumente")
        recent.addItem(withTitle: "Einträge löschen", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recentItem.submenu = recent
        file.addItem(recentItem)
        add(file, "PDFs zusammenfügen …", #selector(mergePDFs(_:)), "o", [.command, .option])
        file.addItem(.separator())
        add(file, "Schließen", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Sichern", #selector(NSDocument.save(_:)), "s")
        add(file, "Sichern unter …", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        add(file, "Duplizieren", #selector(NSDocument.duplicate(_:)))
        add(file, "Zurück zur letzten Version", #selector(NSDocument.revertToSaved(_:)))
        add(file, "Exportieren …", #selector(MainWindowController.exportDocument(_:)))
        add(file, "Als PDF exportieren …", #selector(MainWindowController.exportDocument(_:)))
        file.addItem(.separator())
        add(file, "Drucken …", #selector(NSDocument.printDocument(_:)), "p")

        let edit = sub("Bearbeiten")
        add(edit, "Widerrufen", Selector(("undo:")), "z")
        add(edit, "Wiederholen", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Ausschneiden", #selector(NSText.cut(_:)), "x")
        add(edit, "Kopieren", #selector(NSText.copy(_:)), "c")
        add(edit, "Einsetzen", #selector(NSText.paste(_:)), "v")
        add(edit, "Duplizieren", #selector(MainWindowController.duplicateObject(_:)), "d")
        add(edit, "Löschen", #selector(NSText.delete(_:)))
        add(edit, "Alles auswählen", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let arr2 = NSMenuItem(title: "Anordnen", action: nil, keyEquivalent: "")
        let arrM2 = NSMenu()
        add(arrM2, "Ganz nach vorne", #selector(Canvas.bringToFront(_:)), "]", [.command, .option, .shift])
        add(arrM2, "Eine Ebene nach vorne", #selector(Canvas.bringForward(_:)), "]", [.command, .shift])
        add(arrM2, "Eine Ebene nach hinten", #selector(Canvas.sendBackward(_:)), "[", [.command, .shift])
        add(arrM2, "Ganz nach hinten", #selector(Canvas.sendToBack(_:)), "[", [.command, .option, .shift])
        arr2.submenu = arrM2
        edit.addItem(arr2)
        edit.addItem(.separator())
        add(edit, "Suchen …", #selector(MainWindowController.performFindPanelAction(_:)), "f")
        add(edit, "Weitersuchen", #selector(MainWindowController.findNext(_:)), "g")
        add(edit, "Rückwärts suchen", #selector(MainWindowController.findPrevious(_:)), "g", [.command, .shift])
        edit.addItem(.separator())
        let ins = NSMenuItem(title: "Einfügen", action: nil, keyEquivalent: "")
        let insM = NSMenu()
        add(insM, "Seite aus Datei …", #selector(MainWindowController.insertPagesFromFile(_:)), "i", [.command, .option])
        add(insM, "Leere Seite", #selector(MainWindowController.insertBlankPage(_:)), "n", [.command, .control, .option])
        ins.submenu = insM
        edit.addItem(ins)
        add(edit, "Seite löschen", #selector(MainWindowController.deletePages(_:)))
        add(edit, "Seite duplizieren", #selector(MainWindowController.duplicatePages(_:)))
        add(edit, "Seiten als eigenes PDF sichern …", #selector(MainWindowController.extractPages(_:)))

        let goMenu = sub("Gehe zu")
        add(goMenu, "Vorherige Seite", #selector(MainWindowController.previousPage(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option])
        add(goMenu, "Nächste Seite", #selector(MainWindowController.nextPage(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option])
        add(goMenu, "Erste Seite", #selector(MainWindowController.firstPage(_:)), String(UnicodeScalar(NSHomeFunctionKey)!), [])
        add(goMenu, "Letzte Seite", #selector(MainWindowController.lastPage(_:)), String(UnicodeScalar(NSEndFunctionKey)!), [])
        goMenu.addItem(.separator())
        add(goMenu, "Zurück", #selector(MainWindowController.goBackInHistory(_:)), "[")
        add(goMenu, "Vorwärts", #selector(MainWindowController.goForwardInHistory(_:)), "]")
        goMenu.addItem(.separator())
        add(goMenu, "Gehe zu Seite …", #selector(MainWindowController.goToPageDialog(_:)), "g", [.command, .option])

        let tools = sub("Werkzeuge")
        add(tools, "Textauswahl", #selector(MainWindowController.selectTool(_:)), "", tag: Tool.textSelect.rawValue)
        add(tools, "Rechteckige Auswahl", #selector(MainWindowController.selectTool(_:)), "", tag: Tool.rectSelect.rawValue)
        tools.addItem(.separator())
        add(tools, "Nach links drehen", #selector(MainWindowController.rotateLeft(_:)), "l")
        add(tools, "Nach rechts drehen", #selector(MainWindowController.rotateRight(_:)), "r", [.command, .option])
        add(tools, "Zuschneiden", #selector(MainWindowController.cropToSelection(_:)), "k")
        add(tools, "Zuschnitt aufheben", #selector(MainWindowController.removeCrop(_:)), "k", [.command, .shift])
        tools.addItem(.separator())
        let ann = NSMenuItem(title: "Anmerkungen", action: nil, keyEquivalent: "")
        let annM = NSMenu()
        add(annM, "Hervorheben", #selector(MainWindowController.toggleHighlight(_:)), "h", [.command, .control])
        annM.addItem(.separator())
        for (t, k) in [("Rechteck", ObjKind.rect), ("Oval", .ellipse), ("Linie", .line), ("Pfeil", .arrow), ("Abgerundetes Rechteck", .roundRect),
                       ("Sprechblase", .bubble), ("Stern", .star), ("Vieleck", .polygon)] {
            let i = NSMenuItem(title: t, action: #selector(MainWindowController.insertShapeMenu(_:)), keyEquivalent: "")
            i.representedObject = k.rawValue
            annM.addItem(i)
        }
        annM.addItem(.separator())
        add(annM, "Text", #selector(MainWindowController.insertTextBox(_:)), "t", [.command, .control])
        add(annM, "Notiz", #selector(MainWindowController.insertNote(_:)), "n", [.command, .control])
        add(annM, "Zeichnen", #selector(MainWindowController.selectTool(_:)), "", tag: Tool.draw.rawValue)
        add(annM, "Skizzieren", #selector(MainWindowController.selectTool(_:)), "", tag: Tool.sketch.rawValue)
        add(annM, "Kommentar …", #selector(MainWindowController.editComment(_:)))
        add(annM, "Schwärzen", #selector(MainWindowController.selectTool(_:)), "", tag: Tool.redact.rawValue)
        ann.submenu = annM
        tools.addItem(ann)
        add(tools, "Suchen und schwärzen …", #selector(MainWindowController.searchAndRedact(_:)), "f", [.command, .option])
        add(tools, "Schwärzungen anwenden …", #selector(MainWindowController.applyRedactions(_:)), "r", [.command, .shift])
        let sig = NSMenuItem(title: "Unterschreiben", action: nil, keyEquivalent: "")
        let sigM = NSMenu()
        add(sigM, "Gespeicherte Unterschrift einsetzen", #selector(MainWindowController.insertSavedSignature(_:)))
        add(sigM, "Unterschrift mit Trackpad erstellen …", #selector(MainWindowController.newSignature(_:)))
        add(sigM, "Unterschrift aus Bild erstellen …", #selector(MainWindowController.signatureFromImage(_:)))
        add(sigM, "Unterschrift mit Kamera erstellen …", #selector(MainWindowController.signatureFromCamera(_:)))
        sig.submenu = sigM
        tools.addItem(sig)
        tools.addItem(.separator())
        add(tools, "Informationen einblenden", #selector(MainWindowController.showInfo(_:)), "i")
        add(tools, "Lupe einblenden", #selector(MainWindowController.toggleLoupe(_:)), "´", [])
        add(tools, "Farben einblenden", #selector(NSApplication.orderFrontColorPanel(_:)), "c", [.command, .shift])
        tools.addItem(.separator())
        let ext = NSMenuItem(title: "Bearbeiten (Zusatzfunktionen)", action: nil, keyEquivalent: "")
        let extM = NSMenu()
        add(extM, "Vorhandenen Text bearbeiten", #selector(MainWindowController.selectTool(_:)), "", tag: Tool.editText.rawValue)
        add(extM, "Abdecken", #selector(MainWindowController.selectTool(_:)), "", tag: Tool.whiteout.rawValue)
        add(extM, "Bild einfügen …", #selector(MainWindowController.insertImage(_:)), "i", [.command, .shift])
        add(extM, "Seitenzahlen …", #selector(MainWindowController.pageNumbers(_:)), "n", [.command, .shift])
        extM.addItem(.separator())
        let arr = NSMenuItem(title: "Anordnen", action: nil, keyEquivalent: "")
        let arrM = NSMenu()
        add(arrM, "Ganz nach vorne", #selector(Canvas.bringToFront(_:)), "]", [.command, .option, .shift])
        add(arrM, "Eine Ebene nach vorne", #selector(Canvas.bringForward(_:)), "]", [.command, .shift])
        add(arrM, "Eine Ebene nach hinten", #selector(Canvas.sendBackward(_:)), "[", [.command, .shift])
        add(arrM, "Ganz nach hinten", #selector(Canvas.sendToBack(_:)), "[", [.command, .option, .shift])
        arr.submenu = arrM
        extM.addItem(arr)
        ext.submenu = extM
        tools.addItem(ext)

        let bm = sub("Lesezeichen")
        add(bm, "Lesezeichen hinzufügen", #selector(MainWindowController.addBookmark(_:)))
        add(bm, "Lesezeichen anzeigen", #selector(MainWindowController.sidebarModePicked(_:)), "5", [.command, .option], tag: SidebarMode.bookmarks.rawValue)

        let view = sub("Darstellung")
        for (t, m, k) in [("Nur Inhalt", SidebarMode.none, "1"), ("Miniaturen", .thumbnails, "2"), ("Inhaltsverzeichnis", .outline, "3"),
                          ("Hervorhebungen und Notizen", .annotations, "4"), ("Lesezeichen", .bookmarks, "5"), ("Kontaktbogen", .contactSheet, "6")] {
            add(view, t, #selector(MainWindowController.sidebarModePicked(_:)), k, [.command, .option], tag: m.rawValue)
        }
        add(view, "Position und Größe", #selector(MainWindowController.toggleInspector(_:)), "i", [.command, .option])
        view.addItem(.separator())
        add(view, "Hilfslinien …", #selector(MainWindowController.guideSettings(_:)))
        add(view, "Lineale", #selector(MainWindowController.toggleRulers(_:)), "r", [.command])
        add(view, "Raster", #selector(MainWindowController.toggleGrid(_:)), "'", [.command])
        add(view, "Hilfslinien dieser Seite löschen", #selector(MainWindowController.clearGuidesPage(_:)))
        add(view, "Alle Hilfslinien löschen", #selector(MainWindowController.clearGuidesAll(_:)))
        view.addItem(.separator())
        add(view, "Einzelseite", #selector(MainWindowController.setDisplayMode(_:)), "", tag: 0)
        add(view, "Fortlaufend", #selector(MainWindowController.setDisplayMode(_:)), "", tag: 1)
        add(view, "Zwei Seiten", #selector(MainWindowController.setDisplayMode(_:)), "", tag: 3)
        view.addItem(.separator())
        add(view, "Originalgröße", #selector(MainWindowController.actualSize(_:)), "0")
        add(view, "Größe anpassen", #selector(MainWindowController.zoomToFit(_:)), "9")
        add(view, "Vergrößern", #selector(MainWindowController.zoomIn(_:)), "+")
        add(view, "Verkleinern", #selector(MainWindowController.zoomOut(_:)), "-")
        view.addItem(.separator())
        add(view, "Diashow", #selector(MainWindowController.startSlideshow(_:)), "f", [.command, .shift])
        add(view, "Vollbild", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let help = sub("Hilfe")
        add(help, "Nach Updates suchen …", #selector(checkUpdates(_:)))
        help.addItem(.separator())
        add(help, "Protokoll anzeigen", #selector(showLog(_:)))
        add(help, "Protokoll leeren", #selector(clearLog(_:)))
        add(help, "Protokoll ausführlich", #selector(toggleVerboseLog(_:)))

        let win = sub("Fenster")
        add(win, "Im Dock ablegen", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(win, "Zoomen", #selector(NSWindow.performZoom(_:)))
        win.addItem(.separator())
        add(win, "Alle nach vorne bringen", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = win
        // Reihenfolge wie in der Vorschau
        if let v = main.items.first(where: { $0.title == "Darstellung" }) { main.removeItem(v); main.insertItem(v, at: 3) }
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
_ = NSDocumentController.shared
app.run()
