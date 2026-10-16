// Draws Speak's 1024 px app icon to the path given as the first argument:
// the standard macOS rounded square with a deep indigo-to-teal gradient and a
// white waveform. Run by scripts/make-icon.sh.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The macOS icon grid: an 824 px body centred on the canvas, leaving room for the shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.20, green: 0.18, blue: 0.55, alpha: 1),
    NSColor(srgbRed: 0.10, green: 0.55, blue: 0.62, alpha: 1),
])!
gradient.draw(in: shape, angle: -60)

// A soft highlight across the top edge.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Waveform bars, symmetric about the centre: speech becoming text.
let heights: [CGFloat] = [0.22, 0.42, 0.68, 0.94, 0.68, 0.42, 0.22]
let barWidth: CGFloat = 58
let gap: CGFloat = 34
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = body.midX - total / 2
NSColor.white.setFill()
for h in heights {
    let height = 460 * h
    let bar = NSRect(x: x, y: body.midY - height / 2, width: barWidth, height: height)
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
