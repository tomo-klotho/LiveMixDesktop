import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Asset: Identifiable {
    let id: Int
    let name: String
    let type: String        // "image" / "qml" / "font"
    let url: String
    let md5: String
    let datetime: String
    var image: NSImage?
    var loadFailed = false      // 本体から画像を取得できなかった (日本語のファイル名など)
    var usedBy: [String] = []   // 使っているシーン名
    var isSystem: Bool { type != "image" }   // qml/font は本体の部品
    var deletable: Bool { !isSystem && usedBy.isEmpty }

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? Int, let name = d["name"] as? String else { return nil }
        self.id = id; self.name = name
        type = d["type"] as? String ?? "?"
        url = d["url"] as? String ?? ""
        md5 = d["md5"] as? String ?? ""
        datetime = d["datetime"] as? String ?? ""
    }
}

@MainActor
final class AssetsModel: ObservableObject {
    @Published var assets: [Asset] = []
    @Published var loading = false
    @Published var busy = false
    @Published var message: String?
    @Published var selected: Int?
    @Published var confirmDelete: Asset?

    private let m: MixerModel
    init(model: MixerModel) { m = model }

    func load() async {
        loading = true; defer { loading = false }
        do {
            guard let d = try await m.api.call("GET", "/assets") as? [String: Any],
                  let list = d["assets"] as? [[String: Any]] else { return }
            var items = list.compactMap(Asset.init)
            let usage = try await usageMap()
            for i in items.indices {
                items[i].usedBy = usage[items[i].id] ?? []
            }
            assets = items
            await loadImages()
            message = nil
        } catch { message = "読み込めませんでした: \(describe(error))" }
    }

    /// 各アセット id が、どのシーンで使われているかを調べる
    /// (overlay の assetIdArr / properties.source、layout の bgAssetId)
    private func usageMap() async throws -> [Int: [String]] {
        var scenesOf: [Int: [Int]] = [:]   // layoutId/overlayId → scene 番号は scenes から引く
        var out: [Int: Set<String>] = [:]
        let scenes = (try await m.api.call("GET", "/scenes") as? [String: Any])?["scenes"] as? [[String: Any]] ?? []
        let layouts = (try await m.api.call("GET", "/layouts") as? [String: Any])?["layouts"] as? [[String: Any]] ?? []
        let overlays = (try await m.api.call("GET", "/overlays") as? [String: Any])?["overlays"] as? [[String: Any]] ?? []
        let layoutBg = Dictionary(uniqueKeysWithValues: layouts.compactMap { l -> (Int, Int)? in
            guard let id = l["id"] as? Int, let bg = l["bgAssetId"] as? Int else { return nil }
            return (id, bg)
        })
        func overlayAssets(_ i: Int) -> [Int] {
            guard overlays.indices.contains(i) else { return [] }
            let o = overlays[i]
            var ids = (o["assetIdArr"] as? [Int]) ?? []
            for c in o["assetConfig"] as? [[String: Any]] ?? [] {
                if let s = (c["properties"] as? [String: Any])?["source"] as? Int { ids.append(s) }
            }
            return ids
        }
        _ = scenesOf
        for (i, sc) in scenes.enumerated() {
            let name = sc["name"] as? String ?? "Scene \(i + 1)"
            let num = sc["id"] as? Int ?? i + 1
            if num > 8 { continue }  // 9 以降は本体画面用
            if let lid = sc["layoutId"] as? Int, let bg = layoutBg[lid] { out[bg, default: []].insert(name) }
            if let oid = sc["overlayId"] as? Int {
                // overlayId は 1 始まり、overlays 配列は 0 始まり
                for a in overlayAssets(oid - 1) { out[a, default: []].insert(name) }
            }
        }
        return out.mapValues { $0.sorted() }
    }

    private func loadImages() async {
        for i in assets.indices where assets[i].type == "image" && assets[i].image == nil {
            if let path = URL(string: assets[i].url)?.path, let d = try? await m.api.fetchStatic(path) {
                assets[i].image = NSImage(data: d)
            }
            if assets[i].image == nil { assets[i].loadFailed = true }
        }
    }

