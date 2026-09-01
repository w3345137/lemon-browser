import AppKit
import WebKit

// BrowserTab.swift / WebKitFactory.swift 独立编译时依赖的最小宿主桩。
// 供 TestWebContentCrash / TestMediaAudibility / TestCredentialCapture 共用。
enum SafariIdentity {
    static let applicationName = "LemonTabTest"
}

enum CredentialBridge {
    static let handlerName = "lemonCredentials"
    static let captureScript = WKUserScript(
        source: "",
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )
    static func fillDispatcherScript(payloadJSON: String) -> String { "({ direct: true, targeted: [] })" }
}

final class ContentBlocker {
    static let shared = ContentBlocker()
    func install(on configuration: WKWebViewConfiguration) {}
}

struct WebCredential {
    let username: String
}

enum CredentialStore {
    static func scope(for url: URL) -> String? { url.host }
    static func normalizedScope(_ origin: String) -> String? { origin }
    static func sharesSite(origin: String, with url: URL?) -> Bool { false }
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
    func externalApplicationChoice(for host: String, scheme: String) -> SitePermissionChoice { .ask }
    func setExternalApplicationChoice(_ choice: SitePermissionChoice, for host: String, scheme: String) {}
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
    /// 记录保存密码提示，供测试断言延迟确认行为。
    var offeredCredentials: [(scope: String, username: String)] = []
    func openInNewTab(_ url: URL, select: Bool = true) {}
    func openPopup(with configuration: WKWebViewConfiguration) -> WKWebView {
        WKWebView(frame: .zero, configuration: configuration)
    }
    func closeTab(_ id: UUID) {}
    func tabDidFinishNavigation(_ tab: BrowserTab) {}
    func offerToSaveCredential(scope: String, username: String, password: String) {
        offeredCredentials.append((scope, username))
    }
    func tabWebViewDidChange(_ tab: BrowserTab) {}
}
