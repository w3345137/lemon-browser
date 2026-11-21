import AppKit
import WebKit

@main enum TestInputMethod {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WebKitFactory.inputMethodCompatibilityScript)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        let html = #"""
        <script>
        window.down = 0; window.up = 0;
        // Intentionally unsafe page-world handlers, including window capture.
        window.addEventListener('keydown', e => { if(e.key === 'Enter') window.down++; }, true);
        window.addEventListener('keyup', e => { if(e.key === 'Enter') window.up++; }, true);
        window.editor = (tag = 'input') => {
          document.body.innerHTML = '';
          const el = document.createElement(tag);
          if(tag === 'input') el.type = 'search';
          if(tag === 'div') el.contentEditable = 'true';
          document.body.append(el); el.focus(); down = 0; up = 0; return el;
        };
        window.compose = (el, kind) => el.dispatchEvent(new CompositionEvent(kind, {bubbles:true,composed:true,data:'fixture'}));
        window.key = (el, kind = 'keydown', init = {}) => {
          const event = new KeyboardEvent(kind, {key:'Enter',code:'Enter',bubbles:true,composed:true,cancelable:true,...init});
          el.dispatchEvent(event); return event.defaultPrevented;
        };
        </script><body></body>
        """#
        view.loadHTMLString(html, baseURL: URL(string: "https://ime-fixture.invalid/"))
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof window.editor === 'function' && !!document.body")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        func check(_ label: String, _ script: String) async throws {
            let result = try await view.evaluateJavaScript("(() => { \(script) })()")
            precondition(result as? Bool == true, label)
        }
        for tag in ["input", "textarea", "div"] {
            try await check("normal Enter remains available: \(tag)", """
            const el = editor('\(tag)'); key(el); key(el,'keyup'); return down===1 && up===1;
            """)
            try await check("WebKit end-before-keydown, second Enter immediately works: \(tag)", """
            const el = editor('\(tag)'); compose(el,'compositionstart'); compose(el,'compositionend');
            const canceled = key(el); key(el,'keyup');
            if(!canceled || down!==0 || up!==0) return false;
            key(el); key(el,'keyup'); return down===1 && up===1;
            """)
            try await check("spec-order composition is not canceled and next Enter works: \(tag)", """
            const el=editor('\(tag)'); compose(el,'compositionstart');
            const canceled=key(el,'keydown',{isComposing:true,keyCode:229});
            compose(el,'compositionend'); key(el,'keyup');
            if(canceled || down!==0 || up!==0) return false;
            key(el); key(el,'keyup'); return down===1 && up===1;
            """)
        }
        try await check("legacy 229 without composition events", """
        const el=editor(); key(el,'keydown',{keyCode:229}); key(el,'keyup'); return down===0 && up===0;
        """)
        try await check("Ctrl/Cmd/Shift/Alt shortcuts preserved", """
        for(const modifier of ['ctrlKey','metaKey','shiftKey','altKey']) {
          const el=editor(); compose(el,'compositionend');
          key(el,'keydown',{[modifier]:true}); key(el,'keyup',{[modifier]:true});
          if(down!==1 || up!==1) return false;
        } return true;
        """)
        try await check("composition does not leak to a different input", """
        const first=editor(); compose(first,'compositionstart'); compose(first,'compositionend');
        const second=document.createElement('input'); document.body.append(second);
        key(second); return down===1;
        """)
        _ = try await view.evaluateJavaScript("window.delayed=editor(); compose(delayed,'compositionend')")
        try await Task.sleep(nanoseconds: 100_000_000)
        try await check("ordinary Enter after composition grace period", "key(delayed); return down===1;")
        try await check("nested contenteditable target", """
        const root=editor('div'); const child=document.createElement('span'); root.append(child);
        compose(child,'compositionstart'); compose(child,'compositionend'); key(child); return down===0;
        """)
        try await check("shadow DOM input", """
        const host=editor('div'); host.contentEditable='false';
        const el=document.createElement('input'); host.attachShadow({mode:'open'}).append(el);
        compose(el,'compositionstart'); compose(el,'compositionend'); key(el); return down===0;
        """)
        // Exercise WebKit's native marked-text protocol as well as DOM fixtures.
        // This does not change the user's selected system input source.
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        window.makeFirstResponder(view)
        _ = try await view.evaluateJavaScript("window.nativeEditor=editor(); nativeEditor.focus()")
        try await Task.sleep(nanoseconds: 50_000_000)
        guard let client = window.firstResponder as? NSTextInputClient else {
            preconditionFailure("WebKit native text input client missing")
        }
        client.setMarkedText("chatgpt", selectedRange: NSRange(location: 7, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        client.insertText("chatgpt", replacementRange: NSRange(location: NSNotFound, length: 0))
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.firstResponder?.keyDown(with: enter)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await check("native marked-text commit keeps letters without submitting", "return nativeEditor.value==='chatgpt' && down===0;")
        let again = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.firstResponder?.keyDown(with: again)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await check("second native Enter submits", "return down===1;")
        view.stopLoading()
        print("ime-webkit-isolated-world-page-capture-ordering-keyup-normal-enter-shortcuts-editors=passed")
    }
}
