import AppKit
import SwiftUI

/// Program 出力を本体の RTSP (rtsp://<host>:554/session) で受けて表示する。
///
/// 本体の配信エンジンを使うため、開始時に設定を一時的に変え、停止時に必ず元に戻す:
///   開始: 有効な配信 (YouTube の RTMP など) を無効化 → RTSP 5 を有効化 → エンジン開始 → ffmpeg で受信
///   停止: ffmpeg 終了 → エンジン停止 → 完全停止を待つ → RTSP 5 無効化 → 無効化した配信を有効に戻す
/// 途中でアプリが落ちても、次回起動時に restore.json を見て元に戻す。
@MainActor
final class MonitorController: ObservableObject {
    enum State: Equatable { case idle, starting, running, stopping, failed(String) }
    @Published var state: State = .idle
    @Published var frame: NSImage?
    @Published var fps: Double = 0
    /// 配信中に RTSP 5 も出ているとき、設定に触らず映像だけ受けている (止めても配信はそのまま)
    @Published private(set) var attached = false

    private let api: MixerAPI
    private let log: (String) -> Void
    private var ffmpeg: Process?
    private var frameCount = 0
    private var fpsWindowStart = Date()
    private var lastFrameAt = Date()
    private var watchdog: Timer?

    static let rtspId = 5
    static let ipadStreamId = 1   // 配信エンジンの対象外なので触らない
    static var url: String { "rtsp://\(MixerAPI.host):554/session" }
    static let restoreFile = URL(fileURLWithPath: NSHomeDirectory() + "/.config/livemixdesktop/monitor-restore.json")

    init(api: MixerAPI, log: @escaping (String) -> Void) {
        self.api = api
        self.log = log
    }

    static func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: 開始
    func start() async {
        guard state == .idle || isFailed else { return }
        guard let ff = Self.ffmpegPath() else { state = .failed("ffmpeg が見つかりません (brew install ffmpeg)"); return }
        state = .starting
        // 戻していない設定が残っていれば (前回の異常終了・受信エラー後の再開始など)、必ず先に元へ戻す。
        // そうしないと「既に無効」の配信を記録し損ね、後で有効に戻せなくなる
        if Self.needsRestore {
            await restore()
            if Self.needsRestore {
                state = .failed("前回の設定を元に戻せませんでした。livemix.py で配信設定を確認してください")
                return
            }
        }
        owned = true
        do {
            let st = try await api.call("GET", "/streamer/status") as? [String: Any] ?? [:]
            guard st["egnStatus"] as? String == "stop" else {
                owned = false
                // 配信中: RTSP 5 も出ていれば、設定には触らず受信だけする
                let rtspLive = (st["stream"] as? [[String: Any]] ?? []).contains {
                    $0["id"] as? Int == Self.rtspId && ($0["statusMsg"] as? String ?? "") == "streaming"
                }
                if rtspLive {
                    launchFFmpeg(ff)
                    attached = true
                    state = .running
                    log("monitor attached to live RTSP")
                } else {
                    state = .failed("配信中は Mac モニターを使えません。本体は Program の配信先を 1 つしか有効にできず、RTSP を有効にすると YouTube などの配信先が無効になるためです")
                }
                return
            }
            if let net = try await api.call("GET", "/network/interfaces") as? [String: Any],
               let ifs = net["interfaces"] as? [[String: Any]], !(ifs.contains { $0["isPlugged"] as? Bool == true }) {
                owned = false
                state = .failed("本体の LAN ポートにケーブルを挿してください (挿さっていないと開始できません)")
                return
            }
            let streams = try await streamStates()
            let toDisable = streams.filter { $0.value && $0.key != Self.ipadStreamId && $0.key != Self.rtspId }.map(\.key).sorted()
            try saveRestore(toDisable)
            log("monitor start: disable \(toDisable)")
            for id in toDisable { try await patchStream(id, enabled: false) }
            try await patchStream(Self.rtspId, enabled: true)
            let now = try await streamStates()
            guard !toDisable.contains(where: { now[$0] == true }) else { throw MonitorError("配信を無効にできませんでした") }
            try await api.call("POST", "/streamer/start", ["toggle": false])
            try await waitRtspStreaming()
            launchFFmpeg(ff)
            state = .running
            log("monitor running")
        } catch {
            log("monitor start failed: \(error)")
            await restore()
            state = .failed(describe(error))
        }
    }

