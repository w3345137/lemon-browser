import AppKit
import Foundation
import WebKit
import os

@MainActor
enum MicrosoftLoginResourcePolicy {
    static func applies(to url: URL) -> Bool {
        url.scheme?.lowercased() == "https" &&
        ["login.microsoftonline.com", "login.windows.net"].contains(url.host?.lowercased() ?? "") &&
        (url.port == nil || url.port == 443)
    }

    static func configure(_ configuration: WKWebViewConfiguration) {
        if #available(macOS 15.4, *) {
            configuration.webExtensionController = MicrosoftLoginExtension.shared.controller
        }
    }

    static func installIfNeeded(for url: URL, on view: WKWebView) async {
        guard applies(to: url) else { return }
        if #available(macOS 15.4, *) {
            await MicrosoftLoginExtension.shared.prepare()
        }
        // 旧系统继续使用网站原生加载与通用白屏提示，不用私有重定向API。
    }

    static var resourcesURL: URL? {
        #if LEMON_TEST_COMPATIBILITY_RESOURCES
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/MicrosoftLoginCompatibility.bundle/Contents/Resources", isDirectory: true)
        #else
        Bundle.main.url(forResource: "MicrosoftLoginCompatibility", withExtension: "bundle")?
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        #endif
    }
}

/// 内建且无执行脚本的资源规则，不能加载用户扩展，也不能读取表单或Cookie。
@available(macOS 15.4, *)
@MainActor
private final class MicrosoftLoginExtension {
    static let shared = MicrosoftLoginExtension()
    let controller = WKWebExtensionController(configuration: .nonPersistent())
    private var preparation: Task<Void, Never>?
    private var context: WKWebExtensionContext?

    func prepare() async {
        if preparation == nil {
            preparation = Task {
                do {
                    guard let resources = MicrosoftLoginResourcePolicy.resourcesURL else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    // WKWebExtension(resourceBaseURL:) 把 .bundle 路径误当作
                    // app extension bundle；即便Info.plist完整，在当前WebKit
                    // 也触发原生断言。复制两份已签名静态资源到普通临时目录。
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("lemon-ms-login-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer {
                        if self.context == nil { try? FileManager.default.removeItem(at: directory) }
                    }
                    for filename in ["manifest.json", "rules.json"] {
                        try FileManager.default.copyItem(
                            at: resources.appendingPathComponent(filename),
                            to: directory.appendingPathComponent(filename)
                        )
                    }
                    let ext = try await WKWebExtension(resourceBaseURL: directory)
                    guard ext.errors.isEmpty else { throw ext.errors[0] }
                    let context = WKWebExtensionContext(for: ext)
                    context.uniqueIdentifier = "com.lemon.browser.microsoft-login-cdn.v2"
                    // 只有固定DNR规则，没有background/content_scripts；无痕资料仍
                    // 由每窗口独立的WKWebsiteDataStore管理，扩展存储也不落盘。
                    context.hasAccessToPrivateData = true
                    context.setPermissionStatus(.grantedExplicitly, for: .declarativeNetRequestWithHostAccess)
                    for host in ["aadcdn.msftauth.net", "aadcdn.msauth.net", "login.microsoftonline.com", "login.windows.net"] {
                        let pattern = try WKWebExtension.MatchPattern(string: "https://\(host)/*")
                        context.setPermissionStatus(.grantedExplicitly, for: pattern)
                    }
                    try controller.load(context)
                    self.context = context
                    NotificationCenter.default.addObserver(
                        forName: NSApplication.willTerminateNotification,
                        object: nil,
                        queue: nil
                    ) { _ in
                        try? FileManager.default.removeItem(at: directory)
                    }
                } catch {
                    Logger(subsystem: "com.lemon.browser", category: "LoginCompatibility")
                        .error("Microsoft static resource compatibility unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        await preparation?.value
    }
}
