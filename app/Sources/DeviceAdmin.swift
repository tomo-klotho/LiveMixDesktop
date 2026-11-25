import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 本体の管理 (フェーズ4): プロファイルの書き出し/読み込み、日時、LAN・DNS、工場出荷リセット
@MainActor
final class DeviceAdminModel: ObservableObject {
    // プロファイル
    @Published var profileName = ""
    @Published var profileNameEdit = ""
    // 日時
    @Published var deviceDate = ""
    @Published var deviceDateLoadedAt = Date()   // deviceDate を読んだ時刻 (表示は経過分を足して進める)
    @Published var timezone = "Etc/GMT-9"
    @Published var ntp = false
    // LAN (eth0)
    @Published var ifaceId = "eth0"
    @Published var mac = ""
    @Published var plugged = false
    @Published var ipMode = 0            // 0 DHCP / 3 固定 (IPv4)
    @Published var validModes: [Int] = [0, 3]
    @Published var ip = ""
    @Published var mask = ""
    @Published var gateway = ""
    @Published var curIp = ""
    @Published var curMask = ""
    @Published var curGateway = ""
    @Published var dnsMode = 0           // 0 自動 / 1 固定
    @Published var dnsServers = ""       // 改行・カンマ区切り
    private var curIpMode = 0
    private var curDnsMode = 0
    private var curDnsServers: [String] = []
    // 状態
    @Published var busy = false
    @Published var progress: String?
    @Published var message: String?
    @Published var error: String?
    @Published var confirmImport: URL?
    @Published var confirmNetwork = false
    @Published var showReset = false
    @Published var resetWord = ""

    static let backupDir = URL(fileURLWithPath: NSHomeDirectory() + "/.config/livemixdesktop/profile-backup")
    private let m: MixerModel
    init(model: MixerModel) { m = model }

    var isLive: Bool { m.broadcast.isLive }

    // MARK: 読み込み
    func load() async {
        do {
            if let d = try await m.api.call("GET", "/profile/name") as? [String: Any] {
                profileName = d["profileName"] as? String ?? ""
                profileNameEdit = profileName
            }
            if let d = try await m.api.call("GET", "/datetime") as? [String: Any] {   // 資料の /video/datetime は 404
                deviceDate = d["datetime"] as? String ?? ""
                deviceDateLoadedAt = Date()
                timezone = d["timezone"] as? String ?? timezone
                ntp = d["syncServer"] as? Bool ?? false
            }
            if let d = try await m.api.call("GET", "/network/interfaces") as? [String: Any],
               let i = (d["interfaces"] as? [[String: Any]])?.first {
                ifaceId = i["id"] as? String ?? "eth0"
                mac = i["macAddr"] as? String ?? ""
                plugged = i["isPlugged"] as? Bool ?? false
                let mode = i["mode"] as? [String: Any]
                ipMode = mode?["value"] as? Int ?? 0
                curIpMode = ipMode
                validModes = mode?["valid"] as? [Int] ?? [0, 3]
                curIp = i["ip4Addr"] as? String ?? ""; curMask = i["ip4Mask"] as? String ?? ""
                curGateway = i["ip4Gateway"] as? String ?? ""
                ip = curIp; mask = curMask; gateway = curGateway
            }
            if let d = try await m.api.call("GET", "/network/dns") as? [String: Any] {
                dnsMode = (d["mode"] as? [String: Any])?["value"] as? Int ?? 0
                curDnsMode = dnsMode
                curDnsServers = d["servers"] as? [String] ?? []
                dnsServers = curDnsServers.joined(separator: "\n")
            }
            error = nil
        } catch { self.error = describe(error) }
    }

    // MARK: プロファイル
    func saveProfileName() {
        let n = profileNameEdit.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != profileName else { return }
        run("プロファイル名を変更しました") {
            try await self.m.api.call("PATCH", "/profile/name", ["profileName": n, "sender": "livemixdesktop"])
        }
    }

    /// 本体から profile.tar (config.bson + assets) を取り出す。開始 → ダウンロード → 終了
    private func exportData() async throws -> Data {
        progress = "本体でプロファイルを書き出しています…"
        let r = try await m.api.call("POST", "/profile/export", ["sender": "livemixdesktop"], timeout: 90) as? [String: Any]
        // 書き出しの終了通知 (DELETE) は必ず待ってから次へ進む。終わる前に読み込みを始めると 2010006 で断られる
        do {
            guard let u = r?["url"] as? String, let path = URL(string: u)?.path else {
                throw MixerAPI.APIError.offline("書き出し先の URL がありません")
            }
            progress = "ダウンロードしています…"
            let data = try await m.api.fetchStatic(path, timeout: 120)
            _ = try? await m.api.call("DELETE", "/profile/export", timeout: 30)
            return data
        } catch {
            _ = try? await m.api.call("DELETE", "/profile/export", timeout: 30)
            throw error
        }
    }

