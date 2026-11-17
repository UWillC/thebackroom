// LOCAL ONLY. Headless Chromium check of the CSP on / and on the 404 page (2026-11-17), CSP from docs/_headers.
// Proves the policy breaks nothing: zero CSP violations, fonts and styles load, the feedback widget renders and its
// POST passes the CSP (the request is answered by Playwright, it never reaches the real webhook).
// Usage: NODE_PATH=<dir with playwright> [CHROMIUM_PATH=<chrome>] [BASE=http://127.0.0.1:8799] node tests/csp_root_404/run_headless.mjs
//        without BASE it starts tests/e2e_app/serve.mjs; with BASE it tests that server (e.g. `wrangler pages dev docs`)
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = 8798;
const BASE = process.env.BASE || `http://127.0.0.1:${PORT}`;
const WEBHOOK = 'https://3w7nw22j1d.execute-api.us-east-1.amazonaws.com/webhook/feedback';
let pass = 0; const fails = [];
const ok = (c, l) => { if (c) { pass++; console.log('PASS ' + l); } else { fails.push(l); console.log('FAIL ' + l); } };

let srv = null;
if (!process.env.BASE) {
  srv = spawn(process.execPath, [path.join(HERE, '../e2e_app/serve.mjs')], { env: { ...process.env, PORT: String(PORT) }, stdio: 'inherit' });
  await new Promise((r) => setTimeout(r, 500));
}

async function open(browser, url) {
  const ctx = await browser.newContext();
  await ctx.addInitScript(() => {
    window.__csp = [];
    document.addEventListener('securitypolicyviolation', (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`));
  });
  const page = await ctx.newPage();
  const log = { console: [], errors: [], webhook: [], outside: [], badSub: [] };
  page.on('response', (r) => { if (r.request().resourceType() !== 'document' && r.status() >= 400) log.badSub.push(r.url()); });
  page.on('console', (m) => { if (m.type() === 'error') log.console.push(m.text()); });
  page.on('pageerror', (e) => log.errors.push(String(e)));
  page.on('request', (r) => { if (!r.url().startsWith(BASE) && !r.url().startsWith(WEBHOOK)) log.outside.push(r.url()); });
  await page.route(WEBHOOK, (route) => { log.webhook.push(route.request().postData()); route.fulfill({ status: 200, body: 'ok' }); });
  const resp = await page.goto(url, { waitUntil: 'networkidle' });
  return { ctx, page, log, resp };
}

let browser;
try {
  browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });

  // Landing page
  {
    const { ctx, page, log, resp } = await open(browser, BASE + '/');
    const csp = resp.headers()['content-security-policy'] || '';
    ok(resp.status() === 200, '/: 200');
    ok(csp.includes("script-src 'self'") && csp.includes(`connect-src ${WEBHOOK}`) && !csp.includes(','), '/: one landing CSP');
    ok(await page.evaluate(() => document.fonts.check("16px 'JetBrains Mono'")), '/: JetBrains Mono loaded');
    ok(await page.evaluate(() => getComputedStyle(document.body).backgroundColor) !== 'rgba(0, 0, 0, 0)', '/: inline <style> applied');
    ok(await page.evaluate(() => { const a = document.querySelector('a[href="/privacy"]');
      return a.style.color === 'inherit' && getComputedStyle(a).color === getComputedStyle(a.parentElement).color; }),
      '/: style="" attribute applied');
    ok(await page.locator('.snow-fbw-btn, button[aria-label="Send feedback"]').count() === 1, '/: widget button rendered');
    ok(await page.evaluate(() => !!document.getElementById('snow-fbw-style')
      && getComputedStyle(document.querySelector('button[aria-label="Send feedback"]')).position === 'fixed'), '/: widget <style> applied');
    await page.locator('button[aria-label="Send feedback"]').click();
    await page.fill('#snow-fbw-text', 'csp test, local only');
    await page.click('#snow-fbw-send');
    await page.waitForSelector('.snow-fbw-thanks-msg', { timeout: 5000 }).catch(() => {});
    ok(log.webhook.length === 1, '/: widget POST passed CSP (answered locally)');
    ok(await page.locator('.snow-fbw-thanks-msg').count() === 1, '/: widget thank-you shown');
    const v = await page.evaluate(() => window.__csp);
    ok(v.length === 0, '/: zero CSP violations ' + JSON.stringify(v));
    ok(log.errors.length === 0 && log.console.length === 0, '/: no page errors ' + JSON.stringify([...log.errors, ...log.console]));
    ok(log.outside.length === 0, '/: no other outside requests ' + JSON.stringify(log.outside));
    ok(log.badSub.length === 0, '/: no failed subresource ' + JSON.stringify(log.badSub));
    await ctx.close();
  }

  // 404 page on two missing paths
  for (const p of ['/nonexistent-zz9', '/deep/missing/page.html']) {
    const { ctx, page, log, resp } = await open(browser, BASE + p);
    const csp = resp.headers()['content-security-policy'] || '';
    ok(resp.status() === 404, `${p}: 404`);
    ok(csp.startsWith("default-src 'none'; style-src 'self' 'unsafe-inline'") && !csp.includes('script-src') && !csp.includes(','), `${p}: baseline CSP`);
    ok((await page.textContent('body')).includes('No such file or directory (404)'), `${p}: 404.html served`);
    ok(await page.evaluate(() => document.fonts.check("16px 'JetBrains Mono'")), `${p}: font loaded`);
    ok(await page.evaluate(() => getComputedStyle(document.body).color) === 'rgb(0, 255, 65)', `${p}: inline <style> applied`);
    const v = await page.evaluate(() => window.__csp);
    // the only console error allowed is the document's own 404 status
    const other = log.console.filter((m) => !m.includes('status of 404'));
    ok(log.console.length <= 1 && log.badSub.length === 0, `${p}: no failed subresource ` + JSON.stringify(log.badSub));
    ok(v.length === 0 && log.errors.length === 0 && other.length === 0, `${p}: zero CSP violations/errors ` + JSON.stringify([...v, ...other]));
    await ctx.close();
  }

  // Negative control: the baseline really blocks a script on the 404 page
  {
    const { ctx, page } = await open(browser, BASE + '/nonexistent-zz9');
    await page.evaluate(() => { const s = document.createElement('script'); s.src = '/widget.js'; document.head.appendChild(s); });
    await page.waitForTimeout(500);
    const v = await page.evaluate(() => window.__csp);
    ok(v.some((x) => x.startsWith('script-src')), '404: injected script blocked by CSP (control)');
    await ctx.close();
  }
} finally {
  if (browser) await browser.close();
  if (srv) srv.kill();
}
console.log(`\n${pass} passed, ${fails.length} failed`);
process.exit(fails.length ? 1 : 0);
