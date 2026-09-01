import AppKit
import Combine
import WebKit

enum BrowserTabLifecycleState: String {
    case active
    case warm
    case suspended
    case discarded
}

enum BrowserTabMediaState: Equatable {
    case none
    case playing
    case paused
    case suspended
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool

    @Published var title: String
    @Published var url: URL?
    @Published var isStartPage: Bool
    @Published var isLoading = false
    @Published var estimatedProgress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var favicon: NSImage?
    @Published var hoveredLink: String = ""
    @Published var findText = ""
    @Published var pageZoom: Double = 1
    @Published var isPinned = false
    @Published var lifecycleState: BrowserTabLifecycleState = .active
    @Published var lastAccessedAt = Date()
    @Published var mediaState: BrowserTabMediaState = .none
    /// WebContent 进程崩溃或被系统终止后置为 true；WKWebView 本身变成白屏，
    /// 由窗口层显示“页面已崩溃”占位，用户重新载入后清除。
    /// PageStage 观察的是 BrowserWindowState 而非单个 tab，因此这里必须
    /// 显式转发 objectWillChange，否则进程被杀后占位永远不会出现。
    @Published var webContentDidCrash = false {
        didSet {
            guard webContentDidCrash != oldValue else { return }
            windowState?.tabWebViewDidChange(self)
        }
    }

    private(set) var webView: WKWebView?
    private var progressObserver: NSKeyValueObservation?
    private var titleObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?
    private var lastOfferedCredential: (scope: String, username: String, password: String)?
    private(set) var savedScrollPosition: CGPoint?
    private var ownsScriptMessageHandlers = false
    private var localFileAccess: LocalFileAccessLease?
    private var fullscreenExitObserver: NSKeyValueObservation?
    private var fullscreenExitCompletions: [() -> Void] = []
    private weak var fullscreenExitWebView: WKWebView?
    private var lastTrustedUserGestureAt: Date?
    private var lastExternalApplicationOpen: (scheme: String, date: Date)?

    weak var windowState: BrowserWindowState?

    init(isPrivate: Bool, startURL: URL? = nil, loadsImmediately: Bool = true) {
        self.isPrivate = isPrivate
        self.isStartPage = startURL == nil
        self.title = startURL == nil ? "起始页面" : "新标签页"
        self.url = startURL
        super.init()
        if let startURL, loadsImmediately {
            load(startURL)
        } else if startURL != nil {
            lifecycleState = .suspended
        }
    }

    var hasLoadedPage: Bool {
        !isStartPage && url != nil
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        // 崩溃占位上的“重新载入”和菜单 ⌘R 走同一条路径；崩溃后
        // webView.reload() 会让 WebKit 重新拉起 WebContent 进程。
        let wasCrashed = webContentDidCrash
        webContentDidCrash = false
        if isLoading {
            webView?.stopLoading()
            isLoading = false
            estimatedProgress = 0
            return
        }
        // 崩溃后 WebKit 可能已把 webView.url 清空，此时 reload() 是空操作；
        // 用 tab 记住的 URL 重新加载（Chromium 对崩溃后台标签也是这个语义）。
        if wasCrashed, webView?.url == nil, let remembered = url {
            load(remembered)
            return
        }
        webView?.reload()
    }

    /// 页面侧媒体桥（MediaAudibilityBridge）上报的“可闻”状态。
    /// DOM 媒体与 Web Audio 分别在隔离世界和页面世界统计，Swift 侧做并集。
    private var domMediaAudible = false
    private var webAudioAudible = false

    func mediaAudibilityDidChange(source: String, audible: Bool) {
        switch source {
        case "webaudio": webAudioAudible = audible
        default: domMediaAudible = audible
        }
        let newState: BrowserTabMediaState = (domMediaAudible || webAudioAudible) ? .playing : .none
        if mediaState != newState { mediaState = newState }
    }

