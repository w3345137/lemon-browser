import Foundation
import WebKit

enum CredentialBridge {
    static let handlerName = "lemonCredentials"

    /// 捕获与填充共用的 DOM 辅助函数。填充逻辑和捕获逻辑都要识别
    /// 密码框/账号框，必须保持同一份实现，避免两处启发式漂移。
    private static let sharedDOMHelpersSource = #"""
    const valueDescriptor = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    const valueSetter = valueDescriptor && valueDescriptor.set;
    const valueGetter = valueDescriptor && valueDescriptor.get;
    const nativeValue = (input) => {
      try { return valueGetter ? valueGetter.call(input) : input.value; } catch (_) { return input.value; }
    };
    const setValue = (input, value) => {
      if (valueSetter) valueSetter.call(input, value);
      else input.value = value;
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const isVisible = (input) => {
      if (!input || input.disabled) return false;
      if (input.type === 'hidden') return false;
      const style = window.getComputedStyle(input);
      if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
      const rect = input.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const seenPasswords = new WeakSet();
    const isOneTimeCode = (input) => {
      if (!input) return false;
      const autocomplete = (input.autocomplete || '').toLowerCase();
      if (autocomplete.split(/\s+/).includes('one-time-code')) return true;
      const labels = Array.from(input.labels || []).map(label => label.textContent || '');
      const labelledBy = (input.getAttribute('aria-labelledby') || '').split(/\s+/)
        .map(id => document.getElementById(id)?.textContent || '');
      const hints = [input.name, input.id, input.placeholder, input.getAttribute('aria-label'), ...labels, ...labelledBy]
        .filter(Boolean).join(' ').toLowerCase();
      if (/captcha|otp|one.?time|verification.?code|verify.?code|validate.?code|valid.?code|check.?code|sms.?code|security.?code|dynamic.?password|验证码|校验码|短信码|动态密码|动态口令|一次性密码/.test(hints)) return true;
      // Some IAM forms name their real password "authcode". Require positive
      // password semantics before overriding this ambiguous field name; explicit
      // OTP signals above always win, even for type=password.
      const purpose = [input.placeholder, input.getAttribute('aria-label'),
        input.getAttribute('data-i18n-placeholder'), ...labels, ...labelledBy].filter(Boolean).join(' ').toLowerCase();
      if (input.type === 'password' && (autocomplete.split(/\s+/).includes('current-password') || /password|密码/.test(purpose))) return false;
      return /auth.?code/.test(hints);
    };
    const markPassword = (input) => {
      if (input && input.type === 'password') seenPasswords.add(input);
    };
    const isPassword = (input) => {
      if (!input || isOneTimeCode(input)) return false;
      markPassword(input);
      if (input.type === 'password' || seenPasswords.has(input)) return true;
      const autocomplete = (input.autocomplete || '').toLowerCase();
      return autocomplete.includes('current-password') || autocomplete.includes('new-password');
    };
    // 用户名字段打分：autocomplete 语义最强，type=email/tel 次之，
    // name/id/placeholder 关键词再次，裸文本框仅作最后兜底。
    const usernameScore = (input, passwordInput) => {
      if (!input || input === passwordInput || isPassword(input) || isOneTimeCode(input)) return 0;
      const type = (input.type || 'text').toLowerCase();
      if (!['text', 'email', 'tel', 'url', 'search', 'number', ''].includes(type)) return 0;
      const autocomplete = (input.autocomplete || '').toLowerCase();
      let score = 0;
      if (/username|email|tel/.test(autocomplete)) score = Math.max(score, 100);
      if (type === 'email' || type === 'tel') score = Math.max(score, 80);
      const haystack = [input.name, input.id, input.placeholder, input.getAttribute('aria-label')]
        .filter(Boolean).join(' ').toLowerCase();
      if (/user|email|account|login|phone|mobile|账号|用户|邮箱|手机|工号/.test(haystack)) score = Math.max(score, 60);
      if (score === 0 && (autocomplete === '' || autocomplete === 'on')) score = 10;
      return score;
    };
    const collectInputs = (root) => {
      const found = [];
      const visit = (node) => {
        if (!node) return;
        if (node.querySelectorAll) {
          node.querySelectorAll('input').forEach((input) => found.push(input));
          node.querySelectorAll('*').forEach((element) => {
            if (element.shadowRoot) visit(element.shadowRoot);
          });
        }
      };
      visit(root);
      return Array.from(new Set(found)).filter(isVisible);
    };
    // 只认密码框之前、得分最高的候选；并列时取离密码框最近的一个。
    const usernameFor = (passwordInput, root) => {
      const inputs = collectInputs(root);
      const before = inputs.filter((input) =>
        (input.compareDocumentPosition(passwordInput) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0
      );
      const pool = (before.length ? before : inputs).reverse();
      let best = null;
      let bestScore = 0;
      for (const input of pool) {
        const score = usernameScore(input, passwordInput);
        if (score > bestScore) {
          best = input;
          bestScore = score;
        }
      }
      return best;
    };
    """#

    /// 填充主体：在当前文档和同源 iframe 里找密码框并填入。
    /// 依赖 sharedDOMHelpersSource 中的辅助函数。
    private static let fillBodySource = #"""
    const fillRoot = (root) => {
      const passwordInput = collectInputs(root).find(isPassword);
      if (!passwordInput) return false;
      const usernameInput = usernameFor(passwordInput, passwordInput.form || root);
      if (typeof automatic !== 'undefined' && automatic) {
        if (passwordInput.autocomplete === 'new-password' || !usernameInput ||
            nativeValue(usernameInput) || nativeValue(passwordInput)) return false;
      }
      // 360 中存在“仅密码”凭据。空账号代表不要改动账号框，不能把用户
      // 已经输入的账号清空。
      if (usernameInput && username.length > 0) setValue(usernameInput, username);
      setValue(passwordInput, password);
      if (typeof automatic === 'undefined' || !automatic) passwordInput.focus();
      return true;
    };
    if (fillRoot(document)) return true;
    for (const frame of Array.from(document.querySelectorAll('iframe'))) {
      try {
        if (frame.contentDocument && fillRoot(frame.contentDocument)) return true;
      } catch (_) {}
    }
    return false;
    """#

    /// 自包含的填充函数表达式：(username, password) => Bool。
    /// 用于主框架的独立求值兜底，不依赖捕获脚本是否已安装。
    static let fillFunctionSource =
        "((username, password, automatic = false) => {\n" + sharedDOMHelpersSource + "\n" + fillBodySource + "\n})"

    static let automaticFillReadinessScript = "(() => {\n" + sharedDOMHelpersSource + #"""
    const ready = root => collectInputs(root).some(p => {
      if (!isPassword(p) || p.autocomplete === 'new-password' || nativeValue(p)) return false;
      const u = usernameFor(p, p.form || root);
      return !!u && !nativeValue(u);
    });
    if (ready(document)) return true;
    for (const frame of document.querySelectorAll('iframe')) {
      try { if (frame.contentDocument && ready(frame.contentDocument)) return true; } catch (_) {}
    }
    return false;
    })()
    """#

    /// 主框架填充调度脚本：先尝试同步直填（捕获脚本已安装时走快路径，
    /// 未安装时 eval 自包含逻辑），失败后向同站跨域 iframe 定向
    /// postMessage 扇出（targetOrigin 精确到 frame origin，绝不广播 *）。
    static func fillDispatcherScript(payloadJSON: String) -> String {
        // 顶层是裸字符串，必须带 fragmentsAllowed；否则 JSONSerialization 直接
        // 抛 NSException（Swift try? 接不住）。真机测试抓到过这个崩溃。
        let encodedFillSource = (try? String(
            data: JSONSerialization.data(withJSONObject: fillFunctionSource, options: [.fragmentsAllowed]),
            encoding: .utf8
        )) ?? "null"
        return """
        (() => {
          const payload = \(payloadJSON);
          let fill = null;
          if (typeof window.__lemonPerformFill === 'function') fill = window.__lemonPerformFill;
          if (!fill) { try { fill = eval(\(encodedFillSource)); } catch (_) {} }
          if (fill) {
            let ok = false;
            try { ok = !!fill(payload.username, payload.password, payload.automatic === true); } catch (_) {}
            if (ok) return { direct: true, targeted: [] };
          }
          if (payload.automatic === true) return { direct: false, targeted: [] };
          const message = {
            __lemonFill: true,
            token: payload.token,
            username: payload.username,
            password: payload.password
          };
          try { window.postMessage(message, location.origin); } catch (_) {}
          const multiPartTLDs = ['com.cn', 'net.cn', 'org.cn', 'gov.cn', 'com.hk', 'co.uk'];
          const registrable = (host) => {
            const parts = (host || '').toLowerCase().split('.').filter(Boolean);
            if (parts.length < 2) return (host || '').toLowerCase();
            const lastTwo = parts.slice(-2).join('.');
            if (multiPartTLDs.includes(lastTwo) && parts.length >= 3) return parts.slice(-3).join('.');
            return lastTwo;
          };
          const pageDomain = registrable(location.hostname);
          const targeted = [];
          for (const frame of Array.from(document.querySelectorAll('iframe'))) {
            try {
              if (!frame.src) continue;
              const origin = new URL(frame.src, location.href).origin;
              if (origin === 'null' || origin === location.origin) continue;
              if (registrable(new URL(origin).hostname) !== pageDomain) continue;
              if (frame.contentWindow) {
                frame.contentWindow.postMessage(message, origin);
                targeted.push(origin);
              }
            } catch (_) {}
          }
          return { direct: false, targeted };
        })()
        """
    }

    static let captureScript = WKUserScript(
        source: #"(() => {"# + "\n" + sharedDOMHelpersSource + #"""

          const send = (payload) => {
            try { window.webkit.messageHandlers.lemonCredentials.postMessage(payload); } catch (_) {}
          };

          let lastSent = '';
          // DOM-ready is not form-ready: IAM reveals its iframe login controls
          // after asynchronous initialization. Notify only on a ready transition.
          let wasReady = false, readinessTimer = null;
          const checkReadiness = () => {
            readinessTimer = null;
            const ready = collectInputs(document).some(p => {
              if (!isPassword(p) || p.autocomplete === 'new-password' || nativeValue(p)) return false;
              const u = usernameFor(p, p.form || document);
              return !!u && !nativeValue(u);
            });
            if (ready && !wasReady) send({type: 'formReady', origin: location.origin});
            wasReady = ready;
          };
          const scheduleReadiness = () => {
            if (readinessTimer === null) readinessTimer = setTimeout(checkReadiness, 100);
          };
          new MutationObserver(scheduleReadiness).observe(document.documentElement,
            {subtree: true, childList: true, attributes: true,
             attributeFilter: ['class','style','hidden','type','autocomplete','disabled']});
          document.addEventListener('input', scheduleReadiness, true);
          window.addEventListener('pageshow', scheduleReadiness);
          scheduleReadiness();
          window.__lemonHasCredentialChallenge = () => collectInputs(document)
            .some(input => isPassword(input) || isOneTimeCode(input));
          const capture = (root, reason) => {
            const scope = root || document;
            const inputs = collectInputs(scope);
            const passwordInput = inputs.find((input) => isPassword(input) && nativeValue(input));
            if (!passwordInput) return;
            const usernameInput = usernameFor(passwordInput, passwordInput.form || document);
            const username = usernameInput ? nativeValue(usernameInput) : '';
            const password = nativeValue(passwordInput);
            if (!password) return;
            const key = location.origin + '\n' + username + '\n' + password;
            if (key === lastSent) return;
            lastSent = key;
            send({
              type: 'submit',
              origin: location.origin,
              username,
              password,
              reason: reason || 'unknown'
            });
          };

          const looksLikeSubmit = (target) => {
            if (!target || !(target instanceof Element)) return false;
            const element = target.closest('button, input[type="submit"], input[type="image"], [role="button"], a');
            if (!element) return false;
            const type = (element.getAttribute('type') || '').toLowerCase();
            if (type === 'reset') return false;
            const text = [
              element.innerText,
              element.value,
              element.getAttribute('aria-label'),
              element.className
            ].filter(Boolean).join(' ').toLowerCase();
            if (/captcha|send.?code|resend|验证码|校验码|获取短信|发送短信|换一张|刷新验证|忘记密码|显示密码/.test(text)) return false;
            if (/login|signin|sign-in|submit|continue|next|登|登陆|登录|提交|确定|下一步/.test(text)) return true;
            return element.matches('input[type="submit"], input[type="image"]')
              || (element.tagName === 'BUTTON' && !!element.closest('form') && (type === '' || type === 'submit'));
          };

          document.addEventListener('submit', (event) => capture(event.target || document, 'submit'), true);
          document.addEventListener('click', (event) => {
            if (!looksLikeSubmit(event.target)) return;
            const root = event.target.closest('form') || document;
            setTimeout(() => capture(root, 'click'), 0);
            setTimeout(() => capture(document, 'click-delayed'), 280);
          }, true);
          document.addEventListener('keydown', (event) => {
            if (event.key !== 'Enter') return;
            if (!(event.target instanceof HTMLInputElement)) return;
            setTimeout(() => capture(event.target.form || document, 'enter'), 0);
          }, true);

          // 填充入口：主框架可同步直调；跨域 iframe 由主框架 postMessage 到达。
          // 回执经 messageHandlers 返回，App 侧据此判断填充是否真正落地。
          const performFill = (username, password, automatic = false) => {
        """# + fillBodySource + #"""
          };
          window.__lemonPerformFill = performFill;

          window.addEventListener('message', (event) => {
            const data = event.data;
            if (!data || data.__lemonFill !== true) return;
            if (typeof data.username !== 'string' || typeof data.password !== 'string') return;
            if (typeof data.token !== 'string') return;
            let ok = false;
            try { ok = !!performFill(data.username, data.password); } catch (_) {}
            send({ type: 'fillResult', token: data.token, ok, origin: location.origin });
          });
        })();
        """#,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )
}
