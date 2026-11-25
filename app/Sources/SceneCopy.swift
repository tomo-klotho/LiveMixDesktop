import AppKit
import SwiftUI

/// シーンの中身 (ウインドウ・背景・オーバーレイ) を本体の JSON の形で持ち運ぶ。
/// コピー/貼り付け・ほかのシーンへの複製・テンプレートに使う。貼り付けは下書きで、「適用」するまで本体には送らない。
struct SceneContent {
    var windowInfo: [[String: Any]]
    var assetConfig: [[String: Any]]
    var bgColor: String
    var isUseColor: Bool
    var bgAssetId: Int?

    var json: [String: Any] {
        var d: [String: Any] = ["windowInfo": windowInfo, "assetConfig": assetConfig, "bgColor": bgColor, "isUseColor": isUseColor]
        if let b = bgAssetId { d["bgAssetId"] = b }
        return d
    }
    init(windowInfo: [[String: Any]], assetConfig: [[String: Any]], bgColor: String, isUseColor: Bool, bgAssetId: Int?) {
        self.windowInfo = windowInfo; self.assetConfig = assetConfig
        self.bgColor = bgColor; self.isUseColor = isUseColor; self.bgAssetId = bgAssetId
    }
    init?(_ d: [String: Any]) {
        guard let w = d["windowInfo"] as? [[String: Any]] else { return nil }
        windowInfo = w
        assetConfig = d["assetConfig"] as? [[String: Any]] ?? []
        bgColor = d["bgColor"] as? String ?? "#000000"
        isUseColor = d["isUseColor"] as? Bool ?? true
        bgAssetId = d["bgAssetId"] as? Int
    }
    var summary: String {
        let t = assetConfig.filter { $0["textProperties"] != nil }.count
        return "ウインドウ \(windowInfo.count)・文字 \(t)・画像 \(assetConfig.count - t)"
    }
}

/// Mac に保存する配置のテンプレート (~/.config/livemixdesktop/scene-templates.json)
struct SceneTemplate: Identifiable {
    let id: UUID
    var name: String
    var created: Date
    var content: SceneContent
}

enum TemplateStore {
    static let file = URL(fileURLWithPath: NSHomeDirectory() + "/.config/livemixdesktop/scene-templates.json")

    static func load() -> [SceneTemplate] {
        guard let d = try? Data(contentsOf: file),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.compactMap { t in
            guard let n = t["name"] as? String, let c = (t["content"] as? [String: Any]).flatMap(SceneContent.init) else { return nil }
            return SceneTemplate(id: UUID(uuidString: t["id"] as? String ?? "") ?? UUID(), name: n,
                                 created: Date(timeIntervalSince1970: t["created"] as? Double ?? 0), content: c)
        }
    }
    static func save(_ list: [SceneTemplate]) throws {
        let arr = list.map { ["id": $0.id.uuidString, "name": $0.name, "created": $0.created.timeIntervalSince1970, "content": $0.content.json] as [String: Any] }
        let d = try JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: file, options: .atomic)
    }
}

extension SceneEditorModel {
    /// 今の編集内容 (未適用の変更も含む)。重なり順は並び順で振り直す
    func captureContent() -> SceneContent {
        var ws = windows
        for i in ws.indices { ws[i].z = Double(i + 1) }
        var ov = overlay
        for i in ov.indices { ov[i].z = Double(6 + i) }
        return SceneContent(windowInfo: ws.map(\.json), assetConfig: ov.map(\.json),
                            bgColor: bgColor.hex, isUseColor: bgUseColor, bgAssetId: bgUseColor ? nil : bgAssetId)
    }

    func copyScene() {
        clipboard = (captureContent(), "シーン \(sceneId)「\(nameEdit)」")
        message = "シーン \(sceneId) をコピーしました。貼り付け先のシーンを開いて「貼り付け」を選んでください"
    }

    /// 中身を今のシーンに下書きとして入れる。layoutOnly ならウインドウの配置だけ (背景・オーバーレイはそのまま)
    func paste(_ c: SceneContent, from label: String, layoutOnly: Bool = false) async {
        await refreshAssetList()   // 消えた画像を確かめるため
        var skipped = 0
        var layers: [OverlayLayer] = []
        if !layoutOnly {
            for cfg in c.assetConfig {
                if let l = await makeLayer(cfg) { layers.append(l) } else { skipped += 1 }
            }
        }
        let ws = c.windowInfo.compactMap(LayoutWindow.init).sorted { $0.z < $1.z }
        var bgMissing = false
        change {
            windows = ws
            if !layoutOnly {
                bgColor = Color(hex: c.bgColor)
                if !c.isUseColor, let a = c.bgAssetId, assetURL[a] == nil { bgUseColor = true; bgMissing = true }
                else { bgUseColor = c.isUseColor; if let a = c.bgAssetId { bgAssetId = a } }
                overlay = layers.sorted { $0.z < $1.z }
                overlayDirty = true
            }
            select(nil)
        }
        var msg = "\(label) を\(layoutOnly ? "配置だけ" : "")貼り付けました。「適用」するまで本体には送りません"
        if skipped > 0 { msg += "(本体にない画像 \(skipped) 個は外しました)" }
        if bgMissing { msg += "(背景画像が本体にないので色にしました)" }
        message = msg
    }

