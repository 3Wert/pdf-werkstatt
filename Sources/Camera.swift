import AppKit
import AVFoundation

/// Unterschrift mit der Kamera: Papier vor die Webcam halten, Foto machen, Hintergrund wird entfernt.
final class CameraSignature: NSWindowController, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var preview: AVCaptureVideoPreviewLayer!
    private var done: ((Data) -> Void)?
    private var keep: CameraSignature?

    static func present(on parent: NSWindow, done: @escaping (Data) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        func go() {
            let c = CameraSignature()
            c.done = done
            c.keep = c
            guard c.start() else {
                let a = NSAlert(); a.messageText = "Keine Kamera gefunden"; a.runModal(); return
            }
            parent.beginSheet(c.window!) { _ in c.session.stopRunning(); c.keep = nil }
        }
        switch status {
        case .authorized: go()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { if ok { go() } } }
        default:
            let a = NSAlert()
            a.messageText = "Kein Zugriff auf die Kamera"
            a.informativeText = "Systemeinstellungen › Datenschutz & Sicherheit › Kamera: PDF-Werkstatt erlauben."
            a.runModal()
        }
    }

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        self.init(window: w)
        let root = NSView(frame: w.contentView!.bounds)
        root.wantsLayer = true
        let cam = NSView(frame: NSRect(x: 20, y: 70, width: 600, height: 420))
        cam.wantsLayer = true
        cam.layer?.backgroundColor = NSColor.black.cgColor
        cam.layer?.cornerRadius = 8
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = cam.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        cam.layer?.addSublayer(preview)
        // Rahmen als Hilfe: Unterschrift in den hellen Bereich halten
        let guide = CAShapeLayer()
        guide.path = CGPath(roundedRect: cam.bounds.insetBy(dx: 60, dy: 120), cornerWidth: 8, cornerHeight: 8, transform: nil)
        guide.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        guide.fillColor = nil
        guide.lineDashPattern = [8, 6]
        guide.lineWidth = 2
        cam.layer?.addSublayer(guide)
        let hint = NSTextField(labelWithString: "Unterschrift auf weißem Papier in den Rahmen halten, dann „Aufnehmen“.")
        hint.frame = NSRect(x: 20, y: 40, width: 600, height: 20)
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        let shoot = NSButton(title: "Aufnehmen", target: self, action: #selector(shoot))
        shoot.bezelStyle = .rounded; shoot.keyEquivalent = "\r"
        shoot.frame = NSRect(x: 500, y: 10, width: 120, height: 28)
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 380, y: 10, width: 110, height: 28)
        [cam, hint, shoot, cancel].forEach(root.addSubview)
        w.contentView = root
    }

    private func start() -> Bool {
        guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        return true
    }

    @objc private func shoot() {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        output.capturePhoto(with: settings, delegate: self)
    }

    @objc private func cancel() { close(.cancel) }

    private func close(_ r: NSApplication.ModalResponse) {
        guard let w = window, let p = w.sheetParent else { return }
        p.endSheet(w, returnCode: r)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let d = photo.fileDataRepresentation() else { NSSound.beep(); return }
        let cb = done
        close(.OK)
        DispatchQueue.main.async { cb?(d) }
    }
}