    func resetMediaAudibility() {
        domMediaAudible = false
        webAudioAudible = false
        if mediaState != .none { mediaState = .none }
    }

    /// 标签级静音（点击页签喇叭图标切换，对齐 Chromium）。页面侧由
    /// MediaAudibilityBridge.tabMuteScript 强制执行；标记本身跨导航保留，
    /// 直到用户再次点击或标签关闭。
    @Published var isAudioMuted = false {
        didSet {
            guard isAudioMuted != oldValue else { return }
            applyTabMuteToPage()
        }
    }

    func toggleAudioMute() {
        isAudioMuted.toggle()
    }

    /// 把当前静音状态注入主帧；页面脚本会经 postMessage 扇出到全部子帧。
    private func applyTabMuteToPage() {
        guard let webView else { return }
        let flag = isAudioMuted ? "true" : "false"
        webView.evaluateJavaScript(
            "window.__lemonApplyTabMute && window.__lemonApplyTabMute(\(flag))",
            in: nil,
            in: .page
        ) { _ in }
    }

    /// 新文档的页面脚本加载后主动查询静音状态；按发来消息的帧定向回注，
    /// 跨域 iframe 不等主帧扇出也能第一时间静音。
    func replyTabMuteQuery(to frame: WKFrameInfo) {
        guard let webView else { return }
        let flag = isAudioMuted ? "true" : "false"
        webView.evaluateJavaScript(
            "window.__lemonApplyTabMute && window.__lemonApplyTabMute(\(flag))",
            in: frame,
            in: .page
        ) { _ in }
    }

    var isElementFullscreenActive: Bool {
        guard let webView else { return false }
        return webView.fullscreenState != .notInFullscreen
    }

    /// WebKit 元素全屏会把整个 WKWebView 移进自己的全屏窗口。标签切换和
    /// 关闭必须等它完整回到普通层级后再继续，调用 close 后立即换标签仍会竞态。
    func exitElementFullscreenIfNeeded(completion: @escaping () -> Void = {}) {
        guard let view = webView, view.fullscreenState != .notInFullscreen else {
            completion()
            return
        }

        fullscreenExitCompletions.append(completion)
        guard fullscreenExitObserver == nil else { return }
        fullscreenExitWebView = view
        fullscreenExitObserver = view.observe(\.fullscreenState, options: [.new]) { [weak self, weak view] _, _ in
            DispatchQueue.main.async {
                guard let self, let view,
                      self.fullscreenExitWebView === view,
                      view.fullscreenState == .notInFullscreen else { return }
                self.finishFullscreenExit()
            }
        }

        view.closeAllMediaPresentations { [weak self, weak view] in
            DispatchQueue.main.async {
                guard let self, let view,
                      self.fullscreenExitWebView === view else { return }
                if view.fullscreenState == .notInFullscreen {
                    self.finishFullscreenExit()
                }
            }
        }
    }

    private func finishFullscreenExit() {
        fullscreenExitObserver?.invalidate()
        fullscreenExitObserver = nil
        fullscreenExitWebView = nil
        let completions = fullscreenExitCompletions
        fullscreenExitCompletions.removeAll()
        completions.forEach { $0() }
    }

    func zoomIn() {
        pageZoom = min(pageZoom + 0.1, 3)
        webView?.pageZoom = pageZoom
    }

    func zoomOut() {
        pageZoom = max(pageZoom - 0.1, 0.5)
        webView?.pageZoom = pageZoom
    }

    func resetZoom() {
        pageZoom = 1
        webView?.pageZoom = 1
    }

    func find(_ text: String, backwards: Bool = false) {
        findText = text
        guard let webView else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        webView.find(text, configuration: config) { _ in }
    }

    /// 关闭查找栏或切换标签时清掉页面高亮；从未查找过的标签直接跳过 IPC。
    func clearFindHighlights() {
        guard let webView, !findText.isEmpty else { return }
        findText = ""
        webView.find("", configuration: WKFindConfiguration()) { _ in }
    }

