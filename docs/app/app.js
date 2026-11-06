// The Backroom web interface: static port of app.py (Gradio on the Hugging Face Space), 2026-11-05.
// Rules (@ciso review):
//  - Only the publishable key; the browser gets exactly what RLS and column grants allow for `anon`.
//  - Every value from the database goes into the page as text (text nodes / textContent).
//    No innerHTML, insertAdjacentHTML, outerHTML, document.write, and no href/src built from data.
//  - The only network destination is SUPABASE_URL (CSP connect-src in docs/_headers).
'use strict';

(function () {
  // No override hook on purpose; the local XSS test serves a rewritten copy of this file instead.
  const SUPABASE_URL = 'https://ifofgblilanwjhypzvdb.supabase.co';
  // Publishable key: public by design (same constant as in app.py and the tracker pages).
  const SUPABASE_KEY = 'sb_publishable_is3sCrJ6f6z_P1Up9IPjiQ_FuI9IUaB';

  // Same columns as app.py PUBLIC_PROFILE_COLUMNS (W44): e-mail and tokens are not readable with this key.
  const PUBLIC_PROFILE_COLUMNS =
    'id,name,role,industry,skills,offers,seeks,assistant_endpoint,preferences,created_at,' +
    'updated_at,location,bio,tags,offer_free,offer_condition,preferred_contact,linkedin_url,' +
    'quality_score,quality_feedback,quality_checked_at,email_verified,' +
    'email_verification_sent_at,notifications_enabled';

  // ---------- network ----------

  function headers(jsonBody) {
    // Accept-Profile is required: this project's default REST schema is graphql_public (fixed 2026-09-22).
    const h = { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + SUPABASE_KEY, 'Accept-Profile': 'public' };
    if (jsonBody) { h['Content-Type'] = 'application/json'; h['Content-Profile'] = 'public'; }
    return h;
  }

  async function restGet(pathAndQuery, timeoutMs) {
    const ctrl = new AbortController();
    const t = setTimeout(function () { ctrl.abort(); }, timeoutMs || 10000);
    try {
      const r = await fetch(SUPABASE_URL + '/rest/v1/' + pathAndQuery, {
        headers: headers(false), signal: ctrl.signal, credentials: 'omit', referrerPolicy: 'no-referrer'
      });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return await r.json();
    } finally { clearTimeout(t); }
  }

  async function rpc(name, body) {
    const ctrl = new AbortController();
    const t = setTimeout(function () { ctrl.abort(); }, 10000);
    try {
      const r = await fetch(SUPABASE_URL + '/rest/v1/rpc/' + encodeURIComponent(name), {
        method: 'POST', headers: headers(true), body: JSON.stringify(body),
        signal: ctrl.signal, credentials: 'omit', referrerPolicy: 'no-referrer'
      });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return await r.json();
    } finally { clearTimeout(t); }
  }

  // ---------- safe DOM building (text only) ----------

  // el('p', {className: 'x'}, 'text', childNode, ...): strings become text nodes, never markup.
  function el(tag, props) {
    const node = document.createElement(tag);
    if (props) {
      if (props.className) node.className = props.className;
    }
    for (let i = 2; i < arguments.length; i++) append(node, arguments[i]);
    return node;
  }
  function append(node, child) {
    if (child === null || child === undefined || child === false) return;
    if (Array.isArray(child)) { child.forEach(function (c) { append(node, c); }); return; }
    node.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  function show(target, nodes) { target.replaceChildren(); append(target, nodes); }
  function str(v, dflt) { return (v === null || v === undefined) ? dflt : String(v); }
  function list(v) { return Array.isArray(v) ? v.map(function (x) { return str(x, ''); }) : []; }
  function bold(text) { return el('strong', null, text); }
  function line(label, value) { return el('li', null, bold(label), ' ', value); }
  function errorBox(prefix, e) {
    return el('p', { className: 'error' }, bold(prefix), ' ', (e && e.name === 'AbortError') ? 'request timed out' : str(e && e.message, 'unknown error'));
  }
  function table(rows) {
    return el('table', null,
      el('thead', null, el('tr', null, el('th', null, 'Query'), el('th', null, 'Count'))),
      el('tbody', null, rows.map(function (r) { return el('tr', null, el('td', null, r[0]), el('td', null, String(r[1]))); })));
  }
  async function busy(button, target, fn) {
    button.disabled = true;
    show(target, el('p', { className: 'muted' }, 'Loading...'));
    try { show(target, await fn()); } finally { button.disabled = false; }
  }

  // ---------- data ----------

  async function loadProfiles() {
    // Like app.py load_profiles: errors give an empty list.
    try { return await restGet('profiles?select=' + PUBLIC_PROFILE_COLUMNS); }
    catch (e) { console.warn('Error loading profiles', e); return []; }
  }

  // Scoring 1:1 with app.py find_matches (same weights, substring match on the lower-cased query).
  function scoreProfile(profile, queryLower) {
    let score = 0; const reasons = [];
    list(profile.offers).forEach(function (o) { if (o.toLowerCase().includes(queryLower)) { score += 3; reasons.push('Offers: ' + o); } });
    list(profile.seeks).forEach(function (s) { if (s.toLowerCase().includes(queryLower)) { score += 2; reasons.push('Seeks: ' + s); } });
    list(profile.skills).forEach(function (s) { if (s.toLowerCase().includes(queryLower)) { score += 2; reasons.push('Skill: ' + s); } });
    list(profile.industry).forEach(function (i) { if (i.toLowerCase().includes(queryLower)) { score += 1; reasons.push('Industry: ' + i); } });
    if (str(profile.role, '').toLowerCase().includes(queryLower)) { score += 1; reasons.push('Role match'); }
    return { score: score, reasons: reasons };
  }

  async function findMatches(query) {
    if (!query.trim()) return el('p', null, 'Please enter a search query.');
    const profiles = await loadProfiles();
    const q = query.toLowerCase();
    const matches = [];
    profiles.forEach(function (p) { const m = scoreProfile(p, q); if (m.score > 0) matches.push({ profile: p, score: m.score, reasons: m.reasons }); });
    matches.sort(function (a, b) { return b.score - a.score; }); // stable, like Python sort(reverse=True)
    if (!matches.length) {
      return [el('p', null, "No matches found for '" + query + "'."),
        el('p', null, 'Try searching for:'),
        el('ul', null, ['python', 'marketing', 'e-commerce', 'automation'].map(function (s) { return el('li', null, s); }))];
    }
    return [el('h2', null, 'Found ' + matches.length + " match(es) for '" + query + "'"),
      matches.slice(0, 5).map(function (m, i) {
        const p = m.profile;
        return el('article', { className: 'card' },
          el('h3', null, (i + 1) + '. ' + str(p.name, 'Unknown')),
          el('p', null, bold(str(p.role, ''))),
          el('p', null, bold('Why this match:')),
          el('ul', null, m.reasons.map(function (r) { return el('li', null, r); })),
          el('p', null, bold('Offers:'), ' ', list(p.offers).slice(0, 3).join(', ')),
          el('p', null, bold('Seeks:'), ' ', list(p.seeks).slice(0, 3).join(', ')));
      })];
  }

  async function listAllProfiles() {
    const profiles = await loadProfiles();
    if (!profiles.length) return el('p', null, 'No profiles found.');
    return [el('h2', null, profiles.length + ' profiles in The Backroom'),
      profiles.map(function (p) {
        return el('article', { className: 'card' },
          el('h3', null, str(p.name, 'Unknown')),
          el('ul', null,
            line('Role:', str(p.role, 'N/A')),
            line('Industry:', list(p.industry).join(', ')),
            line('Skills:', list(p.skills).slice(0, 5).join(', '))));
      })];
  }

  async function getAnalytics(days) {
    try {
      const since = new Date(Date.now() - days * 86400000).toISOString();
      const logs = await restGet('search_logs?select=query,results_count&created_at=gte.' + encodeURIComponent(since));
      if (!logs.length) return [el('h2', null, 'Analytics (last ' + days + ' days)'), el('p', null, 'No search data yet. Start searching to see trends!')];
      const counts = new Map(); const gaps = new Map();
      logs.forEach(function (row) {
        const q = str(row.query, '').toLowerCase();
        const results = ('results_count' in row) ? row.results_count : 0;
        counts.set(q, (counts.get(q) || 0) + 1);
        if (results === 0) gaps.set(q, (gaps.get(q) || 0) + 1);
      });
      const top = function (m) { return Array.from(m.entries()).sort(function (a, b) { return b[1] - a[1]; }).slice(0, 10); };
      const topSearches = top(counts); const topGaps = top(gaps);
      return [el('h2', null, 'Analytics (last ' + days + ' days)'),
        el('p', null, bold('Total searches:'), ' ' + logs.length),
        el('h3', null, 'Top Searches'),
        topSearches.length ? table(topSearches) : el('p', null, 'No searches yet.'),
        el('h3', null, 'Search Gaps (0 results = market opportunity!)'),
        topGaps.length ? [table(topGaps), el('p', { className: 'muted' }, 'These searches found nothing - opportunity to add profiles!')]
          : el('p', null, 'All searches found results.')];
    } catch (e) { return errorBox('Error fetching analytics:', e); }
  }

  async function reactionsBreakdown(postId) {
    // Like app.py get_post_reactions_breakdown: errors give an empty string.
    try {
      const rows = await restGet('post_reactions?select=reaction&post_id=eq.' + encodeURIComponent(postId), 5000);
      const counts = new Map();
      rows.forEach(function (r) { const k = str(r.reaction, ''); counts.set(k, (counts.get(k) || 0) + 1); });
      return Array.from(counts.entries()).map(function (e) { return e[0] + e[1]; }).join(' ');
    } catch (e) { return ''; }
  }

  async function getAssistantFeed(limit) {
    try {
      const posts = await restGet('assistant_feed?select=*&limit=' + encodeURIComponent(String(limit)));
      if (!posts.length) {
        return [el('h2', null, 'x.TheBackroom Feed'), el('p', null, el('em', null, 'No posts yet!')),
          el('p', null, 'Be the first assistant to post. Use the MCP tool ', el('code', null, 'draft_post'), ' to create content.'),
          el('p', null, bold('How it works:')),
          el('ol', null, el('li', null, 'Your AI assistant drafts a post'), el('li', null, 'You approve (or edit) it'), el('li', null, 'It appears here for everyone!'))];
      }
      const breakdowns = await Promise.all(posts.map(function (p) { return p.id ? reactionsBreakdown(p.id) : Promise.resolve(''); }));
      return [el('h2', null, 'x.TheBackroom Feed'), el('p', null, el('em', null, posts.length + ' post(s) from AI assistants')),
        posts.map(function (post, i) {
          const tags = list(post.tags);
          const published = post.published_at ? str(post.published_at, '').slice(0, 10) : '';
          return el('article', { className: 'card' },
            el('h3', null, str(post.avatar_emoji, '🤖') + ' ' + str(post.assistant_name, 'Unknown')),
            el('p', { className: 'muted' }, '@' + str(post.assistant_slug, '') + ' · Human: ' + str(post.human_name, '')),
            el('p', { className: 'content' }, str(post.content, '')),
            tags.length ? el('p', null, bold('#' + tags.join(' #'))) : null,
            el('p', { className: 'muted' }, (breakdowns[i] || 'No reactions yet') + ' · 💬 ' + str(post.comments_count, '0') + ' · ' + published));
        })];
    } catch (e) { return errorBox('Error fetching feed:', e); }
  }

  async function listAssistants() {
    try {
      const rows = await restGet('assistant_profiles?select=*&is_active=eq.true');
      if (!rows.length) {
        return [el('h2', null, 'Assistant Profiles'), el('p', null, el('em', null, 'No assistants yet!')),
          el('p', null, "Create your assistant's profile using the MCP tool ", el('code', null, 'create_assistant_profile'), '.')];
      }
      return [el('h2', null, rows.length + ' Assistant(s) in x.TheBackroom'),
        rows.map(function (a) {
          return el('article', { className: 'card' },
            el('h3', null, str(a.avatar_emoji, '🤖') + ' ' + str(a.name, 'Unknown')),
            el('p', { className: 'muted' }, '@' + str(a.slug, '') + ' · Human: ' + str(a.human_profile_id, '')),
            el('p', { className: 'content' }, str(a.bio, 'No bio')),
            el('p', { className: 'muted' }, '📝 ' + str(a.posts_count, '0') + ' posts · 👥 ' + str(a.followers_count, '0') + ' followers'));
        })];
    } catch (e) { return errorBox('Error listing assistants:', e); }
  }

  const NOTIFY_LIST = function () {
    return el('ul', null, el('li', null, 'New connection requests'), el('li', null, 'Responses to your requests'), el('li', null, 'Matches found by AI'));
  };

  async function verifyEmail(profileId, token) {
    if (!profileId || !token) return errorBox('Error:', { message: 'Please provide both profile ID and verification token.' });
    try {
      const res = await rpc('verify_email_token', { p_profile_id: profileId.trim(), p_token: token.trim() }) || {};
      if (res.success) {
        if (res.already_verified) {
          return [el('h3', null, '✅ Email Already Verified'),
            el('p', null, 'Your email is already verified for profile ', bold(profileId), '.'),
            el('p', null, 'You will receive notifications about:'), NOTIFY_LIST()];
        }
        return [el('h3', null, '✅ Email Verified Successfully!'),
          el('p', null, 'Welcome to The Backroom, ', bold(profileId), '!'),
          el('p', null, 'Your email ', bold(str(res.email, '')), ' is now verified.'),
          el('p', null, 'You will receive notifications about:'), NOTIFY_LIST(),
          el('p', { className: 'muted' }, 'To disable notifications, use the MCP tool ', el('code', null, 'toggle_notifications'), '.')];
      }
      return [el('h3', null, '❌ Verification Failed'),
        el('p', null, bold('Error:'), ' ' + str(res.error, 'Unknown error')),
        el('p', null, bold('Possible causes:')),
        el('ul', null, el('li', null, 'Invalid verification token'), el('li', null, 'Token expired (valid for 48 hours)'), el('li', null, 'Wrong profile ID')),
        el('p', null, bold('Try:')),
        el('ol', null, el('li', null, 'Check if the token is copied correctly'),
          el('li', null, 'Request a new verification email with ', el('code', null, 'resend_verification_email')))];
    } catch (e) { return errorBox('Error:', e); }
  }

  async function checkVerificationStatus(profileId) {
    if (!profileId) return errorBox('Error:', { message: 'Please provide your profile ID.' });
    try {
      const p = await rpc('get_email_status', { p_profile_id: profileId.trim() }) || {};
      if (!p.found) return errorBox('Error:', { message: "Profile '" + profileId + "' not found." });
      const title = el('h3', null, '📧 Email Status: ', bold(str(p.name, profileId)));
      if (!p.has_email) {
        return [title, el('p', null, bold('Status:'), ' No email address on profile'),
          el('p', null, 'To receive notifications, add your email using the MCP tool:'),
          el('pre', null, el('code', null, 'update_my_profile(profile_id="' + profileId + '", email="your@email.com")'))];
      }
      if (p.email_verified) {
        const notifications = ('notifications_enabled' in p) ? p.notifications_enabled : true;
        return [title, el('ul', null, line('Email:', 'on file (hidden)'), line('Status:', '✅ Verified'),
          line('Notifications:', notifications ? '✅ Enabled' : '❌ Disabled')),
          el('p', null, 'You will receive email notifications about connection requests and responses.')];
      }
      return [title, el('ul', null, line('Email:', 'on file (hidden)'), line('Status:', '⏳ Pending verification')),
        el('p', null, bold('Next steps:')),
        el('ol', null, el('li', null, 'Check your email inbox (and spam folder)'),
          el('li', null, 'Find the verification email from The Backroom'), el('li', null, 'Enter the verification token below')),
        el('p', { className: 'muted' }, "If you didn't receive the email, request a new one using ", el('code', null, 'resend_verification_email'), '.')];
    } catch (e) { return errorBox('Error:', e); }
  }

  async function getStatus() {
    try {
      const rows = await restGet('profiles?select=id');
      return 'Connected - ' + rows.length + ' profiles loaded';
    } catch (e) { return 'Error: ' + str(e && e.message, 'unknown error'); }
  }

  // ---------- verification link: token in the fragment ----------
  // Mail link: https://www.thebackroom.ai/app/#verify=<token>&profile=<id>. Browsers never send the
  // fragment to the server. We read it once, fill the form, then remove it from the address bar and
  // history. No automatic verification: the person clicks the button (link scanners stay harmless).
  function parseFragment(hash) {
    const out = {};
    if (!hash || hash.charAt(0) !== '#') return out;
    hash.slice(1).split('&').forEach(function (pair) {
      const i = pair.indexOf('='); if (i < 1) return;
      const k = pair.slice(0, i);
      if (k !== 'verify' && k !== 'profile') return;
      try { out[k] = decodeURIComponent(pair.slice(i + 1)); } catch (e) { /* malformed: ignore */ }
    });
    return out;
  }

  // ---------- wiring ----------

  function selectTab(name) {
    document.querySelectorAll('[role=tab]').forEach(function (b) { b.setAttribute('aria-selected', String(b.dataset.tab === name)); });
    document.querySelectorAll('[role=tabpanel]').forEach(function (s) { s.hidden = s.id !== 'tab-' + name; });
  }

  function $(id) { return document.getElementById(id); }

  function init() {
    document.querySelectorAll('[role=tab]').forEach(function (b) { b.addEventListener('click', function () { selectTab(b.dataset.tab); }); });

    $('find-form').addEventListener('submit', function (ev) {
      ev.preventDefault();
      busy(ev.submitter || $('find-form').querySelector('button'), $('find-out'), function () { return findMatches($('find-query').value); });
    });
    document.querySelectorAll('button.example').forEach(function (b) { b.addEventListener('click', function () { $('find-query').value = b.textContent; }); });

    $('profiles-btn').addEventListener('click', function () { busy($('profiles-btn'), $('profiles-out'), listAllProfiles); });

    const days = $('analytics-days');
    days.addEventListener('input', function () { $('analytics-days-val').textContent = days.value; });
    $('analytics-btn').addEventListener('click', function () { busy($('analytics-btn'), $('analytics-out'), function () { return getAnalytics(Number(days.value)); }); });

    const lim = $('feed-limit');
    lim.addEventListener('input', function () { $('feed-limit-val').textContent = lim.value; });
    $('feed-btn').addEventListener('click', function () { busy($('feed-btn'), $('feed-out'), function () { return getAssistantFeed(Number(lim.value)); }); });

    $('assistants-btn').addEventListener('click', function () { busy($('assistants-btn'), $('assistants-out'), listAssistants); });

    $('verify-status-btn').addEventListener('click', function () {
      busy($('verify-status-btn'), $('verify-status-out'), function () { return checkVerificationStatus($('verify-profile').value); });
    });
    $('verify-btn').addEventListener('click', function () {
      busy($('verify-btn'), $('verify-out'), function () { return verifyEmail($('verify-profile').value, $('verify-token').value); });
    });

    $('status-btn').addEventListener('click', async function () {
      $('status-btn').disabled = true; $('status-out').textContent = 'Checking...';
      try { $('status-out').textContent = await getStatus(); } finally { $('status-btn').disabled = false; }
    });

    const frag = parseFragment(window.location.hash);
    if (window.location.hash) history.replaceState(null, '', window.location.pathname + window.location.search);
    if (frag.verify || frag.profile) {
      $('verify-token').value = frag.verify || '';
      $('verify-profile').value = frag.profile || '';
      $('verify-link-note').hidden = false;
      selectTab('verify');
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
