import AppKit
import PDFKit

private let mmPerPt: CGFloat = 25.4 / 72

final class InspectorController: NSViewController, NSTextFieldDelegate {
    weak var canvas: Canvas?
    private var obj: PDFAnnotation?
    private var updating = false

    private let header = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let xF = InspectorController.numField(), yF = InspectorController.numField()
    private let wF = InspectorController.numField(), hF = InspectorController.numField()
    private let familyPop = NSPopUpButton(), stylePop = NSPopUpButton()
    private let sizeF = InspectorController.numField(), sizeStep = NSStepper()
    private let textColor = NSColorWell(style: .default)
    private let alignSeg = NSSegmentedControl()
    private let fillCheck = NSButton(checkboxWithTitle: "Füllung", target: nil, action: nil)
    private let fillColor = NSColorWell(style: .default)
    private let strokeCheck = NSButton(checkboxWithTitle: "Kontur", target: nil, action: nil)
    private let strokeColor = NSColorWell(style: .default)
    private let widthF = InspectorController.numField()
    private let formatF = NSTextField()
    private let startF = InspectorController.numField()
    private let nativeColor = NSColorWell(style: .default)

    private var geoBox: NSView!, textBox: NSView!, shapeBox: NSView!, numBox: NSView!, arrangeBox: NSView!, nativeBox: NSView!
    private var fillRow: NSView!, strokeRow: NSView!, widthRow: NSView!
    private var families: [String] = []
    private var members: [[Any]] = []

    private static func numField() -> NSTextField {
        let f = NSTextField()
        f.alignment = .right
        f.controlSize = .small
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.widthAnchor.constraint(equalToConstant: 58).isActive = true
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 1
        nf.minimumFractionDigits = 0
        f.formatter = nf
        return f
    }