    /// 本体は英数字以外のファイル名の画像を配信できない (一覧には出るが URL が 404 になる)。
    /// 送る前に英数字の名前にする。例: 「オーバーレイiPad.png」→「obareiiPad.png」
    static func deviceSafeName(_ name: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        var stem = ns.deletingPathExtension
        stem = stem.applyingTransform(.toLatin, reverse: false) ?? stem
        stem = stem.applyingTransform(.stripDiacritics, reverse: false) ?? stem
        var out = ""
        for ch in stem.unicodeScalars {
            if ch.isASCII, CharacterSet.alphanumerics.contains(ch) || "._-".unicodeScalars.contains(ch) { out.unicodeScalars.append(ch) }
            else if !out.hasSuffix("-") { out += "-" }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if out.isEmpty { out = "image-\(Int(Date().timeIntervalSince1970))" }
        return ext.isEmpty ? out : "\(out).\(ext)"
    }

    // MARK: 追加
    func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .bmp]
        panel.allowsMultipleSelection = true
        panel.message = "シーンに重ねる画像を選んでください (PNG / JPEG / GIF)"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            busy = true; defer { busy = false }
            var ok = 0
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let ct = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
                do {
                    try await m.api.uploadAsset(type: "image", fileName: Self.deviceSafeName(url.lastPathComponent), data: data, contentType: ct)
                    ok += 1
                } catch { message = "「\(url.lastPathComponent)」を追加できませんでした: \(describe(error))" }
            }
            if ok > 0 {
                m.log("assets: uploaded \(ok) image(s)")
                await load()
                await m.editor.refreshAssetList()   // シーン設定の画像一覧にも反映
                if message == nil { message = "\(ok) 件の画像を追加しました" }
            }
        }
    }

    // MARK: 削除
    func delete(_ asset: Asset) {
        Task {
            busy = true; defer { busy = false }
            do {
                try await m.api.call("DELETE", "/assets/\(asset.id)")
                m.log("assets: deleted id \(asset.id) (\(asset.name))")
                await load()
                await m.editor.refreshAssetList()
                message = "「\(asset.name)」を削除しました"
            } catch { message = "削除できませんでした: \(describe(error))" }
        }
    }

    func saveToDisk(_ asset: Asset) {
        Task {
            guard let path = URL(string: asset.url)?.path, let data = try? await m.api.fetchStatic(path) else {
                message = "ダウンロードできませんでした"; return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = asset.name
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            try? data.write(to: dest)
            message = "保存しました: \(dest.lastPathComponent)"
        }
    }

    private func describe(_ e: Error) -> String {
        switch e {
        case MixerAPI.APIError.http(let c, let b): return "HTTP \(c): \(b.prefix(100))"
        case MixerAPI.APIError.auth: return "ログインが必要です"
        case MixerAPI.APIError.offline(let m): return m
        default: return "\(e)"
        }
    }
}

struct AssetsView: View {
    @EnvironmentObject var m: MixerModel
    @EnvironmentObject var a: AssetsModel

    private let cols = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(a.assets.filter { $0.type == "image" }) { asset in card(asset) }   // qml/font などの本体の部品は出さない
                }
                .padding(14)
            }
            if let msg = a.message {
                Divider()
                Text(msg).font(.caption).foregroundStyle(.secondary).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .onAppear { Task { await a.load() } }
        .alert("画像を削除", isPresented: Binding(get: { a.confirmDelete != nil }, set: { if !$0 { a.confirmDelete = nil } })) {
            Button("削除", role: .destructive) { if let x = a.confirmDelete { a.delete(x); a.confirmDelete = nil } }
            Button("やめる", role: .cancel) { a.confirmDelete = nil }
        } message: {
            Text("「\(a.confirmDelete?.name ?? "")」を本体から削除します。元に戻せません。")
        }
    }

    private var toolbar: some View {
        HStack {
            Text("画像アセット").font(.headline)
            if a.loading || a.busy { ProgressView().controlSize(.small) }
            Spacer()
            Button { a.addImage() } label: { Label("画像を追加", systemImage: "plus") }
                .disabled(a.busy)
            Button { Task { await a.load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("再読み込み")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func card(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85))
                if let img = asset.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(4)
                } else if asset.loadFailed {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                        Text("本体から取得できません").font(.caption2).foregroundStyle(.secondary)
                    }
                    .help("本体は日本語など英数字以外のファイル名の画像を配信できません。英数字の名前で追加し直してください")
                } else if asset.isSystem {
                    Image(systemName: asset.type == "font" ? "textformat" : "curlybraces")
                        .font(.largeTitle).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 110)
            .overlay(alignment: .topTrailing) {
                Text("id \(asset.id)").font(.caption2.monospaced()).padding(2)
                    .background(.black.opacity(0.5)).foregroundStyle(.white).padding(4)
            }
            Text(asset.name).font(.caption).lineLimit(1).help(asset.name)
            if asset.isSystem {
                Label("本体の部品 (\(asset.type))", systemImage: "lock").font(.caption2).foregroundStyle(.secondary)
            } else if asset.usedBy.isEmpty {
                Text("未使用").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("使用中: \(asset.usedBy.joined(separator: ", "))").font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    .help(asset.usedBy.joined(separator: ", "))
            }
            HStack {
                Button { a.saveToDisk(asset) } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).help("Mac に保存")
                Spacer()
                Button { a.confirmDelete = asset } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(!asset.deletable || a.busy)
                    .help(asset.isSystem ? "本体の部品は削除できません"
                          : asset.usedBy.isEmpty ? "削除" : "シーンで使用中のため削除できません")
            }
            .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
