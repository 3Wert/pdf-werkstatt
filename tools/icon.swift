import AppKit
// Flaches App-Symbol: Blatt mit Eselsohr, rote Akzentlinie, Textzeilen
let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: S, height: S).fill()
let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSColor(srgbRed: 0.16, green: 0.20, blue: 0.27, alpha: 1).setFill(); bg.fill()
let page = NSBezierPath()
let l: CGFloat = 300, r: CGFloat = 724, b: CGFloat = 230, t: CGFloat = 800, ear: CGFloat = 120
page.move(to: NSPoint(x: l, y: b)); page.line(to: NSPoint(x: r, y: b)); page.line(to: NSPoint(x: r, y: t - ear))
page.line(to: NSPoint(x: r - ear, y: t)); page.line(to: NSPoint(x: l, y: t)); page.close()
NSColor(srgbRed: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill(); page.fill()
let fold = NSBezierPath(); fold.move(to: NSPoint(x: r - ear, y: t)); fold.line(to: NSPoint(x: r - ear, y: t - ear)); fold.line(to: NSPoint(x: r, y: t - ear)); fold.close()
NSColor(srgbRed: 0.82, green: 0.80, blue: 0.75, alpha: 1).setFill(); fold.fill()
NSColor(srgbRed: 0.62, green: 0.64, blue: 0.68, alpha: 1).setFill()
for (i, w) in [300, 260, 300, 180].enumerated() { NSRect(x: 360, y: 600 - CGFloat(i) * 70, width: CGFloat(w), height: 26).fill() }
NSColor(srgbRed: 0.84, green: 0.16, blue: 0.13, alpha: 1).setFill()
NSRect(x: 360, y: 290, width: 220, height: 34).fill()
NSRect(x: 600, y: 270, width: 10, height: 74).fill()   // Textcursor
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
