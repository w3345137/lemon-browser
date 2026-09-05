import AppKit
import WebKit

@main
struct TestInspectorLive {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 480), configuration: config)
        InspectorController.configure(view)
        precondition(!view.isInspectable, "No external inspection fallback")
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Lemon Inspector 回归"
        window.contentView = view
        window.orderFront(nil)
        view.loadHTMLString("<h1>Inspector fixture</h1><script>window.lemonFixture = 42;</script>", baseURL: URL(string: "https://example.test"))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        precondition(InspectorController.invoke("show", on: view))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let inspector = view.perform(NSSelectorFromString("_inspector"))!.takeUnretainedValue() as! NSObject
        precondition(inspector.value(forKey: "isVisible") as? Bool == true, "Inspector must be visible")
        precondition(InspectorController.invoke("showConsole", on: view))
        precondition(InspectorController.invoke("detach", on: view))
        precondition(InspectorController.invoke("close", on: view))
        window.orderOut(nil)
        print("inspector-live-tests=passed")
    }
}