    private func fileStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }
    private var safeName: String {
        profileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// 自動バックアップ (読み込み・リセットの前)
    private func autoBackup() async throws -> URL {
        let data = try await exportData()
        try FileManager.default.createDirectory(at: Self.backupDir, withIntermediateDirectories: true)
        let url = Self.backupDir.appendingPathComponent("profile-\(safeName)-\(fileStamp()).tar")
        try data.write(to: url)
        m.log("profile backup \(url.lastPathComponent) \(data.count) bytes")
        return url
    }

    func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LiveMixDesktop-\(safeName)-\(fileStamp()).tar"
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        panel.message = "本体の全設定 (シーン・音声・配信先・画像など) を 1 つのファイルに保存します"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        run(nil) {
            let data = try await self.exportData()
            try data.write(to: dest)
            self.m.log("profile export \(dest.lastPathComponent) \(data.count) bytes")
            self.message = "書き出しました: \(dest.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))"
        }
    }

    func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        panel.message = "読み込むプロファイル (.tar) を選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirmImport = url
    }

    // 読み込みの結果は SocketIO の /profile/import・/profile/errors で届く
    private var importWaiter: CheckedContinuation<String?, Never>?
    func onProfileEvent(_ ev: String, _ payload: Any?) {
        guard ev.hasPrefix("/api/v2.0/profile/") else { return }
        let text = (payload.flatMap { try? JSONSerialization.data(withJSONObject: $0) }).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        m.log("profile event \(ev) \(text.prefix(200))")
        let d = payload as? [String: Any]
        let status = d?["status"] as? String ?? ""
        if ev.hasSuffix("/errors") || ["failed", "error"].contains(status) {
            importWaiter?.resume(returning: "本体がエラーを返しました: \(text.prefix(160))"); importWaiter = nil
        } else if ev.hasSuffix("/import") {
            // 実機: status started → progressing (finished "n/13") → finished
            if status == "finished" { importWaiter?.resume(returning: nil); importWaiter = nil }
            else if importWaiter != nil, let msg = d?["message"] as? String {
                progress = "本体が設定を反映しています… \(d?["finished"] as? String ?? "") \(msg)"
            }
        }
    }

    func importProfile(_ url: URL) {
        run(nil) {
            guard let data = try? Data(contentsOf: url) else { throw MixerAPI.APIError.offline("ファイルを読めません") }
            let backup = try await self.autoBackup()
            self.progress = "読み込みを開始しています…"
            try await self.m.api.call("POST", "/profile/import", ["sender": "livemixdesktop"], timeout: 30)
            do {
                self.progress = "アップロードしています…"
                try await self.m.api.uploadMultipart("/profile/upload", fields: [("sender", "livemixdesktop")],
                                                     fileName: "profile.tar", data: data, contentType: "application/x-tar",
                                                     timeout: 180)
            } catch {
                _ = try? await self.m.api.call("DELETE", "/profile/import", ["sender": "livemixdesktop"])   // 読み込みを取り消す
                throw error
            }
            self.progress = "本体が設定を反映しています…"
            let err = await self.waitImport(seconds: 90)
            self.m.log("profile import \(url.lastPathComponent): \(err ?? "ok")")
            if let err { throw MixerAPI.APIError.offline(err + " (バックアップ: \(backup.lastPathComponent))") }
            await self.normalizePauseName()
            self.message = "読み込みました: \(url.lastPathComponent)。読み込み前の設定は \(backup.lastPathComponent) に保存してあります"
            await self.m.reloadAll()
        }
    }

    /// 本体はプロファイル読み込みのたびに一時停止画像の名前へ "-1" を足す (pause_screen-1-1.bin…)。
    /// 中身はそのままに、元の名前 pause_screen.bin で入れ直す。色/画像の選択と色は保つ
    private func normalizePauseName() async {
        guard let d = try? await m.api.call("GET", "/assets/pause_screen") as? [String: Any],
              let name = d["name"] as? String, name != "pause_screen.bin",
              let u = d["url"] as? String, let path = URL(string: u)?.path,
              let img = try? await m.api.fetchStatic(path) else { return }
        do {
            try await m.api.uploadMultipart("/assets/pause_screen/upload", fields: [("sender", "livemixdesktop")],
                                            fileName: "pause_screen.bin", data: img, contentType: "image/png")
            var keep: [String: Any] = ["sender": "livemixdesktop"]
            if let v = d["isUseColor"] { keep["isUseColor"] = v }
            if let v = d["color"] { keep["color"] = v }
            try await m.api.call("PATCH", "/assets/pause_screen", keep)
            m.log("pause screen renamed \(name) -> pause_screen.bin")
        } catch { m.log("pause screen rename failed: \(error)") }
    }

    /// 読み込み完了イベントを待つ。来なければ時間切れ (それでも本体側では反映されていることがある)
    private func waitImport(seconds: Double) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            importWaiter = c
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let self, let w = self.importWaiter else { return }
                self.importWaiter = nil
                w.resume(returning: "本体から完了の知らせが \(Int(seconds)) 秒以内に届きませんでした。本体の状態を確認してください")
                self.m.log("profile import: no completion event within \(Int(seconds))s")
            }
        }
    }

    // MARK: 日時
    func syncToMac() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = Self.zone(timezone) ?? .current
        let now = f.string(from: Date())
        run("本体の時計を Mac に合わせました") {
            try await self.m.api.call("PATCH", "/datetime", ["datetime": now, "timezone": self.timezone,
                                                             "syncServer": self.ntp, "sender": "livemixdesktop"])
        }
    }

    func setTimezone(_ tz: String) {
        timezone = tz
        run("タイムゾーンを変更しました") {
            try await self.m.api.call("PATCH", "/datetime", ["timezone": tz, "sender": "livemixdesktop"])
        }
    }

    func setNTP(_ on: Bool) {
        ntp = on
        run(on ? "インターネットの時刻に自動で合わせます" : "自動合わせをやめました") {
            try await self.m.api.call("PATCH", "/datetime", ["syncServer": on, "sender": "livemixdesktop"])
        }
    }

    /// "Etc/GMT-9" → UTC+9 (Etc の符号は逆)
    static func zone(_ id: String) -> TimeZone? { TimeZone(identifier: id) }
    static let zones: [(id: String, label: String)] = (-12...14).reversed().map { h in
        let id = h == 0 ? "Etc/GMT" : "Etc/GMT\(h > 0 ? "-" : "+")\(abs(h))"
        let extra = h == 9 ? " (日本)" : h == 0 ? " (UTC)" : ""
        return (id, "UTC\(h >= 0 ? "+" : "")\(h)\(extra)")
    }

    // MARK: ネットワーク
    var networkError: String? {
        if ipMode == 3 {
            for (n, v) in [("IP アドレス", ip), ("サブネットマスク", mask), ("ゲートウェイ", gateway)] where !Self.isIPv4(v) {
                return "\(n) の形式が正しくありません"
            }
        }
        if dnsMode == 1 {
            let list = servers
            if list.isEmpty { return "DNS サーバーを 1 つ以上入力してください" }
            if let bad = list.first(where: { !Self.isIPv4($0) && !$0.contains(":") }) { return "DNS「\(bad)」の形式が正しくありません" }
        }
        return nil
    }
    var servers: [String] {
        dnsServers.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }
    static func isIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 4 && p.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// IP 側・DNS 側で変わったものだけを送る (同じ値でも送ると本体が LAN を張り直すことがある)
    var ifaceChanged: Bool {
        ipMode != curIpMode || (ipMode == 3 && (ip != curIp || mask != curMask || gateway != curGateway))
    }
    var dnsChanged: Bool { dnsMode != curDnsMode || (dnsMode == 1 && servers != curDnsServers) }

    func applyNetwork() {
        let sendIface = ifaceChanged, sendDNS = dnsChanged
        guard sendIface || sendDNS else { message = "変更はありません"; return }
        var iface: [String: Any] = ["mode": ["value": ipMode], "sender": "livemixdesktop"]
        if ipMode == 3 { iface["ip4Addr"] = ip; iface["ip4Mask"] = mask; iface["ip4Gateway"] = gateway }
        var dns: [String: Any] = ["mode": ["value": dnsMode], "sender": "livemixdesktop"]
        if dnsMode == 1 { dns["servers"] = servers }
        run("LAN の設定を変更しました。反映まで少しかかることがあります") {
            if sendIface {
                try await self.m.api.call("PATCH", "/network/interfaces/\(self.ifaceId)", iface, timeout: 30)
                self.m.log("network: iface \(iface.filter { $0.key != "sender" })")
            }
            if sendDNS {
                try await self.m.api.call("PATCH", "/network/dns", dns, timeout: 30)
                self.m.log("network: dns \(dns.filter { $0.key != "sender" })")
            }
        }
    }

    // MARK: 工場出荷リセット
    static let resetWordRequired = "リセット"
    func factoryReset() {
        guard resetWord == Self.resetWordRequired else { return }
        showReset = false; resetWord = ""
        run(nil) {
            let backup = try await self.autoBackup()
            self.progress = "工場出荷時の設定に戻しています…"
            try await self.m.api.call("POST", "/system/reset", timeout: 60)
            self.m.log("FACTORY RESET (backup \(backup.lastPathComponent))")
            self.message = "工場出荷時の設定に戻しました。ログインは administrator / password に戻ります。元の設定は \(backup.lastPathComponent) から読み込めます"
        }
    }

    // MARK: 共通
    private func run(_ done: String?, _ f: @escaping () async throws -> Void) {
        Task {
            busy = true; message = nil; error = nil
            defer { busy = false; progress = nil }
            do {
                try await f()
                if let done { message = done }
                await load()
            } catch { self.error = describe(error) }
        }
    }

    private func describe(_ e: Error) -> String {
        switch e {
        case MixerAPI.APIError.http(let c, let b): return "HTTP \(c): \(b.prefix(120))"
        case MixerAPI.APIError.auth: return "ログインが必要です"
        case MixerAPI.APIError.offline(let s): return s
        default: return e.localizedDescription
        }
    }
}

