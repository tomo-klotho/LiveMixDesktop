import AppKit
import SwiftUI

/// シーン (= レイアウト) の 1 ウインドウ。位置・大きさは画面に対する比率 (0〜1)
struct LayoutWindow: Identifiable, Equatable {
    let id = UUID()
    var src: Int            // 1 = HDMI1, 2 = HDMI2
    var alt: Bool           // HDMI2 の B 側なら true
    var x: Double, y: Double, w: Double, h: Double
    var z: Double
    var raw: [String: Any]  // 本体が返した他の項目 (type, renderMode, srcMap など) をそのまま保つ
    var border: WinBorder?  // 枠線 (クロマキーとは併用不可)
    var key: ChromaKey?     // クロマキー (指定色を透明に。一番奥のウインドウだけ)
    /// 切り出し範囲 (srcMap): 入力映像のどこを使うか。入力に対する比率 (0〜1)。既定は全体
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func == (a: LayoutWindow, b: LayoutWindow) -> Bool {
        a.id == b.id && a.src == b.src && a.alt == b.alt && a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h && a.z == b.z &&
        a.border == b.border && a.key == b.key && a.crop == b.crop
    }

    init(src: Int, alt: Bool, x: Double, y: Double, w: Double, h: Double, z: Double) {
        self.src = src; self.alt = alt; self.x = x; self.y = y; self.w = w; self.h = h; self.z = z
        raw = ["type": "HDMI1", "renderMode": "manual",
               "srcMap": ["x_ratio": 0.0, "y_ratio": 0.0, "w_ratio": 1.0, "h_ratio": 1.0]]
    }

    init?(_ d: [String: Any]) {
        guard let src = d["srcId"] as? Int, let loc = d["location"] as? [String: Any] else { return nil }
        self.src = src
        alt = d["altPort"] as? Bool ?? false
        x = loc["x_ratio"] as? Double ?? 0; y = loc["y_ratio"] as? Double ?? 0
        w = loc["w_ratio"] as? Double ?? 1; h = loc["h_ratio"] as? Double ?? 1
        z = loc["z_order"] as? Double ?? 1
        raw = d
        border = (d["border"] as? [String: Any]).flatMap(WinBorder.init)
        key = (d["transparency"] as? [String: Any]).flatMap(ChromaKey.init)
        if let m = d["srcMap"] as? [String: Any] {
            crop = CGRect(x: m["x_ratio"] as? Double ?? 0, y: m["y_ratio"] as? Double ?? 0,
                          width: m["w_ratio"] as? Double ?? 1, height: m["h_ratio"] as? Double ?? 1)
        }
    }

    var json: [String: Any] {
        var d = raw
        d["srcId"] = src
        d["altPort"] = alt
        d["location"] = ["x_ratio": x, "y_ratio": y, "w_ratio": w, "h_ratio": h, "z_order": z]
        var m = d["srcMap"] as? [String: Any] ?? [:]   // 知らないキーは残す
        m["x_ratio"] = crop.minX; m["y_ratio"] = crop.minY; m["w_ratio"] = crop.width; m["h_ratio"] = crop.height
        d["srcMap"] = m
        if d["type"] == nil { d["type"] = "HDMI1" }
        if d["renderMode"] == nil { d["renderMode"] = "manual" }
        if let k = key { d["transparency"] = k.json; d["border"] = nil }
        else { d["transparency"] = nil; d["border"] = border?.json }
        return d
    }

    var sourceKey: String { src == 1 ? "HDMI1" : (alt ? "HDMI2 B" : "HDMI2 A") }
    static let sources: [(label: String, src: Int, alt: Bool)] = [("HDMI1", 1, false), ("HDMI2 A", 2, false), ("HDMI2 B", 2, true)]
}

/// ウインドウの枠線。太さは画面の高さに対する比率 (4 辺同じ)
struct WinBorder: Equatable {
    var width = 0.008
    var color = "#ffffff"

    init() {}
    init?(_ d: [String: Any]) {
        width = d["top_ratio"] as? Double ?? d["left_ratio"] as? Double ?? 0.008
        let r = d["colorR"] as? Int ?? 255, g = d["colorG"] as? Int ?? 255, b = d["colorB"] as? Int ?? 255
        color = String(format: "#%02x%02x%02x", r, g, b)
    }
    var json: [String: Any] {
        let c = Color(hex: color)
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return ["left_ratio": width, "right_ratio": width, "top_ratio": width, "bottom_ratio": width,
                "colorR": Int((n.redComponent * 255).rounded()), "colorG": Int((n.greenComponent * 255).rounded()),
                "colorB": Int((n.blueComponent * 255).rounded())]
    }
}

/// クロマキー: RGB それぞれの範囲 (Low〜High) に入る色を透明にする。
/// 画面では「抜く色」と「幅」で指定し、範囲に直して送る
struct ChromaKey: Equatable {
    var color = "#00c040"   // 抜く色 (グリーンバック)
    var tolerance = 70      // 各色 ± この幅

    init() {}
    init(color: String, tolerance: Int) { self.color = color; self.tolerance = tolerance }
    init?(_ d: [String: Any]) {
        func mid(_ k: String) -> (Int, Int) {
            let lo = d["color\(k)_Low"] as? Int ?? 0, hi = d["color\(k)_High"] as? Int ?? 255
            return ((lo + hi) / 2, (hi - lo) / 2)
        }
        let (r, tr) = mid("R"), (g, tg) = mid("G"), (b, tb) = mid("B")
        color = String(format: "#%02x%02x%02x", r, g, b)
        tolerance = max(tr, tg, tb)
    }
    var rgb: (Int, Int, Int) {
        let n = NSColor(Color(hex: color)).usingColorSpace(.sRGB) ?? .green
        return (Int((n.redComponent * 255).rounded()), Int((n.greenComponent * 255).rounded()), Int((n.blueComponent * 255).rounded()))
    }
    var json: [String: Any] {
        let (r, g, b) = rgb
        func lo(_ v: Int) -> Int { max(0, v - tolerance) }
        func hi(_ v: Int) -> Int { min(255, v + tolerance) }
        return ["colorR_Low": lo(r), "colorR_High": hi(r), "colorG_Low": lo(g), "colorG_High": hi(g),
                "colorB_Low": lo(b), "colorB_High": hi(b)]
    }
    static let green = ChromaKey(color: "#00c040", tolerance: 70)
    static let blue = ChromaKey(color: "#0040c0", tolerance: 70)
}

/// オーバーレイの 1 層 (画像または文字)。位置・大きさは画面に対する比率。編集可能。
struct OverlayLayer: Identifiable, Equatable {
    let id = UUID()
    var textStyle: TextStyle?   // 文字オーバーレイなら見た目 (本体には描画済み PNG を送る)
    var assetId: Int?       // 表示する画像のアセット番号 (source)。文字なら描画済み PNG
    var assetName: String?  // 画像の名前
    var image: NSImage?
    var x: Double, y: Double, w: Double, h: Double, z: Double
    var visible: Bool
    var raw: [String: Any]  // qmlId, fillMode, srcMap, textProperties など他の項目を保つ
    var fillMode = 1        // 0 引き伸ばし / 1 全体を収める / 2 切り抜いて埋める / 6 原寸
    var needsRender = false // 文字の内容・見た目を変えた → 適用時に描き直してアップロード
    var name: String?       // 一覧に出す名前 (assetConfig の lsmixerName に保存。本体は使わない)

    static func == (a: OverlayLayer, b: OverlayLayer) -> Bool {
        a.id == b.id && a.assetId == b.assetId && a.x == b.x && a.y == b.y &&
        a.w == b.w && a.h == b.h && a.z == b.z && a.visible == b.visible &&
        a.textStyle == b.textStyle && a.fillMode == b.fillMode && a.needsRender == b.needsRender && a.name == b.name
    }