    /// 填充结果回执。超时未收到任何成功回执即视为失败，由调用方决定重试或提示。
    private var pendingFillToken: String?
    private var pendingFillCompletion: ((Bool) -> Void)?
    private var pendingFillTimeout: DispatchWorkItem?

    /// 保存密码提示的延迟确认：捕获到提交后，等“登录可能成功”的信号
    /// （导航完成且 URL 变化、SPA 路由变化，或 6 秒兜底）再弹保存提示。
    /// 同 URL 重载视为登录失败，直接丢弃。
    struct PendingCredentialCapture {
        let scope: String
        let username: String
        let password: String
        let pageURL: URL?
    }
    private var pendingCredentialCapture: PendingCredentialCapture?
    private var credentialCaptureWorkItem: DispatchWorkItem?
    /// 测试可缩短；真实环境给 SPA/XHR 登录 6 秒完成窗口。
    static var credentialCaptureConfirmDelay: TimeInterval = 6

    func fill(_ credential: WebCredential, password: String, completion: @escaping (Bool) -> Void) {
        guard let webView else {
            completion(false)
            return
        }
        let token = UUID().uuidString
        pendingFillToken = token
        pendingFillCompletion = completion
        let payload: [String: String] = [
            "token": token,
            "username": credential.username,
            "password": password
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            completeFill(token: token, ok: false)
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.completeFill(token: token, ok: false)
        }
        pendingFillTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: timeout)

