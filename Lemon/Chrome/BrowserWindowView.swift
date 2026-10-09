import AppKit
import SwiftUI

struct BrowserWindowView: View {
    @StateObject var state: BrowserWindowState
    @FocusState private var addressFocused: Bool
    @State private var incomingURLToken: UUID?

    init(isPrivate: Bool = false, isDemo: Bool = false) {
        _state = StateObject(wrappedValue: BrowserWindowState(isPrivate: isPrivate, isDemo: isDemo))
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            AddressBarView(state: state, addressFocused: $addressFocused)
                .frame(height: SafariChrome.addressRowHeight)
                .background(Color(nsColor: .controlBackgroundColor))
            if state.isBookmarkBarVisible {
                Divider().opacity(0.22)
                BookmarkBarView(state: state)
            }
            if state.isFindBarVisible {
                Divider().opacity(0.22)
                FindBarView(state: state)
            }
            Divider().opacity(0.28)
            BookmarkStorageNotice(store: state.bookmarks)
            if let tab = state.selectedTab { SlowPageNotice(tab: tab) }
            if let notice = state.credentialNotice {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                    Text(notice).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { state.credentialNotice = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("关闭提示")
                    .accessibilityLabel("关闭密码填充提示")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            HStack(spacing: 0) {
                if state.isSidebarVisible {
                    SidebarView(state: state)
                        .frame(width: 260)
                    Divider()
                }
                PageStage(state: state)
            }
            StatusBarView(state: state)
        }
        // fullSizeContentView 下 SwiftUI 仍可能在窗口状态变化后恢复
        // 标题栏 safe-area，导致红绿灯独占一行。顶部 chrome 必须
        // 明确延伸到窗口顶端，让红绿灯与标签始终同排。
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowChrome(
            isPrivate: state.isPrivate && !state.isDemo,
            onWindowKey: {
                SettingsNavigation.shared.windowState = state
                // 系统外链应交给当前聚焦的窗口；多窗口时后开的窗口不再抢走接收权。
                guard !state.isPrivate else { return }
                incomingURLToken = IncomingBrowserURL.attach { url in
                    state.openInNewTab(url)
                }
            },
            onWindowClose: {
                // 设置仍打开时保留其资料上下文，不能在关窗后回退显示个人资料。
                if let incomingURLToken {
                    IncomingBrowserURL.detach(incomingURLToken)
                }
                state.handleWindowWillClose()
            }
        ))
        .background(state.isPrivate && !state.isDemo ? Color.black.opacity(0.18) : Color(nsColor: .windowBackgroundColor))
        .focusedSceneValue(\.browserState, state)
        .onChange(of: state.addressFocusToken) { _, _ in
            // TextField 由 isAddressEditing 动态插入，等一轮布局后再请求焦点。
            DispatchQueue.main.async {
                addressFocused = true
                DispatchQueue.main.async {
                    selectAllAddressText()
                }
            }
        }
        .onChange(of: state.selectedTabID) { _, _ in
            if !state.isAddressEditing {
                addressFocused = false
            }
        }
        .onChange(of: addressFocused) { _, focused in
            if !focused {
                state.isAddressEditing = false
                state.syncAddressBar()
            }
        }
        .onOpenURL { url in
            IncomingBrowserURL.deliver(url)
        }
        .onAppear {
            if !state.isPrivate {
                incomingURLToken = IncomingBrowserURL.attach { url in
                    state.openInNewTab(url)
                }
            }
        }
        .alert(
            state.pendingCredentialOffer?.isUpdate == true ? "更新已保存的密码？" : "保存此密码？",
            isPresented: Binding(
                get: { state.pendingCredentialOffer != nil },
                set: { if !$0 { state.pendingCredentialOffer = nil } }
            )
        ) {
            Button(state.pendingCredentialOffer?.isUpdate == true ? "更新密码" : "保存密码") {
                if let offer = state.pendingCredentialOffer {
                    state.resolveCredentialOffer(offer, save: true)
                }
            }
            Button("暂不保存", role: .cancel) {
                if let offer = state.pendingCredentialOffer {
                    state.resolveCredentialOffer(offer, save: false)
                }
            }
        } message: {
            if let offer = state.pendingCredentialOffer {
                let host = URL(string: offer.scope)?.host ?? offer.scope
                Text("网站：\(host)\n账号：\(offer.username.isEmpty ? "仅密码" : offer.username)\n\n密码将加密保存在 macOS Keychain。请确认网站已登录成功后再保存。")
            }
        }
    }

