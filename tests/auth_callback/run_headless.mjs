// LOCAL ONLY. Headless Chromium check of /auth/callback (ROADMAP #21 points 5-8), CSP from docs/_headers.
// Usage: NODE_PATH=<dir with playwright> [CHROMIUM_PATH=<chrome-headless-shell>] node tests/auth_callback/run_headless.mjs
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = 8797;
const BASE = `http://127.0.0.1:${PORT}`;
let pass = 0; const fails = [];
const ok = (c, l) => { if (c) { pass++; console.log('PASS ' + l); } else { fails.push(l); console.log('FAIL ' + l); } };

const srv = spawn(process.execPath, [path.join(HERE, '../e2e_app/serve.mjs')], { env: { ...process.env, PORT: String(PORT) }, stdio: 'inherit' });
await new Promise((r) => setTimeout(r, 500));

const b64url = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const goodJwt = `${b64url({ alg: 'HS256' })}.${b64url({ sub: 'u1', exp: Math.floor(Date.now() / 1000) + 3600 })}.c2ln`;
const XSS = encodeURIComponent('<img src=x onerror="document.title=\'PWNED\'">Call support at evil.example');

const cases = [
  { name: 'payload in error_description', hash: `#error=access_denied&error_code=otp_expired&error_description=${XSS}`, expect: 'LINK EXPIRED', fixed: 'This magic link has expired.' },
  { name: 'payload in error_code', hash: `#error_code=${XSS}`, expect: 'AUTHENTICATION ERROR', fixed: 'Something went wrong during authentication.' },
  { name: 'junk token #access_token=x', hash: '#access_token=x', expect: 'INVALID REQUEST', fixed: 'The authentication request was malformed.' },
  { name: 'malformed % sequence', hash: '#access_token=%E0%A4%A', expect: 'INVALID REQUEST', fixed: 'The authentication request was malformed.' },
  { name: 'well-formed token', hash: `#access_token=${goodJwt}&token_type=bearer&type=magiclink`, expect: 'AUTHENTICATION COMPLETE' },
];

let browser;
try {
  browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
  for (const c of cases) {
    const ctx = await browser.newContext(); const page = await ctx.newPage();
    const errors = []; page.on('pageerror', (e) => errors.push(String(e)));
    const resp = await page.goto(`${BASE}/auth-callback.html${c.hash}`);
    await page.waitForTimeout(300);
    const text = await page.textContent('#content');
    ok((resp.headers()['content-security-policy'] || '').includes("script-src 'self'"), `${c.name}: CSP header present`);
    ok(await page.title() === 'The Backroom | Authentication', `${c.name}: document.title unchanged`);
    ok(text.includes(c.expect), `${c.name}: shows ${c.expect}`);
    if (c.fixed) ok(text.includes(c.fixed) && !text.includes('evil.example') && !text.includes('<img'), `${c.name}: fixed text only, no attacker text`);
    ok(new URL(page.url()).hash === '', `${c.name}: hash stripped by history.replaceState`);
    ok(errors.length === 0, `${c.name}: no page errors ${errors.join(' | ')}`);
    await ctx.close();
  }
} finally {
  if (browser) await browser.close();
  srv.kill();
}
console.log(`\n${pass} passed, ${fails.length} failed`);
process.exit(fails.length ? 1 : 0);
