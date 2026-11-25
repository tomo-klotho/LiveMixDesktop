// Live Mix Desktop のアプリアイコン (1024px PNG) を描く: swift make-icon.swift out.png
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let inset = size * 0.1
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.18, yRadius: size * 0.18)
NSGradient(colors: [NSColor(red: 0.10, green: 0.14, blue: 0.24, alpha: 1), NSColor(red: 0.20, green: 0.10, blue: 0.30, alpha: 1)])!
    .draw(in: path, angle: -90)
// 赤 (PGM) と緑 (PRV) のシーン枠
let r1 = NSRect(x: rect.minX + size * 0.09, y: rect.midY + size * 0.03, width: size * 0.29, height: size * 0.17)
let r2 = NSRect(x: rect.maxX - size * 0.09 - size * 0.29, y: rect.midY + size * 0.03, width: size * 0.29, height: size * 0.17)
for (r, c) in [(r1, NSColor.systemRed), (r2, NSColor.systemGreen)] {
    let p = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18); p.lineWidth = 22; c.setStroke(); p.stroke()
}
// フェーダー
if let sym = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: size * 0.24, weight: .semibold)) {
    let tinted = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
    }
    let s = tinted.size
    tinted.draw(in: NSRect(x: (size - s.width) / 2, y: rect.minY + size * 0.12, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