    override func loadView() {
        let root = NSView()
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        header.font = .boldSystemFont(ofSize: 13)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        // Position & Größe
        for f in [xF, yF, wF, hF] { f.target = self; f.action = #selector(geometryChanged(_:)) }
        geoBox = section("Position und Größe (mm)", rows: [
            row("X", xF, "Y", yF),
            row("Breite", wF, "Höhe", hF),
        ])

        // Text
        families = NSFontManager.shared.availableFontFamilies.sorted()
        familyPop.addItems(withTitles: families)
        familyPop.controlSize = .small
        familyPop.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        familyPop.target = self; familyPop.action = #selector(familyChanged(_:))
        stylePop.controlSize = .small
        stylePop.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stylePop.target = self; stylePop.action = #selector(styleChanged(_:))
        sizeF.target = self; sizeF.action = #selector(sizeChanged(_:))
        sizeStep.minValue = 4; sizeStep.maxValue = 400; sizeStep.increment = 1; sizeStep.valueWraps = false
        sizeStep.controlSize = .small
        sizeStep.target = self; sizeStep.action = #selector(stepped(_:))
        textColor.target = self; textColor.action = #selector(textColorChanged(_:))
        alignSeg.segmentCount = 3
        for (i, s) in ["text.alignleft", "text.aligncenter", "text.alignright"].enumerated() {
            alignSeg.setImage(NSImage(systemSymbolName: s, accessibilityDescription: nil), forSegment: i)
            alignSeg.setWidth(30, forSegment: i)
        }
        alignSeg.controlSize = .small
        alignSeg.target = self; alignSeg.action = #selector(alignChanged(_:))
        textBox = section("Schrift", rows: [
            full(familyPop),
            full(stylePop),
            hstack([label("Größe"), sizeF, sizeStep, NSView(), textColor]),
            hstack([label("Ausrichtung"), NSView(), alignSeg]),
        ])

        // Form
        fillCheck.target = self; fillCheck.action = #selector(fillToggled(_:))
        fillColor.target = self; fillColor.action = #selector(fillColorChanged(_:))
        strokeCheck.target = self; strokeCheck.action = #selector(strokeToggled(_:))
        strokeColor.target = self; strokeColor.action = #selector(strokeColorChanged(_:))
        widthF.target = self; widthF.action = #selector(widthChanged(_:))
        for c in [fillCheck, strokeCheck] { c.controlSize = .small; c.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        fillRow = hstack([fillCheck, NSView(), fillColor])
        strokeRow = hstack([strokeCheck, NSView(), strokeColor])
        widthRow = hstack([label("Linienstärke (pt)"), NSView(), widthF])
        shapeBox = section("Farbe und Linie", rows: [fillRow, strokeRow, widthRow])

        // Seitenzahlen
        formatF.controlSize = .small
        formatF.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        formatF.target = self; formatF.action = #selector(formatChanged(_:))
        startF.target = self; startF.action = #selector(formatChanged(_:))
        let numHint = NSTextField(wrappingLabelWithString: "{n} = Seitenzahl, {N} = Gesamtzahl. Gilt für alle Seitenzahlen.")
        numHint.font = .systemFont(ofSize: 10); numHint.textColor = .secondaryLabelColor
        numBox = section("Seitenzahlen", rows: [full(formatF), hstack([label("Beginnt mit"), NSView(), startF]), numHint])

        // Fremde Anmerkungen (aus anderen Programmen)
        nativeColor.target = self; nativeColor.action = #selector(nativeColorChanged(_:))
        nativeBox = section("Farbe", rows: [hstack([label("Farbe"), NSView(), nativeColor])])

        // Anordnen
        let front = button("Nach vorne", #selector(front(_:)))
        let back = button("Nach hinten", #selector(back(_:)))
        let del = button("Löschen", #selector(del(_:)))
        arrangeBox = section("Anordnen", rows: [hstack([front, back]), hstack([del])])

        let stack = NSStackView(views: [header, hint, geoBox, textBox, shapeBox, numBox, nativeBox, arrangeBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for v in stack.arrangedSubviews where v !== header {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        show(nil)
    }

    // MARK: Bausteine

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func hstack(_ v: [NSView]) -> NSStackView {
        let s = NSStackView(views: v)
        s.orientation = .horizontal
        s.spacing = 6
        s.alignment = .centerY
        for x in v where type(of: x) == NSView.self { x.setContentHuggingPriority(.init(1), for: .horizontal) }
        return s
    }

    private func row(_ a: String, _ fa: NSView, _ b: String, _ fb: NSView) -> NSView {
        hstack([label(a), NSView(), fa, label(b), fb])
    }

    private func full(_ v: NSView) -> NSView { v }

    private func button(_ t: String, _ s: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: s)
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return b
    }

    private func section(_ title: String, rows: [NSView]) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 11, weight: .semibold)
        let line = NSBox(); line.boxType = .separator
        let s = NSStackView(views: [line, t] + rows)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 6
        for r in [line] + rows { r.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        return s
    }

    // MARK: Anzeigen

    /// Modell, das gerade bearbeitet wird: ausgewähltes Objekt oder Standard für neue Objekte.
    private var current: ObjModel { (obj as? WObject)?.model ?? Defaults.model }

    func show(_ a: PDFAnnotation?) {
        guard isViewLoaded else { return }
        obj = a
        updating = true
        defer { updating = false }
        let w = a as? WObject
        let kind = w?.model.kind
        if let w { header.stringValue = w.kindName }
        else if let a { header.stringValue = "Anmerkung (\(a.type ?? "?"))" }
        else { header.stringValue = "Kein Objekt ausgewählt" }
        hint.stringValue = a == nil ? "Ein Objekt anklicken, um Position und Größe genau einzustellen. Farben, Linien und Schrift gibt es oben in der Markierungsleiste." : ""
        hint.isHidden = a != nil

        geoBox.isHidden = a == nil
        // Farben, Linien und Schrift stellt man wie in der Vorschau in der Markierungsleiste ein
        textBox.isHidden = true
        numBox.isHidden = kind != .pageNumber
        nativeBox.isHidden = true
        arrangeBox.isHidden = a == nil
        shapeBox.isHidden = true
        fillRow.isHidden = [.line, .arrow, .ink].contains(kind)
        strokeRow.isHidden = kind == .cover
        widthRow.isHidden = kind == .cover

        if let a, let p = a.page {
            let crop = p.bounds(for: .cropBox)
            xF.doubleValue = Double((a.bounds.minX - crop.minX) * mmPerPt)
            yF.doubleValue = Double((crop.maxY - a.bounds.maxY) * mmPerPt)
            wF.doubleValue = Double(a.bounds.width * mmPerPt)
            hF.doubleValue = Double(a.bounds.height * mmPerPt)
            hF.isEnabled = kind != .text
            wF.isEnabled = kind != .pageNumber
            nativeColor.color = a.color
        }

        let m = current
        let f = NSFont(name: m.fontName, size: m.fontSize) ?? NSFont(name: "ArialMT", size: 12)!
        let fam = f.familyName ?? "Arial"
        if let i = families.firstIndex(of: fam) { familyPop.selectItem(at: i) }
        fillStyles(family: fam, select: f.fontName)
        sizeF.doubleValue = Double(m.fontSize)
        sizeStep.doubleValue = Double(m.fontSize)
        textColor.color = m.textColor.color
        alignSeg.selectedSegment = m.align
        fillCheck.state = m.fill != nil ? .on : .off
        fillColor.color = m.fill?.color ?? .white
        strokeCheck.state = m.stroke != nil ? .on : .off
        strokeColor.color = m.stroke?.color ?? .black
        widthF.doubleValue = Double(m.lineWidth)
        fillCheck.title = kind == .text ? "Hintergrund" : kind == .cover ? "Farbe" : "Füllung"
        strokeCheck.title = kind == .text ? "Rahmen" : "Kontur"
        if kind == .cover { fillCheck.state = .on }
        formatF.stringValue = m.format
        startF.integerValue = m.startNumber
    }

    private func fillStyles(family: String, select name: String) {
        members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        stylePop.removeAllItems()
        stylePop.addItems(withTitles: members.map { ($0.count > 1 ? $0[1] as? String : nil) ?? "Normal" })
        if let i = members.firstIndex(where: { ($0.first as? String) == name }) { stylePop.selectItem(at: i) }
    }

    // MARK: Ändern

    private func change(_ action: String, coalesce: String? = nil, _ f: (inout ObjModel) -> Void) {
        guard !updating else { return }
        if let w = obj as? WObject {
            if w.model.kind == .pageNumber {
                canvas?.applyToAllPageNumbers(f)
            } else {
                var m = w.model; f(&m)
                canvas?.setModel(w, m, bounds: w.model.kind == .text ? nil : w.bounds, action: action, coalesce: coalesce)
            }
            // Stil als Standard für die nächsten Objekte merken
            var d = Defaults.model; f(&d)
            Defaults.model.fontName = d.fontName; Defaults.model.fontSize = d.fontSize
            Defaults.model.textColor = d.textColor; Defaults.model.align = d.align
            if w.model.kind != .text && w.model.kind != .cover && w.model.kind != .pageNumber {
                Defaults.model.stroke = d.stroke; Defaults.model.lineWidth = d.lineWidth
                if w.model.kind == .rect || w.model.kind == .ellipse { Defaults.model.fill = d.fill }
            }
        } else if obj == nil {
            f(&Defaults.model)
        }
        Defaults.save()
        show(obj)
    }

    @objc private func geometryChanged(_ s: Any?) {
        guard !updating, let a = obj, let p = a.page else { return }
        let crop = p.bounds(for: .cropBox)
        let x = crop.minX + CGFloat(xF.doubleValue) / mmPerPt
        let top = crop.maxY - CGFloat(yF.doubleValue) / mmPerPt
        let w = max(1, CGFloat(wF.doubleValue) / mmPerPt)
        let h = max(1, CGFloat(hF.doubleValue) / mmPerPt)
        let r = CGRect(x: x, y: top - h, width: w, height: h)
        if let o = a as? WObject {
            var m = o.model
            if m.kind == .text {
                m.autoWidth = false
                let tmp = WObject(model: m, bounds: r)
                tmp.fitBounds()
                canvas?.setModel(o, m, bounds: tmp.bounds, action: "Position")
            } else {
                canvas?.setModel(o, m, bounds: r, action: "Position")
            }
        } else {
            canvas?.setBounds(a, r, action: "Position")
        }
        show(obj)
    }

    @objc private func familyChanged(_ s: Any?) {
        let fam = families[familyPop.indexOfSelectedItem]
        let ms = NSFontManager.shared.availableMembers(ofFontFamily: fam) ?? []
        let regular = ms.first { m in ["Regular", "Normal", "Roman", "Book", "Medium"].contains((m.count > 1 ? m[1] as? String : nil) ?? "") } ?? ms.first
        guard let name = regular?.first as? String else { return }
        change("Schrift") { $0.fontName = name }
    }

    @objc private func styleChanged(_ s: Any?) {
        let i = stylePop.indexOfSelectedItem
        guard i >= 0, i < members.count, let name = members[i].first as? String else { return }
        change("Schriftschnitt") { $0.fontName = name }
    }

    @objc private func sizeChanged(_ s: Any?) {
        let v = CGFloat(max(2, min(400, sizeF.doubleValue)))
        change("Schriftgröße") { $0.fontSize = v }
    }

    @objc private func stepped(_ s: Any?) {
        let v = CGFloat(sizeStep.doubleValue)
        change("Schriftgröße", coalesce: "size") { $0.fontSize = v }
    }

    @objc private func textColorChanged(_ s: Any?) {
        let c = RGBA(textColor.color)
        change("Textfarbe", coalesce: "textColor") { $0.textColor = c }
    }

    @objc private func alignChanged(_ s: Any?) {
        let a = alignSeg.selectedSegment
        change("Ausrichtung") { $0.align = a }
    }

    @objc private func fillToggled(_ s: Any?) {
        let on = fillCheck.state == .on
        let c = RGBA(fillColor.color)
        change("Füllung") { $0.fill = on ? c : ($0.kind == .cover ? $0.fill : nil) }
    }

    @objc private func fillColorChanged(_ s: Any?) {
        let c = RGBA(fillColor.color)
        change("Füllfarbe", coalesce: "fill") { $0.fill = c }
    }

    @objc private func strokeToggled(_ s: Any?) {
        let on = strokeCheck.state == .on
        let c = RGBA(strokeColor.color)
        change("Kontur") { $0.stroke = on ? c : nil }
    }

    @objc private func strokeColorChanged(_ s: Any?) {
        let c = RGBA(strokeColor.color)
        change("Linienfarbe", coalesce: "stroke") { $0.stroke = c }
    }

    @objc private func widthChanged(_ s: Any?) {
        let v = CGFloat(max(0, min(100, widthF.doubleValue)))
        change("Linienstärke") { $0.lineWidth = v }
    }

    @objc private func formatChanged(_ s: Any?) {
        let f = formatF.stringValue.isEmpty ? "{n}" : formatF.stringValue
        let st = startF.integerValue
        change("Seitenzahlen") { $0.format = f; $0.startNumber = st }
    }

    @objc private func front(_ s: Any?) { canvas?.bringToFront(s) }
    @objc private func back(_ s: Any?) { canvas?.sendToBack(s) }
    @objc private func del(_ s: Any?) { canvas?.delete(s) }

    @objc private func nativeColorChanged(_ s: Any?) {
        guard !updating, let a = obj, !(a is WObject) else { return }
        canvas?.setColor(a, nativeColor.color)
    }
}
