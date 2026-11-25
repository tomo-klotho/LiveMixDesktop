import AppKit
import SwiftUI

/// 配信先 (RTMP / RTP / RTSP) または録画の 1 設定
struct StreamDest: Identifiable {
    let id: Int
    var name: String
    var category: String    // "streaming" / "recording"
    var type: String        // rtmp / rtp / rtsp / usb / cloud
    var destination: String
    var authentication: String   // RTMP はストリームキー、録画は JSON
    var isEnabled: Bool
    var raw: [String: Any]

    // 配信状態 (streamer/status から)
    var statusMsg: String = ""
    var bitrate: Int = 0
    var connQuality: Int = -1   // -1 null, 0 good, 1 ok, 2 bad

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? Int else { return nil }
        self.id = id
        name = d["name"] as? String ?? ""
        category = d["category"] as? String ?? "streaming"
        type = d["type"] as? String ?? "rtmp"
        destination = d["destination"] as? String ?? ""
        authentication = d["authentication"] as? String ?? ""
        isEnabled = d["isEnabled"] as? Bool ?? false
        raw = d
    }

    var isRecording: Bool { category == "recording" }
    var recFileName: String {
        guard isRecording, let d = authentication.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        return j["fileName"] as? String ?? ""
    }
    var qualityLabel: String {
        switch connQuality { case 0: return "良好"; case 1: return "まずまず"; case 2: return "不安定"; default: return "" }
    }
}

@MainActor
final class BroadcastModel: ObservableObject {
    @Published var streams: [StreamDest] = []
    @Published var engineStatus = "stop"      // start / stop
    @Published var overallMsg = ""
    @Published var liveSeconds = 0
    @Published var busy = false
    @Published var message: String?
    @Published var startFailure: String?   // ライブ開始直後に本体が自分で止めたときの案内 (次の開始まで残す)
    // エンコード (video codec id 1 = Stream Out)
    @Published var resolutionIdx = 0
    @Published var resolutions: [(w: Int, h: Int)] = []
    @Published var quality = "fluent"
    @Published var bitrate = 3000
    @Published var frameRate = 30
    // 録画ストレージ
    @Published var usbStatus = "notMounted"
    @Published var recRemaining = -1
    @Published var editing: StreamDest?
    @Published var confirmLive = false

    // 一時停止画面 (§13.7–13.9)
    @Published var pauseUseColor = true
    @Published var pauseColor = Color.black
    @Published var pauseImage: NSImage?
    @Published var pauseLoaded = false
    @Published var confirmPauseUpload: URL?

    private let m: MixerModel
    private var poll: Task<Void, Never>?
    init(model: MixerModel) { m = model }

    var isLive: Bool { engineStatus != "stop" }

