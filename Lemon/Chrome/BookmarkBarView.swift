import AppKit
import SwiftUI

private struct BookmarkNativeDragSurface: NSViewRepresentable {
    let itemID: BookmarkItem.ID?
    let onClick: (() -> Void)?
    let onDrop: (BookmarkItem.ID) -> Bool
    let onOpen: (() -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    var onHoverOpen: (() -> Void)? = nil
    var onHoverChange: ((Bool) -> Void)? = nil
    var onPressChange: ((Bool) -> Void)? = nil
    var onDropAtPosition: ((BookmarkItem.ID, CGFloat) -> Bool)? = nil
    var onDragPositionChange: ((CGFloat?) -> Void)? = nil
    var hoverOpenPositionPredicate: ((CGFloat) -> Bool)? = nil
    let removeTitle: String
    @Binding var targeted: Bool

    func makeNSView(context: Context) -> BookmarkDragNSView {
        let view = BookmarkDragNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: BookmarkDragNSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: BookmarkDragNSView) {
        view.itemID = itemID
        view.onClick = onClick
        view.onDrop = onDrop
        view.onOpen = onOpen
        view.onEdit = onEdit
        view.onDelete = onDelete
        view.onHoverOpen = onHoverOpen
        view.onHoverChange = onHoverChange
        view.onPressChange = onPressChange
        view.onDropAtPosition = onDropAtPosition
        view.onDragPositionChange = onDragPositionChange
        view.hoverOpenPositionPredicate = hoverOpenPositionPredicate
        view.removeTitle = removeTitle
        view.onTargeted = { isTargeted in
            if targeted != isTargeted {
                targeted = isTargeted
            }
        }
    }
}

private final class BookmarkDragNSView: NSView, NSDraggingSource {
    override var mouseDownCanMoveWindow: Bool { false }
    var itemID: BookmarkItem.ID?
    var onClick: (() -> Void)?
    var onDrop: ((BookmarkItem.ID) -> Bool)?
    var onOpen: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onHoverOpen: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onPressChange: ((Bool) -> Void)?
    var onDropAtPosition: ((BookmarkItem.ID, CGFloat) -> Bool)?
    var onDragPositionChange: ((CGFloat?) -> Void)?
    var hoverOpenPositionPredicate: ((CGFloat) -> Bool)?
    var onTargeted: ((Bool) -> Void)?
    var removeTitle = "移除"

