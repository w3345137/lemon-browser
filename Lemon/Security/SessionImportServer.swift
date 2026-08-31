import Foundation
import Network
import WebKit

private struct ImportedCookie: Decodable {
    let name: String
    let value: String
    let domain: String
    let path: String?
    let secure: Bool?
    let httpOnly: Bool?
    let sameSite: String?
    let expirationDate: Double?
}

private struct ImportedPassword: Decodable {
    let url: String
    let username: String
    let password: String
}

private struct ImportedBrowserData: Decodable {
    let cookies: [ImportedCookie]
    let passwords: [ImportedPassword]?
}

@MainActor
final class SessionImportServer: ObservableObject {
    static let shared = SessionImportServer()
    static let port: UInt16 = 18765

    @Published private(set) var isListening = false
    @Published private(set) var token = ""
    @Published private(set) var statusText = ""

    private var listener: NWListener?

    func start() throws {
        stop()
        token = Self.makeToken()
        statusText = "等待 360 浏览器发送登录态和密码…"

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isListening = true
                case let .failed(error):
                    self.statusText = "接收服务失败：\(error.localizedDescription)"
                    self.stop()
                case .cancelled:
                    self.isListening = false
                default:
                    break
                }
            }
        }
        listener.start(queue: DispatchQueue(label: "com.workbuddy.lemon.session-import"))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "com.workbuddy.lemon.session-import.connection"))
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }

            Task { @MainActor in
                guard let self else { return }
                if nextBuffer.count > 8_388_608 {
                    self.respond(connection, status: "413 Payload Too Large", body: "{\"ok\":false}")
                    return
                }
                if self.handleIfComplete(nextBuffer, connection: connection) { return }
                if complete || error != nil {
                    connection.cancel()
                    return
                }
                self.receive(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func handleIfComplete(_ data: Data, connection: NWConnection) -> Bool {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerData = data[..<separator.lowerBound]
        guard let headers = String(data: headerData, encoding: .utf8) else {
            respond(connection, status: "400 Bad Request", body: "{\"ok\":false}")
            return true
        }

        if SessionImportRequestPolicy.isPreflight(headers) {
            respond(connection, status: "204 No Content", body: "")
            return true
        }

        // 一次性口令只在 Lemon 设置页展示，由用户复制进临时扩展。服务端不再
        // 提供读取口令的接口；Origin 可以被本机程序伪造，不能单独作为认证。
        guard SessionImportRequestPolicy.isAuthorizedImport(headers, token: token) else {
            respond(connection, status: "403 Forbidden", body: "{\"ok\":false}")
            return true
        }

        let contentLength = headers.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) }
        guard let contentLength else {
            respond(connection, status: "411 Length Required", body: "{\"ok\":false}")
            return true
        }

        let bodyStart = separator.upperBound
        guard data.count - bodyStart >= contentLength else { return false }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))

        do {
            let decoder = JSONDecoder()
            let payload: ImportedBrowserData
            if let decoded = try? decoder.decode(ImportedBrowserData.self, from: body) {
                payload = decoded
            } else {
                // 兼容 build 4-8 的旧版 Cookie-only 扩展。
                payload = ImportedBrowserData(
                    cookies: try decoder.decode([ImportedCookie].self, from: body),
                    passwords: nil
                )
            }
            Task { @MainActor in
                let cookieCount = await self.install(payload.cookies)
                let passwordResult = self.install(payload.passwords ?? [])
                let verification = self.verify(payload.passwords ?? [])
                self.statusText = "已导入 \(cookieCount) 个 Cookie、\(passwordResult.imported) 项密码；逐项核验 \(verification.verified) 项，异常 \(verification.mismatched) 项；跳过 \(passwordResult.skipped) 项。请关闭并移除临时扩展。"
                self.respond(
                    connection,
                    status: "200 OK",
                    body: "{\"ok\":true,\"cookieCount\":\(cookieCount),\"passwordCount\":\(passwordResult.imported),\"verified\":\(verification.verified),\"mismatched\":\(verification.mismatched),\"skipped\":\(passwordResult.skipped)}"
                )
                self.stop()
            }
        } catch {
            statusText = "360 迁移数据无法解析。"
            respond(connection, status: "400 Bad Request", body: "{\"ok\":false}")
        }
        return true
    }

    private func install(_ imported: [ImportedCookie]) async -> Int {
        let store = WKWebsiteDataStore.default().httpCookieStore
        var count = 0
        for item in imported {
            guard !item.name.isEmpty, !item.domain.isEmpty else { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: item.name,
                .value: item.value,
                .domain: item.domain,
                .path: item.path ?? "/",
                .version: 0
            ]
            if item.secure == true { properties[.secure] = "TRUE" }
            if item.httpOnly == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            switch item.sameSite {
            case "no_restriction":
                properties[HTTPCookiePropertyKey("SameSite")] = "None"
            case "lax":
                properties[HTTPCookiePropertyKey("SameSite")] = "Lax"
            case "strict":
                properties[HTTPCookiePropertyKey("SameSite")] = "Strict"
            default:
                break
            }
            if let expirationDate = item.expirationDate, expirationDate > 0 {
                properties[.expires] = Date(timeIntervalSince1970: expirationDate)
            }
            guard let cookie = HTTPCookie(properties: properties) else { continue }
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) { continuation.resume() }
            }
            count += 1
        }
        return count
    }

    private func install(_ imported: [ImportedPassword]) -> (imported: Int, skipped: Int) {
        var importedCount = 0
        var skippedCount = 0
        for item in imported {
            guard let scope = CredentialStore.normalizedScope(item.url),
                  !item.password.isEmpty else {
                skippedCount += 1
                continue
            }
            do {
                try CredentialStore.shared.save(
                    scope: scope,
                    username: item.username,
                    password: item.password,
                    refreshesCredentials: false
                )
                importedCount += 1
            } catch {
                skippedCount += 1
            }
        }
        CredentialStore.shared.refresh()
        return (importedCount, skippedCount)
    }

    private func verify(_ imported: [ImportedPassword]) -> (verified: Int, mismatched: Int) {
        var verified = 0
        var mismatched = 0
        for item in imported {
            guard let scope = CredentialStore.normalizedScope(item.url), !item.password.isEmpty else {
                mismatched += 1
                continue
            }
            do {
                let stored = try CredentialStore.shared.password(
                    for: WebCredential(scope: scope, username: item.username)
                )
                if stored == item.password {
                    verified += 1
                } else {
                    mismatched += 1
                }
            } catch {
                mismatched += 1
            }
        }
        return (verified, mismatched)
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(bodyData)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