    var text: String? { textStyle?.text }
    var isText: Bool { textStyle != nil }
    var label: String {
        if let n = name, !n.isEmpty { return n }
        if let t = text { return "文字「\(t.replacingOccurrences(of: "\n", with: " "))」" }
        return "画像 \(Self.friendly(assetName, assetId))"
    }
    /// "Image-1773976294663.bin" のような自動の名前は「id 5」と短く出す
    static func friendly(_ name: String?, _ id: Int?) -> String {
        guard let n = name, !n.isEmpty else { return "id \(id ?? 0)" }
        if n.range(of: #"^Image-\d+\.(bin|png|jpe?g)$"#, options: .regularExpression) != nil { return "id \(id ?? 0)" }
        return (n as NSString).deletingPathExtension
    }
    var coversAll: Bool { !isText && w > 0.95 && h > 0.95 }

    /// 本体へ送る assetConfig 1 項目
    var json: [String: Any] {
        var d = raw
        var p = (d["properties"] as? [String: Any]) ?? [:]
        p["x"] = x; p["y"] = y; p["width"] = w; p["height"] = h; p["z"] = Int(z)
        if let a = assetId { p["source"] = a }
        p["fillMode"] = fillMode
        d["properties"] = p
        if let st = textStyle {
            let old = d["textProperties"] as? [String: Any]
            d["textProperties"] = st.json(merging: old, fontSize: old?["fontSize"] as? Int ?? 48)
        }
        d["isVisible"] = visible
        if let n = name, !n.trimmingCharacters(in: .whitespaces).isEmpty { d["lsmixerName"] = n } else { d["lsmixerName"] = nil }
        if d["qmlId"] == nil { d["qmlId"] = isText ? 1 : 2 }
        return d
    }

    /// qmlId と source の両方 (assetIdArr 用)
    var usedAssetIds: [Int] {
        var ids: [Int] = []
        if let q = raw["qmlId"] as? Int { ids.append(q) } else { ids.append(isText ? 1 : 2) }
        if let a = assetId { ids.append(a) }
        return ids
    }
}

@MainActor
final class SceneEditorModel: ObservableObject {
    @Published var sceneId = 1
    @Published var windows: [LayoutWindow] = []
    @Published var bgColor = Color.black
    @Published var bgUseColor = true     // true=色, false=画像
    @Published var bgAssetId: Int?       // 背景画像のアセット
    @Published var selected: UUID?
    @Published var dirty = false
    @Published var pendingScene: Int?        // 未適用のまま切り替えようとしたシーン (確認待ち)
    @Published var nameEdit = ""             // シーン名の編集欄
    @Published var busy = false
    @Published var message: String?
    @Published var clipboard: (content: SceneContent, label: String)?   // アプリ内のコピー
    @Published var templates: [SceneTemplate] = TemplateStore.load()
    var checkReturnPreview: Int?
    @Published var checkReturnScene: Int?    // 「本体の映像で確認」で Program に出す前のシーン

    private var layoutId = 1
    private var original: [String: Any] = [:]

    // オーバーレイ (シーンの最前面に重ねる画像・文字)
    @Published var overlay: [OverlayLayer] = []
    @Published var selectedOverlay: UUID?
    @Published var availableImages: [(id: Int, name: String, image: NSImage?)] = []
    private var overlayId = 1
    var overlayDirty = false
    var assetURL: [Int: String] = [:]
    var assetName: [Int: String] = [:]
    var assetImages: [Int: NSImage] = [:]
    let m: MixerModel
    init(model: MixerModel) {
        m = model
        if let n = Int(ProcessInfo.processInfo.environment["LMD_SCENE"] ?? ""), (1...8).contains(n) { sceneId = n }
    }

    func load(_ scene: Int) async {
        sceneId = scene
        busy = true; defer { busy = false }
        do {
            let sc = try await m.api.call("GET", "/scenes/\(scene)") as? [String: Any]
            layoutId = sc?["layoutId"] as? Int ?? scene
            guard let l = try await m.api.call("GET", "/layouts/\(layoutId)") as? [String: Any] else { return }
            original = l
            windows = (l["windowInfo"] as? [[String: Any]] ?? []).compactMap(LayoutWindow.init).sorted { $0.z < $1.z }
            bgColor = Color(hex: l["bgColor"] as? String ?? "#000000")
            bgUseColor = l["isUseColor"] as? Bool ?? true
            bgAssetId = l["bgAssetId"] as? Int
            selected = windows.last?.id
            overlayId = sc?["overlayId"] as? Int ?? scene
            nameEdit = sc?["name"] as? String ?? "Scene \(scene)"
            if let n = sc?["name"] as? String { m.sceneNames[scene] = n }
            let selIndex = overlay.firstIndex { $0.id == selectedOverlay }
            try await loadOverlay()
            // 読み直しでレイヤーの id が変わるので、選択は同じ位置のレイヤーに付け替える
            selectedOverlay = selIndex.flatMap { overlay.indices.contains($0) ? overlay[$0].id : nil }
            dirty = false
            overlayDirty = false
            undoStack.removeAll(); redoStack.removeAll(); lastRecord = .distantPast; updateUndoFlags()
            message = nil
        } catch { message = "読み込めませんでした: \(error)" }
    }

    /// 本体の画像アセット一覧を読み直す (追加・削除に追従。画像はキャッシュ利用)
    func refreshAssetList() async {
        guard let a = try? await m.api.call("GET", "/assets") as? [String: Any],
              let list = a["assets"] as? [[String: Any]] else { return }
        assetURL.removeAll(); assetName.removeAll()
        for x in list {
            if let id = x["id"] as? Int, x["type"] as? String == "image", let u = x["url"] as? String {
                assetURL[id] = u; assetName[id] = x["name"] as? String ?? "アセット \(id)"
            }
        }
        var imgs: [(id: Int, name: String, image: NSImage?)] = []
        for id in assetURL.keys.sorted() where !(assetName[id] ?? "").hasPrefix(Self.textPrefix) { imgs.append((id: id, name: assetName[id] ?? "", image: await loadAsset(id))) }
        availableImages = imgs
    }

    private func loadOverlay() async throws {
        await refreshAssetList()
        let o = try await m.api.call("GET", "/overlays/\(overlayId)") as? [String: Any]
        let raw = o?["assetConfig"] as? [[String: Any]] ?? []
        var layers: [OverlayLayer] = []
        for c in raw {
            let p = c["properties"] as? [String: Any] ?? [:]
            let style = (c["textProperties"] as? [String: Any]).map(TextStyle.init)
            let src = p["source"] as? Int
            var img: NSImage?
            if let src = src { img = await loadAsset(src) }   // 文字も描画済み PNG を表示
            layers.append(OverlayLayer(textStyle: style, assetId: src,
                                       assetName: src.flatMap { assetName[$0] }, image: img,
                                       x: p["x"] as? Double ?? 0, y: p["y"] as? Double ?? 0,
                                       w: p["width"] as? Double ?? 1, h: p["height"] as? Double ?? 1,
                                       z: p["z"] as? Double ?? 6, visible: c["isVisible"] as? Bool ?? true, raw: c,
                                       fillMode: p["fillMode"] as? Int ?? 1, name: c["lsmixerName"] as? String))
        }
        overlay = layers.sorted { $0.z < $1.z }
    }

    func loadAsset(_ id: Int) async -> NSImage? {
        if let c = assetImages[id] { return c }
        guard let url = assetURL[id], let path = URL(string: url)?.path,
              let d = try? await m.api.fetchStatic(path), let im = NSImage(data: d) else { return nil }
        assetImages[id] = im
        return im
    }

    func addImageOverlay(assetId: Int) {
        change {
            let z = (overlay.map(\.z).max() ?? 5) + 1
            overlay.append(OverlayLayer(textStyle: nil, assetId: assetId, assetName: assetName[assetId],
                                        image: assetImages[assetId], x: 0.6, y: 0.6, w: 0.35, h: 0.35, z: z,
                                        visible: true, raw: ["qmlId": 2, "properties": ["fillMode": 1]]))
            selectedOverlay = overlay.last?.id
            selected = nil
            overlayDirty = true
        }
    }

    func addTextOverlay() {
        change {
            let z = (overlay.map(\.z).max() ?? 5) + 1
            var layer = OverlayLayer(textStyle: TextStyle(), assetId: nil, assetName: nil, image: nil,
                                     x: 0.05, y: 0.8, w: 0.5, h: 0.12, z: z, visible: true,
                                     raw: ["qmlId": 1, "properties": ["fillMode": 1]], needsRender: true)
            layer.image = TextRenderer.render(layer.textStyle!, w: layer.w, h: layer.h, scale: 0.5)?.image
            overlay.append(layer)
            selectedOverlay = overlay.last?.id
            selected = nil
            overlayDirty = true
        }
    }

    func removeOverlay(_ id: UUID) {
        change { overlay.removeAll { $0.id == id }; if selectedOverlay == id { selectedOverlay = nil }; overlayDirty = true }
    }

    func moveOverlayZ(_ id: UUID, by d: Int) {
        guard let i = overlay.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard overlay.indices.contains(j) else { return }
        change { overlay.swapAt(i, j); overlayDirty = true }
    }

