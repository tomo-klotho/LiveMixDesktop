import AppKit
import SwiftUI

/// シーン 1〜8 の縮小表示 (本番画面のシーンボタン用)。
/// 本体にはシーンの画像を返す API がないので、配置 (layout)・オーバーレイ・背景と入力のサムネイルから Mac 側で組み立てる。
/// 本体に書き込むことはない (読み取りだけ)。
@MainActor
final class SceneThumbsModel: ObservableObject {
    struct Win { var key: String; var rect: CGRect; var crop: CGRect; var z: Double }
    struct Layer { var image: NSImage?; var rect: CGRect; var fillMode: Int; var z: Double }
    struct Spec {
        var bgColor: Color = .black
        var bgImage: NSImage?
        var windows: [Win] = []
        var overlays: [Layer] = []
    }

    @Published private(set) var specs: [Int: Spec] = [:]
    private var assetURL: [Int: String] = [:]
    private var assetCache: [Int: NSImage] = [:]
    private var loading = false
    private var timer: Timer?

    /// 表示中だけ定期的に読み直す (シーン設定の変更や本体での変更に追従)
    func start(api: MixerAPI) {
        Task { await load(api: api) }
        timer?.invalidate()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in await self?.load(api: api) } }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func load(api: MixerAPI) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        if let a = try? await api.call("GET", "/assets") as? [String: Any], let list = a["assets"] as? [[String: Any]] {
            assetURL = [:]
            for x in list where x["type"] as? String == "image" {
                if let id = x["id"] as? Int, let u = x["url"] as? String { assetURL[id] = u }
            }
        }
        var out = specs
        for n in 1...8 {
            guard let sc = try? await api.call("GET", "/scenes/\(n)") as? [String: Any],
                  let l = try? await api.call("GET", "/layouts/\(sc["layoutId"] as? Int ?? n)") as? [String: Any] else { continue }
            var s = Spec()
            if l["isUseColor"] as? Bool ?? true { s.bgColor = Color(hex: l["bgColor"] as? String ?? "#000000") }
            else if let id = l["bgAssetId"] as? Int { s.bgImage = await image(id, api: api) }
            for w in (l["windowInfo"] as? [[String: Any]] ?? []).compactMap(LayoutWindow.init) {
                s.windows.append(Win(key: w.sourceKey, rect: CGRect(x: w.x, y: w.y, width: w.w, height: w.h), crop: w.crop, z: w.z))
            }
            s.windows.sort { $0.z < $1.z }
            if let o = try? await api.call("GET", "/overlays/\(sc["overlayId"] as? Int ?? n)") as? [String: Any] {
                for c in o["assetConfig"] as? [[String: Any]] ?? [] where c["isVisible"] as? Bool ?? true {
                    let p = c["properties"] as? [String: Any] ?? [:]
                    let img: NSImage? = await (p["source"] as? Int).asyncMap { await self.image($0, api: api) } ?? nil
                    s.overlays.append(Layer(image: img,
                                            rect: CGRect(x: p["x"] as? Double ?? 0, y: p["y"] as? Double ?? 0,
                                                         width: p["width"] as? Double ?? 1, height: p["height"] as? Double ?? 1),
                                            fillMode: p["fillMode"] as? Int ?? 1, z: p["z"] as? Double ?? 6))
                }
                s.overlays.sort { $0.z < $1.z }
            }
            out[n] = s
        }
        specs = out
    }

    private func image(_ id: Int, api: MixerAPI) async -> NSImage? {
        if let c = assetCache[id] { return c }
        guard let u = assetURL[id], let path = URL(string: u)?.path,
              let d = try? await api.fetchStatic(path), let im = NSImage(data: d) else { return nil }
        assetCache[id] = im
        return im
    }
}

private extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        guard let v = self else { return nil }
        return await f(v)
    }
}

/// 1 シーン分の縮小表示 (16:9)
struct SceneThumbView: View {
    let spec: SceneThumbsModel.Spec?
    let inputs: [(label: String, image: NSImage?)]

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack(alignment: .topLeading) {
                if let s = spec {
                    if let bg = s.bgImage { Image(nsImage: bg).resizable().frame(width: W, height: H) }
                    else { Rectangle().fill(s.bgColor) }
                    ForEach(Array(s.windows.enumerated()), id: \.offset) { _, w in window(w, W: W, H: H) }
                    ForEach(Array(s.overlays.enumerated()), id: \.offset) { _, o in layer(o, W: W, H: H) }
                } else {
                    Rectangle().fill(Color.black.opacity(0.6))
                }
            }
            .frame(width: W, height: H).clipped()
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    @ViewBuilder private func window(_ w: SceneThumbsModel.Win, W: Double, H: Double) -> some View {
        let fw = max(w.rect.width * W, 1), fh = max(w.rect.height * H, 1), c = w.crop
        Group {
            if let img = inputs.first(where: { $0.label == w.key })?.image {
                Image(nsImage: img).resizable()
                    .frame(width: fw / max(c.width, 0.01), height: fh / max(c.height, 0.01))
                    .offset(x: -c.minX * fw / max(c.width, 0.01), y: -c.minY * fh / max(c.height, 0.01))
                    .frame(width: fw, height: fh, alignment: .topLeading).clipped()
            } else {
                Color.gray.opacity(0.35)
            }
        }
        .frame(width: fw, height: fh)
        .offset(x: w.rect.minX * W, y: w.rect.minY * H)
    }

    @ViewBuilder private func layer(_ o: SceneThumbsModel.Layer, W: Double, H: Double) -> some View {
        let fw = max(o.rect.width * W, 1), fh = max(o.rect.height * H, 1)
        Group {
            if let img = o.image {
                switch o.fillMode {
                case 0: Image(nsImage: img).resizable()
                case 2: Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: fw, height: fh).clipped()
                default: Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                }
            } else { Color.clear }
        }
        .frame(width: fw, height: fh, alignment: .leading)
        .offset(x: o.rect.minX * W, y: o.rect.minY * H)
    }
}
