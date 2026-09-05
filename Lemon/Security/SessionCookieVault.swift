import CryptoKit
import Combine
import Foundation
import LocalAuthentication
import Security
import WebKit

/// Safari 会额外恢复浏览器会话 Cookie，WKWebView 宿主应用需要自行补齐。
/// Cookie 值先用 Keychain 中的设备密钥加密，再写入 App 沙盒。
final class SessionCookieVault: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    static let shared = SessionCookieVault()
    @Published private(set) var storageError: String?
    @Published private(set) var lastSavedAt: Date?

    // Keep the legacy service and archive folder so existing sessions remain decryptable.
    private static let keyService = "com.workbuddy.lumen.session-cookie-key"
    private static let keyAccount = "vault-key.v2"
    private let cookieStore: WKHTTPCookieStore
    private let customArchiveURL: URL?
    private let storageQueue = DispatchQueue(label: "com.workbuddy.lemon.session-cookie-vault")
    private var isPreparing = false
    private var isPrepared = false
    private var pendingCompletions: [() -> Void] = []
    private var persistWorkItem: DispatchWorkItem?
    // Accessed only on storageQueue. Never overwrite an archive that failed to decrypt.
    private var canWrite = true
    private var cachedKey: SymmetricKey?
    private var periodicSave: Timer?
    private var snapshotRevision = 0
    private var committedRevision = 0 // storageQueue only

    private override init() {
        cookieStore = WKWebsiteDataStore.default().httpCookieStore
        customArchiveURL = nil
        super.init()
    }

    init(cookieStore: WKHTTPCookieStore, archiveURL: URL, key: SymmetricKey) {
        self.cookieStore = cookieStore
        self.customArchiveURL = archiveURL
        self.cachedKey = key
        super.init()
    }

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

    func flush(completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        persistWorkItem?.cancel()
        persistWorkItem = nil
        guard isPrepared else { completion(); return }
        snapshotSessionCookies(completion: completion)
    }

    func retrySaving() {
        storageQueue.async { [weak self] in
            guard let self else { return }
            // Authenticate/decrypt the existing archive before allowing replacement.
            _ = self.readRecords()
            DispatchQueue.main.async { self.flush {} }
        }
    }

    func stopObserving() {
        dispatchPrecondition(condition: .onQueue(.main))
        periodicSave?.invalidate()
        periodicSave = nil
        persistWorkItem?.cancel()
        persistWorkItem = nil
        cookieStore.remove(self)
        isPrepared = false
    }

    private func restore(_ cookies: [HTTPCookie]) {
        guard !cookies.isEmpty else {
            finishPreparing()
            return
        }

        cookieStore.getAllCookies { [weak self] current in
            guard let self else { return }
            let missing = SessionCookieRecord.missingCookies(backup: cookies, current: current)
            let group = DispatchGroup()
            for cookie in missing {
                group.enter()
                self.cookieStore.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { self.finishPreparing() }
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
        periodicSave = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.schedulePersist(delay: 0)
        }
    }

    private func schedulePersist(delay: TimeInterval = 0.35) {
        guard isPrepared else { return }
        guard persistWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistWorkItem = nil
            self?.snapshotSessionCookies()
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func snapshotSessionCookies(completion: @escaping () -> Void = {}) {
        snapshotRevision += 1
        let revision = snapshotRevision
        cookieStore.getAllCookies { [weak self] cookies in
            let records = cookies.compactMap(SessionCookieRecord.init(cookie:))
                .sorted {
                    ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name)
                }
            self?.storageQueue.async { [weak self] in
                if let self, revision >= self.committedRevision {
                    self.committedRevision = revision
                    self.write(records)
                }
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private var archiveURL: URL {
        if let customArchiveURL { return customArchiveURL }
        let folder = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("session-cookies.v1.enc")
    }

    private func readRecords() -> [SessionCookieRecord] {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            canWrite = true
            return []
        }
        guard let encrypted = try? Data(contentsOf: archiveURL),
              let key = encryptionKey(createIfMissing: false),
              let sealed = try? AES.GCM.SealedBox(combined: encrypted),
              let clear = try? AES.GCM.open(sealed, using: key),
              let records = try? JSONDecoder().decode([SessionCookieRecord].self, from: clear) else {
            canWrite = false
            reportError("无法读取登录会话备份。请允许 Lemon 访问钥匙串后重试保存；原备份已保留。")
            return []
        }
        canWrite = true
        return records
    }

    private func write(_ records: [SessionCookieRecord]) {
        guard canWrite else { return }
        guard let clear = try? JSONEncoder().encode(records),
              let key = encryptionKey(createIfMissing: true),
              let encrypted = try? AES.GCM.seal(clear, using: key).combined else {
            canWrite = false
            reportError("登录会话未能保存。请允许 Lemon 访问钥匙串后重试。")
            return
        }
        do {
            try encrypted.write(to: archiveURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            DispatchQueue.main.async { self.storageError = nil; self.lastSavedAt = Date() }
        } catch {
            reportError("登录会话写入失败：\(error.localizedDescription)")
        }
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async { self.storageError = message }
    }

    private func encryptionKey(createIfMissing: Bool) -> SymmetricKey? {
        if let cachedKey { return cachedKey }
        let authenticationContext = LAContext()
        authenticationContext.localizedReason = "保存和恢复 Lemon 的网站登录状态"
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
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        }
        guard createIfMissing, status == errSecItemNotFound else {
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
        let key = SymmetricKey(data: data)
        cachedKey = key
        return key
    }
}

struct SessionCookieRecord: Codable, Hashable {
    static func missingCookies(backup: [HTTPCookie], current: [HTTPCookie]) -> [HTTPCookie] {
        func key(_ cookie: HTTPCookie) -> String {
            "\(cookie.domain.lowercased())\n\(cookie.path)\n\(cookie.name)"
        }
        let existing = Set(current.map(key))
        return backup.filter { !existing.contains(key($0)) }
    }
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
