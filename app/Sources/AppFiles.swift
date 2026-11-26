import Foundation
import SwiftUI

/// Mac に置くファイル (~/.config/livemixdesktop)。
/// 本体の設定のバックアップにはストリームキーやログインパスワードも入るので、
/// フォルダは本人だけが開ける 700、ファイルは本人だけが読み書きできる 600 にする。
enum AppFiles {
    static let dir = URL(fileURLWithPath: NSHomeDirectory() + "/.config/livemixdesktop")
    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// フォルダを作る。すでにあるフォルダも、dir から下は 700 にそろえる
    static func makeDir(_ d: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var p = d.standardizedFileURL
        while p.path.hasPrefix(dir.path) {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: p.path)
            p.deleteLastPathComponent()
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        try makeDir(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}


/// 実機でまだ試していない機能に付ける印
struct UnverifiedBadge: View {
    var body: some View {
        Label("実機未検証", systemImage: "questionmark.diamond")
            .font(.caption2).foregroundStyle(.orange)
            .help("この機能は実機でまだ試していません。大事な設定やデータがあるときは使わないでください。")
    }
}
