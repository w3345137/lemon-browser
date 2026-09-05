import AppKit
import Combine
import SwiftUI

struct TabStripView: NSViewRepresentable {
    @ObservedObject var state: BrowserWindowState
    let layoutWidth: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(state: state, layoutWidth: layoutWidth) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 2
        layout.minimumInteritemSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)

        let collectionView = TabCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            NativeTabCollectionItem.self,
            forItemWithIdentifier: NativeTabCollectionItem.identifier
        )
        collectionView.registerForDraggedTypes([.lemonTabID])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.contextMenuProvider = { [weak coordinator = context.coordinator] indexPath in
            coordinator?.contextMenu(for: indexPath)
        }
        collectionView.onDropFeedbackCleared = { [weak coordinator = context.coordinator] in
            coordinator?.clearDropFeedback()
        }

        let scrollView = TabStripScrollView()
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScroller = nil
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none

        context.coordinator.collectionView = collectionView
        context.coordinator.layoutWidth = layoutWidth
        context.coordinator.reloadTabs(state.tabs)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // 用户把系统滚动条设为“始终显示”时，也不能让标签栏出现轨道。
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScroller = nil
        context.coordinator.state = state
        context.coordinator.layoutWidth = layoutWidth
        context.coordinator.reloadTabs(state.tabs)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var state: BrowserWindowState
        var layoutWidth: CGFloat
        fileprivate weak var collectionView: TabCollectionView?
        private var tabs: [BrowserTab] = []
        private var subscriptions: [BrowserTab.ID: AnyCancellable] = [:]
        private var contextTab: BrowserTab?
        private var draggingTabID: BrowserTab.ID?

        init(state: BrowserWindowState, layoutWidth: CGFloat) {
            self.state = state
            self.layoutWidth = layoutWidth
        }

        func reloadTabs(_ newTabs: [BrowserTab]) {
            let oldIDs = tabs.map(\.id)
            let newIDs = newTabs.map(\.id)
            tabs = newTabs
            observeTabs(newTabs)

            if oldIDs != newIDs {
                collectionView?.reloadData()
            } else {
                refreshVisibleItems()
            }
            syncSelection()
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            tabs.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: NativeTabCollectionItem.identifier,
                for: indexPath
            ) as! NativeTabCollectionItem
            configure(item, at: indexPath)
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            guard indexPath.item < tabs.count else { return .zero }
            return NSSize(width: tabs[indexPath.item].isPinned ? 38 : regularTabWidth(), height: 36)
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard let indexPath = indexPaths.first, indexPath.item < tabs.count else { return }
            state.select(tabs[indexPath.item].id)
            refreshVisibleItems()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> NSPasteboardWriting? {
            guard indexPath.item < tabs.count else { return nil }
            let item = NSPasteboardItem()
            item.setString(tabs[indexPath.item].id.uuidString, forType: .lemonTabID)
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            canDragItemsAt indexPaths: Set<IndexPath>,
            with event: NSEvent
        ) -> Bool { indexPaths.count == 1 }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItemsAt indexPaths: Set<IndexPath>
        ) {
            guard let indexPath = indexPaths.first, indexPath.item < tabs.count else { return }
            draggingTabID = tabs[indexPath.item].id
            refreshVisibleItems()
            NSCursor.closedHand.push()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            dragOperation operation: NSDragOperation
        ) {
            draggingTabID = nil
            clearDropFeedback()
            refreshVisibleItems()
            NSCursor.pop()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            validateDrop draggingInfo: NSDraggingInfo,
            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation {
            guard let sourceID = draggedTabID(from: draggingInfo),
                  let sourceTab = tabs.first(where: { $0.id == sourceID }) else {
                clearDropFeedback()
                return []
            }

            let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
            let insertion = insertionIndex(at: point, forPinned: sourceTab.isPinned)
            proposedDropIndexPath.pointee = IndexPath(item: insertion, section: 0) as NSIndexPath
            proposedDropOperation.pointee = .before
            self.collectionView?.showInsertion(at: insertion, itemCount: tabs.count)
            return .move
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            acceptDrop draggingInfo: NSDraggingInfo,
            indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation
        ) -> Bool {
            guard let sourceID = draggedTabID(from: draggingInfo),
                  let sourceTab = tabs.first(where: { $0.id == sourceID }) else { return false }
            let insertion = clampedInsertion(indexPath.item, forPinned: sourceTab.isPinned)
            let target = insertion < tabs.count && tabs[insertion].isPinned == sourceTab.isPinned
                ? tabs[insertion].id
                : nil
            let accepted = state.moveTab(sourceID, before: target)
            clearDropFeedback()
            reloadTabs(state.tabs)
            return accepted || tabs.filter { $0.isPinned == sourceTab.isPinned }.count == 1
        }

        func clearDropFeedback() { collectionView?.hideInsertion() }

        func contextMenu(for indexPath: IndexPath) -> NSMenu? {
            guard indexPath.item < tabs.count else { return nil }
            contextTab = tabs[indexPath.item]
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(menuItem(
                contextTab?.isPinned == true ? "取消固定标签页" : "固定标签页",
                #selector(togglePinnedContextTab)
            ))
            menu.addItem(.separator())
            menu.addItem(menuItem("复制标签页", #selector(duplicateContextTab)))
            menu.addItem(menuItem("关闭其他标签页", #selector(closeOtherContextTabs)))
            menu.addItem(menuItem("关闭右侧标签页", #selector(closeRightContextTabs)))
            menu.addItem(.separator())
            menu.addItem(menuItem("关闭标签页", #selector(closeContextTab)))
            return menu
        }

        private func configure(_ item: NativeTabCollectionItem, at indexPath: IndexPath) {
            guard indexPath.item < tabs.count else { return }
            let tab = tabs[indexPath.item]
            item.configure(
                tab: tab,
                selected: tab.id == state.selectedTabID,
                dragging: tab.id == draggingTabID,
                onClose: { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    self.state.closeTab(tab.id)
                    self.reloadTabs(self.state.tabs)
                },
                onToggleMute: { [weak tab] in
                    tab?.toggleAudioMute()
                }
            )
        }

        private func regularTabWidth() -> CGFloat {
            let regularCount = max(1, tabs.filter { !$0.isPinned }.count)
            let pinnedCount = tabs.filter(\.isPinned).count
            let spacing = CGFloat(max(tabs.count - 1, 0)) * 2
            // 使用 SwiftUI 已分配给标签集合的确定宽度。读取尚在布局中的
            // NSScrollView viewport 会得到上一帧宽度，造成标签视觉宽度和
            // 集合点击区域分离，“+”前出现大块空白。
            // 留出 1 pt 取整余量，避免内容宽度与 viewport 临界相等时
            // AppKit 误判为横向溢出并重新创建滚动条。
            let available = max(0, layoutWidth - CGFloat(pinnedCount * 38) - spacing - 1)
            // Chromium 会随标签数量增加逐步压缩宽度；保留足够的图标、标题和关闭按钮空间。
            let adaptiveMinimum: CGFloat = 76
            return min(SafariChrome.tabMaxWidth, max(adaptiveMinimum, available / CGFloat(regularCount)))
        }

        private func insertionIndex(at point: NSPoint, forPinned pinned: Bool) -> Int {
            let raw: Int
            if let hovered = collectionView?.indexPathForItem(at: point), hovered.item < tabs.count,
               let frame = collectionView?.layoutAttributesForItem(at: hovered)?.frame {
                raw = point.x < frame.midX ? hovered.item : hovered.item + 1
            } else {
                raw = tabs.count
            }
            return clampedInsertion(raw, forPinned: pinned)
        }

        private func clampedInsertion(_ insertion: Int, forPinned pinned: Bool) -> Int {
            let pinnedCount = tabs.prefix(while: \.isPinned).count
            return pinned
                ? min(max(0, insertion), pinnedCount)
                : min(max(pinnedCount, insertion), tabs.count)
        }

        private func draggedTabID(from info: NSDraggingInfo) -> BrowserTab.ID? {
            guard let raw = info.draggingPasteboard.string(forType: .lemonTabID) else { return nil }
            return UUID(uuidString: raw)
        }

        private func observeTabs(_ tabs: [BrowserTab]) {
            let ids = Set(tabs.map(\.id))
            subscriptions = subscriptions.filter { ids.contains($0.key) }
            for tab in tabs where subscriptions[tab.id] == nil {
                subscriptions[tab.id] = tab.objectWillChange
                    .receive(on: RunLoop.main)
                    .sink { [weak self, weak tab] _ in
                        DispatchQueue.main.async { [weak self] in
                            // 索引在派发后再解析：sink 触发到异步执行之间标签可能已被移动或删除。
                            guard let self, let tab,
                                  let index = self.tabs.firstIndex(where: { $0.id == tab.id }),
                                  let item = self.collectionView?.item(
                                    at: IndexPath(item: index, section: 0)
                                  ) as? NativeTabCollectionItem else { return }
                            self.configure(item, at: IndexPath(item: index, section: 0))
                        }
                    }
            }
        }

        private func refreshVisibleItems() {
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleItems() {
                if let item = collectionView.item(at: indexPath) as? NativeTabCollectionItem {
                    configure(item, at: indexPath)
                }
            }
            collectionView.collectionViewLayout?.invalidateLayout()
        }

        private func syncSelection() {
            guard let index = tabs.firstIndex(where: { $0.id == state.selectedTabID }) else { return }
            collectionView?.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        }

        private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            return item
        }

        @objc private func togglePinnedContextTab() {
            guard let tab = contextTab else { return }
            state.togglePinned(tab.id)
            reloadTabs(state.tabs)
        }

        @objc private func closeContextTab() {
            guard let tab = contextTab else { return }
            state.closeTab(tab.id)
            reloadTabs(state.tabs)
        }

        @objc private func duplicateContextTab() {
            guard let tab = contextTab else { return }
            state.duplicateTab(tab.id)
            reloadTabs(state.tabs)
        }

        @objc private func closeOtherContextTabs() {
            guard let tab = contextTab else { return }
            state.closeOtherTabs(keeping: tab.id)
            reloadTabs(state.tabs)
        }

        @objc private func closeRightContextTabs() {
            guard let tab = contextTab else { return }
            state.closeTabsToRight(of: tab.id)
            reloadTabs(state.tabs)
        }
    }
}

private extension NSPasteboard.PasteboardType {
    static let lemonTabID = NSPasteboard.PasteboardType("com.workbuddy.lemon.tab-id")
}

private final class TabStripScrollView: NSScrollView {
    // AppKit 会在 NSCollectionView.reloadData() 后异步重新评估 scroller。
    // 仅在 make/update/tile 时隐藏仍会短暂或永久重建轨道，因此从属性
    // 层面拒绝安装横向 scroller，同时保留触控板的横向内容滚动能力。
    override var hasHorizontalScroller: Bool {
        get { false }
        set { super.hasHorizontalScroller = false }
    }

    override var horizontalScroller: NSScroller? {
        get { nil }
        set { super.horizontalScroller = nil }
    }

    override func layout() {
        super.layout()
        suppressHorizontalScroller()
    }

    override func tile() {
        super.tile()
        suppressHorizontalScroller()
    }

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        suppressHorizontalScroller()
    }

    private func suppressHorizontalScroller() {
        super.hasHorizontalScroller = false
        super.horizontalScroller = nil
    }
}

fileprivate final class TabCollectionView: NSCollectionView {
    var contextMenuProvider: ((IndexPath) -> NSMenu?)?
    var onDropFeedbackCleared: (() -> Void)?
    private let insertionView = NSView()

    // 标签栏处于 fullSizeContentView 标题区，明确禁止集合空白和标签手势
    // 被 NSWindow 解释为移动整个窗口。
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        insertionView.wantsLayer = true
        insertionView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionView.layer?.cornerRadius = 1
        insertionView.isHidden = true
        addSubview(insertionView)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else { return nil }
        return contextMenuProvider?(path)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDropFeedbackCleared?()
    }

    func showInsertion(at index: Int, itemCount: Int) {
        let x: CGFloat
        if index < itemCount,
           let frame = layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
            x = frame.minX - 1
        } else if itemCount > 0,
                  let frame = layoutAttributesForItem(at: IndexPath(item: itemCount - 1, section: 0))?.frame {
            x = frame.maxX + 1
        } else {
            x = 1
        }
        insertionView.frame = NSRect(x: x, y: 8, width: 2, height: 24)
        insertionView.isHidden = false
        addSubview(insertionView, positioned: .above, relativeTo: nil)
    }

    func hideInsertion() { insertionView.isHidden = true }
}

private final class NativeTabCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NativeTabCollectionItem")
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let audioButton = NSButton()
    private let loadingIndicator = NSProgressIndicator()
    private var hovering = false
    private var selectedState = false
    private var draggingState = false
    private var pinnedState = false
    private var privateState = false
    private var playingAudio = false
    private var mutedAudio = false
    private var onClose: (() -> Void)?
    private var onToggleMute: (() -> Void)?

    override func loadView() {
        let cellView = TabCellView()
        cellView.onHoverChange = { [weak self] inside in
            self?.hovering = inside
            self?.updateAppearance(animated: true)
        }
        view = cellView
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.cornerCurve = .continuous
        iconView.imageScaling = .scaleProportionallyDown
        titleField.font = .systemFont(ofSize: 12)
        titleField.lineBreakMode = .byTruncatingTail
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭标签页")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 8
        audioButton.isBordered = false
        audioButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "正在播放音频，点击静音")
        audioButton.imageScaling = .scaleProportionallyDown
        audioButton.contentTintColor = .controlAccentColor
        audioButton.target = self
        audioButton.action = #selector(toggleMute)
        audioButton.wantsLayer = true
        audioButton.layer?.cornerRadius = 8
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isIndeterminate = true
        loadingIndicator.isDisplayedWhenStopped = false
        view.addSubview(iconView)
        view.addSubview(loadingIndicator)
        view.addSubview(titleField)
        view.addSubview(audioButton)
        view.addSubview(closeButton)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        iconView.frame = NSRect(x: pinnedState ? 12 : 14, y: 11, width: 14, height: 14)
        loadingIndicator.frame = iconView.frame
        closeButton.frame = NSRect(x: view.bounds.width - 28, y: 10, width: 16, height: 16)
        audioButton.frame = NSRect(x: view.bounds.width - 47, y: 10, width: 16, height: 16)
        titleField.frame = NSRect(
            x: 34,
            y: 9,
            width: max(0, view.bounds.width - (showsAudioIndicator ? 88 : 68)),
            height: 18
        )
    }

    /// 播放中或已静音都要给音频按钮留位（Chromium 静音后保留静音图标）。
    private var showsAudioIndicator: Bool {
        playingAudio || mutedAudio
    }

    func configure(tab: BrowserTab, selected: Bool, dragging: Bool, onClose: @escaping () -> Void, onToggleMute: @escaping () -> Void) {
        selectedState = selected
        draggingState = dragging
        pinnedState = tab.isPinned
        privateState = tab.isPrivate
        playingAudio = tab.mediaState == .playing
        mutedAudio = tab.isAudioMuted
        self.onClose = onClose
        self.onToggleMute = onToggleMute
        titleField.stringValue = tab.title
        titleField.isHidden = tab.isPinned
        let host = tab.url.flatMap { URLInput.simplifiedHost(from: $0) }
        let lifecycleHint: String
        switch tab.lifecycleState {
        case .suspended:
            lifecycleHint = "\n已暂停以节省内存"
        case .discarded:
            lifecycleHint = "\n已在内存压力下释放，点击后恢复"
        case .active, .warm:
            lifecycleHint = ""
        }
        let mediaHint: String
        if mutedAudio {
            mediaHint = "\n已静音，点击喇叭图标恢复声音"
        } else {
            mediaHint = playingAudio ? "\n正在播放音频，点击喇叭图标静音" : ""
        }
        view.toolTip = [tab.title, host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") + lifecycleHint + mediaHint
        audioButton.image = NSImage(
            systemSymbolName: mutedAudio ? "speaker.slash.fill" : "speaker.wave.2.fill",
            accessibilityDescription: mutedAudio ? "已静音，点击恢复声音" : "正在播放音频，点击静音"
        )
        audioButton.contentTintColor = mutedAudio ? .secondaryLabelColor : .controlAccentColor
        audioButton.toolTip = mutedAudio ? "取消静音此标签页" : "静音此标签页"
        iconView.isHidden = tab.isLoading
        if tab.isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
        iconView.alphaValue = tab.lifecycleState == .suspended ? 0.58 : 1
        if let favicon = tab.favicon {
            iconView.image = favicon
            iconView.contentTintColor = nil
        } else {
            iconView.image = NSImage(
                systemSymbolName: tab.isStartPage ? "macwindow" : "globe",
                accessibilityDescription: tab.title
            )
            iconView.contentTintColor = .secondaryLabelColor
        }
        if tab.isPinned, (playingAudio || mutedAudio), !tab.isLoading {
            iconView.image = NSImage(
                systemSymbolName: mutedAudio ? "speaker.slash.fill" : "speaker.wave.2.fill",
                accessibilityDescription: mutedAudio ? "已静音" : "正在播放音频"
            )
            iconView.contentTintColor = mutedAudio ? .secondaryLabelColor : .controlAccentColor
        }
        updateAppearance(animated: false)
        view.needsLayout = true
    }

    private func updateAppearance(animated: Bool) {
        let changes = {
            let attached = self.selectedState && !self.draggingState
            (self.view as? TabCellView)?.attached = attached
            self.view.layer?.cornerRadius = attached ? 0 : 10
            self.view.layer?.zPosition = attached ? 2 : (self.hovering ? 1 : 0)
            if self.draggingState {
                self.view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
                self.view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
                self.view.layer?.borderWidth = 1
                self.view.alphaValue = 0.42
            } else if self.selectedState {
                self.view.layer?.backgroundColor = NSColor.clear.cgColor
                self.view.layer?.borderWidth = 0
                self.view.alphaValue = 1
            } else if self.hovering {
                self.view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.065).cgColor
                self.view.layer?.borderWidth = 0
                self.view.alphaValue = 1
            } else {
                self.view.layer?.backgroundColor = NSColor.clear.cgColor
                self.view.layer?.borderWidth = 0
                self.view.alphaValue = 1
            }
            self.titleField.textColor = self.selectedState ? .labelColor : NSColor.labelColor.withAlphaComponent(0.72)
            self.closeButton.isHidden = self.pinnedState || (!self.selectedState && !self.hovering)
            self.audioButton.isHidden = self.pinnedState || !self.showsAudioIndicator
            self.closeButton.layer?.backgroundColor = self.hovering
                ? NSColor.labelColor.withAlphaComponent(0.07).cgColor
                : NSColor.clear.cgColor
            if self.privateState && self.selectedState {
                self.view.layer?.borderColor = NSColor.systemPurple.withAlphaComponent(0.28).cgColor
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                changes()
            }
        } else {
            changes()
        }
    }

    @objc private func closeTab() { onClose?() }
    @objc private func toggleMute() { onToggleMute?() }
}

private final class TabCellView: NSView {
    var attached = false { didSet { needsDisplay = true } }
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard attached else { return }
        // Chromium 式轮廓：顶部凸圆角，底部反向外扩，底边贴合工具栏。
        // 路径在 cell 内完成，避免滚动容器裁切两侧圆弧。
        let w = bounds.width, h = bounds.height
        let foot: CGFloat = 6
        let radius = min(CGFloat(9), (w - 2 * foot) / 2)
        let k: CGFloat = 0.55228475
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.curve(to: NSPoint(x: foot, y: foot),
                   controlPoint1: NSPoint(x: foot * k, y: 0),
                   controlPoint2: NSPoint(x: foot, y: foot * (1 - k)))
        path.line(to: NSPoint(x: foot, y: h - radius))
        path.curve(to: NSPoint(x: foot + radius, y: h),
                   controlPoint1: NSPoint(x: foot, y: h - radius * (1 - k)),
                   controlPoint2: NSPoint(x: foot + radius * (1 - k), y: h))
        path.line(to: NSPoint(x: w - foot - radius, y: h))
        path.curve(to: NSPoint(x: w - foot, y: h - radius),
                   controlPoint1: NSPoint(x: w - foot - radius * (1 - k), y: h),
                   controlPoint2: NSPoint(x: w - foot, y: h - radius * (1 - k)))
        path.line(to: NSPoint(x: w - foot, y: foot))
        path.curve(to: NSPoint(x: w, y: 0),
                   controlPoint1: NSPoint(x: w - foot, y: foot * (1 - k)),
                   controlPoint2: NSPoint(x: w - foot * k, y: 0))
        path.close()
        NSColor.controlBackgroundColor.setFill()
        path.fill()
    }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
