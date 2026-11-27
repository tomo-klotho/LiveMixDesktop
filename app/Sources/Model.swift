import Foundation
import SwiftUI

struct AudioChannel: Identifiable, Equatable {
    let id: Int
    var name: String
    var gain: Double        // dB
    var pan: Int            // 生値 (%×100)
    var isMute: Bool
    var minDB: Double = -80
    var maxDB: Double = 10
    var stepDB: Double = 0.5

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? Int, let name = d["name"] as? String else { return nil }
        self.id = id
        self.name = name
        gain = Double(d["gain"] as? Int ?? 0) / 100
        pan = d["pan"] as? Int ?? 0
        isMute = d["isMute"] as? Bool ?? false
        if let g = (d["capability"] as? [String: Any])?["gain"] as? [String: Any] {
            minDB = Double(g["min"] as? Int ?? -8000) / 100
            maxDB = Double(g["max"] as? Int ?? 1000) / 100
            stepDB = max(Double(g["step"] as? Int ?? 50) / 100, 0.01)
        }
    }
}

enum Kind: String { case input, output }

@MainActor
final class MixerModel: ObservableObject {
    let api = MixerAPI()

    enum Conn: Equatable { case unknown, ok, needsLogin, offline(String) }
    @Published var conn: Conn = .unknown { didSet { if conn != oldValue { log("conn: \(conn)"); connChanged(from: oldValue) } } }
    /// 切断した時刻 (つながっている間は nil)
    @Published var offlineSince: Date?
    /// メインウインドウで表示中の画面
    @Published var section: AppSection = AppSection.initial
    @Published var linkHint: LinkHint?
    @Published var recoveredMessage: String?
    var wasLiveAtDrop = false

    private(set) var monitor: MonitorController!
    private(set) var editor: SceneEditorModel!
    private(set) var settings: SettingsModel!
    private(set) var assetsModel: AssetsModel!
    private(set) var broadcast: BroadcastModel!

    let levels = LevelsModel()
    private(set) var admin: DeviceAdminModel!
    private(set) var socket: SocketClient!

    init() {
        try? AppFiles.makeDir(AppFiles.dir)   // 古い版が作ったフォルダも本人だけの権限に
        log("launch host=\(MixerAPI.host) cliCookie=\(api.sessionId != nil)")
        monitor = MonitorController(api: api) { [weak self] in self?.log($0) }
        editor = SceneEditorModel(model: self)
        settings = SettingsModel(model: self)
        assetsModel = AssetsModel(model: self)
        broadcast = BroadcastModel(model: self)
        AppDelegate.monitor = monitor
        AppDelegate.editor = editor
        socket = SocketClient(cookie: { [weak self] in self?.api.sessionId })
        socket.log = { [weak self] in self?.log($0) }
        socket.onLevel = { [weak self] p in self?.levels.update(p) }
        socket.onChannel = { [weak self] name, sid in self?.applyChannel(name, sid) }
        socket.onConnect = { [weak self] in Task { await self?.refresh() } }
        socket.onDisconnect = { [weak self] in self?.levels.clear(); Task { await self?.heartbeat() } }   // 切断をすぐ画面に出す
        socket.onStreamerStatus = { [weak self] p in self?.broadcast.applyStatus(p) }
        socket.onStream = { [weak self] p in self?.broadcast.applyStream(p) }
        admin = DeviceAdminModel(model: self)
        socket.onAny = { [weak self] ev, p in self?.admin.onProfileEvent(ev, p) }
        Task {
            await refresh()
            // 前回モニター中に落ちていたら、無効化した配信を元に戻す
            if conn == .ok { await monitor.restoreLeftover() }
        }
        // 画面を開いていなくても接続を見張る (メニューバーのアイコンと切断の案内のため)。開いている間はポーリングに任せる
        Task { [weak self] in
            while true {
                let wait: UInt64 = (self?.offlineSince != nil) ? 3 : 8
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                guard let self else { return }
                if self.offlineSince != nil { self.updateHint() }
                if self.viewers == 0 { await self.heartbeat() }
            }
        }
    }

