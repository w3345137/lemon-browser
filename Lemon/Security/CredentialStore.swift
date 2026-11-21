import Foundation
import LocalAuthentication
import Security

struct WebCredential: Identifiable, Hashable {
    let scope: String
    let username: String

    var id: String { CredentialStore.accountKey(scope: scope, username: username) }

    var displayUsername: String {
        username.isEmpty ? "仅密码" : username
    }

    var displayHost: String {
        URL(string: scope)?.host ?? scope
    }
}

enum CredentialStoreError: LocalizedError {
    case invalidScope
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidScope:
            return "网站地址无效。"
        case let .keychain(status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误：\(status)"
        }
    }
}

enum CredentialSaveDecision: Equatable {
    case save, update, unchanged, unavailable
}

@MainActor
final class CredentialStore: ObservableObject {
    static let shared = CredentialStore()
    // v2 starts a clean Keychain namespace owned by Lemon's stable signing
    // requirement. Early development builds used ad-hoc signatures, which
    // caused macOS to request access separately for every legacy item after
    // each rebuild.
    static let service = "com.lemon.browser.web-password.v3"
    static let legacyService = "com.workbuddy.lumen.web-password.v2"

    @Published private(set) var credentials: [WebCredential] = []
    let inMemory: Bool
    private var temporaryPasswords: [String: String] = [:]

    init(inMemory: Bool = false) {
        self.inMemory = inMemory
        refresh()
    }

    func credentials(for url: URL?) -> [WebCredential] {
        guard let url, let scope = Self.scope(for: url) else { return [] }
        return credentials(forScope: scope)
    }

    /// 按凭据所属的源精确查询，用于页面内嵌的同站登录框。
    func credentials(forScope scope: String) -> [WebCredential] {
        credentials
            .filter { $0.scope == scope }
            .sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
    }

