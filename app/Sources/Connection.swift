import Darwin
import SwiftUI

/// USB 接続 (本体の USB-LAN) が Mac 側に見えているか。
/// 本体アドレスと同じ /24 の IPv4 を持つインターフェースがあれば「ケーブルはつながっている」とみなす
enum LinkCheck {
    static func interfaceName() -> String? {
        let parts = MixerAPI.host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let prefix = parts.prefix(3).joined(separator: ".") + "."
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (a.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buf)
            if ip.hasPrefix(prefix) && ip != MixerAPI.host { return String(cString: a.pointee.ifa_name) }
        }
        return nil
    }
}

/// 切断の原因の見立て
enum LinkHint: Equatable {
    case noCable        // Mac に本体の USB-LAN が見えない
    case noResponse     // USB は見えるが本体が応答しない (起動中・処理中)

    var title: String {
        switch self {
        case .noCable: return "本体との USB 接続が切れています"
        case .noResponse: return "本体が応答しません"
        }
    }
    var detail: String {
        switch self {
        case .noCable: return "USB ケーブルが外れているか、本体の電源が切れています。ケーブルと電源を確かめてください。つながれば自動で再接続します。"
        case .noResponse: return "USB はつながっています。本体の起動中 (電源投入から約 1 分) か、処理が混んでいる可能性があります。自動で再接続します。"
        }
    }
}

/// 切断中に各画面の上に出す案内
struct ConnectionBanner: View {
    @EnvironmentObject var m: MixerModel
    var compact = false

    var body: some View {
        if let since = m.offlineSince {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: m.linkHint == .noCable ? "cable.connector.slash" : "exclamationmark.triangle.fill")
                    .font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text((m.linkHint ?? .noResponse).title).font(.callout.bold()).fixedSize(horizontal: false, vertical: true)
                        TimelineView(.periodic(from: since, by: 1)) { ctx in
                            Text(Self.elapsed(ctx.date.timeIntervalSince(since))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text((m.linkHint ?? .noResponse).detail).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if compact { Button("今すぐ再接続") { m.reconnectNow() }.controlSize(.small).padding(.top, 2) }
                    if m.wasLiveAtDrop && !compact {
                        Text("配信中でした。配信は本体が単独で続けるので、通常は止まりません。再接続後に配信の状態を確かめてください。")
                            .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if !compact { Button("今すぐ再接続") { m.reconnectNow() }.controlSize(.small) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.5)))
        } else if let msg = m.recoveredMessage {
            Label(msg, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let n = max(0, Int(t)); return n < 3600 ? String(format: "%d:%02d", n / 60, n % 60) : String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
    }
}

extension MixerModel {
    /// 接続状態が変わったときの後処理 (conn の didSet から)
    func connChanged(from old: Conn) {
        switch (old, conn) {
        case (_, .offline):
            if offlineSince == nil {
                offlineSince = Date()
                wasLiveAtDrop = broadcast?.isLive ?? false
                recoveredMessage = nil
                levels.clear()
            }
            updateHint()
        case (.offline, .ok), (.offline, .needsLogin):
            guard let since = offlineSince else { return }
            let secs = Int(Date().timeIntervalSince(since))
            log("link recovered after \(secs)s (hint \(String(describing: linkHint)))")
            offlineSince = nil; linkHint = nil
            recoveredMessage = "本体に再接続しました (切断 \(ConnectionBanner.elapsed(Double(secs))))"
            Task { await recoverAfterReconnect() }
        default: break
        }
    }

    func updateHint() {
        let h: LinkHint = LinkCheck.interfaceName() == nil ? .noCable : .noResponse
        if h != linkHint { linkHint = h; log("link hint: \(h)") }
    }

    /// 再接続後: 画面を読み直し、モニターで一時的に変えた配信設定が残っていれば戻す
    func recoverAfterReconnect() async {
        socket.kick()
        await broadcast.refresh()
        await monitor.recoverAfterDrop(live: broadcast.isLive)
        if !editor.dirty && !editor.busy { await editor.load(editor.sceneId) }
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        if offlineSince == nil { recoveredMessage = nil }
    }

    func reconnectNow() {
        updateHint()
        socket.kick()
        Task { await refresh() }
    }
}