    /// assetConfig 1 項目 → 編集用のレイヤー。文字は貼り付け先で描き直す (シーンごとに別の画像にする)。
    /// 画像が本体に無ければ nil
    private func makeLayer(_ c: [String: Any]) async -> OverlayLayer? {
        let p = c["properties"] as? [String: Any] ?? [:]
        let style = (c["textProperties"] as? [String: Any]).map(TextStyle.init)
        var src = p["source"] as? Int
        if style == nil { guard let s = src, assetURL[s] != nil else { return nil } }
        else { src = nil }
        var raw = c
        if style != nil, var pp = raw["properties"] as? [String: Any] { pp["source"] = nil; raw["properties"] = pp }
        var l = OverlayLayer(textStyle: style, assetId: src, assetName: src.flatMap { assetName[$0] },
                             image: nil,
                             x: p["x"] as? Double ?? 0, y: p["y"] as? Double ?? 0,
                             w: p["width"] as? Double ?? 1, h: p["height"] as? Double ?? 1,
                             z: p["z"] as? Double ?? 6, visible: c["isVisible"] as? Bool ?? true, raw: raw,
                             fillMode: p["fillMode"] as? Int ?? 1, needsRender: style != nil, name: c["lsmixerName"] as? String)
        if let st = style { l.image = TextRenderer.render(st, w: l.w, h: l.h, scale: 0.5)?.image }
        else if let s = src { l.image = await loadAsset(s) }
        return l
    }

    /// 今のシーン (適用済みのもの) をほかのシーンへ複製する。複製先を開いて下書きに入れる
    func duplicate(to n: Int) async {
        guard !dirty, n != sceneId else { return }
        let c = captureContent(), label = "シーン \(sceneId)「\(nameEdit)」"
        await load(n)
        await paste(c, from: label)
    }

    // MARK: テンプレート
    func saveTemplate(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var list = templates
        let t = SceneTemplate(id: UUID(), name: n, created: Date(), content: captureContent())
        if let i = list.firstIndex(where: { $0.name == n }) { list[i] = t } else { list.append(t) }
        do { try TemplateStore.save(list); templates = list; message = "テンプレート「\(n)」を保存しました (Mac に保存。本体には送りません)" }
        catch { message = "テンプレートを保存できませんでした: \(error.localizedDescription)" }
    }
    func deleteTemplate(_ id: UUID) {
        let name = templates.first { $0.id == id }?.name ?? ""
        let list = templates.filter { $0.id != id }
        do { try TemplateStore.save(list); templates = list; m.log("template deleted: \(name)"); message = "テンプレート「\(name)」を削除しました" } catch { message = "削除できませんでした: \(error.localizedDescription)" }
    }

    // MARK: 本体の映像で確認 (Program に出して RTSP モニターで見る)
    /// このシーンを Program に出す (Preview に送って CUT)。前の Program を覚えておき、あとで戻せるようにする
    func showOnProgram() async {
        guard !dirty, sceneId != m.pgm else { return }
        let prev = m.pgm
        checkReturnPreview = m.prv
        busy = true; defer { busy = false }
        do {
            try await cutTo(sceneId)
            checkReturnScene = prev
            m.log("scene \(sceneId) put on PGM for check (was \(prev))")
            message = "シーン \(sceneId) を Program に出しました。確認が済んだら「シーン \(prev) に戻す」を押してください"
        } catch { message = "Program に出せませんでした: \(error)" }
    }
    func returnProgram() async {
        guard let prev = checkReturnScene else { return }
        busy = true; defer { busy = false }
        do {
            if m.pgm != prev { try await cutTo(prev) }
            // Preview も確認前のシーンに戻す (PGM と同じシーンは選べない)
            if let p = checkReturnPreview, p != m.pgm, p != m.prv {
                try await m.api.call("PATCH", "/channels/1", ["sceneId": p, "sender": "livemixdesktop"])
                await m.refresh()
            }
            checkReturnScene = nil; checkReturnPreview = nil
            m.log("PGM returned to scene \(prev)")
            message = "Program をシーン \(prev) に戻しました"
        } catch { message = "戻せませんでした: \(error)" }
    }
    private func cutTo(_ n: Int) async throws {
        if m.prv != n {
            try await m.api.call("PATCH", "/channels/1", ["sceneId": n, "sender": "livemixdesktop"])
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try await m.api.call("POST", "/transition", ["mode": "cut", "sender": "livemixdesktop"])
        try await Task.sleep(nanoseconds: 500_000_000)   // 割り当ては切替完了時に入れ替わる
        await m.refresh()
    }
}

/// シーン設定の「コピー・テンプレート」と「本体で確認」の操作列
struct SceneToolsBar: View {
    @EnvironmentObject var m: MixerModel
    @EnvironmentObject var ed: SceneEditorModel
    @StateObject private var askName = Flag()
    @StateObject private var askProgram = Flag()
    @StateObject private var del = TemplateBox()
    private var confirmDelete: SceneTemplate? { get { del.value } nonmutating set { del.value = newValue } }
    @StateObject private var tname = TextBox()