    /// ~/.config/livemixdesktop/app.log に状態変化を記録 (パスワードやクッキーは書かない)
    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        let url = AppFiles.url("app.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? AppFiles.write(Data(line.utf8), to: url) }
    }
    @Published var deviceName = "GV-LSMIXER/I"
    @Published var prv = 0
    @Published var pgm = 0
    @Published var sceneNames: [Int: String] = [:]
    @Published var inputs: [AudioChannel] = []
    /// AFV (Audio Follows Video): 入力 id → オンか。HDMI1/HDMI2 だけ (/source/audio の isFollowVideo)
    @Published var afv: [Int: Bool] = [:]
    /// いま PGM に音が乗っているか (/source/audio の isAudibleOnPgm。AFV オンで映像が PGM に無いと false)
    @Published var audibleOnPgm: [Int: Bool] = [:]
    private var afvEditedAt: [Int: Date] = [:]
    @Published var outputs: [AudioChannel] = []
    @Published var autoMs = 1000
    @Published var transitioning = false
    @Published var lastError: String?
    @Published var showThumbs = true
    /// 入力サムネイル (本体が数秒ごとに更新する約 208×130 の PNG)
    @Published var thumbs: [(label: String, image: NSImage?)] = []
    static let thumbSources = [("HDMI1", "/static/snapshots/HDMI1.png"),
                               ("HDMI2 A", "/static/snapshots/HDMI2A.png"),
                               ("HDMI2 B", "/static/snapshots/HDMI2B.png")]

    private func loadThumbs() async {
        guard showThumbs else { return }
        var out: [(label: String, image: NSImage?)] = []
        for (label, path) in Self.thumbSources {
            // 入力なしのときは 数百バイトの灰色一色の画像が返る → 「信号なし」表示にする
            let data = try? await api.fetchStatic(path)
            out.append((label, data.flatMap { $0.count > 2000 ? NSImage(data: $0) : nil }))
        }
        let summary = out.map { "\($0.label)=\($0.image == nil ? "-" : "img")" }.joined(separator: " ")
        if summary != lastThumbSummary { log("thumbs: \(summary)"); lastThumbSummary = summary }
        thumbs = out
    }
    private var lastThumbSummary = ""

    private var pollTask: Task<Void, Never>?
    private var lastLocalEdit: [String: Date] = [:]          // "input-2" → 最後に手元で変えた時刻
    private var inFlight: Set<String> = []
    private var pending: [String: [String: Any]] = [:]

    // MARK: ポーリング (ウインドウ表示中のみ)
    private(set) var viewers = 0   // 操作画面 (メニュー / ウインドウ) が開いている数