    // MARK: 停止
    func stop() async {
        guard state == .running || state == .starting || isFailed else { return }
        if attached {   // 受信だけしていた: 本体の設定には触らない
            await stopRecording()
            ffmpeg?.terminate(); ffmpeg = nil
            attached = false; frame = nil; state = .idle
            log("monitor detached")
            return
        }
        state = .stopping
        await restore()
        frame = nil
        state = .idle
    }

    /// 本体を元の設定に戻す (restore.json があるときだけ。起動時の後始末にも使う)
    func restore() async {
        await stopRecording()
        ffmpeg?.terminate()
        ffmpeg = nil
        guard let data = try? Data(contentsOf: Self.restoreFile),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let disabled = saved["disabled"] as? [Int] else { return }
        log("monitor restore: re-enable \(disabled)")
        do {
            let st = try await api.call("GET", "/streamer/status") as? [String: Any] ?? [:]
            if st["egnStatus"] as? String != "stop" || (st["overallStatusIdx"] as? Int ?? 0) != 0 {
                try? await api.call("POST", "/streamer/stop")
            }
            try await waitStopped()
            try await patchStreamRetry(Self.rtspId, enabled: false)
            for id in disabled { try await patchStreamRetry(id, enabled: true) }
            try? FileManager.default.removeItem(at: Self.restoreFile)
            owned = false
            log("monitor restored")
        } catch {
            log("monitor restore FAILED: \(error)")
            state = .failed("設定を元に戻せませんでした: \(describe(error))。もう一度開いて閉じるか、livemix.py で確認してください")
        }
    }

    /// USB が切れて戻ったとき: モニター用に変えた配信設定が残っていれば戻す。
    /// 配信中 (live) なら本体の配信を止めてしまうので触らない (受信だけのときは restore.json が無い)
    func recoverAfterDrop(live: Bool) async {
        guard Self.needsRestore, state != .running, state != .starting, state != .stopping else { return }
        guard owned || state == .idle || isFailed else { return }
        if live && !owned { return }
        log("monitor: restoring after link drop")
        await restore()
        frame = nil
        if !isFailed { state = .failed("本体との接続が切れたためモニターを止め、配信先の設定を元に戻しました。もう一度表示できます") }
    }

    static var needsRestore: Bool { FileManager.default.fileExists(atPath: restoreFile.path) }

    /// このアプリ (今回の起動) が配信設定を変えている最中か
    private(set) var owned = false

    /// 起動時の後始末: 前回の異常終了で残った設定だけを戻す (今回のモニターには触らない)
    func restoreLeftover() async {
        guard Self.needsRestore, !owned, state == .idle else { return }
        log("leftover monitor state found; restoring")
        await restore()
    }

    // MARK: Mac への録画 (RTSP を再エンコードせず -c copy でファイル化)
    @Published var recordingURL: URL?
    @Published var recordingStart: Date?
    @Published var recordMessage: String?
    private var recorder: Process?
    static let recordDir = URL(fileURLWithPath: NSHomeDirectory() + "/Movies/Live Mix Desktop")

    func startRecording() {
        guard state == .running, recorder == nil, let ff = Self.ffmpegPath() else { return }
        try? FileManager.default.createDirectory(at: Self.recordDir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = Self.recordDir.appendingPathComponent("LiveMixDesktop-\(f.string(from: Date())).mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        // fragmented MP4: 異常終了してもそこまでの分は再生できる
        p.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-rtsp_transport", "tcp", "-timeout", "5000000", "-i", Self.url,
                       "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
                       "-movflags", "+frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", url.path]
        p.standardInput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let msg = String(data: err.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self = self, self.recorder === proc else { return }
                self.log("recorder exited \(proc.terminationStatus) \(msg.prefix(200))")
                self.recorder = nil
                self.recordMessage = "録画が止まりました (終了コード \(proc.terminationStatus))。ここまでの分は保存済み: \(url.lastPathComponent)"
                self.recordingURL = nil; self.recordingStart = nil
            }
        }
        do {
            try p.run()
            recorder = p; recordingURL = url; recordingStart = Date(); recordMessage = nil
            log("recording start \(url.path)")
        } catch { recordMessage = "録画を開始できません: \(error.localizedDescription)" }
    }

