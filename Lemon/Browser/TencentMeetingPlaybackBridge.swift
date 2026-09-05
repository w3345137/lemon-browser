import Foundation
import WebKit

/// 腾讯会议直播在 Safari / WKWebView 中会优先使用系统原生 HLS，页面无法控制
/// 分片重试和缓冲策略；同一页面在 Chrome 身份下会选择它自带的 HLS.js + MSE。
/// 这里只对精确的直播路径启用兼容身份，避免影响邀请页、登录页和其他网站。
enum TencentMeetingPlaybackBridge {
    static let handlerName = "lemonTencentMeetingLive"

    static func isLivePage(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "meeting.tencent.com"
        else { return false }

        let path = url.path.lowercased()
        return path == "/live" || path.hasPrefix("/live/")
    }

    /// 使用本机 Chrome 的主版本可减少站点风控误判；未安装 Chrome 时使用稳定的
    /// Chromium UA 形态。实际媒体能力仍由 WKWebView 的 MediaSource 探测决定。
    static let chromeCompatibleUserAgent: String = {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
        let installedVersion = Bundle(url: chromeURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = installedVersion.flatMap(normalizedChromeVersion) ?? "140.0.0.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/\(version) Safari/537.36"
    }()

    private static func normalizedChromeVersion(_ value: String) -> String? {
        let parts = value.split(separator: ".")
        guard let major = parts.first,
              !major.isEmpty,
              major.allSatisfy(\.isNumber)
        else { return nil }
        return "\(major).0.0.0"
    }

    /// 页面只负责上报播放阶段和实际技术栈。腾讯页面已有完整恢复状态机：
    /// - HLS.js 分片/清晰度列表重试与 MSE 媒体错误恢复；
    /// - waiting 5 秒后重新获取直播地址；
    /// - error 后重建播放器。
    /// Lemon 不再并行重载 video，避免打断 HLS.js 自己的指数退避。
    static let userScript = WKUserScript(
        source: #"""
        (() => {
          if (location.protocol !== 'https:' ||
              location.hostname.toLowerCase() !== 'meeting.tencent.com' ||
              !/^\/live(?:\/|$)/i.test(location.pathname)) return;
          if (window.__lemonTencentMeetingLiveInstalled) return;
          window.__lemonTencentMeetingLiveInstalled = true;

          let lastPhase = '';
          let lastMode = '';
          let waitingSince = 0;
          const send = (phase, media) => {
            let mode = 'unknown';
            try {
              const source = String(media && (media.currentSrc || media.src) || '');
              if (source.startsWith('blob:') && window.MediaSource) mode = 'hlsjs-mse';
              else if (/\.m3u8(?:$|\?)/i.test(source)) mode = 'native-hls';
              else if (window.Hls && window.Hls.isSupported && window.Hls.isSupported()) mode = 'hlsjs-ready';
            } catch (_) {}
            if (phase === lastPhase && mode === lastMode) return;
            lastPhase = phase;
            lastMode = mode;
            try {
              window.webkit.messageHandlers.lemonTencentMeetingLive.postMessage({
                phase,
                mode,
                waitingMilliseconds: waitingSince ? Date.now() - waitingSince : 0
              });
            } catch (_) {}
          };

          const onMediaEvent = (event) => {
            const media = event.target;
            if (!(media instanceof HTMLMediaElement)) return;
            switch (event.type) {
              case 'waiting':
              case 'stalled':
                if (!waitingSince) waitingSince = Date.now();
                send(event.type, media);
                break;
              case 'playing':
                waitingSince = 0;
                send('playing', media);
                break;
              case 'play':
                send('play', media);
                break;
              case 'pause':
              case 'ended':
              case 'error':
                waitingSince = 0;
                send(event.type, media);
                break;
            }
          };
          for (const type of ['play', 'playing', 'waiting', 'stalled', 'pause', 'ended', 'error']) {
            document.addEventListener(type, onMediaEvent, true);
          }
          addEventListener('pagehide', () => send('pagehide', document.querySelector('video,audio')));

          // TCPlayer/HLS.js 异步加载后再上报一次真实技术栈，便于本地诊断确认
          // Chrome 兼容路径已经命中；该探测不修改播放器实例。
          let probes = 0;
          const probe = setInterval(() => {
            const media = document.querySelector('video,audio');
            if (media) send(media.paused ? 'ready' : 'playing', media);
            probes += 1;
            if (probes >= 20 || (media && String(media.currentSrc || '').startsWith('blob:'))) {
              clearInterval(probe);
            }
          }, 500);
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .page
    )

    static func keepsProcessActive(phase: String) -> Bool {
        switch phase {
        case "play", "playing", "waiting", "stalled":
            return true
        default:
            return false
        }
    }
}
