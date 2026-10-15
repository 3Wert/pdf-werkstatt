import AppKit
import PDFKit

// MARK: Bausteine

func barButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)!
    let b = NSButton(image: img, target: target, action: action)
    b.bezelStyle = .accessoryBarAction
    b.showsBorderOnlyWhileMouseInside = true
    b.toolTip = tip
    b.imagePosition = .imageOnly
    b.symbolConfiguration = .init(pointSize: 14, weight: .regular)
    b.widthAnchor.constraint(equalToConstant: 34).isActive = true
    b.heightAnchor.constraint(equalToConstant: 26).isActive = true
    return b
}

func separator() -> NSView {
    let v = NSBox(); v.boxType = .separator
    v.heightAnchor.constraint(equalToConstant: 18).isActive = true
    return v
}

/// Kleines Farbsymbol wie in der Vorschau: Rahmen = Umriss, Füllung = gefülltes Feld
func swatchImage(_ c: NSColor?, filled: Bool, size: CGFloat = 16) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        let box = r.insetBy(dx: 2, dy: 2)
        let p = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        if let c {
            if filled {
                c.setFill(); p.fill()
                NSColor.black.withAlphaComponent(0.25).setStroke(); p.lineWidth = 0.5; p.stroke()
            } else {
                let q = NSBezierPath(roundedRect: box.insetBy(dx: 1.25, dy: 1.25), xRadius: 2.5, yRadius: 2.5)
                q.lineWidth = 2.5; c.setStroke(); q.stroke()
            }
        } else {
            NSColor.white.setFill(); p.fill()
            NSColor.tertiaryLabelColor.setStroke(); p.lineWidth = 0.75; p.stroke()
            let x = NSBezierPath(); x.move(to: CGPoint(x: box.minX + 1, y: box.minY + 1)); x.line(to: CGPoint(x: box.maxX - 1, y: box.maxY - 1))
            NSColor.systemRed.setStroke(); x.lineWidth = 1.2; x.stroke()
        }
        return true
    }
}

// MARK: Farbauswahl

final class ColorPopover: NSViewController {
    var onPick: ((NSColor?) -> Void)?
    /// Aktuelle Farbe des Ziels – damit „Weitere Farben“ mit dem richtigen Wert startet
    var currentColor: NSColor?
    private let allowsNone: Bool
    private var panelProxy: ColorPanelProxy?

    static let palette: [[NSColor]] = {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
        return [
            [c(0, 0, 0), c(67, 67, 67), c(110, 110, 110), c(153, 153, 153), c(196, 196, 196), c(225, 225, 225), c(242, 242, 242), c(255, 255, 255)],
            [c(176, 18, 26), c(214, 95, 0), c(196, 152, 0), c(38, 130, 50), c(0, 128, 128), c(0, 84, 166), c(92, 47, 145), c(168, 33, 110)],
            [c(237, 28, 36), c(255, 149, 0), c(255, 214, 10), c(52, 199, 89), c(48, 176, 199), c(0, 122, 255), c(175, 82, 222), c(255, 45, 85)],
            [c(255, 160, 160), c(255, 204, 145), c(255, 240, 150), c(170, 235, 175), c(160, 225, 235), c(150, 200, 255), c(215, 180, 245), c(255, 175, 200)],
        ]
    }()