    private func selectAllAddressText() {
        guard let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView else {
            return
        }
        editor.selectAll(nil)
    }

    private var chrome: some View {
        GeometryReader { proxy in
            let stripWidth = tabStripWidth(availableWidth: proxy.size.width)
            HStack(spacing: 8) {
                // 原生 NSWindow 红黄绿按钮绘制在 fullSizeContentView 上方。
                // 这里仅预留同样的空间，标签栏继续与它们保持同一行。
                Color.clear
                    .frame(
                        width: SafariChrome.trafficLightReservedWidth,
                        height: SafariChrome.toolbarHeight
                    )
                    .accessibilityHidden(true)

                TabStripView(state: state, layoutWidth: stripWidth)
                    .frame(
                        width: stripWidth,
                        height: SafariChrome.toolbarHeight
                    )

                toolbarButton("plus", help: "新建标签页") {
                    state.openNewTab()
                }

                // Edge/Chrome 的新建按钮跟随最后一个标签。只有它右侧的
                // 真实空白区承担窗口移动，避免拖动标签时命中窗口标题栏。
                WindowDragRegion()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
        }
        .frame(height: SafariChrome.toolbarHeight)
        .background {
            ZStack {
                // 保留原标签栏灰色，只向白色混合 30%，避免变成纯白。
                Color(nsColor: .underPageBackgroundColor)
                Color.white.opacity(0.30)
            }
        }
    }

    private func tabStripWidth(availableWidth: CGFloat) -> CGFloat {
        let pinnedCount = state.tabs.filter(\.isPinned).count
        let regularCount = state.tabs.count - pinnedCount
        let itemSpacing = CGFloat(max(state.tabs.count - 1, 0)) * SafariChrome.tabSpacing
        let idealWidth = CGFloat(pinnedCount) * SafariChrome.pinnedTabWidth
            + CGFloat(regularCount) * SafariChrome.tabMaxWidth
            + itemSpacing

        // 预留红黄绿按钮、新建标签按钮、内边距与元素间距。
        let maximumWidth = max(SafariChrome.tabMinWidth, availableWidth - 127)
        return min(maximumWidth, max(SafariChrome.pinnedTabWidth, idealWidth))
    }

    private func toolbarButton(
        _ systemName: String,
        active: Bool = false,
        disabled: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(disabled ? 0.28 : 0.78))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

private struct BookmarkStorageNotice: View {
    @ObservedObject var store: BookmarkStore
    var body: some View {
        if let message = store.storageError {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.yellow.opacity(0.15))
        }
    }
}

private struct SlowPageNotice: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        if let notice = tab.slowPageNotice {
            HStack {
                Text(notice).font(.system(size: 12))
                Spacer()
                if tab.canRetrySlowPage { Button("重新打开") { tab.retrySlowPage() } }
                Button("继续等待") { tab.dismissSlowPageNotice() }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

private struct NavigationFailureNotice: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        if let error = tab.navigationError {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36))
                Text("网页加载失败").font(.headline)
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 480)
                HStack {
                    if tab.webView?.backForwardList.currentItem != nil {
                        Button("返回原页面") { tab.returnToLoadedPage() }
                    }
                    Button("重试") { tab.reload() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private struct PageStage: View {
    @ObservedObject var state: BrowserWindowState

    var body: some View {
        ZStack {
            WebViewStackPane(
                entries: state.tabs.compactMap { tab in
                    tab.webView.map { WebViewStackEntry(id: tab.id, webView: $0) }
                },
                selectedID: state.selectedTabID,
                focusRequestID: state.pageFocusRequestID
            )

            if let tab = state.selectedTab, tab.webContentDidCrash {
                CrashedPageOverlay(tab: tab)
            } else if state.selectedTab?.isStartPage != false || state.selectedTab?.webView == nil {
                StartPageView(state: state)
            }
            if let tab = state.selectedTab { NavigationFailureNotice(tab: tab) }
        }
    }
}

/// WebContent 进程崩溃后的占位页。崩溃的 WKWebView 只剩白屏且不产生任何
/// 导航回调，必须给用户一个明确的恢复入口；重新载入复用 reload() 路径。
private struct CrashedPageOverlay: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("页面崩溃了")
                .font(.system(size: 17, weight: .semibold))
            Text("此标签页的网页进程意外退出，页面已停止显示。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("重新载入此页") {
                tab.reload()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("页面崩溃占位")
    }
}
