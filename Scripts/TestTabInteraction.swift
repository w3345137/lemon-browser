import AppKit
import SwiftUI

/// 生产 NSCollectionView/NSCollectionViewItem，独立空白资料和 UserDefaults。
@main
struct TestTabInteraction {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "com.lemon.tests.tab-interaction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TabInteractionPreferences(defaults: defaults)
        precondition(!preferences.closeOnDoubleClick && !preferences.closeOnRightClick)
        preferences.closeOnDoubleClick = true
        preferences.closeOnRightClick = true
        let reloaded = TabInteractionPreferences(defaults: defaults)
        precondition(reloaded.closeOnDoubleClick && reloaded.closeOnRightClick)
        preferences.closeOnDoubleClick = false
        preferences.closeOnRightClick = false

        let state = BrowserWindowState(isDemo: true)
        defer { state.handleWindowWillClose() }
        state.openNewTab()
        state.openNewTab()
        state.tabs[0].isPinned = true // 空白测试标签，不加载外部网页。
        state.tabs[0].title = "固定页签"
        state.tabs[1].title = "普通页签"
        state.tabs[2].title = "音频页签"
        state.tabs[2].mediaState = .playing
        let host = NSHostingView(rootView: TabStripView(state: state, layoutWidth: 680, preferences: preferences)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        func settle() {
            for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            host.layoutSubtreeIfNeeded()
        }
        settle()
        func descendant<T: NSView>(_ view: NSView, as type: T.Type) -> T? {
            if let matched = view as? T { return matched }
            for child in view.subviews {
                if let matched = descendant(child, as: type) { return matched }
            }
            return nil
        }
        guard let collection = descendant(host, as: TabCollectionView.self) else {
            preconditionFailure("native collection missing")
        }
        collection.layoutSubtreeIfNeeded()

        func event(_ type: NSEvent.EventType, index: Int, clicks: Int = 1,
                   flags: NSEvent.ModifierFlags = [], dx: CGFloat = 0, dy: CGFloat = 0) -> NSEvent {
            let frame = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))!.frame
            let point = collection.convert(NSPoint(x: frame.midX + dx, y: frame.midY + dy), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        func click(_ index: Int, count: Int = 1, drag: Bool = false, verticalDrag: Bool = false) {
            app.postEvent(event(.leftMouseUp, index: index, clicks: count), atStart: true)
            if drag { app.postEvent(event(.leftMouseDragged, index: index, dx: 8), atStart: true) }
            if verticalDrag { app.postEvent(event(.leftMouseDragged, index: index, dy: 8), atStart: true) }
            collection.mouseDown(with: event(.leftMouseDown, index: index, clicks: count))
            settle()
        }

        // 默认右键菜单保留，默认双击不会关闭。
        let originalMenu = collection.menu(for: event(.rightMouseDown, index: 1))!
        let menuTitles = originalMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
        precondition(menuTitles == ["固定标签页", "复制标签页", "关闭其他标签页", "关闭右侧标签页", "关闭标签页"])
        click(1); click(1, count: 2)
        precondition(state.tabs.count == 3)

        // 设置修改触发已创建的 NSView 更新，不需要重新建窗口。
        preferences.closeOnDoubleClick = true
        preferences.closeOnRightClick = true
        settle()
        precondition(collection.closeOnDoubleClick && collection.closeOnRightClick)
        precondition(collection.menu(for: event(.rightMouseDown, index: 1)) == nil)
        precondition(state.tabs.count == 3) // 查询菜单没有关闭副作用。

        func item(_ index: Int) -> NativeTabCollectionItem {
            collection.item(at: IndexPath(item: index, section: 0)) as! NativeTabCollectionItem
        }
        func button(_ item: NativeTabCollectionItem, _ label: String) -> NSButton {
            item.view.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == label }!
        }
        let regular = item(1)
        precondition(regular.makeContextMenu()!.items.filter { !$0.isSeparatorItem }.map(\.title) == menuTitles)
        let more = button(regular, "标签页更多操作")
        let cell = regular.view as! TabCellView
        precondition(more.isHidden)
        cell.onHoverChange?(true)
        precondition(!more.isHidden)
        regular.viewDidLayout()
        let close = regular.view.subviews.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("closeTab") }!
        precondition(close.frame.maxX < more.frame.minX)
        precondition(more.target === regular && more.action == NSSelectorFromString("showMoreMenu"))
        cell.onHoverChange?(false)
        precondition(more.isHidden)
        let audioItem = item(2)
        let audioMore = button(audioItem, "标签页更多操作")
        audioItem.viewDidLayout()
        let audio = button(audioItem, "静音此标签页")
        let audioClose = audioItem.view.subviews.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("closeTab") }!
        precondition(!audio.isHidden && audio.frame.maxX < audioClose.frame.minX)
        precondition(audioClose.frame.maxX < audioMore.frame.minX)
        precondition(audioItem.view.subviews.compactMap { $0 as? NSProgressIndicator }.allSatisfy(\.isHidden))

        let snapshotDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/tab-interaction-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        func snapshot(_ name: String) throws {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: snapshotDirectory.appendingPathComponent(name))
        }
        (audioItem.view as! TabCellView).onHoverChange?(true)
        try snapshot("regular-hover.png")
        (audioItem.view as! TabCellView).onHoverChange?(false)
        let pinned = item(0)
        precondition(pinned.makeContextMenu()!.items.first?.title == "取消固定标签页")
        let pinnedMore = button(pinned, "标签页更多操作")
        pinned.viewDidLayout()
        let pinnedWidth = pinned.view.bounds.width
        (pinned.view as! TabCellView).onHoverChange?(true)
        precondition(!pinnedMore.isHidden)
        precondition(abs(pinnedMore.frame.midX - pinnedWidth / 2) < 0.01)
        precondition(pinned.view.bounds.width == pinnedWidth)
        try snapshot("pinned-hover.png")
        (pinned.view as! TabCellView).onHoverChange?(false)
        precondition(pinnedMore.isHidden)

        // 更多入口仍使用原菜单动作，固定/取消固定不会关闭或切换到其他标签。
        let unpinMenu = pinned.makeContextMenu()!
        let unpin = unpinMenu.items[0]
        _ = (unpin.target as! NSObject).perform(unpin.action)
        settle()
        precondition(state.tabs.count == 3 && !state.tabs[0].isPinned)
        state.tabs[0].isPinned = true
        settle()

        // 右键关闭后台标签，不偷换当前选择；由真实子视图转发事件。
        state.select(state.tabs[2].id)
        let selected = state.selectedTabID
        let background = state.tabs[1].id
        let closeHit = button(item(1), "标签页更多操作")
        let hitPoint = closeHit.convert(NSPoint(x: 8, y: 8), to: nil)
        let right = NSEvent.mouseEvent(with: .rightMouseDown, location: hitPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        closeHit.rightMouseDown(with: right)
        settle()
        precondition(state.tabs.count == 2 && !state.tabs.contains { $0.id == background })
        precondition(state.selectedTabID == selected)

        // 连续双击只关一个标签；第三下不能关移动到原位置的另一个标签。
        state.openNewTab(); settle()
        let doubleTarget = state.tabs[1].id
        click(1); click(1, count: 2)
        precondition(state.tabs.count == 2 && !state.tabs.contains { $0.id == doubleTarget })
        click(1, count: 3)
        precondition(state.tabs.count == 2)

        // 两次点击不同标签/拖动后的第二下，不能误识别成双击关闭。
        click(0); click(1, count: 2)
        precondition(state.tabs.count == 2)
        click(1, drag: true); click(1, count: 2)
        precondition(state.tabs.count == 2)
        click(1, verticalDrag: true); click(1, count: 2)
        precondition(state.tabs.count == 2)

        // Control+点击按右键关闭；固定标签可关闭，菜单不会再被系统打开。
        let pinnedID = state.tabs[0].id
        collection.mouseDown(with: event(.leftMouseDown, index: 0, flags: .control))
        settle()
        precondition(state.tabs.count == 1 && !state.tabs.contains { $0.id == pinnedID })

        // 最后一个标签关闭后沿用原逻辑生成起始页，并可关闭开关恢复菜单。
        collection.rightMouseDown(with: event(.rightMouseDown, index: 0))
        settle()
        precondition(state.tabs.count == 1 && state.tabs[0].isStartPage)
        preferences.closeOnDoubleClick = false
        preferences.closeOnRightClick = false
        settle()
        precondition(!collection.closeOnDoubleClick && !collection.closeOnRightClick)
        precondition(collection.menu(for: event(.rightMouseDown, index: 0)) != nil)
        precondition(button(item(0), "标签页更多操作").isHidden)
        preferences.closeOnRightClick = true
        settle()
        let lastFrame = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame
        let blank = collection.convert(NSPoint(x: lastFrame.maxX + 12, y: lastFrame.midY), to: nil)
        let blankEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: blank, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
        let remainingID = state.tabs[0].id
        collection.rightMouseDown(with: blankEvent)
        precondition(state.tabs.count == 1 && state.tabs[0].id == remainingID)
        print("tab-interaction-preferences-native-events-and-menu-tests=passed")
    }
}