    init(allowsNone: Bool) { self.allowsNone = allowsNone; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        var rows: [NSView] = []
        for line in Self.palette {
            let h = NSStackView(views: line.map { col in
                let b = NSButton(image: swatchImage(col, filled: true, size: 22), target: self, action: #selector(picked(_:)))
                b.isBordered = false
                b.imagePosition = .imageOnly
                b.contentTintColor = nil
                b.identifier = NSUserInterfaceItemIdentifier(col.hexString)
                return b
            })
            h.spacing = 2
            rows.append(h)
        }
        var bottom: [NSView] = []
        if allowsNone {
            let none = NSButton(title: "Keine", image: swatchImage(nil, filled: true), target: self, action: #selector(pickedNone))
            none.bezelStyle = .accessoryBarAction
            none.imagePosition = .imageLeading
            bottom.append(none)
        }
        let more = NSButton(title: "Weitere Farben …", target: self, action: #selector(moreColors))
        more.bezelStyle = .accessoryBarAction
        bottom.append(NSView())
        bottom.append(more)
        let b = NSStackView(views: bottom)
        rows.append(b)
        let v = NSStackView(views: rows)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 3
        v.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        b.widthAnchor.constraint(equalTo: rows[0].widthAnchor).isActive = true
        view = v
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        ColorPanelProxy.detach()        // ein offenes Farbpanel darf nicht mehr an einem alten Ziel hängen
    }

    @objc private func picked(_ b: NSButton) {
        guard let hex = b.identifier?.rawValue else { return }
        ColorPanelProxy.detach()
        onPick?(NSColor(hex: hex))
        dismiss(nil)
    }
    @objc private func pickedNone() { ColorPanelProxy.detach(); onPick?(nil); dismiss(nil) }
    @objc private func moreColors() {
        let proxy = ColorPanelProxy(onPick: onPick)
        panelProxy = proxy
        ColorPanelProxy.current = proxy
        let p = NSColorPanel.shared
        p.showsAlpha = false
        if let c = currentColor { p.color = c }
        p.setTarget(proxy)
        p.setAction(#selector(ColorPanelProxy.changed(_:)))
        p.isContinuous = true
        p.orderFront(nil)
        dismiss(nil)
    }
}

final class ColorPanelProxy: NSObject {
    static var current: ColorPanelProxy?
    let onPick: ((NSColor?) -> Void)?
    init(onPick: ((NSColor?) -> Void)?) { self.onPick = onPick }
    @objc func changed(_ p: NSColorPanel) { if ColorPanelProxy.current === self { onPick?(p.color) } }
    /// Farbpanel vom bisherigen Ziel lösen
    static func detach() {
        current = nil
        let p = NSColorPanel.shared
        p.setTarget(nil)
        p.setAction(nil)
    }
}

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
    convenience init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// MARK: Formstil

final class LineStylePopover: NSViewController {
    weak var canvas: Canvas?
    init(canvas: Canvas) { self.canvas = canvas; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    static let widths: [CGFloat] = [0.5, 1, 1.5, 2, 3, 4, 6, 8, 12]

    override func loadView() {
        let m = canvas?.styleModel ?? Defaults.model
        var rows: [NSView] = []
        for w in Self.widths {
            let img = NSImage(size: NSSize(width: 120, height: 16), flipped: false) { r in
                let p = NSBezierPath(); p.move(to: CGPoint(x: 6, y: r.midY)); p.line(to: CGPoint(x: r.maxX - 6, y: r.midY))
                p.lineWidth = w; p.lineCapStyle = .round; NSColor.labelColor.setStroke(); p.stroke()
                return true
            }
            img.isTemplate = false
            let b = NSButton(title: w < 1 ? "0,5 pt" : "\(Int(w)) pt", image: img, target: self, action: #selector(width(_:)))
            b.tag = Int(w * 10)
            b.bezelStyle = .accessoryBarAction
            b.imagePosition = .imageLeading
            b.alignment = .left
            b.state = abs(m.lineWidth - w) < 0.01 ? .on : .off
            b.setButtonType(.pushOnPushOff)
            rows.append(b)
        }
        rows.append(NSBox.separatorLine())
        let dash = NSButton(checkboxWithTitle: "Gestrichelt", target: self, action: #selector(dash(_:)))
        dash.state = m.dash ? .on : .off
        let shadow = NSButton(checkboxWithTitle: "Schatten", target: self, action: #selector(shadow(_:)))
        shadow.state = m.shadow ? .on : .off
        rows += [dash, shadow]
        if m.isLine {
            let arrow = NSButton(checkboxWithTitle: "Pfeilspitze", target: self, action: #selector(arrow(_:)))
            arrow.state = m.kind == .arrow ? .on : .off
            rows.append(arrow)
        }
        let v = NSStackView(views: rows)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 2
        v.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 10, right: 12)
        view = v
    }

    @objc private func width(_ b: NSButton) { canvas?.applyLineStyle(width: CGFloat(b.tag) / 10); dismiss(nil) }
    @objc private func dash(_ b: NSButton) { canvas?.applyLineStyle(dash: b.state == .on) }
    @objc private func shadow(_ b: NSButton) { canvas?.applyLineStyle(shadow: b.state == .on) }
    @objc private func arrow(_ b: NSButton) { canvas?.applyLineStyle(arrow: b.state == .on) }
}

extension NSBox {
    static func separatorLine() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return b
    }
}

// MARK: Textstil

final class TextStylePopover: NSViewController {
    weak var canvas: Canvas?
    private let family = NSPopUpButton(), style = NSPopUpButton()
    private let size = NSComboBox()
    private let color = NSColorWell(style: .minimal)
    private let align = NSSegmentedControl()
    private var families: [String] = []
    private var members: [[Any]] = []

    init(canvas: Canvas) { self.canvas = canvas; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let m = canvas?.styleModel ?? Defaults.model
        families = NSFontManager.shared.availableFontFamilies.sorted()
        family.addItems(withTitles: families)
        let f = NSFont(name: m.fontName, size: m.fontSize) ?? NSFont(name: "ArialMT", size: 12)!
        family.selectItem(withTitle: f.familyName ?? "Arial")
        family.target = self; family.action = #selector(familyChanged)
        fillStyles(f.familyName ?? "Arial", select: f.fontName)
        style.target = self; style.action = #selector(styleChanged)
        size.addItems(withObjectValues: ["8", "9", "10", "11", "12", "14", "16", "18", "20", "24", "28", "36", "48", "64", "72"])
        size.stringValue = String(format: "%g", m.fontSize)
        size.target = self; size.action = #selector(sizeChanged)
        size.widthAnchor.constraint(equalToConstant: 64).isActive = true
        color.color = m.textColor.color
        color.target = self; color.action = #selector(colorChanged)
        align.segmentCount = 3
        for (i, s) in ["text.alignleft", "text.aligncenter", "text.alignright"].enumerated() {
            align.setImage(NSImage(systemSymbolName: s, accessibilityDescription: nil), forSegment: i)
            align.setWidth(32, forSegment: i)
        }
        align.selectedSegment = m.align
        align.target = self; align.action = #selector(alignChanged)
        family.widthAnchor.constraint(equalToConstant: 200).isActive = true
        style.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let row = NSStackView(views: [size, NSTextField(labelWithString: "pt"), NSView(), color])
        row.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let v = NSStackView(views: [family, style, row, align])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        v.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view = v
    }

    private func fillStyles(_ fam: String, select name: String) {
        members = NSFontManager.shared.availableMembers(ofFontFamily: fam) ?? []
        style.removeAllItems()
        style.addItems(withTitles: members.map { ($0.count > 1 ? $0[1] as? String : nil) ?? "Normal" })
        if let i = members.firstIndex(where: { ($0.first as? String) == name }) { style.selectItem(at: i) }
    }

    @objc private func familyChanged() {
        guard let fam = family.titleOfSelectedItem else { return }
        let ms = NSFontManager.shared.availableMembers(ofFontFamily: fam) ?? []
        let reg = ms.first { ["Regular", "Normal", "Roman", "Book", "Medium"].contains(($0.count > 1 ? $0[1] as? String : nil) ?? "") } ?? ms.first
        guard let name = reg?.first as? String else { return }
        fillStyles(fam, select: name)
        canvas?.applyTextStyle { $0.fontName = name }
    }
    @objc private func styleChanged() {
        let i = style.indexOfSelectedItem
        guard i >= 0, i < members.count, let name = members[i].first as? String else { return }
        canvas?.applyTextStyle { $0.fontName = name }
    }
    @objc private func sizeChanged() {
        let v = CGFloat(Double(size.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 12)
        canvas?.applyTextStyle { $0.fontSize = max(2, min(400, v)) }
    }
    @objc private func colorChanged() {
        let c = RGBA(color.color)
        canvas?.applyTextStyle { $0.textColor = c }
    }
    @objc private func alignChanged() {
        let a = align.selectedSegment
        canvas?.applyTextStyle { $0.align = a }
    }
}

