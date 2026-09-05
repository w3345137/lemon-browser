import Foundation
import WebKit

/// 标签音频指示的事件驱动桥。公开 API（requestMediaPlaybackState）只能轮询
/// “有媒体元素在播放”，无法区分静音播放；Chromium 的喇叭图标绑定的是
/// “标签正在出声”（IsCurrentlyAudible）。这里用捕获阶段的媒体事件 +
/// volumechange 在页面侧实时计算“可闻”状态，静音播放不报图标。
enum MediaAudibilityBridge {
    static let handlerName = "lemonMedia"

    /// 隔离世界脚本：监听 DOM 媒体元素的播放与音量事件。媒体事件不冒泡，
    /// 但捕获阶段监听可以收到（捕获路径 document → target 与是否冒泡无关）。
    /// 必须显式指定 .defaultClient——三参 WKUserScript 构造器实际默认进
    /// 页面世界，会被 tabMuteScript 的 muted 补丁带偏（get 到的是页面侧值），
    /// 也暴露给页面脚本的 prototype 篡改。隔离世界里 muted/volume 是原生
    /// 存取器，读到的是真实生效值。
    static let userScript = WKUserScript(
        source: #"""
        (() => {
          if (window.__lemonMediaAudibilityInstalled) return;
          window.__lemonMediaAudibilityInstalled = true;
          const documentID = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
          window.__lemonAudibilityDocumentID = documentID;

          const audibleMedia = new Set();
          let lastReported = false;
          const eventLog = [];

          // 诊断钩子（不影响行为）：排查假可闻/漏报时读取。
          window.__lemonDomMediaDbg = () => ({
            lastReported,
            audibleCount: audibleMedia.size,
            // 卡在集合里的元素即使已从 DOM 移除也能看到（SPA 移除元素诊断）。
            audibleElements: Array.from(audibleMedia).map((el) => ({
              tag: el.tagName.toLowerCase(),
              paused: el.paused,
              muted: el.muted,
              volume: el.volume,
              connected: el.isConnected
            })),
            events: eventLog.slice(-20),
            elements: Array.from(document.querySelectorAll('audio,video')).map((el) => ({
              tag: el.tagName.toLowerCase(),
              paused: el.paused,
              ended: el.ended,
              muted: el.muted,
              volume: el.volume,
              connected: el.isConnected,
              readyState: el.readyState,
              src: (el.currentSrc || el.src || '').slice(0, 80)
            }))
          });

          const send = (audible) => {
            if (audible === lastReported) return;
            lastReported = audible;
            try { window.webkit.messageHandlers.lemonMedia.postMessage({ audible, source: 'dom', documentID }); } catch (_) {}
          };
          const isAudible = (el) => !el.paused && !el.ended && !el.error && el.readyState >= 2 && !el.muted && el.volume > 0;
          const track = (target, type) => {
            if (!(target instanceof HTMLMediaElement)) return;
            eventLog.push([type, target.paused, target.muted, target.volume, target.isConnected]);
            if (eventLog.length > 40) eventLog.shift();
            if (isAudible(target)) audibleMedia.add(target);
            else audibleMedia.delete(target);
            send(audibleMedia.size > 0);
          };
          for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'waiting', 'error', 'loadeddata']) {
            document.addEventListener(type, (event) => track(event.target, type), true);
          }
          window.addEventListener('pagehide', () => send(false));
          window.addEventListener('pageshow', () => {
            lastReported = false;
            document.querySelectorAll('audio,video').forEach(el => track(el, 'pageshow'));
          });

          // 自愈巡检：媒体事件可能遗漏——元素被移出 DOM 后其事件不再经过
          // document 捕获路径（SPA 页面常见清理方式），或状态被页面非常规修改。
          // 每 2 秒按元素真实状态重算一次，两个方向的错误都能自愈。
          setInterval(() => {
            try {
              const now = new Set();
              for (const el of audibleMedia) { if (isAudible(el)) now.add(el); }
              document.querySelectorAll('audio,video').forEach((el) => {
                if (isAudible(el)) now.add(el);
              });
              audibleMedia.clear();
              now.forEach((el) => audibleMedia.add(el));
              send(audibleMedia.size > 0);
            } catch (_) {}
          }, 2000);
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .defaultClient
    )

