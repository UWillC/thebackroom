// URL hash values are attacker-controlled (ROADMAP #21, @ciso 5-8). Nothing from the hash is ever
// rendered: the page shows fixed texts only, chosen by an allowlisted error code.
const MAX_HASH_LENGTH = 8192;

// Decode one hash value; null on a malformed % sequence (decodeURIComponent throws URIError).
function safeDecode(value) {
    try {
        return decodeURIComponent(String(value).replace(/\+/g, ' '));
    } catch (e) {
        return null;
    }
}

// Parse a URL hash ("#a=1&b=2" or "a=1&b=2"). Returns { params, malformed }.
// malformed = true when the hash is too long or any key/value cannot be decoded.
function parseHashParams(hash) {
    const raw = String(hash || '').replace(/^#/, '');
    const params = Object.create(null);
    if (raw.length > MAX_HASH_LENGTH) {
        return { params, malformed: true };
    }
    let malformed = false;
    raw.split('&').forEach(part => {
        if (!part) return;
        const eq = part.indexOf('=');
        const key = safeDecode(eq === -1 ? part : part.slice(0, eq));
        const value = safeDecode(eq === -1 ? '' : part.slice(eq + 1));
        if (key === null || value === null) {
            malformed = true;
            return;
        }
        if (key && !Object.prototype.hasOwnProperty.call(params, key)) {
            params[key] = value;
        }
    });
    return { params, malformed };
}

// Decode a base64url segment to a string; null if invalid.
function base64UrlDecode(segment) {
    try {
        const b64 = segment.replace(/-/g, '+').replace(/_/g, '/');
        const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
        return atob(padded);
    } catch (e) {
        return null;
    }
}

// Shape check only: three base64url segments, JSON payload with a string `sub` and a future `exp`.
// The signature cannot be checked here (no secret in the browser); the page shows success, it does
// not grant anything. A junk value like "#access_token=x" fails this check.
function looksLikeValidAccessToken(token, nowSeconds) {
    if (typeof token !== 'string' || token.length > MAX_HASH_LENGTH) return false;
    if (!/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) return false;
    const json = base64UrlDecode(token.split('.')[1]);
    if (json === null) return false;
    let payload;
    try {
        payload = JSON.parse(json);
    } catch (e) {
        return false;
    }
    if (!payload || typeof payload !== 'object') return false;
    if (typeof payload.sub !== 'string' || !payload.sub) return false;
    if (typeof payload.exp !== 'number' || !(payload.exp > nowSeconds)) return false;
    return true;
}

// Decide what to render from the parsed hash: { view: 'success' | 'error' | 'default', errorCode }.
// errorCode is always a key of errorMessages.
function classify(parsed, nowSeconds) {
    const params = parsed.params;
    if (parsed.malformed) {
        return { view: 'error', errorCode: 'invalid_request' };
    }
    if (params.access_token !== undefined) {
        return looksLikeValidAccessToken(params.access_token, nowSeconds)
            ? { view: 'success', errorCode: null }
            : { view: 'error', errorCode: 'invalid_request' };
    }
    if (params.error || params.error_code) {
        const rawCode = params.error_code || params.error;
        const errorCode = Object.prototype.hasOwnProperty.call(errorMessages, rawCode) ? rawCode : 'default';
        return { view: 'error', errorCode };
    }
    return { view: 'default', errorCode: null };
}

// Escape text before it goes into an innerHTML template
function escapeHtml(s) {
    return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

// Error messages mapping
const errorMessages = {
    'otp_expired': {
        title: 'Link Expired',
        description: 'This magic link has expired. Links are valid for 1 hour.',
        action: 'Ask your AI assistant to send a new magic link.'
    },
    'access_denied': {
        title: 'Access Denied',
        description: 'Authentication was denied.',
        action: 'Try requesting a new magic link.'
    },
    'invalid_request': {
        title: 'Invalid Request',
        description: 'The authentication request was malformed.',
        action: 'Try requesting a new magic link.'
    },
    'default': {
        title: 'Authentication Error',
        description: 'Something went wrong during authentication.',
        action: 'Try requesting a new magic link from your AI assistant.'
    }
};

// Render success content
function renderSuccess() {
    const terminal = document.getElementById('terminal');
    const content = document.getElementById('content');
    const statusBox = document.getElementById('status-box');

    content.innerHTML = `
        <p class="line"><span class="prompt">$</span> verify --magic-link</p>
        <p class="line"><span class="dim">Validating token...</span></p>
        <p class="line"><span class="dim">Linking profile to auth...</span></p>
        <p class="line"><span class="dim">Establishing secure session...</span></p>
        <p class="line">&nbsp;</p>
        <p class="line"><span class="checkmark">[OK]</span> <span class="success">AUTHENTICATION COMPLETE</span></p>
        <p class="line">Your identity has been verified.</p>
        <p class="line"><span class="prompt">$</span> <span class="cursor"></span></p>
    `;

    statusBox.innerHTML = `
        <p><span class="prompt">// NEXT STEP:</span></p>
        <p>Return to your <span class="highlight">AI Assistant</span> and continue.</p>
        <p class="dim" style="margin-top: 0.5rem; font-size: 0.8rem;">Your session is now active. You can close this tab.</p>
    `;
}

// Render error content (errorCode = allowlisted key of errorMessages; texts are fixed)
function renderError(errorCode) {
    const terminal = document.getElementById('terminal');
    const content = document.getElementById('content');
    const statusBox = document.getElementById('status-box');
    const title = document.getElementById('title');

    const code = Object.prototype.hasOwnProperty.call(errorMessages, errorCode) ? errorCode : 'default';
    const errorInfo = errorMessages[code];
    const errorDescription = escapeHtml(errorInfo.description);

    // Add error class
    terminal.classList.add('error');
    statusBox.classList.add('error');
    title.classList.remove('glow');
    title.classList.add('glow-red');

    content.innerHTML = `
        <p class="line"><span class="prompt-error">$</span> verify --magic-link</p>
        <p class="line"><span class="dim">Validating token...</span></p>
        <p class="line"><span class="dim">Checking authentication...</span></p>
        <p class="line">&nbsp;</p>
        <p class="line"><span class="checkmark">[ERR]</span> <span class="error-text">${errorInfo.title.toUpperCase()}</span></p>
        <p class="line">${errorDescription}</p>
        <p class="line"><span class="error-code">error_code: ${escapeHtml(code)}</span></p>
        <p class="line"><span class="prompt-error">$</span> <span class="cursor"></span></p>
    `;

    statusBox.innerHTML = `
        <p><span class="prompt-error">// WHAT TO DO:</span></p>
        <div class="action-hint">
            <p>${errorInfo.action}</p>
        </div>
        <p class="dim" style="margin-top: 1rem; font-size: 0.8rem;">Say to your assistant: <span class="highlight">"Send me a new magic link"</span></p>
    `;
}

// Render loading/default state
function renderDefault() {
    const content = document.getElementById('content');
    const statusBox = document.getElementById('status-box');

    content.innerHTML = `
        <p class="line"><span class="prompt">$</span> auth --status</p>
        <p class="line"><span class="dim">Checking authentication state...</span></p>
        <p class="line">&nbsp;</p>
        <p class="line">No active authentication request.</p>
        <p class="line"><span class="prompt">$</span> <span class="cursor"></span></p>
    `;

    statusBox.innerHTML = `
        <p><span class="prompt">// INFO:</span></p>
        <p>This page handles authentication callbacks.</p>
        <p class="dim" style="margin-top: 0.5rem; font-size: 0.8rem;">Use your AI assistant to request a magic link.</p>
    `;
}

// Main
function main() {
    const parsed = parseHashParams(window.location.hash);

    // Strip tokens / error text from the address bar and history as soon as they are read.
    if (window.location.hash) {
        try {
            history.replaceState(null, '', window.location.pathname + window.location.search);
        } catch (e) {
            // ignore: rendering does not depend on it
        }
    }

    const result = classify(parsed, Math.floor(Date.now() / 1000));
    if (result.view === 'success') {
        renderSuccess();
    } else if (result.view === 'error') {
        renderError(result.errorCode);
    } else {
        renderDefault();
    }
}

if (typeof module !== 'undefined' && module.exports) {
    // Node unit tests (tests/auth_callback/): pure functions only, no DOM.
    module.exports = { safeDecode, parseHashParams, looksLikeValidAccessToken, classify, escapeHtml, errorMessages };
} else {
    main();
}
