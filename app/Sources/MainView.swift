import SwiftUI

/// 1 つのウインドウに全画面をまとめる。左の一覧で画面を切り替える
enum AppSection: String, CaseIterable, Identifiable {
    case live, scenes, broadcast, assets, device, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "本番"
        case .scenes: return "シーン設定"
        case .broadcast: return "配信設定"
        case .assets: return "画像"
        case .device: return "本体の管理"
        case .settings: return "本体の設定一覧"
        }
    }
    var icon: String {
        switch self {
        case .live: return "play.tv"
        case .scenes: return "rectangle.3.group"
        case .broadcast: return "dot.radiowaves.left.and.right"
        case .assets: return "photo.on.rectangle.angled"
        case .device: return "wrench.and.screwdriver"
        case .settings: return "list.bullet.rectangle"
        }
    }
    var subtitle: String {
        switch self {
        case .live: return "映像の切替・音声・ライブ開始"
        case .scenes: return "シーンの配置・文字・画像"
        case .broadcast: return "配信先・画質・一時停止画面"
        case .assets: return "本体に入れた画像"
        case .device: return "バックアップ・日時・LAN"
        case .settings: return "本体の全設定を見る (変更なし)"
        }
    }
    /// 起動時に開く画面 (LMD_SECTION=scenes など。既定は本番)
    static var initial: AppSection {
        ProcessInfo.processInfo.environment["LMD_SECTION"].flatMap(AppSection.init(rawValue:)) ?? .live
    }
}

struct MainView: View {
    @EnvironmentObject var m: MixerModel

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding(get: { m.section }, set: { if let v = $0 { m.section = v } })) {
                Section("操作") {
                    row(.live); row(.scenes)
                }
                Section("設定") {
                    row(.broadcast); row(.assets)
                }
                Section("本体") {
                    row(.device); row(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)   // 一覧は常に表示
            .safeAreaInset(edge: .bottom) { footer }
        } detail: {
            VStack(spacing: 0) {
                if m.conn == .needsLogin {
                    LoginView().frame(maxWidth: 360).padding(40)
                    Spacer()
                } else {
                    detail
                }
            }
            .navigationTitle(m.section.title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1220, minHeight: 700)
    }

    private func row(_ s: AppSection) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(s.title, systemImage: s.icon)
            Text(s.subtitle).font(.caption2).foregroundStyle(.secondary).padding(.leading, 26)
        }
        .tag(s)
        .padding(.vertical, 2)
    }

    @ViewBuilder private var detail: some View {
        switch m.section {
        case .live:
            LiveView().environmentObject(m.broadcast).environmentObject(m.monitor).environmentObject(m.levels)
        case .scenes:
            SceneEditorView().environmentObject(m.editor)
        case .broadcast:
            BroadcastView().environmentObject(m.broadcast)
        case .assets:
            AssetsView().environmentObject(m.assetsModel)
        case .device:
            DeviceAdminView().environmentObject(m.admin)
        case .settings:
            SettingsView().environmentObject(m.settings)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(m.conn == .ok ? Color.green : m.offlineSince != nil ? Color.orange : Color.gray).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.deviceName).font(.caption.bold()).lineLimit(1)
                    Text(m.conn == .ok ? "接続中  PGM \(m.pgm) / PRV \(m.prv)" : m.offlineSince != nil ? "切断中" : "未接続")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await m.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("読み直す")
            }
            .padding(.horizontal, 12)
            Text(AppVersion.label).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).help("Live Mix Desktop \(AppVersion.label)")
                .padding(.horizontal, 12).padding(.bottom, 8)
                .textSelection(.enabled)
        }
    }
}