    private var isLive: Bool { m.broadcast.isLive }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("このシーンをコピー") { ed.copyScene() }
                if let c = ed.clipboard {
                    Button("貼り付け (\(c.label))") { Task { await ed.paste(c.content, from: c.label) } }
                    Button("ウインドウの配置だけ貼り付け") { Task { await ed.paste(c.content, from: c.label, layoutOnly: true) } }
                } else {
                    Button("貼り付け") {}.disabled(true)
                }
                Divider()
                Menu("ほかのシーンへ複製") {
                    ForEach(1...8, id: \.self) { n in
                        Button("\(n)  \(m.sceneNames[n] ?? "Scene \(n)")") { Task { await ed.duplicate(to: n) } }
                            .disabled(n == ed.sceneId)
                    }
                }
                .disabled(ed.dirty)
            } label: { Label("コピー", systemImage: "doc.on.doc") }
            .fixedSize()
            .help(ed.dirty ? "複製は、今の変更を適用か破棄してから使えます" : "シーンの中身をコピー・貼り付け・複製します (貼り付けは適用するまで本体に送りません)")

            Menu {
                Button("今の内容をテンプレートとして保存…") { tname.value = ed.nameEdit; askName.value = true }
                if !ed.templates.isEmpty {
                    Divider()
                    ForEach(ed.templates) { t in
                        Menu("\(t.name)  (\(t.content.summary))") {
                            Button("すべて使う") { Task { await ed.paste(t.content, from: "テンプレート「\(t.name)」") } }
                            Button("ウインドウの配置だけ使う") { Task { await ed.paste(t.content, from: "テンプレート「\(t.name)」", layoutOnly: true) } }
                            Divider()
                            Button("削除…") { confirmDelete = t }
                        }
                    }
                }
            } label: { Label("テンプレート", systemImage: "square.grid.2x2") }
            .fixedSize()
            .help("配置を Mac に保存して、ほかのシーンで使えます")

            Spacer()

            if let prev = ed.checkReturnScene {
                Label("確認中: シーン \(m.pgm) を Program に出しています", systemImage: "eye").font(.caption).foregroundStyle(.orange)
                Button("シーン \(prev) に戻す") { Task { await ed.returnProgram() } }
                    .disabled(ed.busy || m.transitioning)
            }
            Button {
                if ed.sceneId == m.pgm { m.section = .live } else { askProgram.value = true }
            } label: { Label("本体の映像で確認", systemImage: "play.rectangle") }
            .disabled(ed.busy || ed.dirty || isLive || m.conn != .ok)
            .help(isLive ? "配信中は使えません (Program を切り替えると配信に出ます)"
                  : ed.dirty ? "先に「適用」してください (本体は確定した内容を映します)"
                  : "このシーンを Program に出し、Program モニターで実際の映像を見ます")
        }
        .controlSize(.small)
        .alert("テンプレートとして保存", isPresented: $askName.value) {
            TextField("名前", text: $tname.value)
            Button("保存") { ed.saveTemplate(tname.value) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("今の配置 (ウインドウ・背景・オーバーレイ) を Mac に保存します。同じ名前なら上書きします。")
        }
        .alert("テンプレート「\(del.value?.name ?? "")」を削除", isPresented: Binding(get: { del.value != nil }, set: { if !$0 { del.value = nil } })) {
            Button("削除", role: .destructive) { if let t = del.value { ed.deleteTemplate(t.id) }; del.value = nil }
            Button("キャンセル", role: .cancel) { del.value = nil }
        } message: { Text("Mac に保存したテンプレートを削除します。シーンには影響しません。") }
        .alert("シーン \(ed.sceneId) を Program に出す", isPresented: $askProgram.value) {
            Button("出して確認") {
                Task { await ed.showOnProgram(); m.section = .live }
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("今の Program (シーン \(m.pgm)) をシーン \(ed.sceneId) に切り替え、「本番」画面に移ります。そこで「モニターを表示」を押すと映像を見られます。本体につないだモニターの表示も変わります。確認後は「シーン \(m.pgm) に戻す」で戻せます。")
        }
    }
}

final class TextBox: ObservableObject { @Published var value = "" }
final class TemplateBox: ObservableObject { @Published var value: SceneTemplate? }