    private var mouseDownEvent: NSEvent?
    private var startedDragging = false
    private var pointerHoverOpenWorkItem: DispatchWorkItem?
    private var dragHoverOpenWorkItem: DispatchWorkItem?
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.lemonNativeBookmark])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.lemonNativeBookmark])
    }

    deinit {
        pointerHoverOpenWorkItem?.cancel()
        dragHoverOpenWorkItem?.cancel()
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
        schedulePointerHoverOpen()
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
        onPressChange?(false)
        pointerHoverOpenWorkItem?.cancel()
        pointerHoverOpenWorkItem = nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        startedDragging = false
        onPressChange?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging,
              let itemID,
              let mouseDownEvent else { return }

        let origin = mouseDownEvent.locationInWindow
        let current = event.locationInWindow
        guard hypot(current.x - origin.x, current.y - origin.y) >= 3 else { return }

        startedDragging = true
        pointerHoverOpenWorkItem?.cancel()
        pointerHoverOpenWorkItem = nil
        onPressChange?(false)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(itemID.uuidString, forType: .lemonNativeBookmark)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let sourceView = superview ?? self
        draggingItem.setDraggingFrame(sourceView.bounds, contents: dragImage(for: sourceView))
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        onPressChange?(false)
        if !startedDragging {
            onClick?()
        }
        mouseDownEvent = nil
        startedDragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onPressChange?(false)
        guard onOpen != nil || onEdit != nil || onDelete != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        if onOpen != nil {
            menu.addItem(menuItem(title: "在新标签页打开", action: #selector(openFromMenu)))
        }
        if onEdit != nil {
            menu.addItem(menuItem(title: "编辑…", action: #selector(editFromMenu)))
        }
        if onDelete != nil {
            menu.addItem(.separator())
            menu.addItem(menuItem(title: removeTitle, action: #selector(deleteFromMenu)))
        }

        let point = convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func openFromMenu() { onOpen?() }
    @objc private func editFromMenu() { onEdit?() }
    @objc private func deleteFromMenu() { onDelete?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropState(true, sender: sender)
        return draggedItemID(from: sender) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropState(true, sender: sender)
        return draggedItemID(from: sender) == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        updateDropState(false, sender: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = draggedItemID(from: sender) else { return false }
        let position = relativeVerticalPosition(from: sender)
        let accepted = onDropAtPosition?(id, position) ?? onDrop?(id) ?? false
        updateDropState(false, sender: nil)
        return accepted
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        updateDropState(false, sender: nil)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        startedDragging = false
        mouseDownEvent = nil
        NSCursor.arrow.set()
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    private func updateDropState(_ targeted: Bool, sender: NSDraggingInfo?) {
        onTargeted?(targeted)
        let position = sender.map(relativeVerticalPosition(from:))
        onDragPositionChange?(targeted ? position : nil)
        guard targeted,
              let position,
              let onHoverOpen,
              hoverOpenPositionPredicate?(position) ?? true else {
            dragHoverOpenWorkItem?.cancel()
            dragHoverOpenWorkItem = nil
            return
        }
        // draggingUpdated fires continuously; restarting this timer there
        // prevented spring-loading while the pointer was moving.
        guard dragHoverOpenWorkItem == nil else { return }
        let workItem = DispatchWorkItem { onHoverOpen() }
        dragHoverOpenWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func schedulePointerHoverOpen() {
        pointerHoverOpenWorkItem?.cancel()
        guard let onHoverOpen else { return }
        let workItem = DispatchWorkItem { onHoverOpen() }
        pointerHoverOpenWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func relativeVerticalPosition(from info: NSDraggingInfo) -> CGFloat {
        guard bounds.height > 0 else { return 0.5 }
        let point = convert(info.draggingLocation, from: nil)
        return min(1, max(0, point.y / bounds.height))
    }

    private func draggedItemID(from info: NSDraggingInfo) -> BookmarkItem.ID? {
        guard let raw = info.draggingPasteboard.string(forType: .lemonNativeBookmark) else { return nil }
        return UUID(uuidString: raw)
    }

    private func dragImage(for view: NSView) -> NSImage {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return NSImage(size: view.bounds.size)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

private final class BookmarkFolderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class BookmarkFolderPanelController: NSObject {
    private static let didCloseMenu = Notification.Name("LemonBookmarkMenuDidClose")
    private let panel: BookmarkFolderPanel
    private let contentSize: NSSize
    private weak var parentWindow: NSWindow?
    private weak var anchorView: NSView?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var parentCloseObserver: NSObjectProtocol?
    private var isClosing = false
    var onClose: (() -> Void)?

    var isShown: Bool { panel.isVisible }

    init(contentViewController: NSViewController, contentSize: NSSize) {
        self.contentSize = contentSize
        panel = BookmarkFolderPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.contentViewController = contentViewController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]

        contentViewController.view.frame = NSRect(origin: .zero, size: contentSize)
        contentViewController.view.wantsLayer = true
        contentViewController.view.layer?.cornerRadius = 10
        contentViewController.view.layer?.cornerCurve = .continuous
        contentViewController.view.layer?.masksToBounds = true
        contentViewController.view.layer?.borderWidth = 0.5
        contentViewController.view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
    }

    func show(below anchor: NSView) {
        show(anchor: anchor, beside: false)
    }

    func show(beside anchor: NSView) {
        show(anchor: anchor, beside: true)
    }

    private func show(anchor: NSView, beside: Bool) {
        guard let parentWindow = anchor.window else { return }
        self.parentWindow = parentWindow
        anchorView = anchor

        let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorOnScreen = parentWindow.convertToScreen(anchorInWindow)
        let visibleFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let frame = beside ? BookmarkFolderPanelGeometry.beside(
            anchorOnScreen, contentSize: contentSize, within: visibleFrame
        ) : BookmarkFolderPanelGeometry.frame(
            below: anchorOnScreen,
            contentSize: contentSize,
            within: visibleFrame
        )
        panel.setFrame(frame, display: false)
        parentWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        installObservers()
        parentCloseObserver = NotificationCenter.default.addObserver(
            forName: Self.didCloseMenu,
            object: parentWindow, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        NotificationCenter.default.post(name: Self.didCloseMenu, object: panel)
        removeObservers()
        if let parentWindow {
            parentWindow.removeChildWindow(panel)
        }
        panel.orderOut(nil)
        isClosing = false
        onClose?()
    }

    private func installObservers() {
        removeObservers()
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.close()
                return nil
            }
            guard event.window === self.parentWindow else { return event }
            if let anchorView = self.anchorView {
                let point = anchorView.convert(event.locationInWindow, from: nil)
                if anchorView.bounds.contains(point) {
                    return event
                }
            }
            self.close()
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func removeObservers() {
        if let parentCloseObserver {
            NotificationCenter.default.removeObserver(parentCloseObserver)
            self.parentCloseObserver = nil
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}

// Unlike NSPopover, these panels do not dismiss when a native drag begins.
// They share the top-level menu's positioning and lifetime rules.
private struct BookmarkSubmenuAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let folderID: BookmarkItem.ID
    let state: BrowserWindowState
    let bookmarks: BookmarkStore
    let onDismissAll: () -> Void

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var panel: BookmarkFolderPanelController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        let coordinator = context.coordinator
        guard isPresented else {
            coordinator.panel?.close()
            coordinator.panel = nil
            return
        }
        guard coordinator.panel == nil else { return }
        DispatchQueue.main.async {
            guard isPresented, view.window != nil, coordinator.panel == nil else { return }
            let screen = view.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let layout = BookmarkFolderLayout(
                childCount: bookmarks.item(with: folderID)?.children.count ?? 0,
                maximumHeight: screen.height - BookmarkFolderPanelGeometry.screenMargin * 2,
                maximumWidth: screen.width - BookmarkFolderPanelGeometry.screenMargin * 2
            )
            let controller = NSHostingController(rootView: BookmarkFolderPopover(
                folderID: folderID, state: state, bookmarks: bookmarks,
                preferredLayout: layout, onDismissAll: onDismissAll
            ))
            let panel = BookmarkFolderPanelController(contentViewController: controller, contentSize: layout.contentSize)
            panel.onClose = { [weak coordinator] in
                coordinator?.panel = nil
                DispatchQueue.main.async { isPresented = false }
            }
            coordinator.panel = panel
            panel.show(beside: view)
        }
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.panel?.close()
        coordinator.panel = nil
    }
}

private struct NativeBookmarkBar: NSViewRepresentable {
    let items: [BookmarkItem]
    let state: BrowserWindowState
    let bookmarks: BookmarkStore

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, bookmarks: bookmarks)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)

        let collectionView = BookmarkCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            NativeBookmarkCollectionItem.self,
            forItemWithIdentifier: NativeBookmarkCollectionItem.identifier
        )
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.registerForDraggedTypes([.lemonNativeBookmark])
        collectionView.onActivate = { [weak coordinator = context.coordinator] indexPath in
            coordinator?.activate(indexPath)
        }
        collectionView.contextMenuProvider = { [weak coordinator = context.coordinator] indexPath in
            coordinator?.contextMenu(for: indexPath)
        }
        collectionView.onDropFeedbackCleared = { [weak coordinator = context.coordinator] in
            coordinator?.clearDropFeedback()
        }

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScroller?.isHidden = true
        context.coordinator.collectionView = collectionView
        context.coordinator.items = items
        collectionView.reloadData()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.state = state
        context.coordinator.bookmarks = bookmarks
        if context.coordinator.items != items {
            let oldItems = context.coordinator.items
            let requiresTopLevelReload = oldItems.count != items.count
                || zip(oldItems, items).contains { oldItem, newItem in
                    oldItem.id != newItem.id
                        || oldItem.title != newItem.title
                        || oldItem.url != newItem.url
                        || oldItem.isFolder != newItem.isFolder
                }
            context.coordinator.items = items
            // 文件夹内部增删只刷新弹层中的 ObservedObject。重载顶层 collection
            // 会销毁 NSPopover 的 anchor view，导致已打开菜单横向跳位。
            if requiresTopLevelReload {
                context.coordinator.collectionView?.reloadData()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, @preconcurrency NSCollectionViewDelegateFlowLayout {
        var state: BrowserWindowState
        var bookmarks: BookmarkStore
        var items: [BookmarkItem] = []
        fileprivate weak var collectionView: BookmarkCollectionView?
        private var contextItem: BookmarkItem?
        private var folderPanel: BookmarkFolderPanelController?
        private var hoverOpenWorkItem: DispatchWorkItem?
        private var hoveredFolderID: BookmarkItem.ID?
        private var draggingItemID: BookmarkItem.ID?
        private var draggingSourceIndexPath: IndexPath?
        private var nativeDropAccepted = false

        init(state: BrowserWindowState, bookmarks: BookmarkStore) {
            self.state = state
            self.bookmarks = bookmarks
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let collectionItem = collectionView.makeItem(
                withIdentifier: NativeBookmarkCollectionItem.identifier,
                for: indexPath
            ) as! NativeBookmarkCollectionItem
            collectionItem.configure(
                with: items[indexPath.item],
                dragging: items[indexPath.item].id == draggingItemID
            )
            return collectionItem
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            NSSize(width: NativeBookmarkCollectionItem.width(for: items[indexPath.item]), height: 30)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> NSPasteboardWriting? {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(items[indexPath.item].id.uuidString, forType: .lemonNativeBookmark)
            return pasteboardItem
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            writeItemsAt indexPaths: Set<IndexPath>,
            to pasteboard: NSPasteboard
        ) -> Bool {
            guard let indexPath = indexPaths.first, indexPath.item < items.count else { return false }
            pasteboard.declareTypes([.lemonNativeBookmark], owner: nil)
            return pasteboard.setString(items[indexPath.item].id.uuidString, forType: .lemonNativeBookmark)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            canDragItemsAt indexPaths: Set<IndexPath>,
            with event: NSEvent
        ) -> Bool {
            !indexPaths.isEmpty
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItemsAt indexPaths: Set<IndexPath>
        ) {
            guard let path = indexPaths.first, path.item < items.count else { return }
            draggingItemID = items[path.item].id
            draggingSourceIndexPath = path
            nativeDropAccepted = false
            refreshVisibleItems()
            NSCursor.closedHand.set()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            dragOperation operation: NSDragOperation
        ) {
            if !nativeDropAccepted,
               let source = draggingSourceIndexPath,
               let window = collectionView.window {
                let windowPoint = window.convertPoint(fromScreen: screenPoint)
                let collectionPoint = collectionView.convert(windowPoint, from: nil)
                if collectionView.bounds.contains(collectionPoint) {
                    _ = manualMove(from: source, to: collectionPoint)
                }
            }
            draggingItemID = nil
            draggingSourceIndexPath = nil
            nativeDropAccepted = false
            clearDropFeedback()
            refreshVisibleItems()
            NSCursor.arrow.set()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            validateDrop draggingInfo: NSDraggingInfo,
            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation {
            guard draggedItemID(from: draggingInfo) != nil else { return [] }

            let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
            if let hovered = collectionView.indexPathForItem(at: point),
               hovered.item < items.count {
                let target = items[hovered.item]
                let frame = collectionView.layoutAttributesForItem(at: hovered)?.frame ?? .zero
                let relativeX = frame.width > 0 ? (point.x - frame.minX) / frame.width : 0

                if target.isFolder, relativeX > 0.24, relativeX < 0.76 {
                    proposedDropIndexPath.pointee = hovered as NSIndexPath
                    proposedDropOperation.pointee = .on
                    self.collectionView?.hideInsertion()
                    setDropTarget(hovered)
                    scheduleFolderOpen(target, at: hovered)
                } else {
                    let insertion = relativeX < 0.5 ? hovered.item : hovered.item + 1
                    proposedDropIndexPath.pointee = IndexPath(item: insertion, section: 0) as NSIndexPath
                    proposedDropOperation.pointee = .before
                    cancelFolderOpen()
                    setDropTarget(nil)
                    self.collectionView?.showInsertion(at: insertion, itemCount: items.count)
                }
            } else {
                cancelFolderOpen()
                setDropTarget(nil)
                self.collectionView?.showInsertion(at: items.count, itemCount: items.count)
            }
            return .move
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            acceptDrop draggingInfo: NSDraggingInfo,
            indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation
        ) -> Bool {
            guard let itemID = draggedItemID(from: draggingInfo) else { return false }

            if dropOperation == .on,
               indexPath.item < items.count,
               items[indexPath.item].isFolder {
                let accepted = bookmarks.move(itemID, toFolder: items[indexPath.item].id, before: nil)
                nativeDropAccepted = accepted
                clearDropFeedback()
                return accepted
            }

            let siblingID = indexPath.item < items.count ? items[indexPath.item].id : nil
            let accepted = bookmarks.move(itemID, toFolder: nil, before: siblingID)
            nativeDropAccepted = accepted
            clearDropFeedback()
            return accepted
        }

        func manualMove(from source: IndexPath, to point: NSPoint) -> Bool {
            guard source.item < items.count, let collectionView else { return false }
            let itemID = items[source.item].id

            guard let targetIndexPath = collectionView.indexPathForItem(at: point),
                  targetIndexPath.item < items.count else {
                return bookmarks.move(itemID, toFolder: nil, before: nil)
            }

            let target = items[targetIndexPath.item]
            let frame = collectionView.layoutAttributesForItem(at: targetIndexPath)?.frame ?? .zero
            let relativeX = frame.width > 0 ? (point.x - frame.minX) / frame.width : 0
            if target.isFolder, relativeX > 0.24, relativeX < 0.76 {
                return bookmarks.move(itemID, toFolder: target.id, before: nil)
            }

            let siblingIndex = relativeX < 0.5 ? targetIndexPath.item : targetIndexPath.item + 1
            let siblingID = siblingIndex < items.count ? items[siblingIndex].id : nil
            return bookmarks.move(itemID, toFolder: nil, before: siblingID)
        }

        private func draggedItemID(from draggingInfo: NSDraggingInfo) -> BookmarkItem.ID? {
            guard let rawID = draggingInfo.draggingPasteboard.string(forType: .lemonNativeBookmark) else {
                return nil
            }
            return UUID(uuidString: rawID)
        }

        func activate(_ indexPath: IndexPath) {
            guard indexPath.item < items.count else { return }
            let item = items[indexPath.item]
            if item.isFolder {
                if folderPanel?.isShown == true, hoveredFolderID == item.id {
                    dismissFolderPopover()
                } else {
                    showFolder(item, at: indexPath)
                }
            } else {
                state.openBookmark(item)
            }
        }

        private func showFolder(_ item: BookmarkItem, at indexPath: IndexPath) {
            guard let anchor = collectionView?.item(at: indexPath)?.view else { return }
            if folderPanel?.isShown == true, hoveredFolderID == item.id { return }
            let layout = BookmarkFolderLayout(
                childCount: item.children.count,
                maximumHeight: availableFolderHeight(below: anchor),
                maximumWidth: (anchor.window?.screen?.visibleFrame.width ?? 1280) - 16
            )
            let contentSize = NSSize(width: layout.contentSize.width, height: layout.contentSize.height)
            let hostingController = NSHostingController(
                rootView: BookmarkFolderPopover(
                    folderID: item.id,
                    state: state,
                    bookmarks: bookmarks,
                    preferredLayout: layout,
                    onDismissAll: { [weak self] in self?.dismissFolderPopover() }
                )
            )
            let panel = BookmarkFolderPanelController(
                contentViewController: hostingController,
                contentSize: contentSize
            )
            panel.onClose = { [weak self, weak panel] in
                guard let self, self.folderPanel === panel else { return }
                self.folderPanel = nil
                self.hoveredFolderID = nil
            }
            folderPanel?.close()
            folderPanel = panel
            hoveredFolderID = item.id
            panel.show(below: anchor)
        }

        private func dismissFolderPopover() {
            hoverOpenWorkItem?.cancel()
            hoverOpenWorkItem = nil
            folderPanel?.close()
            folderPanel = nil
            hoveredFolderID = nil
        }

        private func availableFolderHeight(below anchor: NSView) -> CGFloat {
            guard let window = anchor.window else {
                return (NSScreen.main?.visibleFrame.height ?? 720) - 96
            }
            let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
            let anchorOnScreen = window.convertToScreen(anchorInWindow)
            let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            // 浮层边距和屏幕底部各预留少量空间。
            return max(
                BookmarkFolderLayout.minimumHeight,
                anchorOnScreen.minY - visibleFrame.minY - 18
            )
        }

        private func scheduleFolderOpen(_ item: BookmarkItem, at indexPath: IndexPath) {
            guard hoveredFolderID != item.id || folderPanel?.isShown != true else { return }
            hoverOpenWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.showFolder(item, at: indexPath)
            }
            hoverOpenWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
        }

        private func cancelFolderOpen() {
            hoverOpenWorkItem?.cancel()
            hoverOpenWorkItem = nil
        }

        func clearDropFeedback() {
            cancelFolderOpen()
            collectionView?.hideInsertion()
            setDropTarget(nil)
        }

        private func setDropTarget(_ indexPath: IndexPath?) {
            guard let collectionView else { return }
            for path in collectionView.indexPathsForVisibleItems() {
                (collectionView.item(at: path) as? NativeBookmarkCollectionItem)?
                    .setDropTargeted(path == indexPath)
            }
        }

        private func refreshVisibleItems() {
            guard let collectionView else { return }
            for path in collectionView.indexPathsForVisibleItems() where path.item < items.count {
                (collectionView.item(at: path) as? NativeBookmarkCollectionItem)?
                    .configure(with: items[path.item], dragging: items[path.item].id == draggingItemID)
            }
        }

        func contextMenu(for indexPath: IndexPath) -> NSMenu? {
            guard indexPath.item < items.count else { return nil }
            contextItem = items[indexPath.item]
            let item = items[indexPath.item]
            let menu = NSMenu()
            menu.autoenablesItems = false
            if !item.isFolder {
                menu.addItem(menuItem("在新标签页打开", #selector(openContextItem)))
            }
            menu.addItem(menuItem("编辑…", #selector(editContextItem)))
            menu.addItem(.separator())
            menu.addItem(menuItem("从书签栏移除", #selector(deleteContextItem)))
            return menu
        }

        private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.isEnabled = true
            return menuItem
        }

        @objc private func openContextItem() {
            if let contextItem { state.openBookmark(contextItem) }
        }

        @objc private func editContextItem() {
            if let contextItem { state.editBookmark(contextItem) }
        }

        @objc private func deleteContextItem() {
            if let contextItem { bookmarks.remove(contextItem.id) }
        }
    }
}

private extension NSPasteboard.PasteboardType {
    static let lemonNativeBookmark = NSPasteboard.PasteboardType("com.workbuddy.lemon.native-bookmark-id")
}

fileprivate final class BookmarkCollectionView: NSCollectionView {
    var onActivate: ((IndexPath) -> Void)?
    var contextMenuProvider: ((IndexPath) -> NSMenu?)?
    var onDropFeedbackCleared: (() -> Void)?
    private var mouseDownPoint: NSPoint?
    private var dragged = false
    private let insertionView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        insertionView.wantsLayer = true
        insertionView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionView.layer?.cornerRadius = 1
        insertionView.isHidden = true
        addSubview(insertionView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragged = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = mouseDownPoint {
            let point = convert(event.locationInWindow, from: nil)
            dragged = dragged || hypot(point.x - start.x, point.y - start.y) >= 3
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseUp(with: event)
        defer {
            mouseDownPoint = nil
            deselectAll(nil)
        }
        guard !dragged else { return }
        if let indexPath = indexPathForItem(at: point) {
            onActivate?(indexPath)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return contextMenuProvider?(indexPath)
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
            x = 8
        }
        insertionView.frame = NSRect(x: x, y: 8, width: 2, height: 24)
        insertionView.isHidden = false
        addSubview(insertionView, positioned: .above, relativeTo: nil)
    }

    func hideInsertion() {
        insertionView.isHidden = true
    }

}

private final class NativeBookmarkCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NativeBookmarkCollectionItem")
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var representedID: BookmarkItem.ID?
    private var hovering = false
    private var dropTargeted = false
    private var draggingState = false

    override var isSelected: Bool {
        didSet { updateAppearance(animated: true) }
    }

    override func loadView() {
        let cellView = BookmarkCellView()
        cellView.onHoverChange = { [weak self] inside in
            self?.hovering = inside
            self?.updateAppearance(animated: true)
        }
        view = cellView
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.cornerCurve = .continuous
        iconView.imageScaling = .scaleProportionallyDown
        titleField.font = .systemFont(ofSize: 12.5)
        titleField.textColor = NSColor.labelColor.withAlphaComponent(0.88)
        titleField.lineBreakMode = .byTruncatingTail
        view.addSubview(iconView)
        view.addSubview(titleField)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        iconView.frame = NSRect(x: 8, y: 8, width: 14, height: 14)
        titleField.frame = NSRect(
            x: 28,
            y: 6,
            width: max(0, view.bounds.width - 36),
            height: 18
        )
    }

    func configure(with item: BookmarkItem, dragging: Bool = false) {
        representedID = item.id
        draggingState = dragging
        titleField.stringValue = item.title
        titleField.isHidden = item.title.isEmpty
        view.toolTip = item.title.isEmpty ? item.url.absoluteString : item.title

        if item.isFolder {
            iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: item.title)
            iconView.contentTintColor = NSColor(calibratedRed: 0.82, green: 0.61, blue: 0.08, alpha: 1)
        } else {
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: item.title)
            iconView.contentTintColor = .secondaryLabelColor
            FaviconService.load(for: item.url) { [weak self] image in
                guard self?.representedID == item.id, let image else { return }
                self?.iconView.image = image
                self?.iconView.contentTintColor = nil
            }
        }
        updateAppearance(animated: false)
        view.needsLayout = true
    }

    func setDropTargeted(_ targeted: Bool) {
        dropTargeted = targeted
        updateAppearance(animated: true)
    }

    private func updateAppearance(animated: Bool) {
        let changes = {
            if self.draggingState {
                self.view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
                self.view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
                self.view.layer?.borderWidth = 1
                self.view.alphaValue = 0.46
            } else if self.dropTargeted {
                self.view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
                self.view.layer?.borderColor = NSColor.controlAccentColor.cgColor
                self.view.layer?.borderWidth = 1.5
                self.view.alphaValue = 1
            } else if self.hovering || self.isSelected {
                self.view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(self.isSelected ? 0.10 : 0.065).cgColor
                self.view.layer?.borderWidth = 0
                self.view.alphaValue = 1
            } else {
                self.view.layer?.backgroundColor = NSColor.clear.cgColor
                self.view.layer?.borderWidth = 0
                self.view.alphaValue = 1
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

    static func width(for item: BookmarkItem) -> CGFloat {
        guard !item.title.isEmpty else { return 30 }
        let font = NSFont.systemFont(ofSize: 12.5)
        let textWidth = ceil((item.title as NSString).size(withAttributes: [.font: font]).width)
        return min(198, 8 + 14 + 6 + textWidth + 12)
    }
}

private final class BookmarkCellView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

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

struct BookmarkBarView: View {
    @ObservedObject var state: BrowserWindowState
    @ObservedObject private var bookmarks: BookmarkStore
    @State private var showingOverflow = false

    init(state: BrowserWindowState) {
        self.state = state
        _bookmarks = ObservedObject(wrappedValue: state.bookmarks)
    }

    var body: some View {
        GeometryReader { proxy in
            let split = visibleItems(for: proxy.size.width)
            HStack(spacing: 0) {
                NativeBookmarkBar(items: split.visible, state: state, bookmarks: bookmarks)

                if !split.overflow.isEmpty {
                    Button {
                        showingOverflow.toggle()
                    } label: {
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: SafariChrome.bookmarkBarHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("更多书签")
                    .popover(isPresented: $showingOverflow, arrowEdge: .bottom) {
                        BookmarkOverflowPopover(
                            itemIDs: split.overflow.map(\.id),
                            state: state,
                            bookmarks: bookmarks,
                            onDismissAll: { showingOverflow = false }
                        )
                    }
                }

                Divider().opacity(0.55)

                Button(action: state.createBookmarkFolder) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: SafariChrome.bookmarkBarHeight)
                }
                .buttonStyle(.plain)
                .help("新建书签文件夹")
            }
        }
        .frame(height: SafariChrome.bookmarkBarHeight)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.74))
    }

    private func visibleItems(for totalWidth: CGFloat) -> (visible: [BookmarkItem], overflow: [BookmarkItem]) {
        let newFolderWidth: CGFloat = 37
        let availableWithoutOverflow = max(0, totalWidth - newFolderWidth)
        let allWidth = bookmarks.barItems.reduce(CGFloat.zero) {
            $0 + NativeBookmarkCollectionItem.width(for: $1)
        }
        guard allWidth > availableWithoutOverflow else {
            return (bookmarks.barItems, [])
        }

        let available = max(0, availableWithoutOverflow - 32)
        var used: CGFloat = 0
        var visibleCount = 0
        for item in bookmarks.barItems {
            let width = NativeBookmarkCollectionItem.width(for: item)
            guard used + width <= available else { break }
            used += width
            visibleCount += 1
        }
        return (
            Array(bookmarks.barItems.prefix(visibleCount)),
            Array(bookmarks.barItems.dropFirst(visibleCount))
        )
    }

}

private struct BookmarkOverflowPopover: View {
    let itemIDs: [BookmarkItem.ID]
    @ObservedObject var state: BrowserWindowState
    @ObservedObject var bookmarks: BookmarkStore
    let onDismissAll: () -> Void
    @State private var stableLayout: BookmarkFolderLayout?

    private var items: [BookmarkItem] {
        itemIDs.compactMap { bookmarks.item(with: $0) }
    }

    private var layout: BookmarkFolderLayout {
        stableLayout ?? BookmarkFolderLayout(
            childCount: items.count,
            maximumHeight: (NSScreen.main?.visibleFrame.height ?? 720) - 96,
            fixedChromeHeight: 8,
            minimumHeight: 46
        )
    }

    var body: some View {
        BookmarkFolderColumns(items: items, folderID: nil, layout: layout,
                              state: state, bookmarks: bookmarks, onDismissAll: onDismissAll,
                              removeTitle: "从书签栏移除")
        .frame(width: menuWidth, height: layout.contentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if stableLayout == nil {
                stableLayout = BookmarkFolderLayout(
                    childCount: items.count,
                    maximumHeight: (NSScreen.main?.visibleFrame.height ?? 720) - 96,
                    fixedChromeHeight: 8,
                    minimumHeight: 46
                )
            }
        }
    }

    private var menuWidth: CGFloat {
        min(layout.contentSize.width, (NSScreen.main?.visibleFrame.width ?? 1280) - 16)
    }
}

private struct BookmarkFolderPopover: View {
    let folderID: BookmarkItem.ID
    @ObservedObject var state: BrowserWindowState
    @ObservedObject var bookmarks: BookmarkStore
    var preferredLayout: BookmarkFolderLayout? = nil
    let onDismissAll: () -> Void
    @State private var stableLayout: BookmarkFolderLayout?
    @State private var addButtonHovering = false

    private var folder: BookmarkItem? {
        bookmarks.item(with: folderID)
    }

    private var layout: BookmarkFolderLayout {
        preferredLayout ?? stableLayout ?? BookmarkFolderLayout(
            childCount: folder?.children.count ?? 0,
            maximumHeight: (NSScreen.main?.visibleFrame.height ?? 720) - 96
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                state.addCurrentPage(to: folderID)
                onDismissAll()
            } label: {
                Text("添加本页到此文件夹")
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(addButtonHovering ? Color.primary.opacity(0.07) : Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(BookmarkFolderActionButtonStyle())
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .disabled(state.selectedTab?.url == nil)
            .onHover { addButtonHovering = $0 }

            Divider()

            if let folder, folder.children.isEmpty {
                Text("暂无书签")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let folder {
                BookmarkFolderColumns(items: folder.children, folderID: folderID, layout: layout,
                                      state: state, bookmarks: bookmarks, onDismissAll: onDismissAll)
                .frame(maxHeight: .infinity)
            }
        }
        // 打开后锁定尺寸。添加书签刷新 children 时，弹层不会重新定位或横向平移。
        .frame(width: preferredLayout?.contentSize.width ?? min(layout.contentSize.width, (NSScreen.main?.visibleFrame.width ?? 1280) - 16),
               height: layout.contentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if stableLayout == nil {
                stableLayout = preferredLayout ?? BookmarkFolderLayout(
                    childCount: folder?.children.count ?? 0,
                    maximumHeight: (NSScreen.main?.visibleFrame.height ?? 720) - 96
                )
            }
        }
    }
}

private struct BookmarkFolderColumns: View {
    let items: [BookmarkItem]
    let folderID: BookmarkItem.ID?
    let layout: BookmarkFolderLayout
    @ObservedObject var state: BrowserWindowState
    @ObservedObject var bookmarks: BookmarkStore
    let onDismissAll: () -> Void
    var removeTitle = "移除"
    @State private var expandedFolderID: BookmarkItem.ID?

    var body: some View {
        let columns = layout.columns(items)
        // Height is bounded by rowsPerColumn. Only extra columns can scroll.
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(columns.indices, id: \.self) { index in
                    if index > 0 { Divider() }
                    BookmarkFolderColumn(
                        items: columns[index], folderID: folderID,
                        trailingBeforeItemID: index + 1 < columns.count ? columns[index + 1].first?.id : nil,
                        state: state, bookmarks: bookmarks, onDismissAll: onDismissAll,
                        expandedFolderID: $expandedFolderID,
                        removeTitle: removeTitle
                    )
                    .frame(width: BookmarkFolderLayout.columnWidth)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }
}

private struct BookmarkFolderActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12) : Color.clear)
            }
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

private struct BookmarkFolderColumn: View {
    let items: [BookmarkItem]
    let folderID: BookmarkItem.ID?
    let trailingBeforeItemID: BookmarkItem.ID?
    @ObservedObject var state: BrowserWindowState
    @ObservedObject var bookmarks: BookmarkStore
    let onDismissAll: () -> Void
    @Binding var expandedFolderID: BookmarkItem.ID?
    var removeTitle = "移除"

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, child in
                BookmarkFolderRow(
                    item: child,
                    parentFolderID: folderID,
                    nextItemID: index + 1 < items.count ? items[index + 1].id : trailingBeforeItemID,
                    state: state,
                    bookmarks: bookmarks,
                    onDismissAll: onDismissAll,
                    removeTitle: removeTitle,
                    showingChildren: Binding(
                        get: { expandedFolderID == child.id },
                        set: { open in
                            if open { expandedFolderID = child.id }
                            else if expandedFolderID == child.id { expandedFolderID = nil }
                        }
                    )
                )
            }
        }
        .padding(.horizontal, 7)
    }
}

private struct BookmarkFolderRow: View {
    let item: BookmarkItem
    let parentFolderID: BookmarkItem.ID?
    let nextItemID: BookmarkItem.ID?
    @ObservedObject var state: BrowserWindowState
    @ObservedObject var bookmarks: BookmarkStore
    let onDismissAll: () -> Void
    var removeTitle = "移除"
    @State private var favicon: NSImage?
    @Binding var showingChildren: Bool
    @State private var dropTargeted = false
    @State private var hovering = false
    @State private var pressing = false
    @State private var dropPosition: CGFloat?

    private enum DropIntent: Equatable {
        case before
        case into
        case after
    }

    private var dropIntent: DropIntent? {
        guard let dropPosition else { return nil }
        if item.isFolder, dropPosition > 0.24, dropPosition < 0.76 {
            return .into
        }
        return dropPosition >= 0.5 ? .before : .after
    }

    var body: some View {
        Button {
            if item.isFolder {
                showingChildren.toggle()
            } else {
                state.openBookmark(item)
                onDismissAll()
            }
        } label: {
            HStack(spacing: 9) {
                if item.isFolder {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(red: 0.82, green: 0.61, blue: 0.08))
                        .frame(width: 16, height: 16)
                } else {
                    BookmarkIcon(image: favicon)
                }

                Text(item.title.isEmpty ? item.url.host ?? item.url.absoluteString : item.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer()
                if item.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        dropIntent == .into
                            ? Color.accentColor.opacity(0.16)
                            : (pressing
                                ? Color.primary.opacity(0.12)
                                : (hovering ? Color.primary.opacity(0.065) : Color.clear))
                    )
            )
            .overlay {
                if dropIntent == .into {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .overlay(alignment: dropIntent == .after ? .bottom : .top) {
                if dropIntent == .before || dropIntent == .after {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .overlay {
            BookmarkNativeDragSurface(
                itemID: item.id,
                onClick: {
                    if item.isFolder {
                        showingChildren.toggle()
                    } else {
                        state.openBookmark(item)
                        onDismissAll()
                    }
                },
                onDrop: {
                    bookmarks.move(
                        $0,
                        toFolder: item.isFolder ? item.id : parentFolderID,
                        before: item.isFolder ? nil : item.id
                    )
                },
                onOpen: item.isFolder ? nil : {
                    state.openBookmark(item)
                    onDismissAll()
                },
                onEdit: {
                    onDismissAll()
                    state.editBookmark(item)
                },
                onDelete: {
                    bookmarks.remove(item.id)
                },
                onHoverOpen: item.isFolder ? { showingChildren = true } : nil,
                onHoverChange: { hovering = $0 },
                onPressChange: { pressing = $0 },
                onDropAtPosition: { draggedID, position in
                    switch intent(for: position) {
                    case .into:
                        return bookmarks.move(draggedID, toFolder: item.id, before: nil)
                    case .before:
                        return bookmarks.move(draggedID, toFolder: parentFolderID, before: item.id)
                    case .after:
                        return bookmarks.move(draggedID, toFolder: parentFolderID, before: nextItemID)
                    }
                },
                onDragPositionChange: { dropPosition = $0 },
                hoverOpenPositionPredicate: item.isFolder ? { $0 > 0.24 && $0 < 0.76 } : nil,
                removeTitle: removeTitle,
                targeted: $dropTargeted
            )
        }
        .background {
            BookmarkSubmenuAnchor(isPresented: $showingChildren, folderID: item.id,
                                  state: state, bookmarks: bookmarks, onDismissAll: onDismissAll)
        }
        .contextMenu {
            if !item.isFolder {
                Button("在新标签页打开") { state.openBookmark(item) }
            }
            Button("编辑…") {
                onDismissAll()
                state.editBookmark(item)
            }
            Divider()
            Button("移除", role: .destructive) {
                bookmarks.remove(item.id)
            }
        }
        .onAppear {
            if !item.isFolder {
                FaviconService.load(for: item.url) { favicon = $0 }
            }
        }
    }

    private func intent(for position: CGFloat) -> DropIntent {
        if item.isFolder, position > 0.24, position < 0.76 {
            return .into
        }
        return position >= 0.5 ? .before : .after
    }
}

private struct BookmarkIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 14, height: 14)
    }
}