        webView.evaluateJavaScript(CredentialBridge.fillDispatcherScript(payloadJSON: json)) {
            [weak self] result, _ in
            Task { @MainActor in
                guard let self, self.pendingFillToken == token else { return }
                // 主框架同步直填成功：立即完成，不再等 iframe 回执。
                if let dict = result as? [String: Any], dict["direct"] as? Bool == true {
                    self.completeFill(token: token, ok: true)
                }
            }
        }
    }

    private func completeFill(token: String, ok: Bool) {
        guard pendingFillToken == token, let completion = pendingFillCompletion else { return }
        pendingFillToken = nil
        pendingFillCompletion = nil
        pendingFillTimeout?.cancel()
        pendingFillTimeout = nil
        completion(ok)
    }

    func recordCredentialCapture(scope: String, username: String, password: String, pageURL: URL?) {
        if let previous = lastOfferedCredential,
           previous.scope == scope,
           previous.username == username,
           previous.password == password {
            return
        }
        pendingCredentialCapture = PendingCredentialCapture(
            scope: scope, username: username, password: password, pageURL: pageURL
        )
        credentialCaptureWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushCredentialCapture()
        }
        credentialCaptureWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.credentialCaptureConfirmDelay,
            execute: workItem
        )
    }

    /// 导航完成：URL 变化说明登录大概率成功并跳转了；同 URL 重载视为失败。
    func handleNavigationFinished(url: URL?) {
        guard let pending = pendingCredentialCapture else { return }
        if let url, let captured = pending.pageURL, url == captured {
            pendingCredentialCapture = nil
            credentialCaptureWorkItem?.cancel()
            credentialCaptureWorkItem = nil
            return
        }
        flushCredentialCapture()
    }

    /// SPA 路由切换只改 URL 不产生导航回调，由 KVO 捕获。
    func handleURLChange(url: URL?) {
        guard let pending = pendingCredentialCapture,
              let captured = pending.pageURL,
              let url, url != captured else { return }
        flushCredentialCapture()
    }

    private func flushCredentialCapture() {
        guard let pending = pendingCredentialCapture else { return }
        pendingCredentialCapture = nil
        credentialCaptureWorkItem?.cancel()
        credentialCaptureWorkItem = nil
        lastOfferedCredential = (pending.scope, pending.username, pending.password)
        windowState?.offerToSaveCredential(
            scope: pending.scope,
            username: pending.username,
            password: pending.password
        )
    }

    func load(_ destination: URL) {
        lastAccessedAt = Date()
        lifecycleState = .active
        isStartPage = false
        webContentDidCrash = false
        let view = ensureWebView()

        if destination.isFileURL {
            let access = LocalFileAccessStore.access(destination)
            localFileAccess = access
            url = access.fileURL
            title = access.fileURL.lastPathComponent
            favicon = NSWorkspace.shared.icon(forFile: access.fileURL.path)
            view.loadFileURL(access.fileURL, allowingReadAccessTo: access.readAccessURL)
            return
        }

        localFileAccess = nil
        url = destination
        title = URLInput.simplifiedHost(from: destination).isEmpty ? "新标签页" : URLInput.simplifiedHost(from: destination)
        view.load(URLRequest(url: destination))
        FaviconService.load(for: destination) { [weak self] image in
            // 异步图标晚到时不允许覆盖已经导航到新地址的标签。
            guard let self, self.url == destination else { return }
            self.favicon = image
        }
    }

    func ensureWebView() -> WKWebView {
        if let webView { return webView }

        let view = WebKitFactory.makeWebView(isPrivate: isPrivate)
        configure(view)
        return view
    }

    func activate() {
        lastAccessedAt = Date()
        lifecycleState = .active
        guard !isStartPage, webView == nil, let url else { return }
        load(url)
    }

    func markWarm() {
        guard lifecycleState != .suspended, lifecycleState != .discarded else { return }
        lifecycleState = .warm
        captureScrollPosition()
    }

    func restoreScroll(_ point: CGPoint) {
        savedScrollPosition = point
    }

    func captureScrollPosition(then completion: (() -> Void)? = nil) {
        guard let currentWebView = webView else {
            completion?()
            return
        }
        currentWebView.evaluateJavaScript("[window.scrollX, window.scrollY]") { [weak self, weak currentWebView] value, _ in
            Task { @MainActor in
                if let self, self.webView === currentWebView,
                   let values = value as? [Double], values.count == 2 {
                    self.savedScrollPosition = CGPoint(x: values[0], y: values[1])
                }
                completion?()
            }
        }
    }

    func applyContentBlocking() {
        guard let webView else { return }
        ContentBlocker.shared.install(on: webView.configuration)
    }

    func adoptPopupWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        if let webView { return webView }
        isStartPage = false
        title = "登录窗口"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.allowsLinkPreview = true
        // WebKit 提供的弹窗 configuration 已继承父页面的 message handlers。
        // 再次 add 同名 handler 会抛出 Objective-C 异常并直接终止 App。
        configure(view, registerScriptMessageHandlers: false)
        return view
    }

    private func configure(_ view: WKWebView, registerScriptMessageHandlers: Bool = true) {
        view.navigationDelegate = self
        view.uiDelegate = self
        ownsScriptMessageHandlers = registerScriptMessageHandlers
        if registerScriptMessageHandlers {
            // UCC 会强持有 handler；直接 add(self) 会让 WebView → UCC → Tab
            // → WebView 成环。经弱引用代理转发即可随 WebView 一起释放。
            let proxy = ScriptMessageProxy(tab: self)
            view.configuration.userContentController.add(proxy, name: "lemonHover")
            view.configuration.userContentController.add(proxy, name: CredentialBridge.handlerName)
            view.configuration.userContentController.add(
                proxy,
                contentWorld: .defaultClient,
                name: "lemonExternalGesture"
            )
            // 媒体桥横跨两个世界：webAudioScript/tabMuteScript 在页面世界上报，
            // DOM 可闻性脚本在隔离世界上报，handler 必须两边都注册。
            view.configuration.userContentController.add(proxy, name: MediaAudibilityBridge.handlerName)
            view.configuration.userContentController.add(proxy, contentWorld: .defaultClient, name: MediaAudibilityBridge.handlerName)
        }

        progressObserver = view.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.estimatedProgress = webView.isLoading && webView.estimatedProgress < 1
                    ? webView.estimatedProgress
                    : 0
            }
        }
        titleObserver = view.observe(\.title, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                if let title = webView.title, !title.isEmpty {
                    self?.title = title
                }
            }
        }
        urlObserver = view.observe(\.url, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                // WebContent 进程崩溃时 WebKit 会把 webView.url 清空；崩溃占位的
                // “重新载入”和会话持久化都依赖原 URL，nil 一律不覆盖已有值。
                guard let newURL = webView.url else { return }
                self?.url = newURL
                self?.handleURLChange(url: newURL)
            }
        }
        webView = view
        windowState?.tabWebViewDidChange(self)
    }

    func tearDown() {
        lifecycleState = .discarded
        releaseWebView()
    }

    private func releaseWebView() {
        if let view = webView {
            view.stopLoading()
            // stopLoading 不会暂停媒体；只靠释放 WKWebView 的话，WebContent
            // 进程异步退出，期间音频会多播好几秒。completion 捕获 view，
            // 保证暂停/退出指令送达后才释放最后一个引用。
            view.closeAllMediaPresentations { _ = view }
            view.pauseAllMediaPlayback { _ = view }
        }
        fullscreenExitObserver?.invalidate()
        fullscreenExitObserver = nil
        fullscreenExitWebView = nil
        fullscreenExitCompletions.removeAll()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        if ownsScriptMessageHandlers {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "lemonHover")
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: CredentialBridge.handlerName)
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: MediaAudibilityBridge.handlerName)
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: MediaAudibilityBridge.handlerName, contentWorld: .defaultClient)
            webView?.configuration.userContentController.removeScriptMessageHandler(
                forName: "lemonExternalGesture",
                contentWorld: .defaultClient
            )
        }
        ownsScriptMessageHandlers = false
        if let token = pendingFillToken {
            completeFill(token: token, ok: false)
        }
        pendingCredentialCapture = nil
        credentialCaptureWorkItem?.cancel()
        credentialCaptureWorkItem = nil
        progressObserver = nil
        titleObserver = nil
        urlObserver = nil
        webView = nil
        windowState?.tabWebViewDidChange(self)
        localFileAccess = nil
        isLoading = false
        estimatedProgress = 0
        resetMediaAudibility()
        webContentDidCrash = false
    }

    private func syncNavigationState() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        isLoading = webView?.isLoading ?? false
        if let url = webView?.url {
            self.url = url
        }
        if let title = webView?.title, !title.isEmpty {
            self.title = title
        }
    }
}

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // 任何新导航都说明 WebContent 进程已经恢复，清掉崩溃占位。
        webContentDidCrash = false
        isLoading = true
        estimatedProgress = 0.05
        // 新文档从静音开始；若自动起播，媒体桥会重新上报。
        resetMediaAudibility()
    }

    /// WebContent 进程崩溃或被系统终止时 WKWebView 只剩白屏，不会触发任何
    /// 导航失败回调。标记后由窗口层显示崩溃占位，重新载入由 reload() 完成。
    /// tearDown / 释放阶段的进程退出是正常路径，绝不能误标。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, lifecycleState != .discarded else { return }
        webContentDidCrash = true
        isLoading = false
        estimatedProgress = 0
        mediaState = .none
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        estimatedProgress = 0
        syncNavigationState()
        handleNavigationFinished(url: webView.url)
        if let url = webView.url {
            windowState?.history.record(title: title, url: url)
            if url.isFileURL {
                favicon = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                FaviconService.load(for: url) { [weak self] image in
                    guard let self, self.url == url else { return }
                    self.favicon = image
                }
            }
        }
        windowState?.tabDidFinishNavigation(self)
        if let savedScrollPosition {
            self.savedScrollPosition = nil
            webView.evaluateJavaScript(
                "window.scrollTo(\(savedScrollPosition.x), \(savedScrollPosition.y))"
            )
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        estimatedProgress = 0
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        estimatedProgress = 0
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url,
           let scheme = ExternalApplicationPolicy.externalScheme(for: url) {
            openExternalApplicationIfAllowed(
                url,
                scheme: scheme,
                navigationAction: navigationAction,
                webView: webView
            )
            return .cancel
        }
        if navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url,
           url.scheme != "about" {
            // ⌘点击链接与 Safari/Chrome 一致：新标签后台打开，不切换当前页面。
            windowState?.openInNewTab(url, select: false)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = windowState?.downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = windowState?.downloads
    }
}

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = ExternalApplicationPolicy.externalScheme(for: url) {
            openExternalApplicationIfAllowed(
                url,
                scheme: scheme,
                navigationAction: navigationAction,
                webView: webView
            )
            return nil
        }
        let host = webView.url?.host ?? navigationAction.request.url?.host ?? ""
        let store = SitePermissionStore.shared
        var choice = store.choice(for: host, kind: .popups)
        if choice == .ask, !host.isEmpty {
            // “询问”必须真的问，否则语义等同于允许。
            let prompt = promptForPopupPermission(host: host)
            choice = prompt.choice
            if prompt.remember {
                store.set(prompt.choice, for: host, kind: .popups)
            }
        }
        if choice == .block {
            return nil
        }
        return windowState?.openPopup(with: configuration)
    }

    private func promptForPopupPermission(host: String) -> (choice: SitePermissionChoice, remember: Bool) {
        let alert = NSAlert()
        alert.messageText = "允许 \(host) 打开弹出式窗口？"
        alert.informativeText = "该网站正在尝试打开一个新窗口。"
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "阻止")
        let rememberBox = NSButton(checkboxWithTitle: "记住此网站的选择", target: nil, action: nil)
        rememberBox.frame = NSRect(x: 0, y: 0, width: 240, height: 20)
        alert.accessoryView = rememberBox
        let allowed = alert.runModal() == .alertFirstButtonReturn
        return (allowed ? .allow : .block, rememberBox.state == .on)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = origin.host
        let store = SitePermissionStore.shared
        let choice: SitePermissionChoice
        switch type {
        case .camera:
            choice = store.choice(for: host, kind: .camera)
        case .microphone:
            choice = store.choice(for: host, kind: .microphone)
        case .cameraAndMicrophone:
            let camera = store.choice(for: host, kind: .camera)
            let microphone = store.choice(for: host, kind: .microphone)
            if camera == .block || microphone == .block {
                choice = .block
            } else if camera == .allow && microphone == .allow {
                choice = .allow
            } else {
                choice = .ask
            }
        @unknown default:
            choice = .ask
        }
        decisionHandler(choice.webKitDecision)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webViewDidClose(_ webView: WKWebView) {
        windowState?.closeTab(id)
    }
}

