import AppKit
import WebKit

// 真机级 BrowserTab 测试的桩：CredentialBridge / MediaAudibilityBridge /
// CredentialStore 使用真实实现，其余外部依赖用最小桩。
enum SafariIdentity {
    static let applicationName = "LemonLiveTest"
}

final class ContentBlocker {
    static let shared = ContentBlocker()
    func install(on configuration: WKWebViewConfiguration) {}
}

enum FaviconService {
    static func load(for url: URL, completion: @escaping (NSImage?) -> Void) {}
}

enum URLInput {
    static func simplifiedHost(from url: URL) -> String { url.host ?? "" }
}

final class LocalFileAccessLease {
    let fileURL: URL
    let readAccessURL: URL
    init(fileURL: URL, readAccessURL: URL) {
        self.fileURL = fileURL
        self.readAccessURL = readAccessURL
    }
}

enum LocalFileAccessStore {
    static func access(_ url: URL) -> LocalFileAccessLease {
        LocalFileAccessLease(fileURL: url, readAccessURL: url.deletingLastPathComponent())
    }
}

enum SitePermissionKind {
    case popups, camera, microphone
}

enum SitePermissionChoice {
    case ask, allow, block
    var webKitDecision: WKPermissionDecision {
        switch self {
        case .ask: return .prompt
        case .allow: return .grant
        case .block: return .deny
        }
    }
}

final class SitePermissionStore {
    static let shared = SitePermissionStore()
    func choice(for host: String, kind: SitePermissionKind) -> SitePermissionChoice { .ask }
    func set(_ choice: SitePermissionChoice, for host: String, kind: SitePermissionKind) {}
}

final class HistoryStore {
    func record(title: String, url: URL) {}
}

final class DownloadStore: NSObject, WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? { nil }
}

@MainActor
final class BrowserWindowState: NSObject {
    let history = HistoryStore()
    let downloads = DownloadStore()
    var finishedNavigations = 0
    var offeredCredentials: [(scope: String, username: String)] = []
    func openInNewTab(_ url: URL, select: Bool = true) {}
    func openPopup(with configuration: WKWebViewConfiguration) -> WKWebView {
        WKWebView(frame: .zero, configuration: configuration)
    }
    func closeTab(_ id: UUID) {}
    func tabDidFinishNavigation(_ tab: BrowserTab) {
        finishedNavigations += 1
    }
    func offerToSaveCredential(scope: String, username: String, password: String) {
        offeredCredentials.append((scope, username))
    }
    func tabWebViewDidChange(_ tab: BrowserTab) {}
}

@MainActor
func waitFor(_ timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    return condition()
}