    /// 页面世界脚本：Web Audio 的 AudioContext 没有 DOM 事件，也不在隔离世界
    /// 可见，只能在页面世界包装构造器拿到实例后监听 statechange。
    /// 可闻性由主输出分析器采样；纯后台 running 的上下文不点亮喇叭。
    static let webAudioScript = WKUserScript(
        source: #"""
        (() => {
          if (window.__lemonWebAudioAudibilityInstalled) return;
          window.__lemonWebAudioAudibilityInstalled = true;
          const documentID = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
          window.__lemonAudibilityDocumentID = documentID;

          const runningContexts = new Set();
          const allContexts = new Set();
          let lastReported = false;
          // 诊断钩子：列出页面创建过的 AudioContext 及其实时状态。
          window.__lemonWebAudioDbg = () => ({
            lastReported,
            contexts: Array.from(allContexts).map((c) => c.state)
          });
          // 读取输出分析器，排除预热上下文、已停止音源和零增益输出。
          const isOutputAudible = (ctx) => {
            if (ctx.state !== 'running') return false;
            try {
              if (typeof window.__lemonHasOutputConnection === 'function') {
                return window.__lemonHasOutputConnection(ctx);
              }
            } catch (_) {}
            return false;
          };
          const recompute = () => {
            runningContexts.clear();
            allContexts.forEach((c) => { if (isOutputAudible(c)) runningContexts.add(c); });
            send(runningContexts.size > 0);
          };
          const send = (audible) => {
            if (audible === lastReported) return;
            lastReported = audible;
            try { window.webkit.messageHandlers.lemonMedia.postMessage({ audible, source: 'webaudio', documentID }); } catch (_) {}
          };

          const wrap = (Original) => {
            if (typeof Original !== 'function') return Original;
            const handler = {
              construct(target, args) {
                const context = Reflect.construct(target, args);
                try {
                  allContexts.add(context);
                  context.addEventListener('statechange', recompute);
                  recompute();
                } catch (_) {}
                return context;
              }
            };
            return new Proxy(Original, handler);
          };

          // 音源停止和接线变化不触发 context statechange，定期采样输出。
          setInterval(() => { try { recompute(); } catch (_) {} }, 250);
          window.addEventListener('pagehide', () => send(false));
          window.addEventListener('pageshow', recompute);

          try {
            const Wrapped = wrap(window.AudioContext);
            if (Wrapped !== window.AudioContext) window.AudioContext = Wrapped;
            if (typeof window.webkitAudioContext === 'function') {
              window.webkitAudioContext = window.AudioContext;
            }
          } catch (_) {}
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .page
    )

    /// 标签静音（对齐 Chromium 点击喇叭图标静音该标签）。WKWebView 没有公开的
    /// 单页静音 API，因此在页面世界强制：
    /// - DOM 媒体：包装 muted 存取器，页面自己的 muted 状态与“标签强制静音”分离
    ///   （页面 get 到的是自己设的值，实际输出 = tabMuted || pageMuted）；
    ///   play() 与 MutationObserver 保证静音期间新建/自动起播的元素也被压住。
    /// - Web Audio：包装 AudioNode.connect，把通向 destination 的连接改道经过
    ///   每个 AudioContext 的主增益节点，静音时 gain=0，播放进度不受影响。
    /// 开关由 Swift 注入 __lemonApplyTabMute(bool)，主帧调用后经 postMessage
    /// 扇出到全部子帧；每个帧加载时也会主动查询当前标签的静音状态。
    static let tabMuteScript = WKUserScript(
        source: #"""
        (() => {
          if (window.__lemonTabMuteInstalled) return;
          window.__lemonTabMuteInstalled = true;

          let tabMuted = false;
          const pageMuted = new WeakMap();
          const masterGains = new Set();

          // --- DOM 媒体：分离“页面想要的 muted”和“实际生效的 muted” ---
          try {
            const proto = HTMLMediaElement.prototype;
            const desc = Object.getOwnPropertyDescriptor(proto, 'muted');
            if (desc && desc.get && desc.set) {
              Object.defineProperty(proto, 'muted', {
                configurable: true,
                get() {
                  const v = pageMuted.get(this);
                  return v === undefined ? desc.get.call(this) : v;
                },
                set(v) {
                  pageMuted.set(this, !!v);
                  desc.set.call(this, tabMuted ? true : !!v);
                }
              });
              const applyTo = (el) => {
                if (!(el instanceof HTMLMediaElement)) return;
                // 首次触碰时先记录页面侧真实值，再按需强制静音；
                // 之后页面的 get 一律读这里，不会看到我们压下去的 true。
                if (!pageMuted.has(el)) pageMuted.set(el, desc.get.call(el));
                const want = tabMuted ? true : pageMuted.get(el);
                try { if (desc.get.call(el) !== want) desc.set.call(el, want); } catch (_) {}
              };
              window.__lemonTabMuteApplyTo = applyTo;
              const origPlay = proto.play;
              proto.play = function() { applyTo(this); return origPlay.call(this); };
              new MutationObserver((records) => {
                if (!tabMuted) return;
                for (const r of records) {
                  r.addedNodes.forEach((n) => {
                    if (n instanceof HTMLMediaElement) applyTo(n);
                    else if (n.querySelectorAll) n.querySelectorAll('audio,video').forEach(applyTo);
                  });
                }
              }).observe(document, { subtree: true, childList: true });
            }
          } catch (_) {}

          // --- Web Audio：destination 连接改道主增益 ---
          try {
            const origConnect = AudioNode.prototype.connect;
            const gainsByContext = new WeakMap();
            // 供可闻性桥查询：该上下文是否确有节点接到输出。
            const meters = new WeakMap();
            window.__lemonHasOutputConnection = (ctx) => {
              const meter = meters.get(ctx);
              if (!meter || tabMuted || ctx.state !== 'running') return false;
              meter.node.getFloatTimeDomainData(meter.samples);
              if (meter.samples.some(value => Math.abs(value) > 0.0001)) meter.lastSignal = performance.now();
              // 短暂停顿保持指示，避免对话间隙和分片边界频繁闪烁。
              return performance.now() - meter.lastSignal < 700;
            };
            const masterFor = (ctx) => {
              let g = gainsByContext.get(ctx);
              if (!g) {
                g = ctx.createGain();
                g.gain.value = tabMuted ? 0 : 1;
                const analyser = ctx.createAnalyser();
                analyser.fftSize = 2048;
                origConnect.call(g, analyser);
                origConnect.call(analyser, ctx.destination);
                meters.set(ctx, {node: analyser, samples: new Float32Array(analyser.fftSize), lastSignal: -Infinity});
                gainsByContext.set(ctx, g);
                masterGains.add(g);
              }
              return g;
            };
            AudioNode.prototype.connect = function(dest, ...rest) {
              try {
                if (dest instanceof AudioNode && this.context &&
                    !(this.context instanceof OfflineAudioContext) &&
                    dest === this.context.destination) {
                  return origConnect.call(this, masterFor(this.context), ...rest);
                }
              } catch (_) {}
              return origConnect.call(this, dest, ...rest);
            };
            const origDisconnect = AudioNode.prototype.disconnect;
            AudioNode.prototype.disconnect = function(dest, ...rest) {
              if (dest === this.context.destination && gainsByContext.has(this.context)) {
                return origDisconnect.call(this, gainsByContext.get(this.context), ...rest);
              }
              return origDisconnect.apply(this, arguments);
            };
          } catch (_) {}

          // --- 开关入口：本地生效 + 扇出到子帧 ---
          window.__lemonApplyTabMute = (muted) => {
            tabMuted = !!muted;
            try {
              if (window.__lemonTabMuteApplyTo) {
                document.querySelectorAll('audio,video').forEach(window.__lemonTabMuteApplyTo);
              }
            } catch (_) {}
            masterGains.forEach((g) => {
              try { g.gain.setTargetAtTime(tabMuted ? 0 : 1, g.context.currentTime, 0.015); }
              catch (_) { try { g.gain.value = tabMuted ? 0 : 1; } catch (_) {} }
            });
            try {
              document.querySelectorAll('iframe').forEach((f) => {
                try { f.contentWindow.postMessage({ __lemonTabMute: tabMuted }, '*'); } catch (_) {}
              });
            } catch (_) {}
          };
          window.addEventListener('message', (event) => {
            const d = event.data;
            if (d && typeof d === 'object' && typeof d.__lemonTabMute === 'boolean') {
              window.__lemonApplyTabMute(d.__lemonTabMute);
            }
          });

          // 新文档主动查询当前标签的静音状态（Swift 按 frameInfo 回注）。
          try { window.webkit.messageHandlers.lemonMedia.postMessage({ type: 'queryTabMute' }); } catch (_) {}
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .page
    )
}