    func save(
        scope rawScope: String,
        username: String,
        password: String,
        refreshesCredentials: Bool = true
    ) throws {
        guard let scope = Self.normalizedScope(rawScope), !password.isEmpty else {
            throw CredentialStoreError.invalidScope
        }

        if inMemory {
            temporaryPasswords[Self.accountKey(scope: scope, username: username)] = password
            if refreshesCredentials { refresh() }
            return
        }

        let account = Self.accountKey(scope: scope, username: username)
        let passwordData = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [
            kSecValueData as String: passwordData,
            kSecAttrLabel as String: "Lemon · \(URL(string: scope)?.host ?? scope)"
        ]

        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            updates.forEach { item[$0.key] = $0.value }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychain(status)
        }
        if refreshesCredentials {
            refresh()
        }
    }

    func password(for credential: WebCredential) throws -> String {
        if inMemory {
            guard let password = temporaryPasswords[credential.id] else {
                throw CredentialStoreError.keychain(errSecItemNotFound)
            }
            return password
        }
        if let password = try password(for: credential, service: Self.service) {
            return password
        }
        if let password = try password(for: credential, service: Self.legacyService) {
            // Lazy migration avoids a launch-time Keychain prompt storm. Once
            // the user allows this legacy item, future reads use Lemon's new
            // namespace and no longer depend on the old bundle identity.
            try? save(scope: credential.scope, username: credential.username, password: password, refreshesCredentials: false)
            return password
        }
        throw CredentialStoreError.keychain(errSecItemNotFound)
    }

    private func password(for credential: WebCredential, service: String, allowsAuthentication: Bool = true) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowsAuthentication {
            // A background save decision must not open a Keychain authorization dialog.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.keychain(errSecDecode)
        }
        return password
    }

    func saveDecision(scope: String, username: String, password: String) -> CredentialSaveDecision {
        if inMemory {
            return Self.saveDecision(scope: scope, username: username, password: password) {
                self.temporaryPasswords[$0.id]
            }
        }
        return Self.saveDecision(scope: scope, username: username, password: password) { credential in
            if let stored = try self.password(for: credential, service: Self.service, allowsAuthentication: false) {
                return stored
            }
            return try self.password(for: credential, service: Self.legacyService, allowsAuthentication: false)
        }
    }

    /// Compare the actual Keychain value rather than the possibly stale account list.
    /// A failed read is unknown, not evidence that the password changed or is absent.
    static func saveDecision(
        scope: String,
        username: String,
        password: String,
        lookup: (WebCredential) throws -> String?
    ) -> CredentialSaveDecision {
        guard let normalized = normalizedScope(scope), !password.isEmpty else { return .unavailable }
        do {
            guard let stored = try lookup(WebCredential(scope: normalized, username: username)) else { return .save }
            // Passwords must match bytes, without Unicode canonical equivalence.
            return stored.utf8.elementsEqual(password.utf8) ? .unchanged : .update
        } catch {
            return .unavailable
        }
    }

    func delete(_ credential: WebCredential) throws {
        if inMemory {
            temporaryPasswords.removeValue(forKey: credential.id)
            refresh()
            return
        }
        for service in [Self.service, Self.legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: credential.id
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.keychain(status)
            }
        }
        refresh()
    }

    func refresh() {
        if inMemory {
            credentials = temporaryPasswords.keys.compactMap(Self.parseAccountKey).sorted { $0.id < $1.id }
            return
        }
        var found: [String: WebCredential] = [:]
        for service in [Self.service, Self.legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess || status == errSecItemNotFound else { continue }
            let rows = result as? [[String: Any]] ?? []
            for attributes in rows {
                guard let account = attributes[kSecAttrAccount as String] as? String,
                      let credential = Self.parseAccountKey(account) else { continue }
                found[credential.id] = credential
            }
        }
        credentials = Array(found.values)
        .sorted {
            if $0.displayHost == $1.displayHost {
                return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
            }
            return $0.displayHost.localizedCaseInsensitiveCompare($1.displayHost) == .orderedAscending
        }
    }

    nonisolated static func scope(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80) ? nil : url.port
        return components.string
    }

    nonisolated static func normalizedScope(_ value: String) -> String? {
        guard let url = URL(string: value) else { return nil }
        return scope(for: url)
    }

    nonisolated static func sharesSite(origin: String, with pageURL: URL?) -> Bool {
        guard let pageScope = pageURL.flatMap(scope(for:)),
              let messageScope = normalizedScope(origin) else { return false }
        // A shared domain suffix is not permission to receive credentials.
        return pageScope == messageScope
    }

    /// 多段公共后缀与多租户托管域名：这些后缀下的每个子域属于不同主人，
    /// 不能视为同一站点。列表不求完整，漏掉的后缀只会让同站判断更宽，
    /// 而凭据填充始终要求精确同源，不会因此泄露给别的源。
    nonisolated private static let publicSuffixes: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "com.hk", "com.tw",
        "co.uk", "org.uk", "ac.uk", "co.jp", "ne.jp", "or.jp", "ac.jp", "co.kr",
        "com.au", "net.au", "com.br", "com.sg", "co.nz", "co.in",
        "github.io", "gitlab.io", "gitee.io", "vercel.app", "netlify.app", "pages.dev",
        "workers.dev", "web.app", "firebaseapp.com", "appspot.com", "herokuapp.com",
        "blogspot.com", "azurewebsites.net", "cloudfront.net", "s3.amazonaws.com",
        "onrender.com", "fly.dev", "glitch.me", "ngrok.io", "ngrok-free.app"
    ]

    nonisolated static func registrableDomain(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host.lowercased() }
        // 从最长的候选后缀开始匹配，命中则再向左取一段作为可注册域名。
        for length in stride(from: min(3, parts.count - 1), through: 2, by: -1) {
            let suffix = parts.suffix(length).joined(separator: ".")
            if publicSuffixes.contains(suffix) {
                return parts.suffix(length + 1).joined(separator: ".")
            }
        }
        return parts.suffix(2).joined(separator: ".")
    }

    /// 框架与页面是否同站（同协议 + 同可注册域名，端口不计）。只用来决定
    /// 是否接收内嵌登录框（如 appstoreconnect.apple.com 内嵌的
    /// idmsa.apple.com）的保存与填充请求；凭据本身仍按框架源精确绑定。
    nonisolated static func isSameSite(origin: String, with pageURL: URL?) -> Bool {
        guard let pageURL, let pageScheme = pageURL.scheme?.lowercased(),
              let pageHost = pageURL.host?.lowercased(),
              let originURL = URL(string: origin), originURL.scheme?.lowercased() == pageScheme,
              let originHost = originURL.host?.lowercased(),
              pageScheme == "https" || pageScheme == "http" else { return false }
        // IP 地址没有“站点”概念，只认同一主机。
        if pageHost.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) {
            return pageHost == originHost
        }
        let pageSite = registrableDomain(pageHost)
        guard pageSite.contains(".") || pageSite == "localhost" else { return false }
        // 自身就是公共后缀（如 github.io 本身）时不存在可共享的站点。
        guard !publicSuffixes.contains(pageSite) else { return pageHost == originHost }
        return pageSite == registrableDomain(originHost)
    }

    nonisolated static func accountKey(scope: String, username: String) -> String {
        scope + "\n" + username
    }

    nonisolated private static func parseAccountKey(_ value: String) -> WebCredential? {
        guard let separator = value.firstIndex(of: "\n") else { return nil }
        let scope = String(value[..<separator])
        let username = String(value[value.index(after: separator)...])
        guard normalizedScope(scope) != nil else { return nil }
        return WebCredential(scope: scope, username: username)
    }
}
