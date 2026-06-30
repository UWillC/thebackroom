/**
 * Feedback Widget - SNOW
 * Vanilla JS, zero deps, self-contained.
 * Loads on netdevops-tools / netdevops / thebackroom landings.
 * Posts to notify-hub /webhook/feedback (AWS API Gateway).
 *
 * Triggers: exit-intent, 45s timer, manual floating button.
 * Cooldown: 7 days post-dismiss via localStorage.
 */
(function () {
  'use strict';

  // --- Config ---
  var WEBHOOK_URL = 'https://3w7nw22j1d.execute-api.us-east-1.amazonaws.com/webhook/feedback';
  var COOLDOWN_DAYS = 7;
  var TIMER_TRIGGER_MS = 45000;
  var SCROLL_THRESHOLD = 0.5;
  var STORAGE_KEY = 'snow_feedback_widget_v1';

  // --- Context detection ---
  var host = window.location.host;
  var pageUrl = window.location.href;
  var pageStartTime = Date.now();
  var maxScroll = 0;
  var hasShown = false;
  var isOpen = false;

  // Per-site copy variant
  var isToolsApp = host.indexOf('netdevops-tools') !== -1;
  var promptText = isToolsApp
    ? "What stopped you from trying the tools today?"
    : "What is missing here that would make you say yes?";

  // --- Cooldown check ---
  function isInCooldown() {
    try {
      var data = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null');
      if (!data || !data.dismissedAt) return false;
      var elapsed = Date.now() - data.dismissedAt;
      return elapsed < (COOLDOWN_DAYS * 86400000);
    } catch (e) { return false; }
  }

  function markDismissed() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ dismissedAt: Date.now() }));
    } catch (e) {}
  }

  if (isInCooldown()) {
    return; // Skip entire widget for 7 days post-dismiss
  }

  // --- Dark mode detection (multi-source: html data-theme, body classes, OS pref) ---
  function isDarkMode() {
    var html = document.documentElement;
    if (html.getAttribute('data-theme') === 'dark') return true;
    if (html.classList.contains('dark') || html.classList.contains('dark-mode')) return true;
    var body = document.body;
    if (body) {
      if (body.getAttribute('data-theme') === 'dark') return true;
      if (body.classList.contains('dark') || body.classList.contains('dark-mode')) return true;
    }
    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) return true;
    return false;
  }

  // --- CSS injection (self-contained, no external stylesheet) ---
  function injectCSS() {
    if (document.getElementById('snow-fbw-style')) return;
    var style = document.createElement('style');
    style.id = 'snow-fbw-style';
    style.textContent = [
      '.snow-fbw-btn {',
      '  position: fixed; bottom: 20px; right: 20px; z-index: 99998;',
      '  width: 48px; height: 48px; border-radius: 50%; border: none;',
      '  background: #2563eb; color: white; font-size: 22px; font-weight: 700;',
      '  cursor: pointer; box-shadow: 0 4px 12px rgba(0,0,0,0.25);',
      '  transition: transform 0.15s ease, box-shadow 0.15s ease;',
      '  font-family: system-ui, -apple-system, sans-serif;',
      '}',
      '.snow-fbw-btn:hover { transform: scale(1.05); box-shadow: 0 6px 16px rgba(0,0,0,0.3); }',
      '.snow-fbw-overlay {',
      '  position: fixed; inset: 0; background: rgba(0,0,0,0.55); z-index: 99999;',
      '  display: flex; align-items: center; justify-content: center; padding: 16px;',
      '  font-family: system-ui, -apple-system, sans-serif;',
      '  animation: snow-fbw-fade 0.18s ease-out;',
      '}',
      '@keyframes snow-fbw-fade { from { opacity: 0; } to { opacity: 1; } }',
      // Light mode (default)
      '.snow-fbw-modal {',
      '  background: white; color: #111; border-radius: 12px; padding: 24px;',
      '  max-width: 440px; width: 100%; box-shadow: 0 20px 60px rgba(0,0,0,0.4);',
      '  max-height: 90vh; overflow-y: auto;',
      '}',
      '.snow-fbw-title { font-size: 18px; font-weight: 600; margin: 0 0 8px; }',
      '.snow-fbw-prompt { font-size: 15px; margin: 0 0 14px; line-height: 1.4; }',
      '.snow-fbw-textarea {',
      '  width: 100%; box-sizing: border-box; min-height: 80px; padding: 10px;',
      '  font-family: inherit; font-size: 14px; border: 1px solid #ccc;',
      '  border-radius: 6px; resize: vertical; background: white; color: #111;',
      '}',
      '.snow-fbw-incentive { font-size: 13px; color: #666; margin: 14px 0 6px; }',
      '.snow-fbw-input {',
      '  width: 100%; box-sizing: border-box; padding: 10px;',
      '  font-family: inherit; font-size: 14px; border: 1px solid #ccc;',
      '  border-radius: 6px; background: white; color: #111;',
      '}',
      '.snow-fbw-honey { position: absolute; left: -9999px; opacity: 0; height: 0; width: 0; }',
      '.snow-fbw-actions { display: flex; gap: 10px; margin-top: 18px; justify-content: flex-end; }',
      '.snow-fbw-btn-primary {',
      '  background: #2563eb; color: white; border: none; padding: 10px 18px;',
      '  border-radius: 6px; font-size: 14px; font-weight: 600; cursor: pointer;',
      '}',
      '.snow-fbw-btn-primary:hover { background: #1d4ed8; }',
      '.snow-fbw-btn-primary:disabled { opacity: 0.5; cursor: not-allowed; }',
      '.snow-fbw-btn-secondary {',
      '  background: transparent; color: #666; border: 1px solid #ccc;',
      '  padding: 10px 16px; border-radius: 6px; font-size: 14px; cursor: pointer;',
      '}',
      '.snow-fbw-thanks { text-align: center; padding: 12px 0; }',
      '.snow-fbw-thanks-icon { font-size: 32px; }',
      '.snow-fbw-thanks-msg { margin: 10px 0 0; font-size: 15px; }',
      // Dark mode override (via class on overlay - set by JS detection)
      '.snow-fbw-overlay.snow-fbw-dark .snow-fbw-modal { background: #1e1e1e; color: #f4f4f4; }',
      '.snow-fbw-overlay.snow-fbw-dark .snow-fbw-textarea,',
      '.snow-fbw-overlay.snow-fbw-dark .snow-fbw-input {',
      '  background: #2a2a2a; color: #f4f4f4; border-color: #444;',
      '}',
      '.snow-fbw-overlay.snow-fbw-dark .snow-fbw-incentive { color: #aaa; }',
      '.snow-fbw-overlay.snow-fbw-dark .snow-fbw-btn-secondary { color: #aaa; border-color: #555; }'
    ].join('\n');
    document.head.appendChild(style);
  }

  // --- Modal DOM ---
  function buildModal() {
    var overlay = document.createElement('div');
    overlay.className = 'snow-fbw-overlay' + (isDarkMode() ? ' snow-fbw-dark' : '');
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-labelledby', 'snow-fbw-title');

    var modal = document.createElement('div');
    modal.className = 'snow-fbw-modal';

    modal.innerHTML = [
      '<h3 id="snow-fbw-title" class="snow-fbw-title">Quick question, 30 seconds?</h3>',
      '<p class="snow-fbw-prompt">' + promptText + '</p>',
      '<textarea class="snow-fbw-textarea" id="snow-fbw-text" placeholder="Type your thoughts..." maxlength="2000"></textarea>',
      '<p class="snow-fbw-incentive">Leave email if you would like a personal response within 24h. (optional)</p>',
      '<input class="snow-fbw-input" id="snow-fbw-email" type="email" placeholder="you@example.com" maxlength="200">',
      '<input class="snow-fbw-honey" id="snow-fbw-honey" type="text" tabindex="-1" autocomplete="off" name="website">',
      '<div class="snow-fbw-actions">',
      '  <button class="snow-fbw-btn-secondary" id="snow-fbw-cancel">No thanks</button>',
      '  <button class="snow-fbw-btn-primary" id="snow-fbw-send">Send</button>',
      '</div>'
    ].join('\n');

    overlay.appendChild(modal);
    return { overlay: overlay, modal: modal };
  }

  // --- Submission ---
  function submit(text, email) {
    var payload = {
      page_url: pageUrl,
      page_host: host,
      feedback_text: text,
      user_email: email || '',
      timestamp: new Date().toISOString(),
      scroll_depth: Math.round(maxScroll * 100) / 100,
      time_on_page_sec: Math.round((Date.now() - pageStartTime) / 1000),
      referrer: document.referrer || '',
      user_agent: navigator.userAgent.slice(0, 200),
      widget_version: '1.0.0'
    };

    // Use text/plain to avoid CORS preflight + keep simple POST.
    return fetch(WEBHOOK_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: JSON.stringify(payload),
      keepalive: true
    });
  }

  // --- Show / hide ---
  function showModal() {
    if (hasShown || isOpen) return;
    hasShown = true;
    isOpen = true;
    injectCSS();

    var built = buildModal();
    var overlay = built.overlay;
    var modal = built.modal;
    document.body.appendChild(overlay);

    var textarea = modal.querySelector('#snow-fbw-text');
    var emailInput = modal.querySelector('#snow-fbw-email');
    var honeyInput = modal.querySelector('#snow-fbw-honey');
    var sendBtn = modal.querySelector('#snow-fbw-send');
    var cancelBtn = modal.querySelector('#snow-fbw-cancel');

    setTimeout(function () { textarea.focus(); }, 100);

    function close() {
      isOpen = false;
      markDismissed();
      if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
    }

    cancelBtn.addEventListener('click', close);

    overlay.addEventListener('click', function (e) {
      if (e.target === overlay) close();
    });

    document.addEventListener('keydown', function escHandler(e) {
      if (e.key === 'Escape' && isOpen) {
        close();
        document.removeEventListener('keydown', escHandler);
      }
    });

    sendBtn.addEventListener('click', function () {
      // Honeypot check - bots fill hidden field
      if (honeyInput.value) {
        close();
        return;
      }

      var text = textarea.value.trim();
      if (!text) {
        textarea.focus();
        textarea.style.borderColor = '#dc2626';
        return;
      }

      sendBtn.disabled = true;
      sendBtn.textContent = 'Sending...';

      submit(text, emailInput.value.trim()).then(function () {
        modal.innerHTML = [
          '<div class="snow-fbw-thanks">',
          '  <div class="snow-fbw-thanks-icon">✓</div>',
          '  <p class="snow-fbw-thanks-msg">Thanks. Read every response.</p>',
          '</div>'
        ].join('\n');
        markDismissed();
        setTimeout(function () {
          isOpen = false;
          if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
        }, 2000);
      }).catch(function () {
        sendBtn.disabled = false;
        sendBtn.textContent = 'Send';
        textarea.style.borderColor = '#dc2626';
      });
    });
  }

  // --- Floating manual button ---
  function injectManualButton() {
    if (document.getElementById('snow-fbw-btn')) return;
    var btn = document.createElement('button');
    btn.id = 'snow-fbw-btn';
    btn.className = 'snow-fbw-btn';
    btn.setAttribute('aria-label', 'Send feedback');
    btn.setAttribute('title', 'Send feedback');
    btn.textContent = '?';
    btn.addEventListener('click', showModal);
    document.body.appendChild(btn);
  }

  // --- Trigger: 45s timer ---
  setTimeout(function () {
    if (!hasShown) showModal();
  }, TIMER_TRIGGER_MS);

  // --- Trigger: exit-intent (mouse leaves viewport top) ---
  function exitIntentHandler(e) {
    if (e.clientY <= 0 && !hasShown && (Date.now() - pageStartTime) > 10000) {
      // Min 10s on page before exit-intent fires (avoid bounce-back UX issues)
      showModal();
    }
  }
  document.addEventListener('mouseout', exitIntentHandler);

  // --- Scroll tracking (for context, not trigger) ---
  function scrollHandler() {
    var docHeight = Math.max(
      document.body.scrollHeight, document.documentElement.scrollHeight,
      document.body.offsetHeight, document.documentElement.offsetHeight
    ) - window.innerHeight;
    if (docHeight <= 0) return;
    var pct = Math.min(1, window.scrollY / docHeight);
    if (pct > maxScroll) maxScroll = pct;
  }
  window.addEventListener('scroll', scrollHandler, { passive: true });

  // --- Init: inject manual button after DOM ready ---
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      injectCSS();
      injectManualButton();
    });
  } else {
    injectCSS();
    injectManualButton();
  }
})();