    func startPolling() {
        viewers += 1
        guard pollTask == nil else { return }
        socket.start()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // SocketIO 接続中は映像切替・レベルは即時反映されるので、保険の全体更新は 10 秒間隔。
                // 切断中は 2 秒ポーリングに戻す。音声ゲイン/ミュートとサムネイルは常にこちらで同期。
                let up = self?.socket.connected ?? false
                try? await Task.sleep(nanoseconds: up ? 10_000_000_000 : 2_000_000_000)
            }
        }
    }

    func stopPolling() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { pollTask?.cancel(); pollTask = nil; socket.stop() }
    }

    /// SocketIO の /channels イベントから PRV/PGM を即時反映
    private func applyChannel(_ name: String, _ sceneId: Int) {
        guard !transitioning else { return }
        switch name {
        case "Preview": prv = sceneId
        case "Program": pgm = sceneId
        default: break
        }
    }

    /// プロファイル読み込みなどで本体の設定が丸ごと変わったあとに、全画面を読み直す
    func reloadAll() async {
        sceneNames = [:]
        await refresh()
        await broadcast.refresh()
        await editor.refreshAssetList()
        await editor.load(editor.sceneId)
    }

    /// 軽い生存確認
    func heartbeat() async {
        do { _ = try await api.call("GET", "/channels", timeout: 3); if conn != .ok && conn != .needsLogin { await refresh() } }
        catch { await handle(error) }
    }

    func refresh() async {
        do {
            if sceneNames.isEmpty { try await loadStatic() }
            try await loadChannels()
            try await loadAudio(.input)
            try? await loadSourceAudio()
            try await loadAudio(.output)
            conn = .ok
            await loadThumbs()
        } catch { await handle(error) }
    }

    private func loadStatic() async throws {
        if let info = try await api.call("GET", "/system/info") as? [String: Any], let n = info["deviceName"] as? String {
            deviceName = n
        }
        if let s = try await api.call("GET", "/scenes") as? [String: Any], let list = s["scenes"] as? [[String: Any]] {
            var names: [Int: String] = [:]
            for sc in list { if let id = sc["id"] as? Int, let n = sc["name"] as? String { names[id] = n } }
            sceneNames = names
        }
        if let t = try await api.call("GET", "/transition") as? [String: Any], let d = t["duration"] as? Int, autoMs == 1000 {
            autoMs = d
        }
    }

    private func loadChannels() async throws {
        guard !transitioning,
              let c = try await api.call("GET", "/channels") as? [String: Any],
              let chans = c["channels"] as? [[String: Any]] else { return }
        for ch in chans {
            let sid = ch["sceneId"] as? Int ?? 0
            switch ch["name"] as? String {
            case "Preview": prv = sid
            case "Program": pgm = sid
            default: break
            }
        }
    }

    private func loadAudio(_ kind: Kind) async throws {
        guard let d = try await api.call("GET", "/audio/\(kind.rawValue)") as? [String: Any],
              let list = d[kind.rawValue] as? [[String: Any]] else { return }
        var fresh = list.compactMap(AudioChannel.init)
        let current = kind == .input ? inputs : outputs
        // 手元で操作した直後の値はポーリングで上書きしない
        for i in fresh.indices {
            let key = "\(kind.rawValue)-\(fresh[i].id)"
            if let t = lastLocalEdit[key], Date().timeIntervalSince(t) < 1.5,
               let mine = current.first(where: { $0.id == fresh[i].id }) {
                fresh[i].gain = mine.gain
                fresh[i].isMute = mine.isMute
            }
        }
        if kind == .input { inputs = fresh } else { outputs = fresh }
    }

    private func loadSourceAudio() async throws {
        guard let d = try await api.call("GET", "/source/audio") as? [String: Any],
              let list = d["audio"] as? [[String: Any]] else { return }
        var a = afv, on = [Int: Bool]()
        for s in list {
            guard let id = s["id"] as? Int else { continue }
            on[id] = s["isAudibleOnPgm"] as? Bool ?? true
            // 映像のある入力 (HDMI) だけ AFV を持つ
            guard (s["type"] as? String) == "digital" else { continue }
            if let t = afvEditedAt[id], Date().timeIntervalSince(t) < 1.5 { continue }   // 手元で変えた直後は上書きしない
            a[id] = s["isFollowVideo"] as? Bool ?? false
        }
        if a != afv { afv = a }
        if on != audibleOnPgm { audibleOnPgm = on }
    }

    func setAFV(_ id: Int, _ on: Bool) {
        let old = afv[id]
        afv[id] = on
        afvEditedAt[id] = Date()
        Task {
            do {
                try await api.call("PATCH", "/source/audio/\(id)", ["isFollowVideo": on, "sender": "livemixdesktop"])
                // 本体の挙動 (2026-11-27 実機確認): AFV をオンにすると、その入力の isMute が true になる (AFV 中の内部表現。音は PGM に乗る)。
                // オフにしても isMute は true のまま残り、音が出なくなる → オフにしたらミュートを解く。
                // 逆に AFV 中にミュートを解くと、本体は AFV をオフにする
                if !on { try await api.call("PATCH", "/audio/input/\(id)", ["isMute": false, "sender": "livemixdesktop"]) }
                afvEditedAt[id] = nil
                try? await loadAudio(.input)
                try? await loadSourceAudio()
            } catch { afv[id] = old; await handle(error) }
        }
    }

    // MARK: 映像
    func selectPreview(_ scene: Int) {
        guard scene != pgm else { return }   // PRV と PGM に同じシーンは不可 (2010103)
        let old = prv
        prv = scene
        Task {
            do { try await api.call("PATCH", "/channels/1", ["sceneId": scene, "sender": "livemixdesktop"]) }
            catch { prv = old; await handle(error) }
        }
    }

    func cut() { transition(["mode": "cut"], waitMs: 300) }
    func auto() { transition(["mode": "auto", "duration": autoMs], waitMs: autoMs + 400) }

    private func transition(_ body: [String: Any], waitMs: Int) {
        guard !transitioning else { return }
        transitioning = true
        var b = body
        b["sender"] = "livemixdesktop"
        Task {
            defer { transitioning = false }
            do {
                try await api.call("POST", "/transition", b)
                try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)  // 割り当ては切替完了時に入れ替わる
                transitioning = false
                try await loadChannels()
            } catch { await handle(error) }
        }
    }

    // MARK: 音声
    func setGain(_ kind: Kind, _ id: Int, _ db: Double) {
        update(kind, id) { $0.gain = db }
        send(kind, id, ["gain": Int((db * 100).rounded())])
    }

    func toggleMute(_ kind: Kind, _ id: Int) {
        // AFV 中 (本体の isMute は true) にミュートを押したら、AFV を切ってミュートにする
        if kind == .input, afv[id] == true {
            afv[id] = false
            afvEditedAt[id] = Date()
            update(kind, id) { $0.isMute = true }
            Task {
                do {
                    try await api.call("PATCH", "/source/audio/\(id)", ["isFollowVideo": false, "sender": "livemixdesktop"])
                    try await api.call("PATCH", "/audio/input/\(id)", ["isMute": true, "sender": "livemixdesktop"])
                    afvEditedAt[id] = nil
                    try? await loadAudio(.input)
                    try? await loadSourceAudio()
                } catch { await handle(error) }
            }
            return
        }
        var newValue = false
        update(kind, id) { $0.isMute.toggle(); newValue = $0.isMute }
        send(kind, id, ["isMute": newValue])
    }

    private func update(_ kind: Kind, _ id: Int, _ f: (inout AudioChannel) -> Void) {
        if kind == .input, let i = inputs.firstIndex(where: { $0.id == id }) { f(&inputs[i]) }
        if kind == .output, let i = outputs.firstIndex(where: { $0.id == id }) { f(&outputs[i]) }
        lastLocalEdit["\(kind.rawValue)-\(id)"] = Date()
    }

    /// 同じチャンネルへの送信は 1 本ずつ。送信中に来た値は最後の 1 つだけ後で送る
    private func send(_ kind: Kind, _ id: Int, _ fields: [String: Any]) {
        let key = "\(kind.rawValue)-\(id)"
        pending[key, default: [:]].merge(fields) { _, new in new }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            while let body = pending.removeValue(forKey: key) {
                var b = body
                b["sender"] = "livemixdesktop"
                do { try await api.call("PATCH", "/audio/\(kind.rawValue)/\(id)", b) }
                catch { await handle(error); pending[key] = nil }
                lastLocalEdit[key] = Date()
            }
            inFlight.remove(key)
            if kind == .output { try? await loadAudio(.output) }  // Stream Out と DisplayA は連動する
        }
    }

    // MARK: ログイン
    func login(user: String, password: String, remember: Bool) async {
        do {
            try await api.login(user: user, password: password)
            if remember { Keychain.save(user: user, password: password) }
            lastError = nil
            await refresh()
        } catch {
            lastError = "ログインできませんでした"
            conn = .needsLogin
        }
    }

    private var autoLoginTried = false

    private func handle(_ error: Error) async {
        switch error {
        case MixerAPI.APIError.auth:
            if !autoLoginTried, let (u, p) = Keychain.load() {
                autoLoginTried = true
                do {
                    try await api.login(user: u, password: p)
                    autoLoginTried = false
                    return
                } catch {}
            }
            conn = .needsLogin
        case MixerAPI.APIError.offline(let msg):
            conn = .offline(msg)
        case MixerAPI.APIError.http(let code, let body):
            lastError = "HTTP \(code): \(body.prefix(120))"
        default:
            lastError = error.localizedDescription
        }
    }
}