// MARK: - 画面

struct DeviceAdminView: View {
    @EnvironmentObject var a: DeviceAdminModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if a.isLive {
                    Label("配信中は読み込み・LAN 変更・リセットはできません", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
                profile
                Divider()
                datetime
                Divider()
                network
                Divider()
                reset
                status
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 600)
        .disabled(a.busy)
        .task { await a.load() }
        .alert("プロファイルを読み込む", isPresented: Binding(get: { a.confirmImport != nil }, set: { if !$0 { a.confirmImport = nil } })) {
            Button("読み込む", role: .destructive) { if let u = a.confirmImport { a.importProfile(u) }; a.confirmImport = nil }
            Button("やめる", role: .cancel) { a.confirmImport = nil }
        } message: {
            Text("「\(a.confirmImport?.lastPathComponent ?? "")」で本体の全設定 (シーン・音声・配信先・画像) を置き換えます。読み込む前に今の設定を自動で書き出して保存します。")
        }
        .alert("LAN の設定を変更", isPresented: $a.confirmNetwork) {
            Button("変更する", role: .destructive) { a.applyNetwork() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("本体の LAN (配信に使うネットワーク) の設定を変えます。値を間違えると配信できなくなります。Mac との USB 接続には影響しません。")
        }
        .sheet(isPresented: $a.showReset) { ResetSheet().environmentObject(a) }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("プロファイル (全設定のバックアップ)").font(.subheadline.bold())
            HStack {
                Text("名前").font(.caption)
                TextField("", text: $a.profileNameEdit).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("変更") { a.saveProfileName() }
                    .disabled(a.profileNameEdit.trimmingCharacters(in: .whitespaces).isEmpty || a.profileNameEdit == a.profileName)
            }
            HStack {
                Button { a.exportProfile() } label: { Label("書き出す…", systemImage: "square.and.arrow.down") }
                Button { a.chooseImport() } label: { Label("読み込む…", systemImage: "square.and.arrow.up") }
                    .disabled(a.isLive)
                Spacer()
                Button { NSWorkspace.shared.open(DeviceAdminModel.backupDir) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("自動バックアップの保存先を開く")
            }
            Text("シーン・音声・配信先・エンコード・画像アセット・一時停止画面をまとめて保存/復元します (本体の公式機能)。読み込みとリセットの前には、今の設定を自動で ~/.config/livemixdesktop/profile-backup に書き出します。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var datetime: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日時").font(.subheadline.bold())
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack {
                        Text("本体の時計: \(displayDate(ctx.date))").font(.caption.monospacedDigit())
                        if isClockOff { Label("ずれています", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                    }
                }
                Spacer()
                Button("Mac の時刻に合わせる") { a.syncToMac() }
            }
            HStack {
                Picker("タイムゾーン", selection: Binding(get: { a.timezone }, set: { a.setTimezone($0) })) {
                    if !DeviceAdminModel.zones.contains(where: { $0.id == a.timezone }) { Text(a.timezone).tag(a.timezone) }
                    ForEach(DeviceAdminModel.zones, id: \.id) { Text($0.label).tag($0.id) }
                }
                .frame(width: 240).font(.caption)
                Toggle("インターネットの時刻に自動で合わせる (NTP)", isOn: Binding(get: { a.ntp }, set: { a.setNTP($0) }))
                    .toggleStyle(.checkbox).font(.caption)
            }
            Text("録画ファイルの日時などに使われます。NTP は本体の LAN がインターネットにつながっているときだけ働きます。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var deviceDateValue: Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.date(from: a.deviceDate)
    }
    /// 読んだ時刻から経過した分を足して、本体の今の時刻として表示する
    private func displayDate(_ now: Date) -> String {
        guard let d = deviceDateValue else { return a.deviceDate.isEmpty ? "—" : a.deviceDate }
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd HH:mm:ss"; f.timeZone = DeviceAdminModel.zone(a.timezone) ?? .current
        return f.string(from: d.addingTimeInterval(now.timeIntervalSince(a.deviceDateLoadedAt)))
    }
    /// 本体と Mac の差 (読んだ時点で比べる。経過時間には左右されない)
    private var isClockOff: Bool { deviceDateValue.map { abs($0.timeIntervalSince(a.deviceDateLoadedAt)) > 120 } ?? false }

    private var network: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAN (配信用ネットワーク・\(a.ifaceId))").font(.subheadline.bold())
            HStack(spacing: 12) {
                Label(a.plugged ? "ケーブル接続中" : "ケーブル未接続", systemImage: a.plugged ? "cable.connector" : "cable.connector.slash")
                    .font(.caption).foregroundStyle(a.plugged ? Color.primary : Color.orange)
                Text("現在 \(a.curIp) / \(a.curMask)  GW \(a.curGateway)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(a.mac).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Picker("IP アドレス", selection: $a.ipMode) {
                Text("自動 (DHCP)").tag(0)
                Text("固定").tag(3)
                if ![0, 3].contains(a.ipMode) { Text("その他 (\(a.ipMode))").tag(a.ipMode) }
            }
            .pickerStyle(.segmented).frame(width: 280)
            if a.ipMode == 3 {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow { Text("IP アドレス").font(.caption); TextField("192.168.0.10", text: $a.ip).frame(width: 160) }
                    GridRow { Text("サブネットマスク").font(.caption); TextField("255.255.255.0", text: $a.mask).frame(width: 160) }
                    GridRow { Text("ゲートウェイ").font(.caption); TextField("192.168.0.1", text: $a.gateway).frame(width: 160) }
                }
                .textFieldStyle(.roundedBorder).font(.caption.monospacedDigit())
            }
            Picker("DNS", selection: $a.dnsMode) {
                Text("自動").tag(0)
                Text("固定").tag(1)
            }
            .pickerStyle(.segmented).frame(width: 200)
            if a.dnsMode == 1 {
                TextEditor(text: $a.dnsServers).font(.caption.monospaced()).frame(width: 300, height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                Text("1 行に 1 つ (IPv4 / IPv6)").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("いま使っている DNS: \(a.dnsServers.replacingOccurrences(of: "\n", with: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                if let e = a.networkError { Text(e).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("元に戻す") { Task { await a.load() } }
                Button("LAN 設定を変更…") { a.confirmNetwork = true }
                    .disabled(a.networkError != nil || a.isLive || !(a.ifaceChanged || a.dnsChanged))
            }
        }
    }

    private var reset: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工場出荷リセット").font(.subheadline.bold())
            HStack {
                Text("本体のすべての設定を工場出荷時に戻します。先に今の設定を自動で書き出します。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("リセット…", role: .destructive) { a.showReset = true }.disabled(a.isLive)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let p = a.progress { HStack { ProgressView().controlSize(.small); Text(p).font(.caption) } }
        if let msg = a.message { Text(msg).font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true) }
        if let e = a.error { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
    }
}

/// リセットは取り消せないので、決まった言葉の入力を求める
struct ResetSheet: View {
    @EnvironmentObject var a: DeviceAdminModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("工場出荷時の設定に戻す", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
            Text("シーン・音声・配信先 (ストリームキー)・画像・LAN 設定・ログインパスワードがすべて初期状態に戻ります。取り消せません。\n実行前に今の設定を ~/.config/livemixdesktop/profile-backup に書き出し、あとで「読み込む」で戻せるようにします。")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("実行するには「\(DeviceAdminModel.resetWordRequired)」と入力してください").font(.caption)
            TextField("", text: $a.resetWord).textFieldStyle(.roundedBorder).frame(width: 160)
            HStack {
                Spacer()
                Button("やめる", role: .cancel) { a.showReset = false; a.resetWord = "" }.keyboardShortcut(.cancelAction)
                Button("リセットする", role: .destructive) { a.factoryReset() }
                    .disabled(a.resetWord != DeviceAdminModel.resetWordRequired)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
