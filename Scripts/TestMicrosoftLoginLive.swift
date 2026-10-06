import AppKit
import WebKit

/// 显式联网验收，不加入离线测试集。不读取Cookie/字段值，不提交登录。
/// 可用LEMON_LOGIN_TEST_URL传入本次授权页，程序仅输出域名和就绪统计。
@main enum TestMicrosoftLoginLive {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let previousFront = NSWorkspace.shared.frontmostApplication
        let supplied = ProcessInfo.processInfo.environment["LEMON_LOGIN_TEST_URL"] ?? ""
        let raw = supplied.isEmpty ? "https://partner.microsoft.com/dashboard" : supplied
        guard let url = URL(string: raw), url.scheme == "https",
              MicrosoftLoginResourcePolicy.applies(to: url) || url.host == "partner.microsoft.com" else {
            fatalError("Only approved Microsoft login entrypoints may be tested")
        }
        let tab = BrowserTab(isPrivate: true, startURL: url, loadsImmediately: false)
        let view = tab.ensureWebView()
        view.configuration.userContentController.addUserScript(WKUserScript(source: #"""
        window.__lemonDiagnosticErrors=[];
        window.addEventListener('error',e=>{
          if(e.target && (e.target.src||e.target.href)){
            try{let u=new URL(e.target.src||e.target.href);__lemonDiagnosticErrors.push({resource:u.hostname+u.pathname});}catch(_){}
          }else{__lemonDiagnosticErrors.push({type:e.error?.name||'error',line:e.lineno,message:String(e.message||'').replace(/https?:\/\/[^ '"\]]+/g,'[url]').slice(0,180)});}
        },true);
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1000,height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        if ProcessInfo.processInfo.environment["LEMON_TEST_SHOW_WINDOW"] == "1" {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderBack(nil)
        }
        tab.load(url)
        defer {
            tab.tearDown(); window.orderOut(nil)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousFront?.activate(options: [])
            }
        }
        let deadline = Date().addingTimeInterval(70)
        var visible = false
        var stableChecks = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            visible = (try? await view.evaluateJavaScript("""
            [...document.querySelectorAll('input:not([type=hidden])')].some(el=>{
              const r=el.getBoundingClientRect(),s=getComputedStyle(el);
              if(r.width<=0||r.height<=0||r.right<=0||r.bottom<=0||r.left>=innerWidth||r.top>=innerHeight)return false;
              for(let parent=el;parent;parent=parent.parentElement){
                const style=getComputedStyle(parent);
                if(style.visibility==='hidden'||style.display==='none'||Number(style.opacity)<0.1)return false;
              }
              return true;
            })
            """)) as? Bool == true
            stableChecks = visible ? stableChecks + 1 : 0
            if stableChecks >= 2 { break }
        }
        print("microsoft-live host=\(view.url?.host ?? "nil") loading=\(view.isLoading) visibleLoginInput=\(visible)")
        let resourceHosts = (try? await view.evaluateJavaScript("[...new Set(performance.getEntriesByType('resource').map(r=>new URL(r.name).hostname))].filter(h=>h.endsWith('.msauth.net')||h.endsWith('.msftauth.net')).sort().join(',')")) as? String
        print("microsoft-live cdn-hosts=\(resourceHosts ?? "unavailable")")
        if !visible {
            let diagnostic = try? await view.evaluateJavaScript("""
            JSON.stringify({hidden:document.hidden,ready:document.readyState,viewport:[innerWidth,innerHeight],errors:window.__lemonDiagnosticErrors,
              scripts:[...document.scripts].filter(s=>s.src).map(s=>{let u=new URL(s.src);return u.hostname+u.pathname;}),
              textLength:document.body?.innerText.length,
              inputStyles:[...document.querySelectorAll('input:not([type=hidden])')].slice(0,3).map(el=>{
                let a=[];for(let p=el;p;p=p.parentElement){let s=getComputedStyle(p),r=p.getBoundingClientRect();a.push([p.tagName,s.display,s.visibility,s.opacity,Math.round(r.width),Math.round(r.height)]);}return a;
              }),hosts:[...new Set(performance.getEntriesByType('resource').map(r=>new URL(r.name).hostname))]})
            """)
            print("read-only diagnostic=\(diagnostic ?? "unavailable")")
        }
        fflush(stdout)
        let snapshot = try await view.takeSnapshot(configuration: nil)
        if let data = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("microsoft-login-live.png"))
        }
        guard visible && stableChecks >= 2 else {
            throw NSError(domain: "LemonLoginLiveTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Login form did not become stably visible within 70 seconds"])
        }
        print("microsoft-login-live-tests=passed")
    }
}
