import AppKit
import SwiftUI

/// 本体の設定を読み取り専用で一覧表示する
struct SettingsSection: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let paths: [String]

    static let all: [SettingsSection] = [
        .init(id: "system", title: "機器情報", icon: "info.circle", paths: ["/system/info", "/storage"]),
        .init(id: "network", title: "ネットワーク", icon: "network", paths: ["/network/interfaces", "/network/dns", "/network/traffic", "/system/ipinstaller"]),
        .init(id: "streams", title: "配信", icon: "dot.radiowaves.left.and.right", paths: ["/streams", "/streamer/status"]),
        .init(id: "codec", title: "エンコード", icon: "film", paths: ["/codec"]),
        .init(id: "switch", title: "映像切替", icon: "rectangle.on.rectangle", paths: ["/channels", "/transition", "/transition/status", "/scenes"]),
        .init(id: "audio", title: "音声", icon: "speaker.wave.2", paths: ["/audio", "/source/audio"]),
        .init(id: "video", title: "映像入力", icon: "cable.connector", paths: ["/source/video"]),
        .init(id: "layouts", title: "レイアウト", icon: "rectangle.3.group", paths: ["/layouts"]),
        .init(id: "overlays", title: "オーバーレイ", icon: "square.stack", paths: ["/overlays"]),
        .init(id: "assets", title: "アセット", icon: "photo.on.rectangle", paths: ["/assets"]),
    ]
}

struct SettingRow: Identifiable {
    let id = UUID()
    let depth: Int
    let key: String
    let value: String?      // nil なら見出し (オブジェクト / 配列)
    let secret: Bool
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var selection: SettingsSection? = SettingsSection.all.first
    @Published var showSecrets = false
    @Published var showJSON = false
    @Published var results: [String: Result<Any, Error>] = [:]
    @Published var loading = false
    @Published var loadedAt: Date?

    private let m: MixerModel
    init(model: MixerModel) {
        m = model
        if let id = ProcessInfo.processInfo.environment["LMD_SETTINGS_SECTION"] {
            selection = SettingsSection.all.first { $0.id == id } ?? selection
        }
    }

    func load(_ s: SettingsSection?) async {
        guard let s = s else { return }
        loading = true; defer { loading = false }
        for p in s.paths {
            do { results[p] = .success(try await m.api.call("GET", p) ?? [:]) }
            catch { results[p] = .failure(error) }
        }
        loadedAt = Date()
    }

    // MARK: 表示用に平らにする
    func rows(for path: String) -> [SettingRow] {
        guard case .success(let v)? = results[path] else { return [] }
        var out: [SettingRow] = []
        flatten(v, key: nil, depth: 0, into: &out)
        return out
    }

