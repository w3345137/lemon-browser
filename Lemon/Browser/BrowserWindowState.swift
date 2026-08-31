import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class BrowserWindowState: NSObject, ObservableObject {
    let isPrivate: Bool
    /// 普通窗口的会话身份。多窗口各自写 session.json 中自己的记录，
    /// 不再后开窗口覆盖先开窗口；无痕窗口不参与持久化。
    let windowSessionID: String

    /// 本次运行中已被活窗口认领的会话记录，启动/新建窗口时不能重复认领。
    private static var claimedWindowSessionIDs = Set<String>()

    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabID: BrowserTab.ID
    @Published var addressText = ""
    @Published var isAddressEditing = false
    @Published var isSidebarVisible = false
    @Published var isBookmarkBarVisible = true
    @Published var isFindBarVisible = false
    @Published var findQuery = ""
    @Published var sidebarTab: SidebarTab = .bookmarks
    @Published var closedTabs: [ClosedTabSnapshot] = []
    @Published var isBookmarkSavePopoverPresented = false
    let downloads: DownloadStore

    let bookmarks = BookmarkStore.shared
    let credentials = CredentialStore.shared
    let history: HistoryStore

    @Published var addressFocusToken = UUID()
    /// 用户显式切换页签后，PageStage 在目标 WKWebView 已经显示并挂到窗口后
    /// 把 first responder 交给网页。用一次性 token 可以让“再次点击当前页签”
    /// 也重新聚焦网页，同时不会影响新建空白页后地址栏的自动聚焦。
    @Published private(set) var pageFocusRequestID: UUID?

    private var contentBlockerObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var persistWorkItem: DispatchWorkItem?
    private var pendingSelectionID: BrowserTab.ID?
    private var pendingCloseTabIDs: Set<BrowserTab.ID> = []

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        self.history = HistoryStore(isPrivate: isPrivate)
        self.downloads = isPrivate ? DownloadStore(persistent: false) : .shared
        let restoredTabs: [BrowserTab]
        let restoredSelectedIndex: Int
        let restoredClosedTabs: [ClosedTabSnapshot]

        // 多窗口恢复：认领一条尚未被活窗口使用的会话记录；没有可认领的
        // 记录时给窗口分配新身份，旧版 pinnedTabURLs 迁移逻辑保持不变。
        let claimed: (windowID: String, snapshot: BrowserSessionSnapshot)?
        if isPrivate {
            claimed = nil
            self.windowSessionID = UUID().uuidString
        } else if let claim = BrowserSessionStore.claimRestorableSession(
            claimedIDs: Self.claimedWindowSessionIDs
        ) {
            claimed = claim
            self.windowSessionID = claim.windowID
            Self.claimedWindowSessionIDs.insert(claim.windowID)
        } else {
            claimed = nil
            self.windowSessionID = UUID().uuidString
            Self.claimedWindowSessionIDs.insert(self.windowSessionID)
        }

        if let claimed {
            let session = claimed.snapshot
            restoredTabs = session.tabs.map { snapshot in
                let tab = BrowserTab(
                    isPrivate: false,
                    startURL: snapshot.url,
                    loadsImmediately: false
                )
                tab.title = snapshot.title
                tab.isPinned = snapshot.isPinned
                if let scrollX = snapshot.scrollX, let scrollY = snapshot.scrollY {
                    tab.restoreScroll(CGPoint(x: scrollX, y: scrollY))
                }
                return tab
            }
            restoredSelectedIndex = min(max(0, session.selectedIndex), restoredTabs.count - 1)
            restoredClosedTabs = session.closedTabs
        } else if !isPrivate {
            let legacyPinned = UserDefaults.standard.stringArray(forKey: "pinnedTabURLs.v1") ?? []
            UserDefaults.standard.removeObject(forKey: "pinnedTabURLs.v1")
            let pinned = legacyPinned.compactMap(URL.init(string:)).map { url in
                let tab = BrowserTab(isPrivate: false, startURL: url, loadsImmediately: false)
                tab.isPinned = true
                return tab
            }
            restoredTabs = pinned.isEmpty ? [BrowserTab(isPrivate: false)] : pinned + [BrowserTab(isPrivate: false)]
            restoredSelectedIndex = restoredTabs.count - 1
            restoredClosedTabs = []
        } else {
            restoredTabs = [BrowserTab(isPrivate: true)]
            restoredSelectedIndex = 0
            restoredClosedTabs = []
        }

        self.tabs = restoredTabs
        self.selectedTabID = restoredTabs[restoredSelectedIndex].id
        self.closedTabs = restoredClosedTabs
        super.init()
        for tab in tabs {
            tab.windowState = self
        }
        if isPrivate {
            selectedTab?.activate()
        } else {
            // 固定标签恢复 URL 之前，先把上次浏览器会话 Cookie 注入默认
            // WebsiteDataStore，避免企业 SSO 页面抢先跳回登录页。
            SessionCookieVault.shared.prepare { [weak self] in
                self?.activateStartupTabs()
            }
        }
        observeContentBlocker()
        observeTermination()
        persistSession()
    }

    var selectedTab: BrowserTab? {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first
    }

    var selectedIndex: Int {
        tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
    }

    /// 点击地址栏只进入编辑状态，回车后统一在新标签页打开。
    func handleAddressBarClick() {
        beginEditingAddress(selectingCurrentURL: selectedTab?.hasLoadedPage == true)
    }

    /// ⌘L：同样走「新标签页打开」规则。
    func focusAddressBarFromKeyboard() {
        handleAddressBarClick()
    }

    func submitAddress(_ raw: String) {
        guard let destination = URLInput.destination(from: raw) else {
            isAddressEditing = false
            syncAddressBar()
            return
        }
        openInNewTab(destination)
        isAddressEditing = false
        syncAddressBar()
    }

    func openBookmark(_ item: BookmarkItem) {
        openInNewTab(item.url)
    }

    func openInNewTab(_ url: URL, select: Bool = true) {
        let tab = BrowserTab(isPrivate: isPrivate, startURL: url)
        tab.windowState = self
        insert(tab, after: selectedIndex, select: select)
        isAddressEditing = false
        syncAddressBar()
    }

    func openLocalHTMLFile() {
        let panel = NSOpenPanel()
        panel.title = "打开本地网页"
        panel.prompt = "打开"
        panel.message = "选择 HTML 文件。页面引用的同目录样式、图片和脚本会一并加载。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["html", "htm", "xhtml"]
            .compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK else { return }
        for (index, selectedURL) in panel.urls.enumerated() {
            let fileURL = LocalFileAccessStore.register(selectedURL)
            openInNewTab(fileURL, select: index == panel.urls.count - 1)
        }
    }

    func openPopup(with configuration: WKWebViewConfiguration) -> WKWebView {
        let tab = BrowserTab(isPrivate: isPrivate)
        tab.windowState = self
        let webView = tab.adoptPopupWebView(configuration: configuration)
        insert(tab, after: selectedIndex, select: true)
        isAddressEditing = false
        syncAddressBar()
        return webView
    }

    func openNewTab() {
        openBlankTabAndFocusAddress()
    }

    func select(_ id: BrowserTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        guard selectedTabID != id else {
            pendingSelectionID = nil
            isAddressEditing = false
            syncAddressBar()
            requestPageFocus()
            return
        }

        if let outgoing = selectedTab, outgoing.isElementFullscreenActive {
            pendingSelectionID = id
            outgoing.exitElementFullscreenIfNeeded { [weak self] in
                guard let self, self.pendingSelectionID == id else { return }
                self.pendingSelectionID = nil
                self.completeSelection(id)
            }
            return
        }

        pendingSelectionID = nil
        completeSelection(id)
    }

    private func completeSelection(_ id: BrowserTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if selectedTabID != id {
            let outgoing = selectedTab
            outgoing?.captureScrollPosition { [weak self] in
                self?.persistSession()
            }
            outgoing?.clearFindHighlights()
        }
        selectedTabID = id
        selectedTab?.activate()
        isAddressEditing = false
        setFindBar(visible: false)
        syncAddressBar()
        enforceTabLifecycle()
        persistSession()
        requestPageFocus()
    }

    private func requestPageFocus() {
        pageFocusRequestID = UUID()
    }

    func closeTab(_ id: BrowserTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.isElementFullscreenActive {
            guard pendingCloseTabIDs.insert(id).inserted else { return }
            tab.exitElementFullscreenIfNeeded { [weak self] in
                guard let self else { return }
                self.pendingCloseTabIDs.remove(id)
                self.closeTabNow(id)
            }
            return
        }
        closeTabNow(id)
    }

    private func closeTabNow(_ id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        if pendingSelectionID == id { pendingSelectionID = nil }
        rememberClosedTab(tabs[index])
        tabs[index].tearDown()
        tabs.remove(at: index)

        if tabs.isEmpty {
            openNewTab()
            return
        }
        // 只有被关的是当前标签才需要重新选择；关后台标签不能偷换用户正在看的页面。
        if wasSelected {
            let fallbackIndex = TabCloseSelectionPolicy.fallbackIndex(
                closedIndex: index,
                remainingCount: tabs.count
            )
            select(tabs[fallbackIndex].id)
        } else {
            persistSession()
        }
    }

    func closeSelectedTab() {
        closeTab(selectedTabID)
    }

    func duplicateTab(_ id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let url = tabs[index].url else { return }
        let copy = BrowserTab(isPrivate: isPrivate, startURL: url)
        copy.windowState = self
        insert(copy, after: index, select: true)
    }

    func closeOtherTabs(keeping id: BrowserTab.ID) {
        let closing = tabs.filter { $0.id != id && !$0.isPinned }
        if let fullscreenTab = closing.first(where: \.isElementFullscreenActive) {
            fullscreenTab.exitElementFullscreenIfNeeded { [weak self] in
                self?.closeOtherTabs(keeping: id)
            }
            return
        }
        for tab in closing {
            rememberClosedTab(tab)
            tab.tearDown()
        }
        tabs.removeAll { $0.id != id && !$0.isPinned }
        select(id)
    }

    func closeTabsToRight(of id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closingIDs = Set(tabs.dropFirst(index + 1).filter { !$0.isPinned }.map(\.id))
        if let fullscreenTab = tabs.first(where: { closingIDs.contains($0.id) && $0.isElementFullscreenActive }) {
            fullscreenTab.exitElementFullscreenIfNeeded { [weak self] in
                self?.closeTabsToRight(of: id)
            }
            return
        }
        for tab in tabs where closingIDs.contains(tab.id) {
            rememberClosedTab(tab)
            tab.tearDown()
        }
        tabs.removeAll { closingIDs.contains($0.id) }
        // 当前标签也在被关集合里时，selectedTabID 不能悬空指着一个已删除的标签。
        if tabs.contains(where: { $0.id == selectedTabID }) {
            persistSession()
        } else {
            select(id)
        }
    }

    func reopenClosedTab() {
        guard let item = closedTabs.first else { return }
        closedTabs.removeFirst()
        let tab = BrowserTab(isPrivate: isPrivate, startURL: item.url)
        tab.windowState = self
        if !item.title.isEmpty {
            tab.title = item.title
        }
        if let scrollX = item.scrollX, let scrollY = item.scrollY {
            tab.restoreScroll(CGPoint(x: scrollX, y: scrollY))
        }
        if item.isPinned == true {
            tab.isPinned = true
        }
        insert(tab, after: selectedIndex, select: true)
    }

    func moveTab(from offsets: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: offsets, toOffset: destination)
        persistSession()
    }

    /// Reorders a tab inside its current pinned/regular section.
    /// Dragging never silently changes pin state; that remains an explicit menu action.
    @discardableResult
    func moveTab(_ id: BrowserTab.ID, before targetID: BrowserTab.ID?) -> Bool {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let movingTab = tabs[sourceIndex]
        let sectionIndices = tabs.indices.filter { tabs[$0].isPinned == movingTab.isPinned }
        guard let first = sectionIndices.first, let last = sectionIndices.last else { return false }

        var destination = last + 1
        if let targetID {
            guard let targetIndex = tabs.firstIndex(where: { $0.id == targetID }),
                  tabs[targetIndex].isPinned == movingTab.isPinned else { return false }
            destination = targetIndex
        }

        let tab = tabs.remove(at: sourceIndex)
        if sourceIndex < destination { destination -= 1 }
        destination = min(max(destination, first), min(last, tabs.count))
        tabs.insert(tab, at: destination)
        selectedTabID = tab.id
        persistSession()
        return sourceIndex != destination
    }

    func togglePinned(_ id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        guard tab.isPinned || tab.url != nil else {
            tabs.insert(tab, at: index)
            return
        }
        tab.isPinned.toggle()
        let pinnedCount = tabs.prefix(while: { $0.isPinned }).count
        tabs.insert(tab, at: pinnedCount)
        selectedTabID = tab.id
        persistSession()
    }

    func tabDidFinishNavigation(_ tab: BrowserTab) {
        persistSession()
    }

    /// WKWebView 本身不适合做 @Published 值，但稳定宿主必须在它创建或释放时
    /// 立即重新同步标签集合。只转发这两个生命周期节点，避免加载进度造成全窗重绘。
    func tabWebViewDidChange(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        objectWillChange.send()
    }

    func selectOffset(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let next = (selectedIndex + delta + tabs.count) % tabs.count
        select(tabs[next].id)
    }

    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    func requestBookmarkSave() {
        guard selectedTab?.url != nil else { return }
        isBookmarkSavePopoverPresented = true
    }

    func fillCredential(_ credential: WebCredential) {
        do {
            let password = try credentials.password(for: credential)
            attemptFill(credential, password: password, isRetry: false)
        } catch {
            presentCredentialError(error)
        }
    }

    /// SPA 登录框可能在点钥匙菜单后才渲染出来；第一次失败等 350ms 自动重试一次，
    /// 仍失败才提示用户。重试必须确认目标标签仍是当前标签，避免填进别的页面。
    private func attemptFill(_ credential: WebCredential, password: String, isRetry: Bool) {
        guard let tab = selectedTab else { return }
        tab.fill(credential, password: password) { [weak self, weak tab] ok in
            Task { @MainActor in
                guard let self, let tab, !ok else { return }
                guard self.selectedTab === tab, tab.webView != nil else { return }
                if !isRetry {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.attemptFill(credential, password: password, isRetry: true)
                    }
                } else {
                    self.presentFillFailure()
                }
            }
        }
    }

    private func presentFillFailure() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "未能自动填充"
        alert.informativeText = "页面上没有找到可填充的登录表单，已自动重试一次。请确认登录框已显示后，再从地址栏钥匙菜单选择账号。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 待用户确认的保存密码请求。放在 @Published 上由窗口层用 SwiftUI alert
    /// 呈现，避免在 WKScriptMessageHandler 回调里跑 runModal 嵌套 runloop。
    struct PendingCredentialOffer: Equatable {
        let scope: String
        let username: String
        let password: String
        let isUpdate: Bool
    }

    @Published var pendingCredentialOffer: PendingCredentialOffer?

    func offerToSaveCredential(scope: String, username: String, password: String) {
        let existing = credentials.credentials.contains {
            $0.scope == scope && $0.username == username
        }
        pendingCredentialOffer = PendingCredentialOffer(
            scope: scope,
            username: username,
            password: password,
            isUpdate: existing
        )
    }

    func resolveCredentialOffer(_ offer: PendingCredentialOffer, save: Bool) {
        if pendingCredentialOffer == offer {
            pendingCredentialOffer = nil
        }
        guard save else { return }
        do {
            try credentials.save(scope: offer.scope, username: offer.username, password: offer.password)
        } catch {
            presentCredentialError(error)
        }
    }

    func clearCurrentWebsiteData() {
        guard let url = selectedTab?.url, let host = url.host?.lowercased() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清除 \(host) 的网站数据？"
        alert.informativeText = "将删除此网站的 Cookie、本地存储和缓存，并退出该网站的登录状态。书签和历史记录不受影响。"
        alert.addButton(withTitle: "清除并重新载入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 无痕窗口使用 nonPersistent 仓库；写死 default() 会误清普通窗口的持久登录态。
        let dataStore = selectedTab?.webView?.configuration.websiteDataStore
            ?? WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: dataTypes) { [weak self] records in
            let matches = records.filter { record in
                let domain = record.displayName.lowercased()
                return domain == host
                    || host.hasSuffix(".\(domain)")
                    || domain.hasSuffix(".\(host)")
            }

            // WebKit 的网站数据记录以页面主机为主，父域 Cookie（例如
            // .xiaohongshu.com）可能不会随 www.xiaohongshu.com 记录一起删除。
            // 先按关联域显式删除 Cookie，再清理其余网站数据。
            let roots = Set(matches.map { $0.displayName.lowercased() } + [host])
            let cookieStore = dataStore.httpCookieStore
            cookieStore.getAllCookies { cookies in
                let relatedCookies = cookies.filter { cookie in
                    let domain = cookie.domain
                        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        .lowercased()
                    return roots.contains { root in
                        domain == root
                            || domain.hasSuffix(".\(root)")
                            || root.hasSuffix(".\(domain)")
                    }
                }

                let group = DispatchGroup()
                for cookie in relatedCookies {
                    group.enter()
                    cookieStore.delete(cookie) { group.leave() }
                }
                group.notify(queue: .main) {
                    dataStore.removeData(ofTypes: dataTypes, for: matches) {
                        Task { @MainActor in
                            self?.selectedTab?.reload()
                        }
                    }
                }
            }
        }
    }

    private func presentCredentialError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法处理密码"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func addCurrentPage(to folderID: BookmarkItem.ID) {
        guard let tab = selectedTab, let url = tab.url else { return }
        let title = tab.title.isEmpty ? URLInput.simplifiedHost(from: url) : tab.title
        bookmarks.addToFolder(folderID, title: title, url: url)
    }

    func createBookmarkFolder() {
        let alert = NSAlert()
        alert.messageText = "新建书签文件夹"
        alert.informativeText = "请输入文件夹名称。"

        let field = NSTextField(string: "")
        field.placeholderString = "文件夹名称"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        bookmarks.addFolder(named: field.stringValue)
    }

    func editBookmark(_ item: BookmarkItem) {
        let alert = NSAlert()
        alert.messageText = item.isFolder ? "编辑书签文件夹" : "编辑书签"
        alert.informativeText = item.isFolder ? "修改文件夹名称。" : "名称可以留空，书签栏将只显示网站图标。"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let titleLabel = NSTextField(labelWithString: "名称")
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 11)
        let titleField = NSTextField(string: item.title)
        titleField.placeholderString = item.isFolder ? "文件夹名称" : "可留空"
        titleField.frame.size = NSSize(width: 320, height: 24)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(titleField)

        var urlField: NSTextField?
        if !item.isFolder {
            let urlLabel = NSTextField(labelWithString: "网址")
            urlLabel.textColor = .secondaryLabelColor
            urlLabel.font = .systemFont(ofSize: 11)
            let field = NSTextField(string: item.url.absoluteString)
            field.frame.size = NSSize(width: 320, height: 24)
            stack.addArrangedSubview(urlLabel)
            stack.addArrangedSubview(field)
            urlField = field
        }

        stack.frame = NSRect(x: 0, y: 0, width: 320, height: item.isFolder ? 54 : 112)
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.isFolder {
            guard !title.isEmpty else { return }
            bookmarks.update(item.id, title: title, url: nil)
            return
        }

        guard let rawURL = urlField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let destination = URLInput.destination(from: rawURL) else { return }
        bookmarks.update(item.id, title: title, url: destination)
    }

    func showHistory() {
        sidebarTab = .history
        isSidebarVisible = true
    }

    func showDownloads() {
        sidebarTab = .downloads
        isSidebarVisible = true
    }

    /// 查找栏的显隐统一从这里走：隐藏时同步清掉查询词和页面高亮，
    /// 避免各入口（关闭按钮、⌘F、菜单）各自处理造成高亮残留。
    func setFindBar(visible: Bool) {
        isFindBarVisible = visible
        if !visible {
            findQuery = ""
            selectedTab?.clearFindHighlights()
        }
    }

    func toggleFindBar() {
        setFindBar(visible: !isFindBarVisible)
    }

    func syncAddressBar() {
        guard !isAddressEditing else { return }
        if let url = selectedTab?.url {
            addressText = url.absoluteString
        } else {
            addressText = ""
        }
    }

    func beginEditingAddress(selectingCurrentURL: Bool) {
        isAddressEditing = true
        if selectingCurrentURL, let url = selectedTab?.url {
            addressText = url.absoluteString
        } else {
            addressText = ""
        }
        addressFocusToken = UUID()
    }

    private func rememberClosedTab(_ tab: BrowserTab) {
        guard let url = tab.url else { return }
        closedTabs.insert(
            ClosedTabSnapshot(
                url: url,
                title: tab.title,
                scrollX: tab.savedScrollPosition.map { Double($0.x) },
                scrollY: tab.savedScrollPosition.map { Double($0.y) },
                isPinned: tab.isPinned
            ),
            at: 0
        )
        if closedTabs.count > 20 {
            closedTabs = Array(closedTabs.prefix(20))
        }
    }

    private func activateStartupTabs() {
        // 体验模式对齐 Chromium 关闭 Memory Saver：恢复会话后立即为
        // 所有标签创建 WKWebView，标签关闭前不由 Lemon 销毁页面。
        selectedTab?.activate()
        for tab in tabs where tab.id != selectedTabID {
            tab.activate()
        }
        enforceTabLifecycle()
    }

    private func openBlankTabAndFocusAddress() {
        let tab = BrowserTab(isPrivate: isPrivate)
        tab.windowState = self
        insert(tab, after: selectedIndex, select: true)
        addressText = ""
        beginEditingAddress(selectingCurrentURL: false)
    }

    private func insert(_ tab: BrowserTab, after index: Int, select: Bool) {
        let pinnedCount = tabs.prefix(while: { $0.isPinned }).count
        let insertAt: Int
        if tab.isPinned {
            // 固定标签必须落在固定区，否则 tabs.prefix(while: \.isPinned) 的分区假设失效。
            insertAt = pinnedCount
        } else {
            let selectedIsPinned = tabs.indices.contains(index) && tabs[index].isPinned
            insertAt = selectedIsPinned
                ? pinnedCount
                : max(pinnedCount, min(index + 1, tabs.count))
        }
        tabs.insert(tab, at: insertAt)
        if select {
            selectedTabID = tab.id
            tab.activate()
        }
        enforceTabLifecycle()
        persistSession()
    }

    private func observeContentBlocker() {
        contentBlockerObserver = NotificationCenter.default.addObserver(
            forName: .lemonContentBlockerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tabs.forEach { $0.applyContentBlocking() }
            }
        }
    }

    private func observeTermination() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // willTerminate 里再排异步 Task 可能来不及执行；快照是小文件，直接同步写。
            MainActor.assumeIsolated {
                self?.persistSession(immediately: true)
            }
        }
    }

    /// 窗口关闭：立即落盘会话，并逐个 tearDown 标签。tearDown 会暂停媒体并
    /// 退出全屏，避免 WebContent 进程异步退出期间继续出声、全屏窗口滞留。
    func handleWindowWillClose() {
        persistSession(immediately: true)
        tabs.forEach { $0.tearDown() }
        Self.claimedWindowSessionIDs.remove(windowSessionID)
    }

    private func enforceTabLifecycle() {
        selectedTab?.activate()
        for tab in tabs where tab.id != selectedTabID && tab.webView != nil {
            tab.markWarm()
        }
    }

    private func persistSession(immediately: Bool = false) {
        guard !isPrivate else { return }
        persistWorkItem?.cancel()
        if immediately {
            saveSessionSnapshot()
            selectedTab?.captureScrollPosition { [weak self] in
                self?.saveSessionSnapshot()
            }
            return
        }
        // 切换/新建/移动标签都会触发持久化，还会伴随滚动位置回读的二次写入；
        // 合并成 0.4 秒内的最后一次，退出与关窗时立即落盘。
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveSessionSnapshot()
            self?.selectedTab?.captureScrollPosition { [weak self] in
                self?.saveSessionSnapshot()
            }
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func saveSessionSnapshot() {
        guard !isPrivate else { return }
        let snapshot = BrowserSessionSnapshot(
            tabs: tabs.map {
                BrowserSessionSnapshot.TabSnapshot(
                    url: $0.url,
                    title: $0.title,
                    isPinned: $0.isPinned,
                    scrollX: $0.savedScrollPosition.map { Double($0.x) },
                    scrollY: $0.savedScrollPosition.map { Double($0.y) }
                )
            },
            selectedIndex: selectedIndex,
            closedTabs: Array(closedTabs.prefix(20))
        )
        BrowserSessionStore.save(windowID: windowSessionID, snapshot: snapshot)
    }
}

enum SidebarTab: String, CaseIterable {
    case bookmarks = "书签"
    case history = "历史记录"
    case downloads = "下载"
}
