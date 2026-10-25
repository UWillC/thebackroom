// Parse URL hash parameters
function getHashParams() {
    const hash = window.location.hash.substring(1);
    const params = {};
    hash.split('&').forEach(part => {
        const [key, value] = part.split('=');
        if (key) {
            params[key] = decodeURIComponent(value || '');
        }
    });
    return params;
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

// Render error content
function renderError(params) {
    const terminal = document.getElementById('terminal');
    const content = document.getElementById('content');
    const statusBox = document.getElementById('status-box');
    const title = document.getElementById('title');

    // error_code / error / error_description come from the URL (attacker-controlled):
    // the code is allowlisted to the keys of errorMessages, the description is HTML-escaped.
    const rawCode = params.error_code || params.error || 'default';
    const errorCode = Object.prototype.hasOwnProperty.call(errorMessages, rawCode) ? rawCode : 'default';
    const errorInfo = errorMessages[errorCode];
    const errorDescription = escapeHtml((params.error_description || errorInfo.description).replace(/\+/g, ' '));

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
        <p class="line"><span class="error-code">error_code: ${errorCode}</span></p>
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
const params = getHashParams();

if (params.access_token) {
    // Success - we have an access token
    renderSuccess();
} else if (params.error || params.error_code) {
    // Error
    renderError(params);
} else {
    // No params - default state
    renderDefault();
}