    func setOverlayVisible(_ id: UUID, _ v: Bool) {
        guard let i = overlay.firstIndex(where: { $0.id == id }) else { return }
        change { overlay[i].visible = v; overlayDirty = true }
    }

    func imageForAsset(_ id: Int) -> NSImage? { assetImages[id] ?? availableImages.first { $0.id == id }?.image }

    func overlayBinding(_ id: UUID) -> Binding<OverlayLayer>? {
        guard overlay.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            // 適用後の読み直しでレイヤーが作り直されると id が消える。古い表示が残っていても落ちないよう仮の値を返す
            get: { self.overlay.first { $0.id == id }
                   ?? OverlayLayer(textStyle: nil, assetId: nil, assetName: nil, image: nil,
                                   x: 0, y: 0, w: 0.1, h: 0.1, z: 6, visible: false, raw: [:]) },
            set: { nv in
                guard let i = self.overlay.firstIndex(where: { $0.id == id }), self.overlay[i] != nv else { return }
                self.recordUndo()
                var v = nv
                let old = self.overlay[i]
                if let st = v.textStyle, st != old.textStyle || v.w != old.w || v.h != old.h {   // 文字は枠の大きさに合わせて描き直す
                    v.needsRender = true
                    v.image = TextRenderer.render(st, w: v.w, h: v.h, scale: 0.5)?.image   // 画面確認用 (小さめ)
                }
                self.overlay[i] = v
                self.overlayDirty = true
                self.dirty = true
            })
    }

    func apply() async {
        busy = true; defer { busy = false }
        // クロマキーは「一番奥のウインドウ 1 つだけ・枠線なし」(本体の制約)。並べ替えで崩れていても直す
        if let k = windows.firstIndex(where: { $0.key != nil }) {
            let w = windows.remove(at: k)
            windows.insert(w, at: 0)
            for i in windows.indices.dropFirst() where windows[i].key != nil { windows[i].key = nil }
            windows[0].border = nil
        }
        // 重なり順は配列の順番 (後ろほど手前) で振り直す
        for i in windows.indices { windows[i].z = Double(i + 1) }
        var body: [String: Any] = ["windowInfo": windows.map(\.json), "bgColor": bgColor.hex,
                                   "isUseColor": bgUseColor, "sender": "livemixdesktop"]
        if let a = bgAssetId, !bgUseColor { body["bgAssetId"] = a }
        do {
            try await m.api.call("PATCH", "/layouts/\(layoutId)", body)
            m.log("scene \(sceneId) layout \(layoutId) applied: \(windows.map(\.sourceKey))")
            if overlayDirty {
                // 重なり順は配列の順 (後ろほど手前) で z を振り直す。6 以上にして映像(z 1〜)より前に
                for i in overlay.indices { overlay[i].z = Double(6 + i) }
                // 文字は Mac で描いた PNG をアップロードして source にする
                var uploaded: [Int] = [], replaced: [Int] = []
                do {
                    for i in overlay.indices where overlay[i].isText && (overlay[i].needsRender || overlay[i].assetId == nil) {
                        let st = overlay[i].textStyle!
                        guard let r = TextRenderer.render(st, w: overlay[i].w, h: overlay[i].h) else { throw MixerAPI.APIError.offline("文字を描画できませんでした") }
                        let name = "\(Self.textPrefix)\(Int(Date().timeIntervalSince1970 * 1000))-\(i).png"
                        let res = try await m.api.uploadAsset(type: "image", fileName: name, data: r.png, contentType: "image/png")
                        guard let nid = res["id"] as? Int else { throw MixerAPI.APIError.offline("アップロード結果に id がありません") }
                        uploaded.append(nid)
                        if let old = overlay[i].assetId { replaced.append(old) }
                        overlay[i].assetId = nid
                        overlay[i].image = r.image
                        overlay[i].needsRender = false
                        overlay[i].raw["textProperties"] = st.json(merging: overlay[i].raw["textProperties"] as? [String: Any], fontSize: r.fontSize)
                    }
                    let cfg = overlay.map(\.json)
                    let ids = Array(Set(overlay.flatMap(\.usedAssetIds))).sorted()
                    try await m.api.call("PATCH", "/overlays/\(overlayId)",
                                         ["assetConfig": cfg, "assetIdArr": ids, "sender": "livemixdesktop"])
                    m.log("scene \(sceneId) overlay \(overlayId): \(overlay.count) item(s), assets \(ids), text uploaded \(uploaded)")
                } catch {
                    for id in uploaded { _ = try? await m.api.call("DELETE", "/assets/\(id)") }   // 失敗したら今回の分を片付ける
                    throw error
                }
                await cleanupTextAssets(replaced)
            }
            // 本体のシーン設定は「下書き (PATCH) → 確定 (commit)」。確定しないと再起動や revoke で消える (2026-11-25 実機確認)
            try await m.api.call("POST", "/scenes/\(sceneId)/commit", ["sender": "livemixdesktop"])
            m.log("scene \(sceneId) committed")
            await load(sceneId)
            message = sceneId == m.pgm
                ? "シーン \(sceneId) に適用して確定しました。Program に出ている映像に変化がなければ、一度別のシーンに切り替えて戻してください"
                : "シーン \(sceneId) に適用して確定しました"
        } catch { message = "適用できませんでした: \(error)" }
    }

    func change(_ f: () -> Void) { recordUndo(); f(); dirty = true }


    // MARK: 元に戻す / やり直す (⌘Z / ⇧⌘Z)
    // 変更の直前の状態を積む。ドラッグやスライダーの連続した変更は 0.6 秒以内なら 1 回分にまとめる
    struct Snapshot {
        var windows: [LayoutWindow], overlay: [OverlayLayer]
        var bgColor: Color, bgUseColor: Bool, bgAssetId: Int?
        var selected: UUID?, selectedOverlay: UUID?, overlayDirty: Bool
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastRecord = Date.distantPast
    @Published var canUndo = false
    @Published var canRedo = false

    private func snapshot() -> Snapshot {
        Snapshot(windows: windows, overlay: overlay, bgColor: bgColor, bgUseColor: bgUseColor, bgAssetId: bgAssetId,
                 selected: selected, selectedOverlay: selectedOverlay, overlayDirty: overlayDirty)
    }
    private func restore(_ s: Snapshot) {
        windows = s.windows; overlay = s.overlay
        bgColor = s.bgColor; bgUseColor = s.bgUseColor; bgAssetId = s.bgAssetId
        selected = s.selected; selectedOverlay = s.selectedOverlay; overlayDirty = s.overlayDirty
    }
    private func updateUndoFlags() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }

