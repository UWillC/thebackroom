// LOCAL ONLY. End-to-end test of docs/app in headless Chromium (Playwright).
//   mock-csp   : hostile data from a local mock, page CSP on (CSP connect-src pointed at the mock)
//   mock-nocsp : the same without CSP, so a pass proves our rendering (text only), not just the CSP
//   prod       : real Supabase, read-only calls only (E2E_PROD=1): lists, feed, analytics, status, RPCs with a
//                profile id that does not exist (no row is written)
// Usage: NODE_PATH=<dir with playwright> [CHROMIUM_PATH=<chrome-headless-shell>] node tests/e2e_app/run_e2e.mjs
//        E2E_PROD=1 adds the prod run
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const CSP_PROD = "default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self'; connect-src https://ifofgblilanwjhypzvdb.supabase.co; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
let pass = 0; const fails = [];
const ok = (cond, label) => { if (cond) { pass++; console.log('PASS ' + label); } else { fails.push(label); console.log('FAIL ' + label); } };
const procs = [];
function start(file, env) {
  const p = spawn(process.execPath, [path.join(HERE, file)], { env: { ...process.env, ...env }, stdio: 'inherit' });
  procs.push(p); return p;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function withPage(browser, fn) {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const log = { console: [], requests: [], pageErrors: [] };
  page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') log.console.push(m.text()); });
  page.on('pageerror', (e) => log.pageErrors.push(String(e)));
  page.on('request', (r) => log.requests.push(r.url()));
  try { await fn(page, log); } finally { await ctx.close(); }
}

async function clickTab(page, name) { await page.click(`[role=tab][data-tab=${name}]`); }
async function waitOut(page, sel) {
  await page.waitForFunction((s) => { const t = document.querySelector(s).textContent; return t && !t.includes('Loading...'); }, sel, { timeout: 15000 });
  return page.textContent(sel);
}
const hosts = (urls) => [...new Set(urls.map((u) => new URL(u).host))];

async function mockRun(browser, port, csp, label) {
  const base = `http://127.0.0.1:${port}`;
  await withPage(browser, async (page, log) => {
    const resp = await page.goto(base + '/app');
    ok(new URL(page.url()).pathname === '/app/', `${label}: /app redirects to /app/`);
    const cspHdr = resp.headers()['content-security-policy'] || '';
    if (csp) ok(cspHdr === CSP_PROD.replace('https://ifofgblilanwjhypzvdb.supabase.co', 'http://127.0.0.1:8790'), `${label}: CSP header from _headers on /app/`);
    else ok(cspHdr === '', `${label}: no CSP (rendering test)`);

    await page.fill('#find-query', 'python'); await page.click('#find-form button[type=submit]');
    let t = await waitOut(page, '#find-out');
    ok(t.includes('Found 1 match(es)') && t.includes('Evil <img src=x onerror='), `${label}: Find shows payload as literal text`);
    ok(t.includes('Offers: python <img') && t.includes('Role match'), `${label}: Find reasons 1:1 (offers, role)`);

    await clickTab(page, 'profiles'); await page.click('#profiles-btn');
    t = await waitOut(page, '#profiles-out');
    ok(t.includes('2 profiles in The Backroom') && t.includes('<svg onload='), `${label}: All Profiles literal text`);

    await clickTab(page, 'analytics'); await page.click('#analytics-btn');
    t = await waitOut(page, '#analytics-out');
    ok(t.includes('Total searches: 3') && t.includes('Search Gaps') && t.includes('<img src=x'), `${label}: Analytics counts and literal query`);

    await clickTab(page, 'rooms');
    ok((await page.textContent('#tab-rooms')).includes('Rooms and messages are private.'), `${label}: My Rooms static text`);

    await clickTab(page, 'feed'); await page.click('#feed-btn');
    t = await waitOut(page, '#feed-out');
    ok(t.includes('1 post(s) from AI assistants') && t.includes('🔥2') && t.includes('<script>window.__xss'), `${label}: Feed with reactions, literal text`);

    await clickTab(page, 'assistants'); await page.click('#assistants-btn');
    t = await waitOut(page, '#assistants-out');
    ok(t.includes('1 Assistant(s) in x.TheBackroom') && t.includes('Asst <script>'), `${label}: Assistants literal text`);

    await clickTab(page, 'verify'); await page.fill('#verify-profile', 'evil'); await page.click('#verify-status-btn');
    t = await waitOut(page, '#verify-status-out');
    ok(t.includes('Pending verification') && t.includes('N <img'), `${label}: Check Status literal text`);
    await page.fill('#verify-token', 'bad'); await page.click('#verify-btn');
    t = await waitOut(page, '#verify-out');
    ok(t.includes('Verification Failed') && t.includes('Invalid <script>'), `${label}: Verify failure literal text`);

    await clickTab(page, 'status'); await page.click('#status-btn');
    await page.waitForFunction(() => document.querySelector('#status-out').textContent.startsWith('Connected'), null, { timeout: 10000 });
    ok((await page.textContent('#status-out')) === 'Connected - 2 profiles loaded', `${label}: Status`);

    const xss = await page.evaluate(() => window.__xss);
    ok(xss === undefined, `${label}: no payload executed (window.__xss undefined)`);
    const injected = await page.evaluate(() => document.querySelectorAll('main img, main script, main svg, main iframe, main a[href^="javascript"]').length);
    ok(injected === 0, `${label}: no img/script/svg/iframe/javascript: link created in the page`);
    ok(log.pageErrors.length === 0, `${label}: no page errors ${log.pageErrors.join(' | ')}`);
    ok(log.console.length === 0, `${label}: no console errors or CSP violations ${log.console.join(' | ')}`);
    ok(hosts(log.requests).every((h) => h === `127.0.0.1:${port}` || h === '127.0.0.1:8790'), `${label}: requests only to own origin + mock (${hosts(log.requests).join(', ')})`);
  });

  // Verification link: token in the fragment
  await withPage(browser, async (page, log) => {
    await page.goto(base + '/app/#verify=good-token&profile=evil');
    await page.waitForSelector('#tab-verify:not([hidden])');
    ok(!page.url().includes('#') && !page.url().includes('good-token'), `${label}: fragment removed from the address bar`);
    ok(await page.inputValue('#verify-token') === 'good-token' && await page.inputValue('#verify-profile') === 'evil', `${label}: link fills token and profile`);
    ok(await page.isVisible('#verify-link-note'), `${label}: note to click Verify is shown`);
    ok(!log.requests.some((u) => u.includes('verify_email_token')), `${label}: no automatic verification on page load`);
    const hist = await page.evaluate(() => history.length);
    await page.click('#verify-btn');
    const t = await waitOut(page, '#verify-out');
    ok(t.includes('Email Verified Successfully!') && t.includes('me@example.com<img'), `${label}: Verify success, e-mail shown as text`);
    ok(!log.requests.some((u) => u.includes('good-token')), `${label}: token never in a request URL (only in the POST body)`);
    await page.goBack().catch(() => null);
    ok(hist <= 2 && !page.url().includes('good-token'), `${label}: no history entry holding the token (back goes to ${page.url()})`);
    ok(await page.evaluate(() => window.__xss) === undefined, `${label}: no payload executed on verify`);
  });

  // Hostile fragment
  await withPage(browser, async (page) => {
    await page.goto(base + '/app/#verify=%3Cimg%20src%3Dx%20onerror%3D%22window.__xss%3D1%22%3E&profile=%3Cscript%3Ewindow.__xss%3D1%3C%2Fscript%3E');
    await page.waitForSelector('#tab-verify:not([hidden])');
    ok(await page.inputValue('#verify-token') === '<img src=x onerror="window.__xss=1">', `${label}: hostile fragment lands only in the input value`);
    ok(await page.evaluate(() => window.__xss) === undefined, `${label}: hostile fragment not executed`);
  });
}

async function prodRun(browser, port) {
  const base = `http://127.0.0.1:${port}`; const label = 'prod';
  await withPage(browser, async (page, log) => {
    const resp = await page.goto(base + '/app/');
    ok((resp.headers()['content-security-policy'] || '') === CSP_PROD, `${label}: production CSP on /app/`);
    await clickTab(page, 'profiles'); await page.click('#profiles-btn');
    let t = await waitOut(page, '#profiles-out');
    const m = t.match(/(\d+) profiles in The Backroom/);
    ok(!!m, `${label}: All Profiles loads (${m ? m[1] : t.slice(0, 80)})`);
    await clickTab(page, 'status'); await page.click('#status-btn');
    await page.waitForFunction(() => /^(Connected|Error)/.test(document.querySelector('#status-out').textContent), null, { timeout: 15000 });
    const st = await page.textContent('#status-out');
    ok(m && st === `Connected - ${m[1]} profiles loaded`, `${label}: Status "${st}"`);
    await clickTab(page, 'find'); await page.fill('#find-query', 'a'); await page.click('#find-form button[type=submit]');
    t = await waitOut(page, '#find-out');
    ok(/Found \d+ match\(es\)|No matches found/.test(t), `${label}: Find runs`);
    await clickTab(page, 'analytics'); await page.fill('#analytics-days', '30'); await page.click('#analytics-btn');
    t = await waitOut(page, '#analytics-out');
    ok(t.startsWith('Analytics (last 30 days)') && !t.includes('Error'), `${label}: Analytics loads`);
    await clickTab(page, 'feed'); await page.click('#feed-btn');
    t = await waitOut(page, '#feed-out');
    ok(t.startsWith('x.TheBackroom Feed') && !t.includes('Error'), `${label}: Feed loads`);
    await clickTab(page, 'assistants'); await page.click('#assistants-btn');
    t = await waitOut(page, '#assistants-out');
    ok(/Assistant/.test(t) && !t.includes('Error'), `${label}: Assistants load (${t.slice(0, 40)})`);
    await clickTab(page, 'verify'); await page.fill('#verify-profile', 'e2e-does-not-exist-2026-11-05'); await page.click('#verify-status-btn');
    t = await waitOut(page, '#verify-status-out');
    ok(t.includes("Profile 'e2e-does-not-exist-2026-11-05' not found"), `${label}: get_email_status RPC (unknown id, read only)`);
    await page.fill('#verify-token', 'not-a-token'); await page.click('#verify-btn');
    t = await waitOut(page, '#verify-out');
    ok(t.includes('Verification Failed') && t.includes('Profile not found'), `${label}: verify_email_token RPC (unknown id, nothing written)`);
    ok(log.pageErrors.length === 0, `${label}: no page errors ${log.pageErrors.join(' | ')}`);
    ok(log.console.length === 0, `${label}: no console errors, CORS or CSP violations ${log.console.join(' | ')}`);
    const h = hosts(log.requests);
    ok(h.every((x) => x === `127.0.0.1:${port}` || x === 'ifofgblilanwjhypzvdb.supabase.co'), `${label}: requests only to own origin + Supabase (${h.join(', ')})`);
    ok(!log.requests.some((u) => /fonts\.googleapis|gstatic|cdnjs|huggingface/.test(u)), `${label}: no Google Fonts, cdnjs or Hugging Face`);
  });
}

try {
  start('mock_supabase.mjs', { MOCK_PORT: '8790' });
  start('serve.mjs', { PORT: '8788', MOCK_ORIGIN: 'http://127.0.0.1:8790' });
  start('serve.mjs', { PORT: '8789', MOCK_ORIGIN: 'http://127.0.0.1:8790', NO_CSP: '1' });
  if (process.env.E2E_PROD === '1') start('serve.mjs', { PORT: '8787' });
  await sleep(800);
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {}) });
  try {
    await mockRun(browser, 8788, true, 'mock-csp');
    await mockRun(browser, 8789, false, 'mock-nocsp');
    if (process.env.E2E_PROD === '1') await prodRun(browser, 8787);
  } finally { await browser.close(); }
} finally { procs.forEach((p) => p.kill()); }
console.log(`== ${pass} PASS, ${fails.length} FAIL`);
process.exit(fails.length ? 1 : 0);
