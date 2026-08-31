import Foundation
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

@MainActor
final class CredentialStore: ObservableObject {
    static let shared = CredentialStore()
    // v2 starts a clean Keychain namespace owned by Lemon's stable signing
    // requirement. Early development builds used ad-hoc signatures, which
    // caused macOS to request access separately for every legacy item after
    // each rebuild.
    // Keep the legacy Keychain service so the product rename does not orphan saved passwords.
    static let service = "com.workbuddy.lumen.web-password.v2"

    @Published private(set) var credentials: [WebCredential] = []

    private init() {
        refresh()
    }

    func credentials(for url: URL?) -> [WebCredential] {
        guard let url, let scope = Self.scope(for: url) else { return [] }
        return credentials
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: credential.id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.keychain(errSecDecode)
        }
        return password
    }

    func delete(_ credential: WebCredential) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: credential.id
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
        refresh()
    }

    func refresh() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            credentials = []
            return
        }

        let rows = result as? [[String: Any]] ?? []
        credentials = rows.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            return Self.parseAccountKey(account)
        }
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
        components.port = url.port
        return components.string
    }

    nonisolated static func normalizedScope(_ value: String) -> String? {
        guard let url = URL(string: value) else { return nil }
        return scope(for: url)
    }

    nonisolated static func sharesSite(origin: String, with pageURL: URL?) -> Bool {
        guard let pageScope = pageURL.flatMap(scope(for:)),
              let messageScope = normalizedScope(origin),
              let pageHost = URL(string: pageScope)?.host,
              let messageHost = URL(string: messageScope)?.host else { return false }
        return registrableDomain(pageHost) == registrableDomain(messageHost)
    }

    nonisolated static func registrableDomain(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host.lowercased() }
        let multiPartTLDs = Set(["com.cn", "net.cn", "org.cn", "gov.cn", "com.hk", "co.uk"])
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if multiPartTLDs.contains(lastTwo), parts.count >= 3 {
            return parts.suffix(3).joined(separator: ".")
        }
        return lastTwo
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
