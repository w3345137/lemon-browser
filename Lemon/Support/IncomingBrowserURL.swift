import AppKit
import Carbon
import Foundation

@MainActor
enum LemonIdentityMigration {
    static let bundleIdentifier = "com.lemon.browser"
    static let legacyBundleIdentifier = "com.workbuddy.lumen"
    static let supportFolderName = "Lemon"
    static let legacySupportFolderName = "Lumen"
    private static let markerKey = "completedLemonIdentityMigration.v1"

    /// App Store 沙盒下 homeDirectory 指向容器，且无法读取其他 App 的
    /// Library/Containers 数据；文件合并只在非沙盒（本机开发/GitHub 分发）构建进行。
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }

        if !isSandboxed {
            migrateLocalDataFromLegacyIdentity()
        }
        migrateDefaultBrowserIfNeeded()
        defaults.set(true, forKey: markerKey)
    }

    private static func migrateLocalDataFromLegacyIdentity() {
        let defaults = UserDefaults.standard
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let containerLibrary = library
            .appendingPathComponent("Containers/\(legacyBundleIdentifier)/Data/Library", isDirectory: true)

        let oldSupport = library.appendingPathComponent("Application Support/\(legacySupportFolderName)", isDirectory: true)
        let newSupport = library.appendingPathComponent("Application Support/\(supportFolderName)", isDirectory: true)
        mergeDirectory(from: containerLibrary.appendingPathComponent("Application Support/\(legacySupportFolderName)"), to: oldSupport)
        mergeDirectory(from: oldSupport, to: newSupport)

        let oldWebKit = library.appendingPathComponent("WebKit/\(legacyBundleIdentifier)", isDirectory: true)
        let newWebKit = library.appendingPathComponent("WebKit/\(bundleIdentifier)", isDirectory: true)
        mergeDirectory(from: containerLibrary.appendingPathComponent("WebKit"), to: oldWebKit)
        mergeDirectory(from: oldWebKit, to: newWebKit)

        let oldHTTP = library.appendingPathComponent("HTTPStorages/\(legacyBundleIdentifier)", isDirectory: true)
        let newHTTP = library.appendingPathComponent("HTTPStorages/\(bundleIdentifier)", isDirectory: true)
        mergeDirectory(from: containerLibrary.appendingPathComponent("HTTPStorages/\(legacyBundleIdentifier)"), to: oldHTTP)
        mergeDirectory(from: oldHTTP, to: newHTTP)
        copyFileIfMissing(
            from: library.appendingPathComponent("HTTPStorages/\(legacyBundleIdentifier).binarycookies"),
            to: library.appendingPathComponent("HTTPStorages/\(bundleIdentifier).binarycookies")
        )

        let preferencesURL = containerLibrary
            .appendingPathComponent("Preferences/\(legacyBundleIdentifier).plist")
        if let data = try? Data(contentsOf: preferencesURL),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in values {
                defaults.set(value, forKey: key)
            }
        }
        let oldPreferencesURL = library.appendingPathComponent("Preferences/\(legacyBundleIdentifier).plist")
        if let data = try? Data(contentsOf: oldPreferencesURL),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }

    private static func mergeDirectory(from source: URL, to destination: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let item as URL in enumerator {
            let relative = item.path.replacingOccurrences(of: source.path + "/", with: "")
            let target = destination.appendingPathComponent(relative)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                copyFileIfMissing(from: item, to: target)
            }
        }
    }

    private static func copyFileIfMissing(from source: URL, to destination: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else { return }
        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.copyItem(at: source, to: destination)
    }

    private static func migrateDefaultBrowserIfNeeded() {
        for scheme in ["http", "https"] {
            guard let current = LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String?,
                  current == legacyBundleIdentifier else { continue }
            if isSandboxed {
                // 沙盒内 LSSetDefaultHandlerForURLScheme 不可用，
                // 使用公开 NSWorkspace API 接管默认浏览器。
                NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL,
                    toOpenURLsWithScheme: scheme
                ) { _ in }
            } else {
                _ = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleIdentifier as CFString)
            }
        }
    }
}

final class LocalFileAccessLease {
    let fileURL: URL
    let readAccessURL: URL

