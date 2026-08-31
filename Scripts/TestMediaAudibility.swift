import AppKit
import WebKit

@main
enum TestMediaAudibility {
    @MainActor
    static func main() {
        _ = NSApplication.shared

        let tab = BrowserTab(isPrivate: false, startURL: URL(string: "https://example.com/")!, loadsImmediately: false)
        precondition(tab.mediaState == .none)

        // DOM 媒体可闻 → 喇叭亮起；静音/暂停 → 熄灭。
        tab.mediaAudibilityDidChange(source: "dom", audible: true)
        precondition(tab.mediaState == .playing)
        tab.mediaAudibilityDidChange(source: "dom", audible: false)
        precondition(tab.mediaState == .none)

        // DOM 与 Web Audio 两个世界是并集关系：一路静音不应熄灭另一路。
        tab.mediaAudibilityDidChange(source: "dom", audible: true)
        tab.mediaAudibilityDidChange(source: "webaudio", audible: true)
        tab.mediaAudibilityDidChange(source: "webaudio", audible: false)
        precondition(tab.mediaState == .playing)
        tab.mediaAudibilityDidChange(source: "dom", audible: false)
        precondition(tab.mediaState == .none)

        // 未知 source 按 DOM 媒体处理，消息不应造成崩溃或状态错乱。
        tab.mediaAudibilityDidChange(source: "unknown", audible: true)
        precondition(tab.mediaState == .playing)

        // 标签静音开关：点击喇叭图标切换；静音不改变“可闻”统计本身
        // （页面侧由 tabMuteScript 强制压低输出后，桥会自然回落为 none）。
        precondition(tab.isAudioMuted == false)
        tab.toggleAudioMute()
        precondition(tab.isAudioMuted == true)
        tab.toggleAudioMute()
        precondition(tab.isAudioMuted == false)

        // 静音脚本必须覆盖 DOM 媒体强制静音、Web Audio 主增益与跨帧扇出。
        let muteSource = MediaAudibilityBridge.tabMuteScript.source
        precondition(muteSource.contains("__lemonApplyTabMute"))
        precondition(muteSource.contains("HTMLMediaElement.prototype"))
        precondition(muteSource.contains("AudioNode.prototype.connect"))
        precondition(muteSource.contains("__lemonTabMute"))
        precondition(muteSource.contains("queryTabMute"))
        // 主增益注册表必须暴露给可闻性桥（“连到输出才算可闻”判定）。
        precondition(muteSource.contains("__lemonHasOutputConnection"))

        // 可闻性桥必须有自愈巡检（事件遗漏/SPA 清理两个方向都能收敛），
        // Web Audio 侧必须用输出连接过滤纯后台 running 的上下文。
        precondition(MediaAudibilityBridge.userScript.source.contains("setInterval"))
        precondition(MediaAudibilityBridge.webAudioScript.source.contains("__lemonHasOutputConnection"))
        precondition(MediaAudibilityBridge.webAudioScript.source.contains("setInterval"))

        // 导航/释放重置：新文档从静音开始；标签静音标记跨导航保留（Chromium 语义）。
        tab.resetMediaAudibility()
        precondition(tab.mediaState == .none)

        print("media-audibility-tests=passed")
    }
}
