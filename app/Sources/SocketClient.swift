import Foundation
import SwiftUI

/// 音声レベルメーター用の値 (dB)。audio/level イベントから更新。
/// MixerModel とは別オブジェクトにして、毎秒の更新で全ウインドウが再描画されるのを避ける。
@MainActor
final class LevelsModel: ObservableObject {
    struct LR: Equatable { var l: Double; var r: Double }
    @Published private(set) var level: [String: LR] = [:]   // "input-4" / "output-3" → L/R dB

    /// payload = {count, data:[{input:[{id,R,L,name}], output:[...]} × count]}
    func update(_ payload: [String: Any]) {
        guard let data = payload["data"] as? [[String: Any]], let last = data.last else { return }
        var out = level
        for kind in ["input", "output"] {
            for ch in last[kind] as? [[String: Any]] ?? [] {
                guard let id = ch["id"] as? Int else { continue }
                out["\(kind)-\(id)"] = LR(l: Double(ch["L"] as? Int ?? -8000) / 100,
                                          r: Double(ch["R"] as? Int ?? -8000) / 100)
            }
        }
        if out != level { level = out }
    }

    func clear() { if !level.isEmpty { level = [:] } }
}

/// 本体の SocketIO (Engine.IO v4) クライアント。
/// 実機の挙動: EIO=4 だが心拍は「クライアントが 2 を送り、サーバーが 3 を返す」(EIO3 流儀)。
/// pingTimeout=15s なので 4 秒ごとに 2 を送る。無送信だと ~15 秒で切断される。
/// イベントは /api/v2.0/... と接頭辞なしの両方で届くので、前者だけ処理する。
@MainActor
final class SocketClient: NSObject, ObservableObject, URLSessionDelegate {
    @Published private(set) var connected = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var pingTimer: Timer?
    private var backoff = 1.0
    private var stopped = true

    private let cookie: () -> String?
    var onChannel: ((String, Int) -> Void)?   // (name, sceneId)
    var onLevel: (([String: Any]) -> Void)?
    var onStreamerStatus: (([String: Any]) -> Void)?
    var onStream: (([String: Any]) -> Void)?
    var onAny: ((String, Any?) -> Void)?      // audio/level 以外のすべてのイベント
    var onConnect: (() -> Void)?              // (再)接続時に全体 refresh させる
    var onDisconnect: (() -> Void)?
    var log: ((String) -> Void)?

    init(cookie: @escaping () -> String?) {
        self.cookie = cookie
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    func start() { guard stopped else { return }; stopped = false; backoff = 1; connect() }

    /// 再接続の待ち時間をなくしてすぐつなぎ直す (本体の復帰を検出したとき)
    func kick() {
        guard !stopped, !connected else { return }
        backoff = 1
        task?.cancel(); task = nil
        connect()
    }

    func stop() {
        stopped = true
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        if connected { connected = false }
    }

    private func connect() {
        guard !stopped else { return }
        guard let sid = cookie() else { scheduleReconnect(); return }
        var req = URLRequest(url: URL(string: "wss://\(MixerAPI.host)/socket.io/?EIO=4&transport=websocket")!)
        req.setValue("session=\(sid)", forHTTPHeaderField: "Cookie")
        req.setValue("https://\(MixerAPI.host)", forHTTPHeaderField: "Origin")
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let e):
                    self.drop("recv: \(e.localizedDescription)")
                case .success(let msg):
                    switch msg {
                    case .string(let s): self.onFrame(s)
                    case .data(let d): if let s = String(data: d, encoding: .utf8) { self.onFrame(s) }
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func onFrame(_ s: String) {
        if s == "3" { return }                 // 自分の ping への pong
        if s == "2" { sendRaw("3"); return }   // サーバー ping (まれ) → pong
        if s.hasPrefix("0") {                  // Engine.IO OPEN
            sendRaw("40")                      // デフォルト名前空間へ CONNECT
            startPing()
            return
        }
        if s.hasPrefix("40") {                 // 名前空間 CONNECT 完了
            if !connected { connected = true; backoff = 1; log?("socket: connected"); onConnect?() }
            return
        }
        guard s.hasPrefix("42"),
              let data = s.dropFirst(2).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let ev = arr.first as? String, ev.hasPrefix("/api/v2.0/") else { return }
        let payload = arr.count > 1 ? arr[1] : nil
        if ev != "/api/v2.0/audio/level" { onAny?(ev, payload) }
        switch ev {
        case "/api/v2.0/audio/level":
            if let p = payload as? [String: Any] { onLevel?(p) }
        case "/api/v2.0/channels":
            if let p = payload as? [String: Any], let name = p["name"] as? String,
               let sid = p["sceneId"] as? Int { onChannel?(name, sid) }
        case "/api/v2.0/streamer/status":
            if let p = payload as? [String: Any] { onStreamerStatus?(p) }
        case "/api/v2.0/streams":
            if let p = payload as? [String: Any] { onStream?(p) }
        default: break
        }
    }

    private func startPing() {
        pingTimer?.invalidate()
        // .common モードで回す: ファイル選択パネルなどのモーダル表示中も心拍を止めない (止まると ~15 秒で切断される)
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendRaw("2") }
        }
        RunLoop.main.add(t, forMode: .common)
        pingTimer = t
    }

    private func sendRaw(_ s: String) {
        task?.send(.string(s)) { [weak self] err in
            if let err { Task { @MainActor in self?.drop("send: \(err.localizedDescription)") } }
        }
    }

    private func drop(_ why: String) {
        guard !stopped, task != nil else { return }
        if connected { log?("socket: dropped (\(why))") }
        connected = false
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(); task = nil
        onDisconnect?()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = backoff
        backoff = min(backoff * 2, 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in self?.connect() }
        }
    }

    // 本体の自己署名証明書 (ATEN) を本体アドレスに対してだけ受け入れる
    nonisolated func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if c.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           c.protectionSpace.host == MixerAPI.host, let trust = c.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
