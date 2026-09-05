import Foundation

@main
enum TestWangfeiPlayback {
    static func main() {
        let source = WangfeiPlaybackBridge.userScript.source
        precondition(source.contains("wangfei\\.la"))
        precondition(source.contains("/vod-play-"))
        precondition(source.contains("RAW_ANTI_BOT_"))
        precondition(source.contains(".m3u8"))
        precondition(source.contains("jinyingyun"))
        precondition(source.contains("hd\\.ijycnd\\.com"))
        precondition(source.contains("/index.m3u8"))
        precondition(source.contains("provider === 'xigua'"))
        precondition(source.contains("svip\\.xgplay\\d+\\.com"))
        precondition(source.contains("data-lemon-wangfei-provider-player"))
        precondition(source.contains("autoplay; fullscreen; picture-in-picture"))
        precondition(source.contains("provider !== 'ruyi'"))
        precondition(source.contains("svip\\.ryplay\\d+\\.com"))
        precondition(source.contains("正在切换备用线路"))
        precondition(source.contains("location.replace(alternate.href)"))
        precondition(source.contains("data-lemon-wangfei-player"))
        precondition(source.contains("video.controls = true"))
        precondition(source.contains("正在加载视频"))
        precondition(WangfeiPlaybackBridge.userScript.isForMainFrameOnly)
        print("wangfei-playback-tests=passed")
    }
}