    // SocketIO 接続中は状態がイベントで届くので、保険の全体更新は 10 秒間隔 (切断中は 2 秒)
    func start() {
        if poll == nil { m.startPolling() }   // 配信ウインドウだけ開いていても SocketIO をつなぐ
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let up = self?.m.socket.connected ?? false
                try? await Task.sleep(nanoseconds: up ? 10_000_000_000 : 2_000_000_000)
            }
        }
    }

    /// streamer/status (REST の応答 / SocketIO イベント共通) を反映。無いキーは今の値のまま
    func applyStatus(_ st: [String: Any]) {
        if let v = st["egnStatus"] as? String { engineStatus = v }
        if let v = st["overallStatusMsg"] as? String { overallMsg = v }
        if let v = st["time"] as? Int { liveSeconds = v }
        guard let list = st["stream"] as? [[String: Any]] else { return }
        var items = streams
        for s in list {
            guard let id = s["id"] as? Int, let i = items.firstIndex(where: { $0.id == id }) else { continue }
            items[i].statusMsg = s["statusMsg"] as? String ?? ""
            items[i].bitrate = s["bitrate"] as? Int ?? 0
            items[i].connQuality = s["connQuality"] as? Int ?? -1
            if items[i].isRecording { recRemaining = s["remainingRecTime"] as? Int ?? -1 }
        }
        streams = items
    }

    /// /streams イベント (配信先 1 件の設定変更) を反映。状態欄は残す
    func applyStream(_ d: [String: Any]) {
        guard var fresh = StreamDest(d), let i = streams.firstIndex(where: { $0.id == fresh.id }) else { return }
        let old = streams[i]
        fresh.statusMsg = old.statusMsg; fresh.bitrate = old.bitrate; fresh.connQuality = old.connQuality
        streams[i] = fresh
    }
    func stop() { if poll != nil { m.stopPolling() }; poll?.cancel(); poll = nil }

    func refresh() async {
        do {
            if let d = try await m.api.call("GET", "/streams") as? [String: Any],
               let list = d["streams"] as? [[String: Any]] {
                let items = list.compactMap(StreamDest.init)
                let st = try await m.api.call("GET", "/streamer/status") as? [String: Any] ?? [:]
                streams = items
                applyStatus(st)
            }
            if resolutions.isEmpty { try await loadCodec() }
            if let sto = try await m.api.call("GET", "/storage") as? [String: Any],
               let usb = sto["USB"] as? [String: Any] { usbStatus = usb["status"] as? String ?? "notMounted" }
            message = nil
        } catch { message = describe(error) }
    }

    private func loadCodec() async throws {
        guard let c = try await m.api.call("GET", "/codec") as? [String: Any],
              let codec = c["codec"] as? [String: Any],
              let v = (codec["video"] as? [[String: Any]])?.first(where: { $0["id"] as? Int == 1 }) else { return }
        resolutions = (v["resolutionRef"] as? [[String: Any]] ?? []).map { (w: $0["width"] as? Int ?? 0, h: $0["height"] as? Int ?? 0) }
        resolutionIdx = v["resolutionIdx"] as? Int ?? 0
        quality = v["quality"] as? String ?? "fluent"
        bitrate = v["bitrate"] as? Int ?? 3000
        frameRate = v["frameRate"] as? Int ?? 30
    }

    // MARK: ライブ配信
    /// (旧) ライブ開始時に RTSP 5 も有効にする機能。使わない: 本体は Program (channel 2) の配信先を 1 つしか有効にできず、RTSP 5 を有効にすると
    /// RTMP 2 (YouTube) が自動で無効になる (2026-11-25 実機確認)。配信中のモニターはできない
    let monitorWithLive = false
    private var rtspEnabledByLive = false

    /// RTSP 5 を足すと 2 本を超えるか (iPad 用と RTSP 自身は数えない)
    var monitorSlotFull: Bool {
        streams.filter { $0.isEnabled && $0.id != MonitorController.ipadStreamId && $0.id != MonitorController.rtspId }.count >= 2
    }

    func goLive() {
        run {
            // 配信していないときのモニターは配信先を一時無効にしているので、先に止めて元に戻す
            if self.m.monitor.state == .running && !self.m.monitor.attached { await self.m.monitor.stop() }
            let rtsp = self.streams.first { $0.id == MonitorController.rtspId }
            if self.monitorWithLive && !self.monitorSlotFull, let r = rtsp, !r.isEnabled {
                try await self.m.api.call("PATCH", "/streams/\(r.id)", ["isEnabled": true, "sender": "livemixdesktop"])
                self.rtspEnabledByLive = true
            }
            try await self.m.api.call("POST", "/streamer/start", ["toggle": false])
            self.m.log("broadcast: go live (monitor rtsp \(self.monitorWithLive && !self.monitorSlotFull))")
            self.startFailure = nil
            Task { await self.watchStart() }
            if self.monitorWithLive && !self.monitorSlotFull {
                try? await Task.sleep(nanoseconds: 3_000_000_000)   // RTSP が streaming になるのを待ってから受信
                await self.m.monitor.start()
            }
        }
    }
    /// 開始直後に本体が配信先へつながらず自分で止めた (connecting → stop) ときに知らせる
    private func watchStart() async {
        var sawLive = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let st = try? await m.api.call("GET", "/streamer/status") as? [String: Any] else { continue }
            let eng = st["egnStatus"] as? String ?? "stop"
            let streams = st["stream"] as? [[String: Any]] ?? []
            if streams.contains(where: { ($0["bitrate"] as? Int ?? 0) > 0 || ($0["statusMsg"] as? String ?? "").lowercased().contains("stream") }) { sawLive = true }
            if eng == "stop" {
                if !sawLive {
                    m.log("broadcast: engine stopped right after start (destination refused?)")
                    startFailure = "配信先に接続できず、本体が配信を止めました。ストリームキーと YouTube 側 (ライブ配信が有効か) を確かめてください"
                }
                return
            }
            if sawLive { return }
        }
    }

    func stopLive() {
        run {
            if self.m.monitor.attached { await self.m.monitor.stop() }
            try await self.m.api.call("POST", "/streamer/stop")
            self.m.log("broadcast: stop")
            if self.rtspEnabledByLive {
                // エンジンが止まりきってから RTSP 5 を元の無効に戻す
                for _ in 0..<20 {
                    let st = try? await self.m.api.call("GET", "/streamer/status") as? [String: Any]
                    if st?["egnStatus"] as? String == "stop" { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                _ = try? await self.m.api.call("PATCH", "/streams/\(MonitorController.rtspId)", ["isEnabled": false, "sender": "livemixdesktop"])
                self.rtspEnabledByLive = false
            }
        }
    }
    func pause() { run { try await self.m.api.call("POST", "/streamer/pause", ["toggle": false]) } }
    func resume() { run { try await self.m.api.call("POST", "/streamer/resume") } }

    // MARK: 配信先の編集
    func setEnabled(_ s: StreamDest, _ v: Bool) {
        run { try await self.m.api.call("PATCH", "/streams/\(s.id)", ["isEnabled": v, "sender": "livemixdesktop"]) }
    }
    func save(_ s: StreamDest) {
        run {
            try await self.m.api.call("PATCH", "/streams/\(s.id)",
                ["name": s.name, "destination": s.destination, "authentication": s.authentication, "sender": "livemixdesktop"])
            self.m.log("broadcast: saved stream \(s.id)")
        }
    }

    // MARK: エンコード
    func applyEncode() {
        run {
            var body: [String: Any] = ["quality": self.quality, "frameRate": self.frameRate,
                                       "resolutionIdx": self.resolutionIdx, "sender": "livemixdesktop"]
            if self.quality == "manual" { body["bitrate"] = self.bitrate }
            try await self.m.api.call("PATCH", "/codec/video/1", body)
            self.m.log("broadcast: encode \(self.quality) \(self.resolutionIdx) \(self.frameRate)fps")
        }
    }

    // MARK: 録画
    func loadPause() async {
        guard let d = try? await m.api.call("GET", "/assets/pause_screen") as? [String: Any] else { return }
        pauseUseColor = d["isUseColor"] as? Bool ?? true
        var hex = d["color"] as? String ?? "#000000"
        if hex.count == 9 { hex = "#" + hex.suffix(6) }   // #AARRGGBB → #RRGGBB
        pauseColor = Color(hex: hex)
        if let u = d["url"] as? String, let path = URL(string: u)?.path, let data = try? await m.api.fetchStatic(path) {
            pauseImage = NSImage(data: data)
        } else { pauseImage = nil }
        pauseLoaded = true
    }

    private var pauseColorTask: Task<Void, Never>?

    func setPause(useColor: Bool? = nil, color: Color? = nil) {
        var body: [String: Any] = ["sender": "livemixdesktop"]
        if let u = useColor { body["isUseColor"] = u; pauseUseColor = u }
        if let c = color {
            // 色を選んでいる間は送らず、手を止めて 0.4 秒後に 1 回だけ送る
            pauseColor = c
            pauseColorTask?.cancel()
            pauseColorTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, let self else { return }
                let hex = "#FF" + self.pauseColor.hex.dropFirst().uppercased()
                self.run {
                    try await self.m.api.call("PATCH", "/assets/pause_screen", ["color": hex, "sender": "livemixdesktop"])
                    self.m.log("pause screen: color \(hex)")
                }
            }
            return
        }
        run {
            try await self.m.api.call("PATCH", "/assets/pause_screen", body)
            self.m.log("pause screen: \(body.filter { $0.key != "sender" })")
            await self.loadPause()
        }
    }

    func choosePauseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = "一時停止中に流す画像を選んでください (1920×1080 推奨)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirmPauseUpload = url
    }

    /// 本体の一時停止画像を差し替える。元の画像は先に Mac へ保存しておく
    func uploadPauseImage(_ url: URL) {
        run {
            guard let data = try? Data(contentsOf: url) else { throw MixerAPI.APIError.offline("画像を読めません") }
            if let d = try? await self.m.api.call("GET", "/assets/pause_screen") as? [String: Any],
               let u = d["url"] as? String, let path = URL(string: u)?.path,
               let old = try? await self.m.api.fetchStatic(path) {
                let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
                let dir = URL(fileURLWithPath: NSHomeDirectory() + "/.config/livemixdesktop/pause-backup")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? old.write(to: dir.appendingPathComponent("pause_screen-\(f.string(from: Date())).bin"))
            }
            let ct = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            try await self.m.api.uploadMultipart("/assets/pause_screen/upload", fields: [("sender", "livemixdesktop")],
                                                 fileName: "pause_screen.bin", data: data, contentType: ct)   // 本体の既定名を保つ (送った名前で保存される)
            self.m.log("pause screen: uploaded \(url.lastPathComponent)")
            if self.pauseUseColor {
                try await self.m.api.call("PATCH", "/assets/pause_screen", ["isUseColor": false, "sender": "livemixdesktop"])
            }
            await self.loadPause()
            self.message = nil
        }
    }

    func formatUSB() {
        run { try await self.m.api.call("POST", "/storage/0"); self.m.log("broadcast: format USB") }
    }

    private func run(_ f: @escaping () async throws -> Void) {
        Task { busy = true; defer { busy = false }
            do { try await f(); await refresh() } catch { message = describe(error) }
        }
    }

    private func describe(_ e: Error) -> String {
        switch e {
        case MixerAPI.APIError.http(let c, let b):
            if b.contains("2010150") { return "本体の LAN ポートにケーブルを挿してください" }
            if b.contains("2010151") { return "配信/録画は最大 2 つまでです" }
            if b.contains("2010152") { return "有効な配信先がありません" }
            if b.contains("2010153") { return "USB ストレージが使えません" }
            return "HTTP \(c): \(b.prefix(80))"
        case MixerAPI.APIError.auth: return "ログインが必要です"
        case MixerAPI.APIError.offline(let m): return "本体に接続できません: \(m)"
        default: return "\(e)"
        }
    }
}

