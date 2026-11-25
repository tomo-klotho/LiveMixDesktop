import Foundation
import Security

/// GV-LSMIXER/I (ATEN UC9020 系) の RESTful API クライアント。
/// 認証はログインで得たセッションクッキー (session=...) を Cookie ヘッダーで送る。
final class MixerAPI: NSObject, URLSessionDelegate {
    static let host = ProcessInfo.processInfo.environment["LMD_HOST"] ?? "192.168.254.1"
    private let base = "https://\(MixerAPI.host)/api/v2.0"
    private var urlSession: URLSession!
    private(set) var sessionId: String?

    enum APIError: Error { case auth(Int), http(Int, String), offline(String) }

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.httpShouldSetCookies = false
        urlSession = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        sessionId = Self.cliSessionCookie()
    }

    // 本体の自己署名証明書 (ATEN) は本体アドレスに対してだけ受け入れる
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if c.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           c.protectionSpace.host == Self.host, let trust = c.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    @discardableResult
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> Any? {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        if let t = timeout { req.timeoutInterval = t }
        if let sid = sessionId { req.setValue("session=\(sid)", forHTTPHeaderField: "Cookie") }
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await urlSession.data(for: req) }
        catch { throw APIError.offline(error.localizedDescription) }
        let http = resp as! HTTPURLResponse
        if let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
           let r = setCookie.range(of: #"session=([^;]+)"#, options: .regularExpression) {
            sessionId = String(setCookie[r].dropFirst("session=".count))
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.auth(http.statusCode) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        if data.isEmpty { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// /static 以下のファイル (スナップショット PNG など) を取得
    func fetchStatic(_ path: String, timeout: TimeInterval? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://\(Self.host)\(path)")!)
        if let t = timeout { req.timeoutInterval = t }
        if let sid = sessionId { req.setValue("session=\(sid)", forHTTPHeaderField: "Cookie") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await urlSession.data(for: req) }
        catch { throw APIError.offline(error.localizedDescription) }
        let code = (resp as! HTTPURLResponse).statusCode
        if code == 401 || code == 403 { throw APIError.auth(code) }
        guard code == 200 else { throw APIError.http(code, path) }
        return data
    }

    /// 画像などのアセットをアップロード (POST /assets/upload, multipart/form-data)。
    /// 本体仕様: type ("image"/"qml"/"font") と file が必須。id は送らない (省略で自動採番、既存 id は不可)。
    @discardableResult
    func uploadAsset(type: String, fileName: String, data: Data, contentType: String) async throws -> [String: Any] {
        try await uploadMultipart("/assets/upload", fields: [("type", type), ("sender", "livemixdesktop")],
                                  fileName: fileName, data: data, contentType: contentType)
    }

    /// multipart/form-data で 1 ファイルを送る (アセット、一時停止画面など)
    @discardableResult
    func uploadMultipart(_ path: String, fields: [(String, String)], fileName: String, data: Data,
                         contentType: String, timeout: TimeInterval = 30) async throws -> [String: Any] {
        let boundary = "LiveMixDesktop-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let sid = sessionId { req.setValue("session=\(sid)", forHTTPHeaderField: "Cookie") }
        req.httpBody = body
        let out: Data, resp: URLResponse
        do { (out, resp) = try await urlSession.data(for: req) }
        catch { throw APIError.offline(error.localizedDescription) }
        let http = resp as! HTTPURLResponse
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.auth(http.statusCode) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: out, encoding: .utf8) ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:]
    }

    func login(user: String, password: String) async throws {
        let cred = Data("\(user):\(password)".utf8).base64EncodedString()
        sessionId = nil
        try await call("POST", "/auth/login", ["authorization": cred])  // 本体は小文字キーを要求
    }

    /// CLI (livemix.py) が保存したセッションクッキーがあれば流用する
    static func cliSessionCookie() -> String? {
        let path = NSHomeDirectory() + "/.config/livemixdesktop/cookies.txt"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") || line.hasPrefix("#HttpOnly_") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)  // 有効期限欄は空のことがある
            if f.count >= 7, f[0].hasSuffix(host), f[5] == "session" { return String(f[6]) }
        }
        return nil
    }
}

/// ログイン情報をキーチェーンに保存 (任意)
enum Keychain {
    static let service = "io.github.tomo-klotho.livemixdesktop"

    static func save(user: String, password: String) {
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: user, kSecValueData as String: Data(password.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> (String, String)? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? [String: Any],
              let user = d[kSecAttrAccount as String] as? String, let pw = d[kSecValueData as String] as? Data
        else { return nil }
        return (user, String(decoding: pw, as: UTF8.self))
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