    func recordUndo() {
        let now = Date()
        if now.timeIntervalSince(lastRecord) > 0.6 {
            undoStack.append(snapshot())
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        lastRecord = now
        redoStack.removeAll()
        updateUndoFlags()
    }
    /// 次の変更を、直前の変更とまとめずに 1 回分として記録させる (ドラッグの開始時など)
    func breakUndoGroup() { lastRecord = .distantPast }

    func undo() {
        guard !busy, let s = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(s)
        lastRecord = .distantPast
        dirty = !undoStack.isEmpty   // 読み込んだ時の状態まで戻したら未変更
        updateUndoFlags()
    }
    func redo() {
        guard !busy, let s = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(s)
        lastRecord = .distantPast
        dirty = true
        updateUndoFlags()
    }

    // MARK: キャンバス上の選択・移動
    enum Item: Hashable { case window(UUID), overlay(UUID), background }
    @Published var bgSelected = false

    var selectedItem: Item? {
        if let s = selected { return .window(s) }
        if let o = selectedOverlay { return .overlay(o) }
        return bgSelected ? .background : nil
    }
    func select(_ it: Item?) {
        switch it {
        case .window(let id): selected = id; selectedOverlay = nil; bgSelected = false
        case .overlay(let id): selectedOverlay = id; selected = nil; bgSelected = false
        case .background: selected = nil; selectedOverlay = nil; bgSelected = true
        case nil: selected = nil; selectedOverlay = nil; bgSelected = false
        }
    }
    /// 画面に対する比率の矩形
    func rect(_ it: Item) -> CGRect? {
        switch it {
        case .window(let id): return windows.first { $0.id == id }.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        case .overlay(let id): return overlay.first { $0.id == id }.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        case .background: return nil
        }
    }
    func minSize(_ it: Item) -> Double { if case .window = it { return 0.05 }; return 0.03 }

    /// 位置・大きさを変える (画面からはみ出さないよう収める)
    func setRect(_ it: Item, _ r0: CGRect) {
        let mn = minSize(it)
        var r = r0
        r.size.width = min(max(r.width, mn), 1); r.size.height = min(max(r.height, mn), 1)
        r.origin.x = min(max(r.minX, 0), 1 - r.width); r.origin.y = min(max(r.minY, 0), 1 - r.height)
        func q(_ v: Double, _ full: Double) -> Double { (v * full).rounded() / full }   // 出力の 1 画素単位にそろえる
        switch it {
        case .window(let id):
            guard let b = binding(id) else { return }
            var v = b.wrappedValue
            v.x = q(r.minX, 1920); v.y = q(r.minY, 1080); v.w = q(r.width, 1920); v.h = q(r.height, 1080)
            b.wrappedValue = v
        case .overlay(let id):
            guard let b = overlayBinding(id) else { return }
            var v = b.wrappedValue
            v.x = q(r.minX, 1920); v.y = q(r.minY, 1080); v.w = q(r.width, 1920); v.h = q(r.height, 1080)
            b.wrappedValue = v
        case .background: break
        }
    }

    /// 点 (比率) の下にあるものを手前から順に。オーバーレイ (表示中) → ウインドウ
    func hits(at p: CGPoint) -> [Item] {
        let ov = overlay.reversed().filter { $0.visible && CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h).contains(p) }.map { Item.overlay($0.id) }
        let wn = windows.reversed().filter { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h).contains(p) }.map { Item.window($0.id) }
        return ov + wn
    }

    /// 矢印キー: 移動 (option で大きさ)。step は出力の画素数
    func nudge(dx: Int, dy: Int, resize: Bool) {
        guard !busy, let it = selectedItem, var r = rect(it) else { return }
        if resize { r.size.width += Double(dx) / 1920; r.size.height += Double(dy) / 1080 }
        else { r.origin.x += Double(dx) / 1920; r.origin.y += Double(dy) / 1080 }
        setRect(it, r)
    }

    func deleteSelected() {
        guard !busy else { return }
        switch selectedItem {
        case .window(let id): remove(id)
        case .overlay(let id): removeOverlay(id)
        case .background, nil: break
        }
    }

    // MARK: レイヤーの並べ替え (一覧は上ほど手前 = 配列の逆順)
    func moveWindowLayers(from: IndexSet, to: Int) {
        change {
            var rev = Array(windows.reversed()); rev.move(fromOffsets: from, toOffset: to)
            windows = Array(rev.reversed())
        }
    }
    func moveOverlayLayers(from: IndexSet, to: Int) {
        change {
            var rev = Array(overlay.reversed()); rev.move(fromOffsets: from, toOffset: to)
            overlay = Array(rev.reversed()); overlayDirty = true
        }
    }

    // MARK: 吸着 (スナップ)
    struct Guide: Hashable { let vertical: Bool; let pos: Double }
    @Published var guides: [Guide] = []

    /// 吸着の候補線: 画面の端・中央と、ほかのウインドウ・オーバーレイの端・中央
    private func snapLines(excluding it: Item) -> (xs: [Double], ys: [Double]) {
        var xs: [Double] = [0, 0.5, 1], ys: [Double] = [0, 0.5, 1]
        let others = windows.filter { Item.window($0.id) != it }.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            + overlay.filter { $0.visible && Item.overlay($0.id) != it }.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        for o in others { xs += [o.minX, o.midX, o.maxX]; ys += [o.minY, o.midY, o.maxY] }
        return (xs, ys)
    }
    private func bestSnap(_ edges: [Double], _ lines: [Double], _ tol: Double) -> (delta: Double, line: Double)? {
        var best: (Double, Double)?
        for e in edges { for l in lines where abs(l - e) <= tol && abs(l - e) < abs(best?.0 ?? .infinity) { best = (l - e, l) } }
        return best
    }
    /// 移動中の矩形を候補線に寄せる。tol は比率 (画面上の数 px 分)
    func snapMove(_ r: CGRect, _ it: Item, tolX: Double, tolY: Double) -> CGRect {
        let (xs, ys) = snapLines(excluding: it)
        var out = r; var g: [Guide] = []
        if let s = bestSnap([r.minX, r.midX, r.maxX], xs, tolX) { out.origin.x += s.delta; g.append(Guide(vertical: true, pos: s.line)) }
        if let s = bestSnap([r.minY, r.midY, r.maxY], ys, tolY) { out.origin.y += s.delta; g.append(Guide(vertical: false, pos: s.line)) }
        guides = g
        return out
    }
    /// 右下の角で大きさを変えている矩形を候補線に寄せる
    func snapResize(_ r: CGRect, _ it: Item, tolX: Double, tolY: Double) -> CGRect {
        let (xs, ys) = snapLines(excluding: it)
        var out = r; var g: [Guide] = []
        if let s = bestSnap([r.maxX], xs, tolX) { out.size.width += s.delta; g.append(Guide(vertical: true, pos: s.line)) }
        if let s = bestSnap([r.maxY], ys, tolY) { out.size.height += s.delta; g.append(Guide(vertical: false, pos: s.line)) }
        guides = g
        return out
    }

    /// シーンを切り替える。未適用の変更があれば確認を出す
    func requestScene(_ n: Int) {
        guard n != sceneId else { return }
        if dirty { pendingScene = n } else { Task { await load(n) } }
    }

    /// 確認ダイアログの答え
    func resolvePending(apply doApply: Bool) {
        guard let n = pendingScene else { return }
        pendingScene = nil
        Task {
            if doApply {
                await apply()
                guard !dirty else { return }   // 適用に失敗したら移動しない
            }
            await load(n)
        }
    }

    /// シーン名を変える (本体の scenes/:id name。確定まで行う)
    func renameScene() {
        let name = nameEdit.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != (m.sceneNames[sceneId] ?? "") else { return }
        let id = sceneId
        Task {
            busy = true; defer { busy = false }
            do {
                try await m.api.call("PATCH", "/scenes/\(id)", ["name": name, "sender": "livemixdesktop"])
                try await m.api.call("POST", "/scenes/\(id)/commit", ["sender": "livemixdesktop"])
                m.sceneNames[id] = name
                m.log("scene \(id) renamed: \(name)")
                message = "シーン \(id) の名前を「\(name)」にしました"
            } catch { message = "名前を変えられませんでした: \(error)" }
        }
    }

    /// このアプリが作った文字画像のファイル名の頭
    static let textPrefix = "LiveMixDesktopText-"

    /// 描き直しで使われなくなった文字画像を削除する。
    /// このアプリが作ったもの (textPrefix) で、どのオーバーレイ・レイアウトからも参照されていないものだけ。
    /// OnAir が作った画像は残す (画像アセット画面で手動削除)。
    private func cleanupTextAssets(_ ids: [Int]) async {
        guard !ids.isEmpty,
              let ov = (try? await m.api.call("GET", "/overlays") as? [String: Any])?["overlays"] as? [[String: Any]],
              let ls = (try? await m.api.call("GET", "/layouts") as? [String: Any])?["layouts"] as? [[String: Any]]
        else { return }
        var used = Set<Int>()
        for o in ov {
            used.formUnion(o["assetIdArr"] as? [Int] ?? [])
            for c in o["assetConfig"] as? [[String: Any]] ?? [] {
                if let s = (c["properties"] as? [String: Any])?["source"] as? Int { used.insert(s) }
            }
        }
        for l in ls { if let b = l["bgAssetId"] as? Int { used.insert(b) } }
        for id in ids where !used.contains(id) {
            guard let a = try? await m.api.call("GET", "/assets/\(id)") as? [String: Any],
                  (a["name"] as? String ?? "").hasPrefix(Self.textPrefix) else { continue }
            if (try? await m.api.call("DELETE", "/assets/\(id)")) != nil { m.log("text asset \(id) removed (replaced)") }
        }
    }

    // MARK: 型 (プリセット)
    func presetFull(_ s: (label: String, src: Int, alt: Bool)) {
        change { windows = [LayoutWindow(src: s.src, alt: s.alt, x: 0, y: 0, w: 1, h: 1, z: 1)]; selected = windows.last?.id }
    }

    func presetPiP(main: (label: String, src: Int, alt: Bool), sub: (label: String, src: Int, alt: Bool)) {
        change {
            windows = [LayoutWindow(src: main.src, alt: main.alt, x: 0, y: 0, w: 1, h: 1, z: 1),
                       LayoutWindow(src: sub.src, alt: sub.alt, x: 0.64, y: 0.64, w: 0.33, h: 0.33, z: 2)]
            selected = windows.last?.id
        }
    }

    func presetSplit(left: (label: String, src: Int, alt: Bool), right: (label: String, src: Int, alt: Bool)) {
        change {
            windows = [LayoutWindow(src: left.src, alt: left.alt, x: 0, y: 0.25, w: 0.5, h: 0.5, z: 1),
                       LayoutWindow(src: right.src, alt: right.alt, x: 0.5, y: 0.25, w: 0.5, h: 0.5, z: 2)]
            selected = windows.last?.id
        }
    }

    func presetEmpty() { change { windows = []; selected = nil } }

    func addWindow() {
        change {
            windows.append(LayoutWindow(src: 1, alt: false, x: 0.3, y: 0.3, w: 0.4, h: 0.4, z: Double(windows.count + 1)))
            selected = windows.last?.id
        }
    }

    func remove(_ id: UUID) { change { windows.removeAll { $0.id == id }; selected = windows.last?.id } }

    func move(_ id: UUID, by delta: Int) {
        guard let i = windows.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard windows.indices.contains(j) else { return }
        change { windows.swapAt(i, j) }
    }

    func binding(_ id: UUID) -> Binding<LayoutWindow>? {
        guard windows.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.windows.first { $0.id == id } ?? LayoutWindow(src: 1, alt: false, x: 0, y: 0, w: 1, h: 1, z: 1) },
                       set: { nv in if let i = self.windows.firstIndex(where: { $0.id == id }), self.windows[i] != nv { self.recordUndo(); self.windows[i] = nv; self.dirty = true } })
    }
}

