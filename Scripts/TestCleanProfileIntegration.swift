import AppKit
import SwiftUI
import WebKit

/// 编译完整生产源码，以真实窗口状态验证功能和隔离；不启动个人窗口。
@main
struct TestCleanProfileIntegration {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let a = BrowserWindowState(isDemo: true)
        let b = BrowserWindowState(isDemo: true)
        let privateWindow = BrowserWindowState(isPrivate: true, isDemo: true)
        defer {
            a.handleWindowWillClose()
            b.handleWindowWillClose()
            privateWindow.handleWindowWillClose()
        }
        precondition(!a.isPrivate && a.isDemo)
        precondition(a.isBookmarkBarVisible)
        precondition(!a.websiteDataStore.isPersistent)
        precondition(a.websiteDataStore !== b.websiteDataStore)
        precondition(a.bookmarks.barItems.isEmpty && a.history.entries.isEmpty && a.credentials.credentials.isEmpty)
        precondition(a.credentials !== b.credentials && a.permissions !== b.permissions)
        precondition(a.startPage !== b.startPage && a.startPage !== privateWindow.startPage)
        try a.startPage.saveShortcut(title: "Temporary test shortcut", address: "https://shortcuts.example/")
        try a.startPage.setVisible(.favorites, false)
        precondition(b.startPage.configuration.shortcuts.isEmpty && b.startPage.isVisible(.favorites))
        precondition(privateWindow.startPage.configuration.shortcuts.isEmpty)
        let startHost = NSHostingView(rootView: StartPageView(state: a))
        startHost.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        startHost.layoutSubtreeIfNeeded()
        precondition(!BrowserWindowState.hasUsedPersistentProfile)

        let url = URL(string: "https://public.example/login")!
        a.bookmarks.saveBookmark(title: "Test bookmark", url: url, to: .bar)
        a.history.record(title: "Test visit", url: url)
        precondition(a.bookmarks.barItems.count == 1 && a.history.entries.count == 1)
        precondition(b.bookmarks.barItems.isEmpty && b.history.entries.isEmpty)
        privateWindow.history.record(title: "Private visit", url: url)
        precondition(privateWindow.history.entries.isEmpty)

        let scope = "https://public.example"
        a.offerToSaveCredential(scope: scope, username: "test-user", password: "fake-password")
        guard let offer = a.pendingCredentialOffer else { preconditionFailure("clean profile cannot save") }
        precondition(!offer.isUpdate)
        a.resolveCredentialOffer(offer, save: true)
        precondition(a.credentials.credentials.count == 1)
        a.offerToSaveCredential(scope: scope, username: "test-user", password: "fake-password")
        precondition(a.pendingCredentialOffer == nil)
        a.offerToSaveCredential(scope: scope, username: "test-user", password: "changed-password")
        precondition(a.pendingCredentialOffer?.isUpdate == true)
        precondition(b.credentials.credentials.isEmpty)
        privateWindow.offerToSaveCredential(scope: scope, username: "test-user", password: "fake-password")
        precondition(privateWindow.pendingCredentialOffer == nil)

        a.permissions.set(.block, for: "public.example", kind: .popups)
        precondition(b.permissions.choice(for: "public.example", kind: .popups) == .ask)
        // 每个设置分类都通过生产视图实例化；没有演示占位分支。
        SettingsNavigation.shared.windowState = a
        for section in SettingsSection.allCases {
            SettingsNavigation.shared.selection = section
            let host = NSHostingView(rootView: SettingsView())
            host.frame = NSRect(x: 0, y: 0, width: 920, height: 640)
            host.layoutSubtreeIfNeeded()
            precondition(SettingsNavigation.shared.windowState === a)
        }
        print("clean-profile-production-window-and-settings-integration=passed")
    }
}
