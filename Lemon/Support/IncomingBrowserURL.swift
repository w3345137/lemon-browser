import AppKit
import Carbon
import Foundation

@MainActor
enum LegacySandboxDataMigration {
    private static let markerKey = "completedUnsandboxedDataMigration.v1"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let containerLibrary = home
            .appendingPathComponent("Library/Containers/com.workbuddy.lumen/Data/Library", isDirectory: true)
        guard fileManager.fileExists(atPath: containerLibrary.path) else {
            defaults.set(true, forKey: markerKey)
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupRoot = home
            .appendingPathComponent("Library/Application Support/Lemon Migration Backup \(timestamp)", isDirectory: true)
        try? fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        migrateDirectory(
            from: containerLibrary.appendingPathComponent("Application Support/Lumen", isDirectory: true),
            to: home.appendingPathComponent("Library/Application Support/Lumen", isDirectory: true),
            backupRoot: backupRoot,
            backupName: "Application Support"
        )
        migrateDirectory(
            from: containerLibrary.appendingPathComponent("WebKit", isDirectory: true),
            to: home.appendingPathComponent("Library/WebKit/com.workbuddy.lumen", isDirectory: true),
            backupRoot: backupRoot,
            backupName: "WebKit"
        )
        migrateDirectory(
            from: containerLibrary.appendingPathComponent("HTTPStorages/com.workbuddy.lumen", isDirectory: true),
            to: home.appendingPathComponent("Library/HTTPStorages/com.workbuddy.lumen", isDirectory: true),
            backupRoot: backupRoot,
            backupName: "HTTPStorages"
        )

        let preferencesURL = containerLibrary
            .appendingPathComponent("Preferences/com.workbuddy.lumen.plist")
        if let data = try? Data(contentsOf: preferencesURL),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in values {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: markerKey)
    }

    private static func migrateDirectory(
        from source: URL,
        to destination: URL,
        backupRoot: URL,
        backupName: String
    ) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.moveItem(
                at: destination,
                to: backupRoot.appendingPathComponent(backupName, isDirectory: true)
            )
        }
        try? fileManager.copyItem(at: source, to: destination)
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