    /// ffmpeg に SIGINT を送って正常終了させる (3 秒で終わらなければ強制終了)
    func stopRecording() async {
        guard let p = recorder, let url = recordingURL else { return }
        recorder = nil
        if p.isRunning { p.interrupt() }
        for _ in 0..<30 where p.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        if p.isRunning { p.terminate() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        log("recording stop \(url.lastPathComponent) \(size) bytes")
        recordMessage = "保存しました: \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
        recordingURL = nil; recordingStart = nil
    }

    // MARK: ffmpeg → JPEG フレーム
    private func launchFFmpeg(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-rtsp_transport", "tcp",
                       "-timeout", "5000000", "-fflags", "nobuffer", "-flags", "low_delay", "-i", Self.url,
                       "-an", "-vf", "fps=15,scale=960:-2", "-q:v", "6",
                       "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let parser = JPEGStreamParser { [weak self] jpeg in
            guard let img = NSImage(data: jpeg) else { return }
            Task { @MainActor in self?.show(img) }
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { parser.feed(d) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self = self, self.state == .running, self.ffmpeg === proc else { return }
                self.log("ffmpeg exited \(proc.terminationStatus)")
                if self.attached { self.attached = false }
                self.state = .failed("映像の受信が止まりました (ffmpeg 終了コード \(proc.terminationStatus))")
            }
        }
        lastFrameAt = Date()
        watchdog?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkStall() } }
        RunLoop.main.add(t, forMode: .common); watchdog = t
        do { try p.run(); ffmpeg = p } catch { state = .failed("ffmpeg を起動できません: \(error.localizedDescription)") }
    }

    /// 映像が 8 秒届かなければ受信を止めて知らせる (USB が抜けると ffmpeg が待ち続けることがある)
    private func checkStall() {
        guard state == .running else { if state == .idle { watchdog?.invalidate(); watchdog = nil }; return }
        guard Date().timeIntervalSince(lastFrameAt) > (frame == nil ? 20 : 8) else { return }   // 最初の 1 枚は遅いことがある
        log("monitor stalled (no frame 8s)")
        watchdog?.invalidate(); watchdog = nil
        let p = ffmpeg; ffmpeg = nil
        p?.terminate()
        if attached { attached = false }
        state = .failed("映像が届かなくなりました。本体との接続を確かめてください")
    }

    private func show(_ img: NSImage) {
        guard state == .running || state == .starting else { return }   // 止めた後に届いた最後のフレームは捨てる
        lastFrameAt = Date()
        if frame == nil { log("monitor first frame \(Int(img.size.width))x\(Int(img.size.height))") }
        frame = img
        frameCount += 1
        let dt = Date().timeIntervalSince(fpsWindowStart)
        if dt >= 1 { fps = Double(frameCount) / dt; frameCount = 0; fpsWindowStart = Date() }
    }

    // MARK: 本体 API の小道具
    private var isFailed: Bool { if case .failed = state { return true } else { return false } }

    private func streamStates() async throws -> [Int: Bool] {
        let d = try await api.call("GET", "/streams") as? [String: Any]
        var out: [Int: Bool] = [:]
        for s in d?["streams"] as? [[String: Any]] ?? [] {
            if let id = s["id"] as? Int { out[id] = s["isEnabled"] as? Bool ?? false }
        }
        return out
    }

    private func patchStream(_ id: Int, enabled: Bool) async throws {
        try await api.call("PATCH", "/streams/\(id)", ["isEnabled": enabled, "sender": "livemixdesktop"])
    }

    /// 停止直後は 2010255 (Please turn off live-streaming) で拒否されるので待って再試行
    private func patchStreamRetry(_ id: Int, enabled: Bool) async throws {
        for i in 0..<12 {
            do { try await patchStream(id, enabled: enabled); return }
            catch MixerAPI.APIError.http(_, let body) where body.contains("2010255") && i < 11 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func waitRtspStreaming() async throws {
        for _ in 0..<20 {
            let st = try await api.call("GET", "/streamer/status") as? [String: Any]
            let s = (st?["stream"] as? [[String: Any]])?.first { $0["id"] as? Int == Self.rtspId }
            if s?["statusIdx"] as? Int == 4 { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw MonitorError("RTSP 配信が始まりませんでした")
    }

    private func waitStopped() async throws {
        for _ in 0..<30 {
            let st = try await api.call("GET", "/streamer/status") as? [String: Any]
            if st?["egnStatus"] as? String == "stop", st?["overallStatusIdx"] as? Int == 0 { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw MonitorError("配信エンジンの停止を確認できません")
    }

    private func saveRestore(_ disabled: [Int]) throws {
        // 念のため、既存の記録があれば和集合にして、戻す対象を絶対に減らさない
        var all = Set(disabled)
        if let d = try? Data(contentsOf: Self.restoreFile),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let old = o["disabled"] as? [Int] {
            all.formUnion(old)
        }
        let disabled = all.sorted()
        let data = try JSONSerialization.data(withJSONObject: ["disabled": disabled, "at": ISO8601DateFormatter().string(from: Date())])
        try data.write(to: Self.restoreFile, options: .atomic)
    }

    private func describe(_ e: Error) -> String {
        switch e {
        case let m as MonitorError: return m.message
        case MixerAPI.APIError.http(let code, let body):
            if body.contains("2010150") { return "本体の LAN ポートにケーブルを挿してください" }
            return "HTTP \(code): \(body.prefix(100))"
        case MixerAPI.APIError.auth: return "ログインが必要です"
        case MixerAPI.APIError.offline(let m): return "本体に接続できません: \(m)"
        default: return e.localizedDescription
        }
    }
}

struct MonitorError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

/// ffmpeg の image2pipe (MJPEG) 出力を JPEG 1 枚ずつに切り出す
final class JPEGStreamParser {
    private var buf = Data()
    private let onFrame: (Data) -> Void
    private let lock = NSLock()
    init(onFrame: @escaping (Data) -> Void) { self.onFrame = onFrame }

    func feed(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buf.append(d)
        while true {
            guard let soi = buf.firstRange(of: Data([0xFF, 0xD8])) else { buf.removeAll(); return }
            guard let eoi = buf[soi.upperBound...].firstRange(of: Data([0xFF, 0xD9])) else {
                if soi.lowerBound > buf.startIndex { buf.removeSubrange(buf.startIndex..<soi.lowerBound) }
                return
            }
            onFrame(Data(buf[soi.lowerBound..<eoi.upperBound]))
            buf.removeSubrange(buf.startIndex..<eoi.upperBound)
        }
    }
}

// MARK: - 画面

struct MonitorView: View {
    @EnvironmentObject var mon: MonitorController
    @EnvironmentObject var m: MixerModel

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                if let f = mon.frame {
                    Image(nsImage: f).resizable().aspectRatio(16.0 / 9.0, contentMode: .fit)
                } else {
                    switch mon.state {
                    case .starting: ProgressView("配信エンジンを開始しています…").foregroundStyle(.white)
                    case .stopping: ProgressView("停止して設定を戻しています…").foregroundStyle(.white)
                    case .failed(let msg): Text(msg).foregroundStyle(.orange).multilineTextAlignment(.center).padding()
                    default: Text("停止中").foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(minWidth: 480)

            HStack(spacing: 10) {
                switch mon.state {
                case .running:
                    Label("PGM 受信中  \(String(format: "%.0f", mon.fps)) fps", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                    Text("配信 (YouTube 等) は一時無効").foregroundStyle(.secondary)
                case .idle, .failed:
                    Button("開始") { Task { await mon.start() } }
                default:
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if mon.state == .running {
                    if let start = mon.recordingStart {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Label("録画中 \(elapsed(ctx.date.timeIntervalSince(start)))", systemImage: "record.circle.fill")
                                .foregroundStyle(.red).monospacedDigit()
                        }
                        Button("録画停止") { Task { await mon.stopRecording() } }
                    } else {
                        Button { mon.startRecording() } label: { Label("Mac に録画", systemImage: "record.circle") }
                    }
                    Button("停止") { Task { await mon.stop() } }
                        .help(mon.recordingStart != nil ? "録画も停止して保存します" : "モニターを停止")
                }
                Button { NSWorkspace.shared.open(MonitorController.recordDir) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("録画の保存先 (ムービー/Live Mix Desktop) を開く")
            }
            .font(.caption)
            if let msg = mon.recordMessage {
                Text(msg).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("シーンのオーバーレイに全画面の画像があると、映像はその下に隠れます (シーン設定で非表示にできます)。")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .onAppear { Task { await mon.start() } }
        .onDisappear { Task { await mon.stop() } }
    }

    private func elapsed(_ t: TimeInterval) -> String {
        let n = Int(t); return String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
    }
}