/// WKUserContentController 会强持有 handler；这个代理只弱引用标签，
/// 避免 WebView → configuration → UCC → BrowserTab → WebView 的保留环，
/// 也避免弹窗标签继承的 configuration 把父标签一直留在内存里。
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        tab?.receiveScriptMessage(message)
    }
}

extension BrowserTab {
    func receiveScriptMessage(_ message: WKScriptMessage) {
        if message.name == "lemonExternalGesture" {
            lastTrustedUserGestureAt = Date()
            return
        }
        if message.name == "lemonHover" {
            hoveredLink = message.body as? String ?? ""
            return
        }
        if message.name == MediaAudibilityBridge.handlerName {
            guard let body = message.body as? [String: Any] else { return }
            if body["type"] as? String == "queryTabMute" {
                replyTabMuteQuery(to: message.frameInfo)
                return
            }
            guard let audible = body["audible"] as? Bool else { return }
            mediaAudibilityDidChange(source: body["source"] as? String ?? "dom", audible: audible)
            return
        }
        guard message.name == CredentialBridge.handlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let origin = body["origin"] as? String,
              CredentialStore.sharesSite(origin: origin, with: webView?.url) else { return }

        // 跨域 iframe 的填充回执：只认与当前页同站、且令牌匹配的框架。
        if type == "fillResult" {
            if let token = body["token"] as? String, body["ok"] as? Bool == true {
                completeFill(token: token, ok: true)
            }
            return
        }

        guard type == "submit", !isPrivate,
              let username = body["username"] as? String,
              let password = body["password"] as? String,
              !password.isEmpty,
              let pageScope = webView?.url.flatMap(CredentialStore.scope(for:))
                    ?? CredentialStore.normalizedScope(origin) else { return }
        recordCredentialCapture(
            scope: pageScope,
            username: username,
            password: password,
            pageURL: webView?.url
        )
    }
}

