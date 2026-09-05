import AppKit
import SwiftUI

struct WindowChrome: NSViewRepresentable {
    var isPrivate: Bool
    var onWindowKey: (() -> Void)?
    var onWindowClose: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            apply(to: view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView.window, coordinator: context.coordinator)
    }

    private func apply(to window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        coordinator.onWindowKey = onWindowKey
        coordinator.onWindowClose = onWindowClose
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // SwiftUI 的默认 WindowGroup 会在 macOS 26 自动附加一个空工具栏，
        // 即使隐藏标题仍会留下居中的玻璃胶囊，并把自定义标签栏向下挤压。
        // Lemon 自己绘制完整浏览器 chrome，因此只保留原生标题栏按钮。
        window.toolbar = nil
        // 保留 .titled，NSWindow 才能正常成为 key window；移除后窗口会按
        // borderless 处理，地址栏和 WKWebView 内的输入框都无法取得键盘焦点。
        window.isMovableByWindowBackground = false
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.titled)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.styleMask.insert(.resizable)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior.insert(.fullScreenPrimary)

        // 交给标准 titled NSWindow 的主题框架计算系统圆角。固定 14 pt 会在
        // Retina 屏幕上显得过大，也无法随系统窗口外观调整。
        var roundedView: NSView? = window.contentView
        for _ in 0..<3 {
            roundedView?.layer?.cornerRadius = 0
            roundedView?.layer?.masksToBounds = false
            roundedView = roundedView?.superview
        }

        // 使用 AppKit 标准窗口按钮。系统会自动处理 key/inactive 灰态、
        // 悬浮图形、按压反馈、禁用状态、Option 修饰键及辅助功能。
        for buttonType in [NSWindow.ButtonType.closeButton,
                           .miniaturizeButton,
                           .zoomButton] {
            if let button = window.standardWindowButton(buttonType) {
                button.isHidden = false
                button.alphaValue = 1
            }
        }
        coordinator.installTrafficLights(on: window)

        window.backgroundColor = isPrivate
            ? NSColor(calibratedWhite: 0.11, alpha: 1)
            : NSColor.windowBackgroundColor
        window.minSize = NSSize(width: 780, height: 520)
        window.tabbingMode = .disallowed
        coordinator.install(on: window)
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        var onWindowKey: (() -> Void)?
        var onWindowClose: (() -> Void)?
        private var observationTokens: [NSObjectProtocol] = []
        private var isSnapping = false

        deinit {
            observationTokens.forEach(NotificationCenter.default.removeObserver)
        }

        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            observationTokens.forEach(NotificationCenter.default.removeObserver)
            observationTokens.removeAll()
            self.window = window

            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observationTokens.append(
                    NotificationCenter.default.addObserver(
                        forName: name,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.removeSystemTilingMarginsIfNeeded()
                            if let window = self?.window {
                                self?.installTrafficLights(on: window)
                            }
                        }
                    }
                )
            }

            observationTokens.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.onWindowKey?()
                    }
                }
            )

            observationTokens.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.onWindowClose?()
                    }
                }
            )

            DispatchQueue.main.async { [weak self] in
                self?.removeSystemTilingMarginsIfNeeded()
            }
        }

        func installTrafficLights(on window: NSWindow) {
            WindowTrafficLightManager.shared.install(on: window)
        }

        /// macOS 的“填充”窗口默认会在可用屏幕四周留下约 8 pt 平铺边距。
        /// 当窗口四边都符合该特征时，将它贴合 visibleFrame；半屏和自由缩放不受影响。
        private func removeSystemTilingMarginsIfNeeded() {
            guard !isSnapping,
                  let window,
                  !window.styleMask.contains(.fullScreen),
                  let screen = window.screen else { return }

            let frame = window.frame
            let target = screen.visibleFrame
            let gaps = [
                frame.minX - target.minX,
                target.maxX - frame.maxX,
                frame.minY - target.minY,
                target.maxY - frame.maxY
            ]
            guard gaps.allSatisfy({ $0 >= 4 && $0 <= 24 }) else { return }

            isSnapping = true
            window.setFrame(target, display: true, animate: false)
            isSnapping = false
        }
    }
}