// MARK: - 画面

struct SceneEditorView: View {
    @EnvironmentObject var m: MixerModel
    @EnvironmentObject var ed: SceneEditorModel
    @StateObject private var keys = EditorKeys()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConnectionBanner()
            sceneTabs
            SceneToolsBar()
            HStack(spacing: 6) {
                Text("名前").font(.caption)
                TextField("", text: $ed.nameEdit).textFieldStyle(.roundedBorder).frame(width: 180).font(.caption)
                    .onSubmit { ed.renameScene() }
                Button("名前を変更") { ed.renameScene() }.controlSize(.small)
                    .disabled(ed.busy || ed.nameEdit.trimmingCharacters(in: .whitespaces).isEmpty || ed.nameEdit == (m.sceneNames[ed.sceneId] ?? ""))
                if ed.dirty {
                    Label("未適用の変更があります", systemImage: "pencil.circle.fill").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            if ed.sceneId == m.pgm {
                Label("このシーンは Program (番組出力) に出ています。適用した内容が映像に出ないときは、一度別のシーンに切り替えて戻してください",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    LayoutCanvas()
                    presets
                }
                .frame(minWidth: 440, maxWidth: .infinity)
                LayerList().frame(width: 210)
                ScrollView { LayerInspector().padding(10) }
                    .frame(width: 270)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            .disabled(ed.busy)   // 読み込み・適用の途中に触った変更は消えるので、その間は編集させない
            HStack {
                if let msg = ed.message { Text(msg).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if ed.busy { ProgressView().controlSize(.small) }
                Button { ed.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!ed.canUndo || ed.busy).help("元に戻す (⌘Z)")
                Button { ed.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!ed.canRedo || ed.busy).help("やり直す (⇧⌘Z)")
                Button("変更を破棄") { Task { await ed.load(ed.sceneId) } }.disabled(!ed.dirty || ed.busy)
                    .help("まだ適用していない変更を捨てて、本体の今の設定を読み直します")
                Button("適用") { Task { await ed.apply() } }
                    .disabled(!ed.dirty || ed.busy)   // Return では送らない (数値欄の確定で誤って本体に送るため)
                    .help("本体に送って確定します (⌘S)")
                Button("") { Task { await ed.apply() } }.keyboardShortcut("s", modifiers: .command)
                    .disabled(!ed.dirty || ed.busy).opacity(0).frame(width: 0)
            }
        }
        .padding(14)
        .frame(minWidth: 960, minHeight: 640)
        .onAppear {
            m.startPolling(); keys.install(ed)
            if !ed.dirty { Task { await ed.load(ed.sceneId) } }   // 未適用の変更は閉じても残す
        }
        .onDisappear { m.stopPolling(); keys.remove() }
        .alert("シーン \(ed.sceneId) の変更は未適用です", isPresented: Binding(get: { ed.pendingScene != nil }, set: { if !$0 { ed.pendingScene = nil } })) {
            Button("適用して移動") { ed.resolvePending(apply: true) }
            Button("破棄して移動", role: .destructive) { ed.resolvePending(apply: false) }
            Button("キャンセル", role: .cancel) { ed.pendingScene = nil }
        } message: {
            Text("シーン \(ed.pendingScene ?? 0) に移る前に、今の変更をどうしますか?")
        }
    }

    private var sceneTabs: some View {
        HStack(spacing: 4) {
            Text("シーン").font(.subheadline.bold())
            ForEach(1...8, id: \.self) { n in
                Button {
                    ed.requestScene(n)
                } label: {
                    VStack(spacing: 0) {
                        Text("\(n)").font(.callout.monospacedDigit().bold())
                        Text(m.sceneNames[n] ?? "Scene \(n)").font(.system(size: 9)).lineLimit(1)
                    }
                    .frame(width: 64, height: 32)
                    .background(RoundedRectangle(cornerRadius: 5).fill(n == ed.sceneId ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(n == m.pgm ? .red : n == m.prv ? .green : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .disabled(ed.busy)
                .help(n == m.pgm ? "Program (番組出力) に出ています" : n == m.prv ? "Preview に出ています" : "")
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) { RoundedRectangle(cornerRadius: 2).strokeBorder(.red, lineWidth: 2).frame(width: 10, height: 8); Text("PGM").font(.caption2) }
                HStack(spacing: 3) { RoundedRectangle(cornerRadius: 2).strokeBorder(.green, lineWidth: 2).frame(width: 10, height: 8); Text("PRV").font(.caption2) }
            }
            .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var presets: some View {
        let s = LayoutWindow.sources
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("全画面").font(.caption).frame(width: 52, alignment: .leading)
                ForEach(s, id: \.label) { src in Button(src.label) { ed.presetFull(src) } }
                Button("背景のみ") { ed.presetEmpty() }
            }
            HStack(spacing: 4) {
                Text("PiP").font(.caption).frame(width: 52, alignment: .leading)
                Button("HDMI1 + 2A") { ed.presetPiP(main: s[0], sub: s[1]) }
                Button("2A + HDMI1") { ed.presetPiP(main: s[1], sub: s[0]) }
            }
            HStack(spacing: 4) {
                Text("左右").font(.caption).frame(width: 52, alignment: .leading)
                Button("HDMI1 | 2A") { ed.presetSplit(left: s[0], right: s[1]) }
                Button("2A | HDMI1") { ed.presetSplit(left: s[1], right: s[0]) }
            }
        }
        .controlSize(.small)
    }
}

/// 16:9 のキャンバスに配置を描く。
/// クリックで選択 (同じ場所をもう一度クリックすると下に重なった物へ)・ドラッグで移動・右下の角で大きさ。
/// ドラッグ中は画面の端・中央やほかの枠に吸着 (option で吸着なし)、角のドラッグで shift を押すと縦横比を保つ
struct LayoutCanvas: View {
    @EnvironmentObject var m: MixerModel
    @EnvironmentObject var ed: SceneEditorModel

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack(alignment: .topLeading) {
                if ed.bgUseColor {
                    Rectangle().fill(ed.bgColor)
                } else if let id = ed.bgAssetId, let img = ed.imageForAsset(id) {
                    Image(nsImage: img).resizable().frame(width: W, height: H)
                } else {
                    Rectangle().fill(Color.black)
                    Text("背景画像を選んでください").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(ed.windows) { win in windowView(win, W: W, H: H) }
                ForEach(ed.overlay) { o in overlayView(o, W: W, H: H) }
                if ed.windows.isEmpty {
                    Text("背景のみ").font(.caption).foregroundStyle(.white.opacity(0.6))
                        .frame(width: W, height: H).allowsHitTesting(false)
                }
                ForEach(ed.guides, id: \.self) { g in
                    Path { p in
                        if g.vertical { p.move(to: CGPoint(x: g.pos * W, y: 0)); p.addLine(to: CGPoint(x: g.pos * W, y: H)) }
                        else { p.move(to: CGPoint(x: 0, y: g.pos * H)); p.addLine(to: CGPoint(x: W, y: g.pos * H)) }
                    }
                    .stroke(Color.pink, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)
                }
                if let it = ed.selectedItem, let r = ed.rect(it) {
                    Text(String(format: "X %.0f  Y %.0f   %.0f × %.0f px", r.minX * 1920, r.minY * 1080, r.width * 1920, r.height * 1080))
                        .font(.caption2.monospacedDigit()).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.6)).foregroundStyle(.white)
                        .frame(width: W, height: H, alignment: .bottomLeading).allowsHitTesting(false)
                }
            }
            .frame(width: W, height: H)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in dragChanged(g, W: W, H: H) }
                .onEnded { g in dragEnded(g, W: W, H: H) })
            .clipped()
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.3)))
    }

    private func thumb(_ key: String) -> NSImage? { m.thumbs.first { $0.label == key }?.image }

    // MARK: ドラッグ
    private func dragChanged(_ g: DragGesture.Value, W: Double, H: Double) {
        let d = CanvasDrag.shared
        if !d.active {
            d.active = true; d.moved = false; d.item = nil; d.mode = .none
            // 文字入力欄からカーソルを外す (矢印キーをキャンバスの操作に使えるように。入力中の数値も確定される)
            if let w = NSApp.keyWindow, w.firstResponder is NSText { w.makeFirstResponder(nil) }
            let p = CGPoint(x: g.startLocation.x / W, y: g.startLocation.y / H)
            if let sel = ed.selectedItem, let r = ed.rect(sel) {
                if abs(g.startLocation.x - r.maxX * W) <= 9 && abs(g.startLocation.y - r.maxY * H) <= 9 {
                    d.mode = .resize; d.item = sel; d.start = r; d.wasSelected = true
                } else if r.contains(p) {
                    d.mode = .move; d.item = sel; d.start = r; d.wasSelected = true
                }
            }
            if d.item == nil {
                if let top = ed.hits(at: p).first, let r = ed.rect(top) {
                    ed.select(top); d.mode = .move; d.item = top; d.start = r; d.wasSelected = false
                } else {
                    ed.select(.background)   // 何もない所 = 背景
                }
            }
            ed.breakUndoGroup()   // 1 回のドラッグを 1 回分の「元に戻す」にする
        }
        guard let it = d.item, d.mode != .none else { return }
        if !d.moved && hypot(g.translation.width, g.translation.height) < 3 { return }
        d.moved = true
        let flags = NSEvent.modifierFlags
        let tolX = 7 / W, tolY = 7 / H   // 画面上 7px 以内なら吸着
        var r = d.start
        switch d.mode {
        case .move:
            r.origin.x = min(max(r.minX + g.translation.width / W, 0), 1 - r.width)
            r.origin.y = min(max(r.minY + g.translation.height / H, 0), 1 - r.height)
            if flags.contains(.option) { ed.guides = [] } else { r = ed.snapMove(r, it, tolX: tolX, tolY: tolY) }
        case .resize:
            let mn = ed.minSize(it)
            r.size.width = min(max(d.start.width + g.translation.width / W, mn), 1 - r.minX)
            r.size.height = min(max(d.start.height + g.translation.height / H, mn), 1 - r.minY)
            if flags.contains(.shift) {
                // 縦横比を保つ (はみ出すときは小さい方に合わせる)
                let a = d.start.height / max(d.start.width, 0.0001)
                var w = r.width
                if w * a > 1 - r.minY { w = (1 - r.minY) / a }
                r.size.width = w; r.size.height = w * a
                ed.guides = []
            } else if flags.contains(.option) {
                ed.guides = []
            } else {
                r = ed.snapResize(r, it, tolX: tolX, tolY: tolY)
            }
        case .none: break
        }
        ed.setRect(it, r)
    }

    private func dragEnded(_ g: DragGesture.Value, W: Double, H: Double) {
        let d = CanvasDrag.shared
        // 選択中の物の上を動かさずにクリック → 下に重なっている物を順に選ぶ
        if !d.moved, d.wasSelected, d.mode == .move, let it = d.item {
            let hs = ed.hits(at: CGPoint(x: g.startLocation.x / W, y: g.startLocation.y / H))
            if hs.count > 1, let i = hs.firstIndex(of: it) { ed.select(hs[(i + 1) % hs.count]) }
        }
        d.active = false; d.item = nil; d.mode = .none
        ed.guides = []
    }

    // MARK: 描画 (操作はキャンバス全体のジェスチャーで受ける)
    @ViewBuilder
    private func overlayView(_ o: OverlayLayer, W: Double, H: Double) -> some View {
        let isSel = ed.selectedOverlay == o.id
        Group {
            if let img = o.image {
                switch o.fillMode {
                case 0: Image(nsImage: img).resizable()
                case 2: Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: max(o.w * W, 8), height: max(o.h * H, 8)).clipped()
                default: Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                }
            } else if let t = o.text {
                Text(t).font(.system(size: max(H * o.h * 0.5, 8))).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.3)
            } else {
                Color.white.opacity(0.15)
            }
        }
        .frame(width: max(o.w * W, 8), height: max(o.h * H, 8), alignment: .leading)
        .opacity(o.visible ? (isSel ? 1 : 0.85) : 0.25)
        .overlay(isSel ? Rectangle().strokeBorder(Color.yellow, lineWidth: 2) : nil)
        .overlay(alignment: .bottomTrailing) {
            if isSel { Rectangle().fill(Color.yellow).frame(width: 10, height: 10) }
        }
        .offset(x: o.x * W, y: o.y * H)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func windowView(_ win: LayoutWindow, W: Double, H: Double) -> some View {
        let isSel = ed.selected == win.id
        ZStack {
            if let img = thumb(win.sourceKey) {
                // 切り出し範囲だけを枠いっぱいに見せる
                let fw = max(win.w * W, 8), fh = max(win.h * H, 8), c = win.crop
                Image(nsImage: img).resizable()
                    .frame(width: fw / max(c.width, 0.01), height: fh / max(c.height, 0.01))
                    .offset(x: -c.minX * fw / max(c.width, 0.01), y: -c.minY * fh / max(c.height, 0.01))
                    .frame(width: fw, height: fh, alignment: .topLeading)
                    .clipped()
            } else {
                Color.gray.opacity(0.5)
            }
            Text(win.sourceKey).font(.caption2.bold()).padding(2)
                .background(.black.opacity(0.55)).foregroundStyle(.white)
        }
        .frame(width: max(win.w * W, 8), height: max(win.h * H, 8))
        .overlay(Rectangle().strokeBorder(isSel ? Color.accentColor : Color.white.opacity(0.7), lineWidth: isSel ? 2 : 1))
        .overlay(alignment: .bottomTrailing) {
            if isSel { Rectangle().fill(Color.accentColor).frame(width: 10, height: 10) }
        }
        .offset(x: win.x * W, y: win.y * H)
        .allowsHitTesting(false)
    }
}