private extension BrowserTab {
    func openExternalApplicationIfAllowed(
        _ url: URL,
        scheme: String,
        navigationAction: WKNavigationAction,
        webView: WKWebView
    ) {
        let wasExplicitLink = navigationAction.navigationType == .linkActivated
        let hasRecentGesture = ExternalApplicationPolicy.isRecentGesture(at: lastTrustedUserGestureAt)
        guard wasExplicitLink || hasRecentGesture else { return }

        // 一些页面会按顺序试探同一协议的多个 URL，防止短时间内
        // 重复打开客户端。
        if let previous = lastExternalApplicationOpen,
           previous.scheme == scheme,
           Date().timeIntervalSince(previous.date) < 1.5 {
            return
        }

        let sourceHost = navigationAction.sourceFrame.request.url?.host
            ?? webView.url?.host
            ?? self.url?.host
            ?? "当前网站"
        let store = SitePermissionStore.shared
        var choice = store.externalApplicationChoice(for: sourceHost, scheme: scheme)

        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            showMissingExternalApplicationAlert(scheme: scheme)
            return
        }
        let applicationName = applicationDisplayName(at: applicationURL)

        if choice == .ask {
            let prompt = promptForExternalApplication(
                sourceHost: sourceHost,
                applicationName: applicationName,
                scheme: scheme
            )
            choice = prompt.choice
            if prompt.remember {
                store.setExternalApplicationChoice(choice, for: sourceHost, scheme: scheme)
            }
        }
        guard choice == .allow else { return }

