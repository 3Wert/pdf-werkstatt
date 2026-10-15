import AppKit

/// Kleine Leiste am Zuschneide-Rahmen: Maße, Abbrechen, Alle Seiten, Zuschneiden
final class CropBar: NSView {
    var onCrop: (() -> Void)?
    var onCropAll: (() -> Void)?
    var onCancel: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        func b(_ t: String, _ s: Selector, key: String = "") -> NSButton {
            let x = NSButton(title: t, target: self, action: s)
            x.bezelStyle = .rounded
            x.controlSize = .small
            x.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            x.keyEquivalent = key
            return x
        }
        let stack = NSStackView(views: [label, b("Abbrechen", #selector(cancel), key: "\u{1b}"), b("Alle Seiten", #selector(all)), b("Zuschneiden", #selector(crop), key: "\r")])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }
    required init?(coder: NSCoder) { nil }

    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    override var wantsUpdateLayer: Bool { true }

    func setSize(_ s: CGSize) {
        label.stringValue = String(format: "%.0f × %.0f mm", s.width * 25.4 / 72, s.height * 25.4 / 72)
        layoutSubtreeIfNeeded()
    }

    @objc private func crop() { onCrop?() }
    @objc private func all() { onCropAll?() }
    @objc private func cancel() { onCancel?() }
}
