import SwiftUI

/// 終了時にモニターが動いていたら、本体の配信設定を元に戻してから終わる
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var monitor: MonitorController?

    @MainActor static var editor: SceneEditorModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // シーン設定に未適用の変更があれば確認する
        if let ed = AppDelegate.editor, ed.dirty {
            let a = NSAlert()
            a.messageText = "シーン \(ed.sceneId) に未適用の変更があります"
            a.informativeText = "終了すると、この変更は失われます。"
            a.addButton(withTitle: "キャンセル")
            a.addButton(withTitle: "破棄して終了")
            if a.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        guard MonitorController.needsRestore else { return .terminateNow }
        Task { @MainActor in
            await AppDelegate.monitor?.restore()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 起動中にもう一度 open / ダブルクリックされたら、操作ウインドウを前に出す
    @MainActor static var openMain: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            AppDelegate.openMain?()
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.centerMainWindow()
        }
        return false
    }

    /// 操作ウインドウをメインディスプレイ (メニューバーのある画面) の中央に移して前面へ
    @MainActor static func centerMainWindow() {
        DispatchQueue.main.async {
            guard let w = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("main") && $0.isVisible }),
                  let screen = NSScreen.screens.first else { return }
            let vf = screen.visibleFrame
            var f = w.frame
            f.size.width = min(f.width, vf.width); f.size.height = min(f.height, vf.height)   // 画面に収める
            f.origin = NSPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2)
            w.setFrame(f, display: true)
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// 指定タイトルのウインドウをメインディスプレイ (内蔵ディスプレイ) の中央へ
    @MainActor static func centerWindow(titled title: String) {
        DispatchQueue.main.async {
            guard let w = NSApp.windows.first(where: { $0.title == title && $0.isVisible }),
                  let screen = NSScreen.screens.first else { return }
            let vf = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: vf.midX - w.frame.width / 2, y: vf.midY - w.frame.height / 2))
            w.makeKeyAndOrderFront(nil)
        }
    }
}

/// openWindow をアプリデリゲートから呼べるように受け渡す (メニューバーのラベルは常に存在する)
struct OpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    let systemImage: String
    var body: some View {
        Image(systemName: systemImage)
            .onAppear { AppDelegate.openMain = { openWindow(id: "main") } }
    }
}

@main
struct LiveMixDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = MixerModel()

    var body: some Scene {
        // すべての画面を 1 つのウインドウにまとめる (左の一覧で切り替え)
        Window("Live Mix Desktop", id: "main") {
            MainView().environmentObject(model)
                .onAppear { AppDelegate.centerMainWindow() }
        }
        .defaultSize(width: 1440, height: 880)
        .defaultPosition(.center)
        .defaultLaunchBehavior(ProcessInfo.processInfo.environment["LMD_NOWINDOW"] == "1" ? .suppressed : .presented)

        MenuBarExtra {
            MixerView().environmentObject(model).environmentObject(model.levels)
        } label: {
            OpenWindowBridge(systemImage: model.conn == .ok ? "slider.horizontal.3" : "slider.horizontal.below.rectangle")
        }
        .menuBarExtraStyle(.window)

    }
}

struct MixerView: View {
    @EnvironmentObject var m: MixerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ConnectionBanner(compact: true)
            switch m.conn {
            case .needsLogin: LoginView()
            case .offline(let msg):
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            case .unknown:
                ProgressView().frame(maxWidth: .infinity)
            case .ok:
                ThumbsView()
                ScenesView()
                Divider()
                AudioSection(title: "入力", kind: .input, channels: m.inputs)
                AudioSection(title: "出力", kind: .output, channels: m.outputs.filter { $0.name != "DisplayA Audio" },
                             note: "Stream Out を変えると DisplayA も連動します")
            }
            if let e = m.lastError {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { m.startPolling() }
        .onDisappear { m.stopPolling() }
    }

