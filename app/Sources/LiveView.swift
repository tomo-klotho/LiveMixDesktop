import AppKit
import SwiftUI

/// 本番用の操作画面: Program モニター・シーン切替・音声・配信状態を 1 画面に。
/// キーボード: 1〜8 で Preview を選ぶ / Space で CUT / Return で AUTO。
/// 誤操作を防ぐため、ライブ開始・停止にはショートカットを付けない (確認ダイアログ必須)。
struct LiveView: View {
    @EnvironmentObject var m: MixerModel
    @EnvironmentObject var b: BroadcastModel
    @EnvironmentObject var mon: MonitorController
    @EnvironmentObject var levels: LevelsModel

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            ConnectionBanner().padding(.horizontal, 14).padding(.top, 8)
            if let msg = b.startFailure, !b.isLive {
                Label(msg, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 6)
            }
            Divider()
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    monitor
                    ThumbsView()
                }
                .frame(minWidth: 560)
                VStack(alignment: .leading, spacing: 14) {
                    ScenesView()
                    sceneNameList
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            AudioSection(title: "入力", kind: .input, channels: m.inputs)
                            AudioSection(title: "出力", kind: .output, channels: m.outputs.filter { $0.name != "DisplayA Audio" })
                        }
                    }
                }
                .frame(width: 360)
            }
            .padding(14)
        }
        .background(numberKeys)
        .frame(minWidth: 960, minHeight: 640)
        .onAppear { m.startPolling(); b.start() }
        .onDisappear {
            m.stopPolling(); b.stop()
            Task { await mon.stop() }   // モニターで一時無効にした配信先を戻す (受信だけのときは配信に触らない)
        }
        .alert("ライブ配信を開始", isPresented: $b.confirmLive) {
            Button("開始する", role: .destructive) { b.goLive() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("有効な配信先 (\(liveTargets)) に配信を始めます。YouTube 等に実際に公開されます。")
        }
        .alert("配信を停止", isPresented: $confirmStop.value) {
            Button("停止する", role: .destructive) { b.stopLive() }
            Button("続ける", role: .cancel) {}
        } message: {
            Text("ライブ配信を終了します。")
        }
    }

    @StateObject private var confirmStop = Flag()

    private var liveTargets: String {
        b.streams.filter { $0.isEnabled && !$0.isRecording && $0.id != MonitorController.ipadStreamId && $0.id != MonitorController.rtspId }
            .map(\.name).joined(separator: ", ")
    }

    // MARK: 配信状態
    private var statusBar: some View {
        HStack(spacing: 14) {
            Circle().fill(m.conn == .ok ? Color.green : Color.gray).frame(width: 8, height: 8)
                .help(m.conn == .ok ? "本体に接続中" : "本体に接続できません")
            Text(m.deviceName).font(.headline)
            Divider().frame(height: 22)
            Circle().fill(b.isLive ? Color.red : Color.gray).frame(width: 12, height: 12)
            Text(b.isLive ? "配信中" : "停止中").font(.title3.bold()).foregroundStyle(b.isLive ? .red : .secondary)
            if b.isLive {
                Text(String(format: "%02d:%02d:%02d", b.liveSeconds / 3600, (b.liveSeconds / 60) % 60, b.liveSeconds % 60))
                    .font(.title3.monospacedDigit())
            }
            ForEach(b.streams.filter { $0.isEnabled && $0.id != MonitorController.ipadStreamId }) { s in
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.name).font(.caption.bold())
                    Text(b.isLive ? "\(s.statusMsg)  \(s.bitrate) kbps \(s.qualityLabel)" : (s.isRecording ? "録画" : "待機"))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if b.busy { ProgressView().controlSize(.small) }
            if b.isLive {
                Button("一時停止") { b.pause() }
                Button("再開") { b.resume() }
                Button("配信停止") { confirmStop.value = true }.tint(.red)
            } else {
                Button("ライブ開始") { b.confirmLive = true }
                    .tint(.red).buttonStyle(.borderedProminent)
                    .disabled(liveTargets.isEmpty || m.conn != .ok)
            }
            Button { m.section = .broadcast } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("配信先・エンコードの設定")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(b.isLive ? Color.red.opacity(0.08) : Color.clear)
    }

    // MARK: Program モニター
    private var monitor: some View {
        VStack(spacing: 6) {
            ZStack {
                Color.black
                if let f = mon.frame {
                    Image(nsImage: f).resizable().aspectRatio(16.0 / 9.0, contentMode: .fit)
                } else {
                    switch mon.state {
                    case .starting: ProgressView("映像を準備しています…").foregroundStyle(.white)
                    case .stopping: ProgressView("停止しています…").foregroundStyle(.white)
                    case .failed(let msg): Text(msg).foregroundStyle(.orange).multilineTextAlignment(.center).padding()
                    default:
                        VStack(spacing: 8) {
                            Text("Program モニター").foregroundStyle(.secondary)
                            Text(mon.source == .ipad ? "iPad Stream (720p・15fps・映像のみ) で表示します。配信の設定には触りません"
                                 : b.isLive ? "配信中は高画質 (RTSP) のモニターを使えません。iPad Stream に切り替えてください"
                                 : "表示中は配信先 (YouTube 等) を一時的に無効にします")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .padding()
                    }
                }
                VStack {
                    HStack {
                        Text("PGM  シーン \(m.pgm)").font(.caption.bold()).padding(4)
                            .background(Color.red.opacity(0.85)).foregroundStyle(.white)
                        Spacer()
                        if let start = mon.recordingStart {
                            TimelineView(.periodic(from: start, by: 1)) { ctx in
                                Label(elapsed(ctx.date.timeIntervalSince(start)), systemImage: "record.circle.fill")
                                    .font(.caption.monospacedDigit()).padding(4)
                                    .background(.black.opacity(0.6)).foregroundStyle(.red)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(6)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            HStack(spacing: 8) {
                switch mon.state {
                case .running:
                    Text(mon.usingIPad ? "iPad Stream で受信中 (720p)" : mon.attached ? "配信の映像を受信中" : "モニター中 (配信先は一時無効)")
                        .font(.caption).foregroundStyle(mon.usingIPad || mon.attached ? .green : .orange)
                    Text("\(String(format: "%.0f", mon.fps)) fps").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if mon.recordingStart != nil {
                        Button("Mac 録画を停止") { Task { await mon.stopRecording() } }
                    } else if !mon.usingIPad {
                        Button { mon.startRecording() } label: { Label("Mac に録画", systemImage: "record.circle") }
                    }
                    Button("モニターを閉じる") { Task { await mon.stop() } }
                case .idle, .failed:
                    Picker("", selection: $mon.source) {
                        ForEach(MonitorController.Source.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize().help(mon.source.help)
                    Spacer()
                    Button("モニターを表示") { Task { await mon.start() } }
                        .disabled(m.conn != .ok)
                default:
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
            if let msg = mon.recordMessage {
                Text(msg).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: シーン名 (1〜8)
    private var sceneNameList: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), spacing: 2) {
            ForEach(1...8, id: \.self) { n in
                Text("\(n)  \(m.sceneNames[n] ?? "Scene \(n)")")
                    .font(.caption2).lineLimit(1)
                    .foregroundStyle(n == m.pgm ? .red : n == m.prv ? .green : .secondary)
            }
        }
    }

    // MARK: 数字キー 1〜8 → Preview (画面には出さないボタンでショートカットを受ける)
    private var numberKeys: some View {
        ZStack {
            ForEach(1...8, id: \.self) { n in
                Button("") { m.selectPreview(n) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: [])
                    .disabled(n == m.pgm || m.transitioning)
            }
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func elapsed(_ t: TimeInterval) -> String {
        let n = Int(t); return String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
    }
}

/// @State の代わり (Command Line Tools ではマクロが使えないため)
final class Flag: ObservableObject { @Published var value = false }
