import AppKit
import SwiftUI

/// 文字オーバーレイの見た目。本体は文字を描かない (defaultText.qml は画像を表示するだけ) ので、
/// Mac で透過 PNG に描いてアップロードし、その画像を source にする。OnAir と同じ方式。
/// 編集用の値は assetConfig の textProperties に保存する (OnAir のキーに合わせ、知らないキーは残す)。
struct TextStyle: Equatable {
    var text = "テキスト"
    var fontFamily = "Hiragino Sans"
    var bold = true
    var textColor = "#ffffff"
    var hasOutline = true
    var outlineColor = "#000000"
    var hasBackground = false
    var backgroundColor = "#000000"
    var backgroundOpacity = 0.6
    var align = 1               // 0 左 / 1 中央 / 2 右

    static let fonts = ["Hiragino Sans", "Hiragino Maru Gothic ProN", "Hiragino Mincho ProN",
                        "Helvetica Neue", "Avenir Next", "Futura", "Menlo"]

    init() {}

    init(_ tp: [String: Any]) {
        text = tp["textData"] as? String ?? ""
        fontFamily = tp["fontFamily"] as? String ?? fontFamily
        bold = (tp["fontWeight"] as? Int ?? 6) >= 6
        textColor = Self.rgb(tp["textColor"] as? String) ?? textColor
        hasOutline = tp["hasOutline"] as? Bool ?? false
        outlineColor = Self.rgb(tp["outlineColor"] as? String) ?? outlineColor
        hasBackground = tp["hasBackground"] as? Bool ?? false
        backgroundColor = Self.rgb(tp["backgroundColor"] as? String) ?? backgroundColor
        backgroundOpacity = tp["lsmixerBackgroundOpacity"] as? Double ?? 1
        align = tp["lsmixerAlign"] as? Int ?? 1
    }

    /// 既存の textProperties に上書きして返す (知らないキーは保つ)
    func json(merging old: [String: Any]?, fontSize: Int) -> [String: Any] {
        var d = old ?? ["fontStyle": 0, "outlineSize": 1.0, "backgroundRounded": true, "overflow": 2]
        d["textData"] = text
        d["fontFamily"] = fontFamily
        d["fontWeight"] = bold ? 6 : 4
        d["fontSize"] = fontSize
        d["textColor"] = textColor
        d["hasOutline"] = hasOutline
        d["outlineColor"] = outlineColor
        d["hasBackground"] = hasBackground
        d["backgroundColor"] = backgroundColor
        d["lsmixerBackgroundOpacity"] = backgroundOpacity
        d["lsmixerAlign"] = align
        return d
    }

    /// "#AARRGGBB" / "#RRGGBB" → "#rrggbb"
    private static func rgb(_ s: String?) -> String? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 8 { s = String(s.suffix(6)) }
        return s.count == 6 ? "#" + s.lowercased() : nil
    }
}

enum TextRenderer {
    /// 出力 (1920×1080) に対する枠の比率 w×h の画像を描く。scale 2 で 4K 相当 (OnAir と同程度)。
    /// 文字は枠に収まる最大の大きさに自動調整。戻り値は (PNG, 1080p 換算の文字サイズ)
    static func render(_ s: TextStyle, w: Double, h: Double, scale: Double = 2) -> (png: Data, image: NSImage, fontSize: Int)? {
        let W = max(Int((w * 1920 * scale).rounded()), 8), H = max(Int((h * 1080 * scale).rounded()), 8)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let pad = Double(H) * 0.08
        let box = CGRect(x: 0, y: 0, width: Double(W), height: Double(H))
        let inner = box.insetBy(dx: pad, dy: pad * (s.hasOutline ? 1.3 : 1))

        let para = NSMutableParagraphStyle()
        para.alignment = [.left, .center, .right][min(max(s.align, 0), 2)]
        para.lineBreakMode = .byWordWrapping
        func font(_ size: Double) -> NSFont {
            let base = NSFont(name: s.fontFamily, size: size) ?? .systemFont(ofSize: size)
            return s.bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        }
        // フォント自体の行間 (ヒラギノは大きい) は使わず、行と行の間だけ少し空ける
        func attrs(_ size: Double) -> [NSAttributedString.Key: Any] {
            let p = para.mutableCopy() as! NSMutableParagraphStyle
            p.lineSpacing = size * 0.12
            return [.font: font(size), .paragraphStyle: p, .foregroundColor: NSColor(Color(hex: s.textColor))]
        }
        func measure(_ size: Double) -> CGSize {
            let r = (s.text as NSString).boundingRect(with: CGSize(width: inner.width, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin],
                                                      attributes: attrs(size))
            return r.size
        }
        // 枠に収まる最大の文字サイズを二分探索
        var lo = 4.0, hi = Double(H)
        for _ in 0..<18 {
            let mid = (lo + hi) / 2
            let m = measure(mid)
            if m.height <= inner.height && m.width <= inner.width + 0.5 { lo = mid } else { hi = mid }
        }
        let size = lo

        NSGraphicsContext.saveGraphicsState()
        // 上から下へ座標を取る (flipped) にして、文字の縦位置を素直に計算する
        let cg = ctx.cgContext
        cg.translateBy(x: 0, y: CGFloat(H))
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        NSColor.clear.set()
        box.fill()
        if s.hasBackground {
            NSColor(Color(hex: s.backgroundColor)).withAlphaComponent(s.backgroundOpacity).setFill()
            NSBezierPath(roundedRect: box, xRadius: Double(H) * 0.15, yRadius: Double(H) * 0.15).fill()
        }
        let m = measure(size)
        let rect = CGRect(x: inner.minX, y: inner.midY - m.height / 2, width: inner.width, height: m.height)
        if s.hasOutline {
            // 縁取り: 文字を周囲 16 方向にずらして重ね描き (輪郭線方式だと角にトゲが出る)
            var a = attrs(size)
            a[.foregroundColor] = NSColor(Color(hex: s.outlineColor))
            let r = size * 0.06
            for k in 0..<16 {
                let t = Double(k) / 16 * 2 * .pi
                (s.text as NSString).draw(with: rect.offsetBy(dx: cos(t) * r, dy: sin(t) * r),
                                          options: [.usesLineFragmentOrigin], attributes: a)
            }
        }
        (s.text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs(size))
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let img = NSImage(size: NSSize(width: W, height: H))
        img.addRepresentation(rep)
        return (png, img, Int((size / scale).rounded()))
    }
}