        lastExternalApplicationOpen = (scheme, Date())
        NSWorkspace.shared.open(url)
    }

    func promptForExternalApplication(
        sourceHost: String,
        applicationName: String,
        scheme: String
    ) -> (choice: SitePermissionChoice, remember: Bool) {
        let alert = NSAlert()
        alert.messageText = "允许打开“\(applicationName)”？"
        alert.informativeText = "\(sourceHost) 正在尝试通过 \(scheme) 链接打开此应用。"
        alert.addButton(withTitle: "打开 \(applicationName)")
        alert.addButton(withTitle: "取消")
        let rememberBox = NSButton(
            checkboxWithTitle: "一直允许 \(sourceHost) 打开此类链接",
            target: nil,
            action: nil
        )
        rememberBox.frame = NSRect(x: 0, y: 0, width: 360, height: 20)
        alert.accessoryView = rememberBox
        let allowed = alert.runModal() == .alertFirstButtonReturn
        return (allowed ? .allow : .block, rememberBox.state == .on)
    }

    func showMissingExternalApplicationAlert(scheme: String) {
        let alert = NSAlert()
        alert.messageText = "无法打开链接"
        alert.informativeText = "Mac 上没有找到可以处理 \(scheme) 链接的应用。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func applicationDisplayName(at applicationURL: URL) -> String {
        let bundleName = Bundle(url: applicationURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let fallbackName = Bundle(url: applicationURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return bundleName ?? fallbackName ?? applicationURL.deletingPathExtension().lastPathComponent
    }
}