// MARK: - 画面

struct BroadcastView: View {
    @EnvironmentObject var b: BroadcastModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConnectionBanner()
                liveControl
                Divider()
                destinations
                Divider()
                encode
                Divider()
                recording
                Divider()
                PauseScreenSection()
                if let msg = b.message { Text(msg).font(.caption).foregroundStyle(.red) }
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 560)
        .onAppear { b.start() }
        .onDisappear { b.stop() }
        .sheet(item: $b.editing) { s in StreamEditor(form: StreamDraft(s)).environmentObject(b) }
        .alert("一時停止画面を差し替え", isPresented: Binding(get: { b.confirmPauseUpload != nil }, set: { if !$0 { b.confirmPauseUpload = nil } })) {
            Button("差し替える") { if let u = b.confirmPauseUpload { b.uploadPauseImage(u) }; b.confirmPauseUpload = nil }
            Button("やめる", role: .cancel) { b.confirmPauseUpload = nil }
        } message: {
            Text("本体の一時停止画像を「\(b.confirmPauseUpload?.lastPathComponent ?? "")」に置き換えます。今の画像は ~/.config/livemixdesktop/pause-backup に保存します。")
        }
        .alert("ライブ配信を開始", isPresented: $b.confirmLive) {
            Button("開始する", role: .destructive) { b.goLive() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("有効な配信先 (\(b.streams.filter { $0.isEnabled && !$0.isRecording }.map(\.name).joined(separator: ", "))) に配信を始めます。YouTube 等に実際に公開されます。")
        }
    }

    private var liveControl: some View {
        HStack(spacing: 12) {
            Circle().fill(b.isLive ? Color.red : Color.gray).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.isLive ? "配信中" : "停止中").font(.headline)
                Text(b.overallMsg).font(.caption2).foregroundStyle(.secondary)
            }
            if b.isLive {
                Text(String(format: "%02d:%02d:%02d", b.liveSeconds / 3600, (b.liveSeconds / 60) % 60, b.liveSeconds % 60))
                    .font(.title3.monospacedDigit())
            }
            Spacer()
            if b.busy { ProgressView().controlSize(.small) }
            if b.isLive {
                Button("一時停止") { b.pause() }
                Button("再開") { b.resume() }
                Button("配信停止") { b.stopLive() }.tint(.red)
            } else {
                Button("ライブ開始") { b.confirmLive = true }
                    .tint(.red)   // Return では反応させない (誤操作防止)
                    .disabled(b.streams.allSatisfy { !$0.isEnabled || $0.isRecording })
            }
        }
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("配信先").font(.subheadline.bold())
            // この機種はスロット固定 (RTMP / RTSP)。iPad 用 RTP は除外
            ForEach(b.streams.filter { !$0.isRecording && $0.type != "rtp" }) { s in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { s.isEnabled }, set: { b.setEnabled(s, $0) })).labelsHidden()
                        .disabled(b.isLive)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(s.name)  ").font(.callout) + Text(s.type.uppercased()).font(.caption2).foregroundColor(.secondary)
                        Text(s.destination.isEmpty ? "(未設定)" : maskedDestination(s))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if b.isLive && s.isEnabled {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(s.statusMsg).font(.caption2)
                            if s.bitrate > 0 { Text("\(s.bitrate) kbps \(s.qualityLabel)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    Button { b.editing = s } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).disabled(b.isLive)
                }
                .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }
            Text("YouTube 等は RTMP の枠に設定します (本体のスロット固定、追加は不可)。").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var encode: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("エンコード (配信の画質)").font(.subheadline.bold())
            HStack {
                Text("解像度").frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(get: { b.resolutionIdx }, set: { b.resolutionIdx = $0 })) {
                    ForEach(Array(b.resolutions.enumerated()), id: \.offset) { i, r in Text("\(r.w)×\(r.h)").tag(i) }
                }.labelsHidden().frame(width: 140)
                Text("フレームレート").frame(width: 100, alignment: .trailing)
                Picker("", selection: Binding(get: { b.frameRate }, set: { b.frameRate = $0 })) {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }.labelsHidden().frame(width: 90)
            }
            HStack {
                Text("画質").frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(get: { b.quality }, set: { b.quality = $0 })) {
                    Text("なめらか").tag("fluent"); Text("標準").tag("normal"); Text("高画質").tag("quality"); Text("手動").tag("manual")
                }.labelsHidden().frame(width: 140)
                if b.quality == "manual" {
                    Text("ビットレート").frame(width: 100, alignment: .trailing)
                    TextField("", value: Binding(get: { b.bitrate }, set: { b.bitrate = $0 }), format: .number)
                        .frame(width: 70)
                    Text("kbps").font(.caption)
                }
                Spacer()
                Button("適用") { b.applyEncode() }.disabled(b.isLive)
            }
            if b.isLive { Text("配信中はエンコード設定を変更できません").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("USB 録画").font(.subheadline.bold())
            ForEach(b.streams.filter { $0.isRecording }) { s in
                HStack(spacing: 8) {
                    Toggle("録画を有効", isOn: Binding(get: { s.isEnabled }, set: { b.setEnabled(s, $0) }))
                    Text("ファイル名: \(s.recFileName.isEmpty ? "(未設定)" : s.recFileName)").font(.caption)
                    Spacer()
                    Button { b.editing = s } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).disabled(b.isLive)
                }
            }
            HStack {
                Text("USB: \(usbLabel)").font(.caption).foregroundStyle(.secondary)
                if b.recRemaining > 0 { Text("残り \(b.recRemaining / 60) 分").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("USB をフォーマット") { b.formatUSB() }.controlSize(.small)
                    .disabled(b.isLive || b.usbStatus == "notMounted")
            }
            Text("録画は「録画を有効」にしてから「ライブ開始」で始まります。配信と同時に 1 つずつ、合計 2 つまで。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var usbLabel: String {
        switch b.usbStatus { case "mounted", "usable": return "接続済み"; case "notMounted": return "未接続"; default: return b.usbStatus }
    }
    private func maskedDestination(_ s: StreamDest) -> String {
        s.authentication.isEmpty || s.isRecording ? s.destination : "\(s.destination)/••••••"
    }
}