    func json(for path: String) -> String {
        guard case .success(let v)? = results[path],
              let d = try? JSONSerialization.data(withJSONObject: mask(v), options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }

    private func flatten(_ v: Any, key: String?, depth: Int, into out: inout [SettingRow]) {
        if let d = v as? [String: Any] {
            if let k = key { out.append(SettingRow(depth: depth, key: label(k), value: nil, secret: false)) }
            let nd = key == nil ? depth : depth + 1
            for k in d.keys.sorted(by: keyOrder) { flatten(d[k]!, key: k, depth: nd, into: &out) }
        } else if let a = v as? [Any] {
            if a.allSatisfy({ !($0 is [String: Any]) && !($0 is [Any]) }) {
                // 単純な値の配列は 1 行で
                out.append(SettingRow(depth: depth, key: label(key ?? ""), value: a.map(display).joined(separator: ", "), secret: false))
                return
            }
            if let k = key { out.append(SettingRow(depth: depth, key: label(k), value: nil, secret: false)) }
            for (i, e) in a.enumerated() {
                let title = (e as? [String: Any]).flatMap { itemTitle($0) } ?? "#\(i + 1)"
                flatten(e, key: title, depth: key == nil ? depth : depth + 1, into: &out)
            }
        } else if let k = key {
            let secret = isSecret(k, v)
            out.append(SettingRow(depth: depth, key: label(k), value: secret && !showSecrets ? "•••••• (伏せています)" : display(v, key: k),
                                  secret: secret))
        }
    }

    /// 配列の要素の見出し (名前や id があれば使う)
    private func itemTitle(_ d: [String: Any]) -> String? {
        let name = d["name"] as? String ?? d["id"].map { "\($0)" }
        guard let n = name else { return nil }
        if let id = d["id"], d["name"] != nil { return "\(n) (id \(id))" }
        return n
    }

    private func keyOrder(_ a: String, _ b: String) -> Bool {
        let first = ["id", "name", "deviceName", "category", "type", "isEnabled"]
        let ia = first.firstIndex(of: a) ?? 99, ib = first.firstIndex(of: b) ?? 99
        return ia != ib ? ia < ib : a < b
    }

    private func display(_ v: Any) -> String { display(v, key: "") }

    private func display(_ v: Any, key: String) -> String {
        if v is NSNull { return "なし" }
        if let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() { return b ? "はい" : "いいえ" }
        if let n = v as? Int {
            switch key {
            case "gain", "micGain", "inputThreshold": return String(format: "%.2f dB (%d)", Double(n) / 100, n)
            case "pan": return String(format: "%.0f%% (%d)", Double(n) / 100, n)
            case "duration", "delay": return "\(n) ms"
            case "bitrate": return "\(n) kbps"
            case "samplerate": return "\(n) Hz"
            default: return "\(n)"
            }
        }
        if let d = v as? Double { return d == d.rounded() && abs(d) < 1e9 ? String(Int(d)) : String(format: "%.4g", d) }
        if let s = v as? String { return s.isEmpty ? "(空)" : maskString(s) }
        return "\(v)"
    }

    // MARK: 秘密情報の扱い
    private func isSecret(_ key: String, _ v: Any) -> Bool {
        let k = key.lowercased()
        if k.contains("password") || k.contains("authentication") || k.contains("streamkey") || k == "key" {
            return !(v as? String ?? "").isEmpty
        }
        return false
    }

    /// rtmp://host/app/<キー> のキー部分を伏せる
    private func maskString(_ s: String) -> String {
        guard !showSecrets, s.range(of: #"^rtmps?://"#, options: .regularExpression) != nil else { return s }
        guard let r = s.range(of: #"^rtmps?://[^/]+/[^/]*/?"#, options: .regularExpression), r.upperBound < s.endIndex else { return s }
        return String(s[..<r.upperBound]) + "••••••"
    }

    private func mask(_ v: Any) -> Any {
        if showSecrets { return v }
        if let d = v as? [String: Any] {
            var o: [String: Any] = [:]
            for (k, x) in d {
                if isSecret(k, x) { o[k] = "••••••" }
                else if let s = x as? String { o[k] = maskString(s) }
                else { o[k] = mask(x) }
            }
            return o
        }
        if let a = v as? [Any] { return a.map(mask) }
        return v
    }

    // MARK: 項目名の日本語化
    private func label(_ k: String) -> String {
        let t: [String: String] = [
            "deviceName": "機器名", "serialNumber": "シリアル番号", "fwVersion": "ファームウェア", "buildVersion": "ビルド",
            "boardVersion": "基板", "panelVersion": "パネル", "bootType": "起動モード", "statusIdx": "状態番号", "message": "メッセージ",
            "security": "セキュリティ", "USB": "USB ストレージ", "status": "状態", "remainingRecTime": "残り録画時間",
            "formatted": "フォーマット済み", "usability": "使用可否", "capability": "設定範囲",
            "interfaces": "インターフェース", "ip4Addr": "IPv4 アドレス", "ip4Mask": "サブネットマスク", "ip4Gateway": "ゲートウェイ",
            "ip6Addr": "IPv6 アドレス", "ip6Mask": "IPv6 プレフィックス", "ip6Gateway": "IPv6 ゲートウェイ", "macAddr": "MAC アドレス",
            "isPlugged": "ケーブル接続", "mode": "モード", "valid": "選べる値", "value": "値", "servers": "DNS サーバー",
            "traffic": "通信", "trafficIdx": "通信量の段階", "access": "アクセス",
            "streams": "配信の設定", "stream": "配信ごとの状態", "category": "種類", "channelId": "チャンネル", "isEnabled": "有効",
            "destination": "宛先", "authentication": "認証情報", "audioCodecId": "音声コーデック", "videoCodecId": "映像コーデック",
            "egnId": "エンジン", "egnStatus": "エンジン状態", "overallStatusIdx": "全体の状態番号", "overallStatusMsg": "全体の状態",
            "time": "配信時間", "statusMsg": "状態", "recStatusIdx": "録画状態番号", "connQuality": "接続品質", "failCode": "失敗コード",
            "bitrate": "ビットレート", "codec": "コーデック", "config": "共通設定", "tv_format": "TV 方式", "video": "映像",
            "audio": "音声", "profile": "プロファイル", "rateControl": "レート制御", "format": "形式", "qualityRef": "画質の目安",
            "quality": "画質", "level": "レベル", "frameRate": "フレームレート", "keyframes": "キーフレーム間隔", "cropRatio": "切り抜き",
            "resolutionIdx": "解像度番号", "samplerate": "サンプリング周波数", "delay": "遅延",
            "channels": "チャンネル", "sceneId": "シーン", "switchMode": "シーンボタンの動作", "duration": "オート切替の時間",
            "position": "T バー位置", "direction": "向き", "scenes": "シーン", "layoutId": "レイアウト", "overlayId": "オーバーレイ",
            "input": "入力", "output": "出力", "gain": "音量", "pan": "パン", "isMute": "ミュート", "isCompressorEnabled": "コンプレッサー",
            "inputThreshold": "しきい値", "source": "ソース", "isFollowVideo": "映像に連動", "isAudibleOnPgm": "PGM で聞こえる",
            "micGain": "マイクゲイン", "isMicTrackMono": "マイクをモノラル", "address": "ポート", "isEditable": "編集可",
            "isForPad": "iPad 用", "isForPgm": "PGM 用", "isForPrv": "PRV 用", "snapshot": "スナップショット", "altSnapshot": "B 側スナップショット",
            "layouts": "レイアウト", "bgColor": "背景色", "bgAssetId": "背景画像", "isUseColor": "背景色を使う", "group": "グループ",
            "windowInfo": "ウインドウ", "srcId": "入力", "altPort": "HDMI2 B 側", "location": "位置", "srcMap": "切り出し範囲",
            "renderMode": "描画モード", "x_ratio": "左", "y_ratio": "上", "w_ratio": "幅", "h_ratio": "高さ", "z_order": "重なり順",
            "overlays": "オーバーレイ", "assetConfig": "重ねる素材", "assetIdArr": "使うアセット", "isVisible": "表示",
            "properties": "配置", "textProperties": "文字の設定", "textData": "文字", "qmlId": "部品", "assets": "アセット",
            "fileName": "ファイル名", "url": "URL", "datetime": "日時", "md5": "MD5",
        ]
        return t[k] ?? k
    }
}

struct SettingsView: View {
    @EnvironmentObject var s: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.all, selection: $s.selection) { sec in
                Label(sec.title, systemImage: sec.icon).tag(sec)
            }
            .frame(width: 170)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                ScrollView {
                    if let sec = s.selection {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(sec.paths, id: \.self) { p in pathBlock(p) }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .onAppear { Task { await s.load(s.selection) } }
        .onChange(of: s.selection) { _, new in Task { await s.load(new) } }
    }

    private var toolbar: some View {
        HStack {
            Text(s.selection?.title ?? "").font(.headline)
            if s.loading { ProgressView().controlSize(.small) }
            Spacer()
            Toggle("秘密情報を表示", isOn: $s.showSecrets).toggleStyle(.checkbox).font(.caption)
            Toggle("JSON", isOn: $s.showJSON).toggleStyle(.checkbox).font(.caption)
            Button { Task { await s.load(s.selection) } } label: { Image(systemName: "arrow.clockwise") }
                .help("再読み込み")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder
    private func pathBlock(_ p: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("GET /api/v2.0\(p)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("JSON をコピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.json(for: p), forType: .string)
                }
                .controlSize(.small)
            }
            if case .failure(let e)? = s.results[p] {
                Text("取得できませんでした: \(String(describing: e))").font(.caption).foregroundStyle(.red)
            } else if s.showJSON {
                Text(s.json(for: p)).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(s.rows(for: p)) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(r.key)
                                .font(r.value == nil ? .caption.bold() : .caption)
                                .foregroundStyle(r.value == nil ? .primary : .secondary)
                                .frame(width: max(200 - Double(r.depth) * 14, 90), alignment: .leading)
                            if let v = r.value {
                                Text(v).font(.caption.monospaced()).textSelection(.enabled)
                                    .foregroundStyle(r.secret && !s.showSecrets ? .orange : .primary)
                            }
                        }
                        .padding(.leading, Double(r.depth) * 14)
                        .padding(.top, r.value == nil ? 6 : 0)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }
        }
    }
}