    private let securityScopeURL: URL
    private let isAccessingSecurityScope: Bool

    init(fileURL: URL, securityScopeURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        self.readAccessURL = self.fileURL.deletingLastPathComponent()
        self.securityScopeURL = securityScopeURL
        self.isAccessingSecurityScope = securityScopeURL.startAccessingSecurityScopedResource()
    }

    deinit {
        if isAccessingSecurityScope {
            securityScopeURL.stopAccessingSecurityScopedResource()
        }
    }
}

@MainActor
enum LocalFileAccessStore {
    private struct Record: Codable {
        let filePath: String
        let bookmark: Data
    }

    private static let defaultsKey = "localFileSecurityBookmarks.v1"

    /// Saves the sandbox extension while macOS is still granting access to the
    /// file delivered by Finder or NSOpenPanel.
    @discardableResult
    static func register(_ url: URL) -> URL {
        let fileURL = url.standardizedFileURL
        guard fileURL.isFileURL else { return url }

        let didStart = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let bookmark = try? fileURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return fileURL }

        var records = loadRecords()
        records[fileURL.path] = Record(filePath: fileURL.path, bookmark: bookmark)
        saveRecords(records)
        return fileURL
    }

    static func access(_ url: URL) -> LocalFileAccessLease {
        let requestedURL = url.standardizedFileURL
        let records = loadRecords()
        guard let record = records[requestedURL.path] else {
            return LocalFileAccessLease(fileURL: requestedURL, securityScopeURL: requestedURL)
        }

        var isStale = false
        let resolvedURL: URL?
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: record.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // Bookmarks saved by build 38 lacked the app-scope entitlement.
            // Resolve their location so the user can reopen the same file once
            // and transparently replace the legacy record.
            resolvedURL = try? URL(
                resolvingBookmarkData: record.bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
        guard let resolvedURL else {
            return LocalFileAccessLease(fileURL: requestedURL, securityScopeURL: requestedURL)
        }

        let resolvedFileURL = resolvedURL.standardizedFileURL
        if isStale {
            register(resolvedFileURL)
        }
        return LocalFileAccessLease(fileURL: resolvedFileURL, securityScopeURL: resolvedFileURL)
    }

    private static func loadRecords() -> [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? PropertyListDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        return records
    }

    private static func saveRecords(_ records: [String: Record]) {
        guard let data = try? PropertyListEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

@MainActor
enum IncomingBrowserURL {
    private static var queued: [URL] = []
    private static var last: (url: URL, at: Date)?
    private static var handler: ((URL) -> Void)?
    private static var handlerToken: UUID?

    static func deliver(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" || url.isFileURL else { return }
        let destination = url.isFileURL ? LocalFileAccessStore.register(url) : url
        if let last, last.url == destination, Date().timeIntervalSince(last.at) < 0.6 {
            return
        }
        self.last = (destination, Date())
        if let handler {
            handler(destination)
        } else {
            queued.append(destination)
        }
    }

    /// 返回 token 供窗口关闭时注销；否则已关闭窗口的 state 仍会接收外链。
    @discardableResult
    static func attach(_ handler: @escaping (URL) -> Void) -> UUID {
        let token = UUID()
        handlerToken = token
        self.handler = handler
        let pending = queued
        queued = []
        pending.forEach(handler)
        return token
    }

    static func detach(_ token: UUID) {
        guard handlerToken == token else { return }
        handler = nil
        handlerToken = nil
    }
}

final class LemonAppDelegate: NSObject, NSApplicationDelegate {
    private var isSavingBeforeQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isSavingBeforeQuit else { return .terminateLater }
        isSavingBeforeQuit = true
        DownloadStore.shared.prepareToQuit {
            SessionCookieVault.shared.flush {
                self.isSavingBeforeQuit = false
                if let message = SessionCookieVault.shared.storageError {
                    let alert = NSAlert()
                    alert.messageText = "登录状态尚未保存"
                    alert.informativeText = message
                    alert.addButton(withTitle: "返回浏览器")
                    alert.addButton(withTitle: "仍然退出")
                    sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
                } else {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            urls.forEach(IncomingBrowserURL.deliver)
        }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        Task { @MainActor in
            IncomingBrowserURL.deliver(url)
        }
    }
}