final class StreamDraft: ObservableObject { @Published var d: StreamDest; init(_ s: StreamDest){ d=s } }

struct StreamEditor: View {
    @EnvironmentObject var b: BroadcastModel
    @Environment(\.dismiss) private var dismiss
    @StateObject var form: StreamDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(form.d.id == 0 ? "配信先を追加" : "配信先を編集").font(.headline)
            Form {
                TextField("名前", text: $form.d.name)
                if form.d.isRecording {
                    TextField("録画ファイル名", text: Binding(
                        get: { form.d.recFileName },
                        set: { form.d.authentication = "{\"fileName\":\"\($0)\",\"maxFileDuration\":14400}" }))
                } else {
                    TextField("配信先 URL (rtmp://…)", text: $form.d.destination)
                    SecureField("ストリームキー", text: $form.d.authentication)
                    Text("YouTube 等の「ストリーム URL」を URL 欄、「ストリームキー」をキー欄に入れます")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") { b.save(form.d); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 420)
    }
}

/// 一時停止 (配信の「一時停止」中に流れる画面) の設定
struct PauseScreenSection: View {
    @EnvironmentObject var b: BroadcastModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("一時停止画面").font(.subheadline.bold())
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(b.pauseUseColor ? b.pauseColor : Color.black)
                    if !b.pauseUseColor, let img = b.pauseImage {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: 160, height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: Binding(get: { b.pauseUseColor }, set: { b.setPause(useColor: $0) })) {
                        Text("色").tag(true)
                        Text("画像").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                    if b.pauseUseColor {
                        ColorPicker("色", selection: Binding(get: { b.pauseColor }, set: { b.setPause(color: $0) }),
                                    supportsOpacity: false).font(.caption)
                    } else {
                        Button("画像を選ぶ…") { b.choosePauseImage() }.controlSize(.small)
                    }
                }
                Spacer()
            }
            .disabled(b.busy || !b.pauseLoaded)
            Text("配信を「一時停止」すると、映像の代わりにこの画面が流れます。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .task { await b.loadPause() }
    }
}