    private var header: some View {
        HStack {
            Circle().fill(m.conn == .ok ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(m.deviceName).font(.headline)
            Spacer()
            Button {
                m.section = .live; openMainWindow()
            } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless).help("Live Mix Desktop のウインドウを開く")
            Button { Task { await m.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("再読み込み")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("終了")
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ThumbsView: View {
    @EnvironmentObject var m: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("入力").font(.subheadline.bold())
                Spacer()
                Toggle("表示", isOn: $m.showThumbs).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            if m.showThumbs {
                HStack(spacing: 6) {
                    ForEach(Array(m.thumbs.enumerated()), id: \.offset) { _, t in
                        VStack(spacing: 2) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.85))
                                if let img = t.image {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                } else {
                                    Text("信号なし").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .aspectRatio(16.0 / 10.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(t.label).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct ScenesView: View {
    @EnvironmentObject var m: MixerModel
    /// 渡すとボタンにシーンの縮小表示を出す (本番画面)
    var specs: [Int: SceneThumbsModel.Spec]? = nil
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("シーン").font(.subheadline.bold())
                Spacer()
                legend(.red, "PGM"); legend(.green, "PRV")
            }
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(1...8, id: \.self) { n in
                    Button { m.selectPreview(n) } label: {
                        if let specs = specs {
                            SceneThumbView(spec: specs[n], inputs: m.thumbs)
                                .overlay(alignment: .topLeading) {
                                    Text("\(n)").font(.caption.monospacedDigit().bold())
                                        .frame(minWidth: 16).padding(.horizontal, 3)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(n == m.pgm || n == m.prv ? fill(n) : Color.black.opacity(0.6)))
                                        .foregroundStyle(.white).padding(3)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(n == m.pgm || n == m.prv ? border(n) : Color.primary.opacity(0.2), lineWidth: n == m.pgm || n == m.prv ? 3 : 1))
                                .contentShape(Rectangle())
                        } else {
                            Text("\(n)").font(.title3.monospacedDigit().bold())
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(RoundedRectangle(cornerRadius: 6).fill(fill(n)))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border(n), lineWidth: 2))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(n == m.pgm || m.transitioning)
                    .help(m.sceneNames[n] ?? "Scene \(n)")
                }
            }
            HStack {
                Button("CUT") { m.cut() }.keyboardShortcut(.space, modifiers: [])
                Button("AUTO") { m.auto() }.keyboardShortcut(.return, modifiers: [])
                Picker("", selection: $m.autoMs) {
                    ForEach([500, 1000, 2000, 3000], id: \.self) { Text(String(format: "%.1f 秒", Double($0) / 1000)).tag($0) }
                }
                .labelsHidden().frame(width: 80)
                Spacer()
                if m.transitioning { ProgressView().controlSize(.small) }
            }
            .disabled(m.transitioning)
        }
    }

    private func fill(_ n: Int) -> Color {
        n == m.pgm ? .red.opacity(0.85) : n == m.prv ? .green.opacity(0.85) : Color.primary.opacity(0.08)
    }
    private func border(_ n: Int) -> Color { n == m.pgm ? .red : n == m.prv ? .green : .clear }
    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 3) { Circle().fill(c).frame(width: 7, height: 7); Text(t).font(.caption2).foregroundStyle(.secondary) }
    }
}

struct AudioSection: View {
    @EnvironmentObject var m: MixerModel
    @EnvironmentObject var levels: LevelsModel
    let title: String
    let kind: Kind
    let channels: [AudioChannel]
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            ForEach(channels) { ch in
                // AFV 中は本体の isMute が true になるが、実際は PGM に乗るので「ミュート」とは表示しない
                let afvOn = kind == .input && m.afv[ch.id] == true
                let muted = ch.isMute && !afvOn
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        Button { m.toggleMute(kind, ch.id) } label: {
                            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .foregroundStyle(muted ? .red : .primary).frame(width: 18)
                        }
                        .buttonStyle(.borderless)
                        .help(afvOn ? "AFV 中です。押すとミュートになり、AFV は切れます" : muted ? "ミュート解除" : "ミュート")
                        Text(shortName(ch.name)).font(.caption).frame(width: 64, alignment: .leading)
                            .overlay(alignment: .trailing) { afvButton(ch) }
                        Slider(value: Binding(get: { ch.gain },
                                              set: { m.setGain(kind, ch.id, snap($0, ch)) }),
                               in: ch.minDB...ch.maxDB)
                            .controlSize(.small)
                            .opacity(muted ? 0.45 : 1)
                        Text(String(format: "%+.1f", ch.gain)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                    }
                    if let lv = levels.level["\(kind.rawValue)-\(ch.id)"] {
                        VStack(spacing: 1) {
                            MeterBar(db: muted ? -80 : lv.l)
                            MeterBar(db: muted ? -80 : lv.r)
                        }
                        .padding(.leading, 90).padding(.trailing, 48)
                    }
                }
                .contextMenu { Button("0 dB に戻す") { m.setGain(kind, ch.id, 0) } }
            }
            if let note = note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    /// HDMI 入力だけに出す AFV (Audio Follows Video) の切り替え
    @ViewBuilder private func afvButton(_ ch: AudioChannel) -> some View {
        if kind == .input, let on = m.afv[ch.id] {
            let silent = on && m.audibleOnPgm[ch.id] == false
            Button { m.setAFV(ch.id, !on) } label: {
                Text("AFV").font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(on ? Color.accentColor : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? Color.clear : Color.secondary.opacity(0.6)))
                    .foregroundStyle(on ? Color.white : Color.secondary)
                    .opacity(silent ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .help(on ? (silent ? "AFV オン: この入力の映像が PGM に無いので、今は音が PGM に乗っていません"
                               : "AFV オン: この入力の映像が PGM に映っているときだけ音を PGM に乗せます")
                     : "AFV オフ: どのシーンでも音を PGM に乗せます。押すと、映像が PGM に映っているときだけ鳴らします")
        }
    }

    private func snap(_ v: Double, _ ch: AudioChannel) -> Double {
        min(max((v / ch.stepDB).rounded() * ch.stepDB, ch.minDB), ch.maxDB)
    }

    private func shortName(_ n: String) -> String {
        n.replacingOccurrences(of: " Audio", with: "").replacingOccurrences(of: "Mic. In", with: "Mic")
    }
}

/// 音声レベルメーター (1 本 = L または R)。-60dB〜0dB を 0〜1 にマップ。
struct MeterBar: View {
    let db: Double
    var body: some View {
        GeometryReader { geo in
            let frac = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: geo.size.width * CGFloat(frac))
            }
        }
        .frame(height: 3)
    }
    private var color: Color { db > -3 ? .red : db > -12 ? .yellow : .green }
}

/// @State はマクロ実装で Command Line Tools だけでは使えないため、ObservableObject で持つ
final class LoginForm: ObservableObject {
    @Published var user = "administrator"
    @Published var password = ""
    @Published var remember = true
    @Published var busy = false
}

struct LoginView: View {
    @EnvironmentObject var m: MixerModel
    @StateObject private var f = LoginForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本体にログイン").font(.subheadline.bold())
            TextField("ユーザー名", text: $f.user).textFieldStyle(.roundedBorder)
            SecureField("パスワード", text: $f.password).textFieldStyle(.roundedBorder).onSubmit(submit)
            Toggle("キーチェーンに保存して自動ログイン", isOn: $f.remember).font(.caption)
            HStack {
                Spacer()
                if f.busy { ProgressView().controlSize(.small) }
                Button("ログイン", action: submit).keyboardShortcut(.defaultAction).disabled(f.password.isEmpty || f.busy)
            }
        }
    }

    private func submit() {
        f.busy = true
        Task { @MainActor in
            await m.login(user: f.user, password: f.password, remember: f.remember)
            f.password = ""
            f.busy = false
        }
    }
}
