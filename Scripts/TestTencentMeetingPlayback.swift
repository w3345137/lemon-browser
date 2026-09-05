import Foundation

@main
enum TestTencentMeetingPlayback {
    static func main() {
        precondition(
            TencentMeetingPlaybackBridge.isLivePage(
                URL(string: "https://meeting.tencent.com/live/123456")
            )
        )
        precondition(
            TencentMeetingPlaybackBridge.isLivePage(
                URL(string: "https://meeting.tencent.com/live?meeting=123456")
            )
        )
        precondition(
            !TencentMeetingPlaybackBridge.isLivePage(
                URL(string: "https://meeting.tencent.com/dm/example")
            )
        )
        precondition(
            !TencentMeetingPlaybackBridge.isLivePage(
                URL(string: "https://example.com/live/123456")
            )
        )

        let userAgent = TencentMeetingPlaybackBridge.chromeCompatibleUserAgent
        precondition(userAgent.contains("Chrome/"))
        precondition(userAgent.contains("Safari/537.36"))
        precondition(!userAgent.contains("Version/"))

        let source = TencentMeetingPlaybackBridge.userScript.source
        precondition(source.contains("meeting.tencent.com"))
        precondition(source.contains("hlsjs-mse"))
        precondition(source.contains("native-hls"))
        precondition(source.contains("waiting"))
        precondition(source.contains("stalled"))
        precondition(source.contains("pagehide"))

        for activePhase in ["play", "playing", "waiting", "stalled"] {
            precondition(TencentMeetingPlaybackBridge.keepsProcessActive(phase: activePhase))
        }
        for inactivePhase in ["ready", "pause", "ended", "error", "pagehide", "unknown"] {
            precondition(!TencentMeetingPlaybackBridge.keepsProcessActive(phase: inactivePhase))
        }

        print("tencent-meeting-playback-tests=passed")
    }
}