/// 全局窗口按钮管理器不依赖 SwiftUI representable 的短暂生命周期。
/// AppKit 可能在窗口样式或全屏切换后重建标准按钮，所以每次都从
/// `NSWindow` 取得当前实例，并调整它们原有的标题栏容器。这样既保留
/// 系统失焦、悬浮和按压状态，也不会出现旧按钮留在自建宿主中的竞态。
@MainActor
private final class WindowTrafficLightManager {
    static let shared = WindowTrafficLightManager()

    private var observationTokens: [NSObjectProtocol] = []

    private init() {
        observationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow else { return }
                    self?.setButtonsHidden(true, on: window)
                }
            }
        )

        for name in [NSWindow.willExitFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            observationTokens.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self, let window = note.object as? NSWindow else { return }
                        self.restore(on: window)
                    }
                }
            )
        }
    }

    func install(on window: NSWindow) {
        let buttons = standardButtons(in: window)
        guard buttons.count == 3,
              let titlebarView = buttons[0].superview,
              let titlebarContainer = titlebarView.superview,
              let frameView = titlebarContainer.superview else { return }

        let toolbarHeight = SafariChrome.toolbarHeight
        titlebarContainer.autoresizingMask = [.width, .minYMargin]
        titlebarContainer.frame = NSRect(
            x: 0,
            y: max(0, frameView.bounds.height - toolbarHeight),
            width: frameView.bounds.width,
            height: toolbarHeight
        )
        titlebarView.autoresizingMask = [.width, .height]
        titlebarView.frame = titlebarContainer.bounds

        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            button.frame = NSRect(
                x: SafariChrome.trafficLightLeading
                    + CGFloat(index) * SafariChrome.trafficLightCenterSpacing,
                y: floor((toolbarHeight - size.height) / 2),
                width: size.width,
                height: size.height
            )
            button.isHidden = window.styleMask.contains(.fullScreen)
            button.alphaValue = 1
            button.needsDisplay = true
        }
    }

    private func restore(on window: NSWindow) {
        for delay in [0.1, 0.35, 0.8, 1.5, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window,
                      !window.styleMask.contains(.fullScreen) else { return }
                self.install(on: window)
            }
        }
    }

    private func standardButtons(in window: NSWindow) -> [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
    }

    private func setButtonsHidden(_ hidden: Bool, on window: NSWindow) {
        standardButtons(in: window).forEach { $0.isHidden = hidden }
    }
}

/// 只让顶部工具行的空白区域承担窗口拖动，按钮和输入控件仍正常接收点击。
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableBackgroundView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DraggableBackgroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

enum SafariChrome {
    static let toolbarHeight: CGFloat = 40
    // 与 BrowserWindowView 中的占位区域共同定义窗口按钮安全区。
    // 14/34/54 pt 是 20 pt 中心间距下的原生按钮 frame 起点；
    // 14×16 pt 的系统按钮因此在 40 pt 标签栏内精确居中。
    static let trafficLightLeading: CGFloat = 14
    static let trafficLightCenterSpacing: CGFloat = 20
    static let trafficLightReservedWidth: CGFloat = 57
    static let addressRowHeight: CGFloat = 40
    static let bookmarkBarHeight: CGFloat = 40
    static let addressHeight: CGFloat = 30
    static let tabMinWidth: CGFloat = 118
    static let tabMaxWidth: CGFloat = 220
    // 原生集合的布局、点击与悬浮区域独立；底部曲线在单元内部绘制。
    static let tabSpacing: CGFloat = 0
    // 固定标签保持可辨识间距，图标按实际单元宽度居中。
    static let pinnedTabWidth: CGFloat = 42
}
