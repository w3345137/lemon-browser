import WebKit

/// 网飞啦的旧 MacCMS 播放壳只渲染黑色容器，再通过脚本变量转交第三方播放器。
/// 对播放页读取站点自身已提供的 HLS 地址，直接使用 WebKit 原生 video 播放。
enum WangfeiPlaybackBridge {
    static let userScript = WKUserScript(
        source: #"""
        (() => {
          if (!/^(?:www\.)?wangfei\.la$/i.test(location.hostname) ||
              !/^\/vod-play-/i.test(location.pathname) ||
              window.__lemonWangfeiPlaybackInstalled) return;
          window.__lemonWangfeiPlaybackInstalled = true;

          const decodeSource = (raw) => {
            if (typeof raw !== 'string' || !raw) return '';
            try {
              return raw.startsWith('RAW_ANTI_BOT_')
                ? atob(raw.slice('RAW_ANTI_BOT_'.length))
                : raw;
            } catch (_) { return ''; }
          };

          const resolveHLS = () => {
            const source = decodeSource(window.player_aaaa && window.player_aaaa.url);
            if (/^https:\/\/.+\.m3u8(?:$|[?#])/i.test(source)) return source;

            // 金鹰云线路先给出播放页地址；其播放页固定从同一路径下加载
            // index.m3u8。只接受已核验的 HTTPS 提供方，避免推导任意 URL。
            const provider = String(window.player_aaaa && window.player_aaaa.from || '');
            if (provider === 'jinyingyun' &&
                /^https:\/\/hd\.ijycnd\.com\/play\/[a-z0-9_-]+\/?$/i.test(source)) {
              return source.replace(/\/$/, '') + '/index.m3u8';
            }
            return '';
          };

          const resolveEmbeddedPlayer = () => {
            const source = decodeSource(window.player_aaaa && window.player_aaaa.url);
            const provider = String(window.player_aaaa && window.player_aaaa.from || '');
            if (provider === 'xigua' &&
                /^https:\/\/svip\.xgplay\d+\.com\/play\/[a-z0-9_-]+\/?$/i.test(source)) {
              return source;
            }
            return '';
          };

          const showMessage = (host, text) => {
            const message = document.createElement('div');
            message.textContent = text;
            message.style.cssText = 'display:grid;position:absolute;inset:0;place-items:center;padding:24px;color:#ddd;background:#000;font:15px -apple-system,BlinkMacSystemFont,sans-serif;text-align:center';
            host.style.position = 'relative';
            host.replaceChildren(message);
          };

          const switchFromRegionBlockedProvider = (host) => {
            const provider = String(window.player_aaaa && window.player_aaaa.from || '');
            const source = decodeSource(window.player_aaaa && window.player_aaaa.url);
            if (provider !== 'ruyi' ||
                !/^https:\/\/svip\.ryplay\d+\.com\/share\/[a-f0-9]+\/?$/i.test(source)) return false;

            const current = location.pathname.match(/^\/vod-play-id-(\d+)-sid-(\d+)-nid-(\d+)\.html$/i);
            if (!current) return false;
            const storageKey = `lemon-wangfei-tried-${current[1]}-${current[3]}`;
            const tried = new Set((sessionStorage.getItem(storageKey) || '').split(',').filter(Boolean));
            tried.add(current[2]);

            const alternate = [...document.querySelectorAll('a[href*="/vod-play-id-"]')]
              .map(link => {
                try { return new URL(link.getAttribute('href'), location.href); } catch (_) { return null; }
              })
              .find(url => {
                if (!url || url.origin !== location.origin) return false;
                const match = url.pathname.match(/^\/vod-play-id-(\d+)-sid-(\d+)-nid-(\d+)\.html$/i);
                return match && match[1] === current[1] && match[3] === current[3] && !tried.has(match[2]);
              });

            if (!alternate) {
              showMessage(host, '当前线路限制所在地区访问，且没有可用的备用线路');
              return true;
            }
            sessionStorage.setItem(storageKey, [...tried].join(','));
            showMessage(host, '当前线路限制所在地区访问，正在切换备用线路…');
            setTimeout(() => location.replace(alternate.href), 120);
            return true;
          };

          let attempts = 0;
          const mountNativePlayer = () => {
            attempts += 1;
            const source = resolveHLS();
            const embeddedPlayer = resolveEmbeddedPlayer();
            const host = document.querySelector('.player-box-main');
            if (!host) {
              if (attempts < 60) setTimeout(mountNativePlayer, 100);
              return;
            }
            if (switchFromRegionBlockedProvider(host)) return;
            if (embeddedPlayer) {
              if (host.querySelector('iframe[data-lemon-wangfei-provider-player]')) return;
              const frame = document.createElement('iframe');
              frame.setAttribute('data-lemon-wangfei-provider-player', '');
              frame.src = embeddedPlayer;
              frame.allow = 'autoplay; fullscreen; picture-in-picture';
              frame.allowFullscreen = true;
              frame.referrerPolicy = 'strict-origin-when-cross-origin';
              frame.style.cssText = 'display:block;width:100%;height:100%;min-height:360px;border:0;background:#000';
              host.replaceChildren(frame);
              return;
            }
            if (!source) {
              if (attempts < 60) setTimeout(mountNativePlayer, 100);
              return;
            }
            if (host.querySelector('video[data-lemon-wangfei-player]')) return;

            const video = document.createElement('video');
            video.setAttribute('data-lemon-wangfei-player', '');
            video.controls = true;
            video.autoplay = true;
            video.playsInline = true;
            video.preload = 'auto';
            video.style.cssText = 'display:block;width:100%;height:100%;min-height:360px;background:#000;object-fit:contain';

            const message = document.createElement('div');
            message.textContent = '正在加载视频…';
            message.style.cssText = 'display:grid;position:absolute;inset:0;place-items:center;color:#bbb;background:#000;font:15px -apple-system,BlinkMacSystemFont,sans-serif;pointer-events:none';
            video.addEventListener('error', () => {
              message.textContent = '视频加载失败，请刷新页面后重试';
              message.style.color = '#fff';
              message.style.display = 'grid';
            });
            video.addEventListener('loadeddata', () => { message.style.display = 'none'; });

            host.style.position = 'relative';
            host.replaceChildren(video, message);
            video.src = source;
            video.load();
            video.play().catch(() => {});
          };
          mountNativePlayer();
        })();
        """#,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .page
    )
}