/// キャンバスのドラッグ中の状態 (@State が使えないため)
final class CanvasDrag {
    static let shared = CanvasDrag()
    enum Mode { case none, move, resize }
    var active = false, moved = false, wasSelected = false
    var mode = Mode.none
    var item: SceneEditorModel.Item?
    var start = CGRect.zero
}

/// ドラッグ開始時の値を覚えておく (@State が使えないため)。translation は開始点からの移動量
final class DragStore {
    static let shared = DragStore()
    private var starts: [String: (Double, Double)] = [:]
    func start(_ key: String, _ current: (Double, Double)) -> (Double, Double) {
        if let s = starts[key] { return s }
        starts[key] = current
        return current
    }
    func end(_ key: String) { starts.removeValue(forKey: key) }
}

/// レイヤー一覧: オーバーレイ (最前面) → ウインドウ (映像) → 背景。上ほど手前。
/// オーバーレイ同士・ウインドウ同士はドラッグで並べ替えられる (グループをまたぐ移動はできない)
struct LayerList: View {
    @EnvironmentObject var m: MixerModel
    @EnvironmentObject var ed: SceneEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("レイヤー").font(.caption.bold())
                Text("上ほど手前").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                addMenu
                Button { ed.deleteSelected() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled({ if case .window = ed.selectedItem { return false }; if case .overlay = ed.selectedItem { return false }; return true }())
                    .help("選んでいるレイヤーを削除 (delete)")
            }
            List(selection: Binding(get: { ed.selectedItem }, set: { ed.select($0) })) {
                Section("オーバーレイ (文字・画像)") {
                    if ed.overlay.isEmpty {
                        Text("なし").font(.caption2).foregroundStyle(.secondary).selectionDisabled()
                    }
                    ForEach(Array(ed.overlay.reversed())) { o in
                        overlayRow(o).tag(SceneEditorModel.Item.overlay(o.id))
                    }
                    .onMove { ed.moveOverlayLayers(from: $0, to: $1) }
                }
                Section("ウインドウ (映像)") {
                    if ed.windows.isEmpty {
                        Text("なし").font(.caption2).foregroundStyle(.secondary).selectionDisabled()
                    }
                    ForEach(Array(ed.windows.reversed())) { w in
                        windowRow(w).tag(SceneEditorModel.Item.window(w.id))
                    }
                    .onMove { ed.moveWindowLayers(from: $0, to: $1) }
                }
                Section("背景") {
                    bgRow.tag(SceneEditorModel.Item.background)
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 26)
            Text("ドラッグで重なり順を入れ替え").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var addMenu: some View {
        Menu {
            Button { ed.addWindow() } label: { Label("ウインドウ (映像) を追加", systemImage: "rectangle.on.rectangle") }
                .disabled(ed.windows.count >= 4)
            Button { ed.addTextOverlay() } label: { Label("文字を追加", systemImage: "textformat") }
            Menu("画像を追加") {
                if ed.availableImages.isEmpty { Text("画像がありません") }
                ForEach(ed.availableImages, id: \.id) { a in
                    Button { ed.addImageOverlay(assetId: a.id) } label: { Text("\(a.name) (id \(a.id))") }
                }
            }
        } label: { Image(systemName: "plus") }
            .menuStyle(.borderlessButton).frame(width: 28).help("レイヤーを追加")
    }

    private func thumbBox<V: View>(_ v: V) -> some View {
        v.frame(width: 36, height: 20).background(Color.black.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func overlayRow(_ o: OverlayLayer) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { o.visible }, set: { ed.setOverlayVisible(o.id, $0) }))
                .toggleStyle(.checkbox).labelsHidden().help("表示 / 非表示")
            if let img = o.image {
                thumbBox(Image(nsImage: img).resizable().aspectRatio(contentMode: .fit))
            } else {
                thumbBox(Image(systemName: "textformat"))
            }
            Text(o.label).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            if o.coversAll && o.visible {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption2)
                    .help("画面全体を覆います。下の映像が隠れます")
            }
        }
        .opacity(o.visible ? 1 : 0.5)
    }

    private func windowRow(_ w: LayoutWindow) -> some View {
        HStack(spacing: 6) {
            if let img = m.thumbs.first(where: { $0.label == w.sourceKey })?.image {
                thumbBox(Image(nsImage: img).resizable())
            } else {
                thumbBox(Image(systemName: "video").font(.caption2))
            }
            Text(w.sourceKey).font(.caption)
            Spacer(minLength: 0)
            Text(String(format: "%.0f×%.0f%%", w.w * 100, w.h * 100)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var bgRow: some View {
        HStack(spacing: 6) {
            if ed.bgUseColor {
                thumbBox(Rectangle().fill(ed.bgColor))
                Text("色").font(.caption)
            } else {
                if let id = ed.bgAssetId, let img = ed.imageForAsset(id) {
                    thumbBox(Image(nsImage: img).resizable())
                } else {
                    thumbBox(Image(systemName: "photo").font(.caption2))
                }
                Text("画像").font(.caption)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 選んでいるレイヤーの設定 (別枠)
struct LayerInspector: View {
    @EnvironmentObject var ed: SceneEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch ed.selectedItem {
            case .window(let id):
                if let b = ed.binding(id) {
                    title("ウインドウ (映像)", "rectangle.on.rectangle")
                    WindowInspector(win: b, id: id)
                }
            case .overlay(let id):
                if let b = ed.overlayBinding(id) {
                    title(b.wrappedValue.isText ? "オーバーレイ (文字)" : "オーバーレイ (画像)", b.wrappedValue.isText ? "textformat" : "photo")
                    OverlayInspector(ov: b, id: id)
                }
            case .background:
                title("背景", "square.fill")
                BackgroundInspector()
            case nil:
                Text("レイヤーを選ぶと、ここで設定を変えられます").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon).font(.subheadline.bold())
    }
}

/// 背景: 色か画像
struct BackgroundInspector: View {
    @EnvironmentObject var ed: SceneEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("種類", selection: Binding(get: { ed.bgUseColor }, set: { v in ed.change { ed.bgUseColor = v } })) {
                Text("色").tag(true); Text("画像").tag(false)
            }
            .pickerStyle(.segmented).font(.caption)
            if ed.bgUseColor {
                ColorPicker("色", selection: Binding(get: { ed.bgColor }, set: { c in ed.change { ed.bgColor = c } }),
                            supportsOpacity: false).font(.caption)
            } else {
                Text("画像").font(.caption)
                if ed.availableImages.isEmpty { Text("画像がありません (画像の管理で追加)").font(.caption2).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
                    ForEach(ed.availableImages, id: \.id) { a in
                        Button { ed.change { ed.bgAssetId = a.id } } label: {
                            VStack(spacing: 2) {
                                Group {
                                    if let img = a.image { Image(nsImage: img).resizable().aspectRatio(16.0 / 9.0, contentMode: .fit) }
                                    else { Color.gray.opacity(0.3) }
                                }
                                .frame(width: 72, height: 40).background(Color.black.opacity(0.4))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ed.bgAssetId == a.id ? Color.accentColor : .clear, lineWidth: 2))
                                Text("id \(a.id)").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain).help(a.name)
                    }
                }
            }
        }
    }
}

struct OverlayInspector: View {
    @EnvironmentObject var ed: SceneEditorModel
    @Binding var ov: OverlayLayer
    let id: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("名前 (一覧の表示用・空欄で自動)", text: Binding(get: { ov.name ?? "" }, set: { ov.name = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder).font(.caption)
            if !ov.isText {
                Picker("画像", selection: Binding(
                    get: { ov.assetId ?? -1 },
                    set: { newId in
                        ov.assetId = newId
                        if let a = ed.availableImages.first(where: { $0.id == newId }) { ov.assetName = a.name; ov.image = a.image }
                    })) {
                    ForEach(ed.availableImages, id: \.id) { Text("\($0.name) (id \($0.id))").tag($0.id) }
                }
                .font(.caption)
                fillModePicker
            } else {
                TextStyleEditor(style: Binding(get: { ov.textStyle ?? TextStyle() }, set: { ov.textStyle = $0 }))
                if ov.needsRender {
                    Text("「適用」で文字を描いて本体に送ります").font(.caption2).foregroundStyle(.orange)
                }
            }
            slider("左", $ov.x, 0...(1 - ov.w))
            slider("上", $ov.y, 0...(1 - ov.h))
            slider("幅", $ov.w, 0.03...(1 - ov.x))
            slider("高さ", $ov.h, 0.03...(1 - ov.y))
            HStack {
                Button { ov.x = 0; ov.y = 0; ov.w = 1; ov.h = 1 } label: { Text("全画面") }
                Spacer()
                Button(role: .destructive) { ed.removeOverlay(id) } label: { Image(systemName: "trash") }.help("このオーバーレイを外す")
            }
            .controlSize(.small).buttonStyle(.borderless)
        }
    }

    private func slider(_ label: String, _ v: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        RatioRow(label: label, value: v, range: range, full: label == "左" || label == "幅" ? 1920 : 1080)
    }
}

extension OverlayInspector {
    var fillModePicker: some View {
        Picker("表示", selection: $ov.fillMode) {
            Text("全体を収める").tag(1)
            Text("切り抜いて埋める").tag(2)
            Text("引き伸ばす").tag(0)
            Text("原寸").tag(6)
        }
        .font(.caption)
    }
}

/// 文字オーバーレイの内容・見た目。文字の大きさは枠に収まるよう自動 (枠の大きさで調整)
struct TextStyleEditor: View {
    @Binding var style: TextStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("文字", text: $style.text, axis: .vertical)
                .lineLimit(1...3).font(.caption).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Picker("", selection: $style.fontFamily) {
                    ForEach(TextStyle.fonts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().font(.caption)
                Toggle("太字", isOn: $style.bold).toggleStyle(.checkbox).font(.caption2)
            }
            HStack(spacing: 6) {
                Picker("", selection: $style.align) {
                    Image(systemName: "text.alignleft").tag(0)
                    Image(systemName: "text.aligncenter").tag(1)
                    Image(systemName: "text.alignright").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 96)
                Spacer()
                colorWell("文字色", $style.textColor)
            }
            HStack(spacing: 6) {
                Toggle("縁取り", isOn: $style.hasOutline).toggleStyle(.checkbox).font(.caption2)
                if style.hasOutline { colorWell("", $style.outlineColor) }
                Spacer()
                Toggle("背景", isOn: $style.hasBackground).toggleStyle(.checkbox).font(.caption2)
                if style.hasBackground { colorWell("", $style.backgroundColor) }
            }
            if style.hasBackground {
                HStack(spacing: 4) {
                    Text("背景の濃さ").font(.caption2)
                    Slider(value: $style.backgroundOpacity, in: 0.1...1).controlSize(.mini)
                    Text(String(format: "%3.0f%%", style.backgroundOpacity * 100)).font(.caption2.monospacedDigit()).frame(width: 34)
                }
            }
            Text("文字の大きさは枠に合わせて自動で決まります。枠を広げると大きくなります (「適用」で反映)")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func colorWell(_ label: String, _ hex: Binding<String>) -> some View {
        ColorPicker(label, selection: Binding(get: { Color(hex: hex.wrappedValue) }, set: { hex.wrappedValue = $0.hex }),
                    supportsOpacity: false)
            .font(.caption2).fixedSize()
    }
}

struct WindowInspector: View {
    @EnvironmentObject var ed: SceneEditorModel
    @Binding var win: LayoutWindow
    let id: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("入力", selection: Binding(
                get: { win.sourceKey },
                set: { key in
                    if let s = LayoutWindow.sources.first(where: { $0.label == key }) { win.src = s.src; win.alt = s.alt }
                })) {
                ForEach(LayoutWindow.sources, id: \.label) { Text($0.label).tag($0.label) }
            }
            .font(.caption)
            slider("左", $win.x, 0...(1 - win.w))
            slider("上", $win.y, 0...(1 - win.h))
            slider("幅", $win.w, 0.05...(1 - win.x))
            slider("高さ", $win.h, 0.05...(1 - win.y))
            HStack {
                Button { win.h = min(win.w * 1.0, 1 - win.y) } label: { Text("16:9 に合わせる") }
                    .help("幅と同じ比率 (画面と同じ 16:9) にする")
                Spacer()
            }
            .controlSize(.small)
            HStack {
                Spacer()
                Button(role: .destructive) { ed.remove(id) } label: { Image(systemName: "trash") }.help("削除")
            }
            .buttonStyle(.borderless)
            Divider()
            // 枠線
            HStack(spacing: 6) {
                Toggle("枠線", isOn: Binding(get: { win.border != nil },
                                            set: { win.border = $0 ? WinBorder() : nil }))
                    .disabled(win.key != nil).help(win.key != nil ? "クロマキー設定があるウインドウには枠線を付けられません" : "枠線")
                    .toggleStyle(.checkbox).font(.caption2)
                if win.border != nil {
                    ColorPicker("", selection: Binding(get: { Color(hex: win.border!.color) }, set: { win.border?.color = $0.hex }),
                                supportsOpacity: false).labelsHidden()
                    Slider(value: Binding(get: { win.border?.width ?? 0.008 }, set: { win.border?.width = ($0 * 1000).rounded() / 1000 }),
                           in: 0.002...0.03).controlSize(.mini)
                }
            }
            Divider()
            cropSection
            // クロマキー (transparency) は本体に保存はできるが、fw V1.4.136 では映像に効かない (2026-11-25 実機確認)。
            // そのため設定欄は出さない。本体に既にある値は LayoutWindow.key として読み書きで保つ
        }
    }

    private func slider(_ label: String, _ v: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        RatioRow(label: label, value: v, range: range, full: label == "左" || label == "幅" ? 1920 : 1080)
    }

    // MARK: 切り出し (srcMap)。入力映像の上下左右を削り、残りを枠いっぱいに表示する
    private static let minCrop = 0.05
    private var cropSection: some View {
        let c = win.crop
        let left = Binding<Double>(get: { win.crop.minX }, set: { v in
            let r = 1 - win.crop.maxX; win.crop.origin.x = v; win.crop.size.width = 1 - v - r })
        let right = Binding<Double>(get: { 1 - win.crop.maxX }, set: { v in
            win.crop.size.width = 1 - win.crop.minX - v })
        let top = Binding<Double>(get: { win.crop.minY }, set: { v in
            let b = 1 - win.crop.maxY; win.crop.origin.y = v; win.crop.size.height = 1 - v - b })
        let bottom = Binding<Double>(get: { 1 - win.crop.maxY }, set: { v in
            win.crop.size.height = 1 - win.crop.minY - v })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("切り出し").font(.caption.bold())
                Text("入力映像の端を削る").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("元に戻す") { win.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                    .controlSize(.mini).disabled(c == CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            RatioRow(label: "左", value: left, range: 0...max(0, 1 - Self.minCrop - (1 - c.maxX)), full: 1920)
            RatioRow(label: "右", value: right, range: 0...max(0, 1 - Self.minCrop - c.minX), full: 1920)
            RatioRow(label: "上", value: top, range: 0...max(0, 1 - Self.minCrop - (1 - c.maxY)), full: 1080)
            RatioRow(label: "下", value: bottom, range: 0...max(0, 1 - Self.minCrop - c.minY), full: 1080)
            HStack {
                Button("枠の比率に合わせる") { fitCropToFrame() }.controlSize(.mini)
                    .help("映像が縦横に伸び縮みしないよう、枠と同じ比率になるまで切り出し範囲を中央に向けて狭める")
                Spacer()
            }
        }
    }

    /// 枠 (出力上の w×h) と切り出し範囲の比率をそろえる。切り出し範囲の中心は保つ
    private func fitCropToFrame() {
        let frameAspect = (win.w * 1920) / max(win.h * 1080, 1)
        var c = win.crop
        let cropAspect = (c.width * 1920) / max(c.height * 1080, 1)
        if cropAspect > frameAspect {
            let nw = c.height * 1080 * frameAspect / 1920
            c.origin.x += (c.width - nw) / 2; c.size.width = nw
        } else {
            let nh = c.width * 1920 / frameAspect / 1080
            c.origin.y += (c.height - nh) / 2; c.size.height = nh
        }
        win.crop = c
    }
}

// MARK: - 色の変換
extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, opacity: 1)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

/// 位置・大きさの 1 行: スライダー + 出力の画素数 (1920×1080 換算) の数値入力
struct RatioRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let full: Double

    var body: some View {
        let r = range.lowerBound <= range.upperBound ? range : range.lowerBound...range.lowerBound
        HStack(spacing: 4) {
            Text(label).font(.caption2).frame(width: 26, alignment: .leading)
            Slider(value: Binding(get: { min(max(value, r.lowerBound), r.upperBound) },
                                  set: { value = ($0 * full).rounded() / full }), in: r)
                .controlSize(.mini)
            TextField("", value: Binding(get: { Int((value * full).rounded()) },
                                         set: { value = min(max(Double($0) / full, r.lowerBound), r.upperBound) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).font(.caption2.monospacedDigit())
                .multilineTextAlignment(.trailing).frame(width: 48)
                .help("出力 (1920×1080) での画素数。Return で確定")
            Text("px").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// シーン設定ウインドウのキー操作。文字入力中 (テキスト欄にカーソルがある) は横取りしない
///  矢印: 選択中の枠を 4px 移動 (shift で 40px) / option+矢印: 大きさ / delete: 削除 / ⌘Z・⇧⌘Z: 元に戻す・やり直す
final class EditorKeys: ObservableObject {
    private var monitor: Any?

    func install(_ ed: SceneEditorModel) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak ed] e in
            guard let ed, let w = e.window, w.title == "シーン設定", w.attachedSheet == nil,
                  !(w.firstResponder is NSText) else { return e }
            let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
            if f.contains(.command) {
                guard e.charactersIgnoringModifiers?.lowercased() == "z" else { return e }
                if f.contains(.shift) { ed.redo() } else { ed.undo() }
                return nil
            }
            guard !f.contains(.control), ed.selectedItem != nil else { return e }
            let step = f.contains(.shift) ? 40 : 4
            let resize = f.contains(.option)
            switch e.keyCode {
            case 123: ed.nudge(dx: -step, dy: 0, resize: resize)
            case 124: ed.nudge(dx: step, dy: 0, resize: resize)
            case 125: ed.nudge(dx: 0, dy: step, resize: resize)
            case 126: ed.nudge(dx: 0, dy: -step, resize: resize)
            case 51, 117: ed.deleteSelected()
            default: return e
            }
            return nil
        }
    }

    func remove() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
