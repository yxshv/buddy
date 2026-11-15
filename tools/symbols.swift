// Renders the SF Symbols that result cards use into PNG masks: black glyphs on transparent, so
// cards.css can tint them with mask-image. Usage: swift tools/symbols.swift <output dir>
import AppKit

let symbols = [
    "note": "doc.text.fill",
    "calendar": "calendar",
    "file": "doc.fill",
    "email": "envelope.fill",
    "task": "checkmark.circle.fill",
    "link": "link",
    "open": "arrow.up.right",
]

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let side = 96.0 // drawn large; shown at ~20px

for (kind, name) in symbols {
    let config = NSImage.SymbolConfiguration(pointSize: side * 0.62, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        FileHandle.standardError.write("no symbol \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Fill the square edge to edge (keeping the aspect), so CSS sizes the glyph itself.
    let scale = side / max(symbol.size.width, symbol.size.height)
    let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    let rect = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
    symbol.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(kind).png"))
}
