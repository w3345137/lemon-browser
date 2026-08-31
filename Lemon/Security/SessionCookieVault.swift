import CryptoKit
import Foundation
import LocalAuthentication
import Security
import WebKit

/// Safari 会额外恢复浏览器会话 Cookie，WKWebView 宿主应用需要自行补齐。
/// Cookie 值先用 Keychain 中的设备密钥加密，再写入 App 沙盒。
final class SessionCookieVault: NSObject, WKHTTPCookieStoreObserver {
    static let shared = SessionCookieVault()

    // Keep the legacy service and archive folder so existing sessions remain decryptable.
    private static let keyService = "com.workbuddy.lumen.session-cookie-key"
    private static let keyAccount = "vault-key.v2"
    private let cookieStore = WKWebsiteDataStore.default().httpCookieStore
    private let storageQueue = DispatchQueue(label: "com.workbuddy.lemon.session-cookie-vault")
    private var isPreparing = false
    private var isPrepared = false
    private var pendingCompletions: [() -> Void] = []
    private var persistWorkItem: DispatchWorkItem?

    private override init() {}

    func prepare(completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if isPrepared {
            completion()
            return
        }

        pendingCompletions.append(completion)
        guard !isPreparing else { return }
        isPreparing = true

        storageQueue.async { [weak self] in
            let restoredCookies = self?.readRecords().compactMap(\.cookie) ?? []
            DispatchQueue.main.async {
                self?.restore(restoredCookies)
            }
        }
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        DispatchQueue.main.async { [weak self] in
            self?.schedulePersist()
        }
    }

    private func restore(_ cookies: [HTTPCookie]) {
        guard !cookies.isEmpty else {
            finishPreparing()
            return
        }

        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            cookieStore.setCookie(cookie) {
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.finishPreparing()
        }
    }

    private func finishPreparing() {
        cookieStore.add(self)
        isPreparing = false
        isPrepared = true
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        completions.forEach { $0() }
        schedulePersist(delay: 0)
    }

    private func schedulePersist(delay: TimeInterval = 0.35) {
        guard isPrepared else { return }
        persistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.snapshotSessionCookies()
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func snapshotSessionCookies() {
        cookieStore.getAllCookies { [weak self] cookies in
            let records = cookies.compactMap(SessionCookieRecord.init(cookie:))
                .sorted {
                    ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name)
                }
            self?.storageQueue.async { [weak self] in
                self?.write(records)
            }
        }
    }

    private var archiveURL: URL {
        let folder = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("session-cookies.v1.enc")
    }

    private func readRecords() -> [SessionCookieRecord] {
        guard let encrypted = try? Data(contentsOf: archiveURL),
              let key = encryptionKey(createIfMissing: false),
              let sealed = try? AES.GCM.SealedBox(combined: encrypted),
              let clear = try? AES.GCM.open(sealed, using: key),
              let records = try? JSONDecoder().decode([SessionCookieRecord].self, from: clear) else {
            return []
        }
        return records
    }

    private func write(_ records: [SessionCookieRecord]) {
        guard let clear = try? JSONEncoder().encode(records),
              let key = encryptionKey(createIfMissing: true),
              let encrypted = try? AES.GCM.seal(clear, using: key).combined else { return }
        try? encrypted.write(to: archiveURL, options: .atomic)
    }

    private func encryptionKey(createIfMissing: Bool) -> SymmetricKey? {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyService,
            kSecAttrAccount as String: Self.keyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard createIfMissing, status == errSecItemNotFound || status == errSecUserCanceled || status == errSecAuthFailed else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let data = Data(bytes)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyService,
            kSecAttrAccount as String: Self.keyAccount,
            kSecValueData as String: data,
            kSecAttrLabel as String: "Lemon session cookie key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return encryptionKey(createIfMissing: false)
        }
        guard addStatus == errSecSuccess else { return nil }
        return SymmetricKey(data: data)
    }
}

struct SessionCookieRecord: Codable, Hashable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let isSecure: Bool
    let isHTTPOnly: Bool
    let sameSitePolicy: String?
    let version: Int

    init?(cookie: HTTPCookie) {
        guard cookie.expiresDate == nil else { return nil }
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
        sameSitePolicy = cookie.properties?[.sameSitePolicy] as? String
        version = cookie.version
    }

    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .discard: "TRUE",
            .version: String(version)
        ]
        // Foundation 以 Secure 键是否存在来判断安全属性；写入 "FALSE"
        // 仍会得到 isSecure=true，因此非 HTTPS Cookie 必须省略该键。
        if isSecure {
            properties[.secure] = "TRUE"
        }
        if isHTTPOnly {
            properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE"
        }
        if let sameSitePolicy {
            properties[.sameSitePolicy] = sameSitePolicy
        }
        return HTTPCookie(properties: properties)
    }
}
