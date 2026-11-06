// LOCAL ONLY. Static server for docs/ that behaves like Cloudflare Pages for /app: applies docs/_headers
// (exact paths and /* splats), redirects /app -> /app/, serves index.html for directories.
// Options (env):
//   PORT          listen port (default 8788)
//   MOCK_ORIGIN   if set, app.js is served with SUPABASE_URL = MOCK_ORIGIN and the CSP connect-src is
//                 pointed at it (the XSS test talks to a local mock, never to Supabase)
//   NO_CSP=1      drop Content-Security-Policy, so the XSS test checks our rendering, not the CSP
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DOCS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../docs');
const PROD_SUPABASE = 'https://ifofgblilanwjhypzvdb.supabase.co';
const MOCK = process.env.MOCK_ORIGIN || '';
const NO_CSP = process.env.NO_CSP === '1';
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.txt': 'text/plain; charset=utf-8', '.png': 'image/png', '.md': 'text/markdown' };

function parseHeaders() {
  const rules = []; let cur = null;
  for (const raw of fs.readFileSync(path.join(DOCS, '_headers'), 'utf8').split('\n')) {
    if (!raw.trim() || raw.trim().startsWith('#')) continue;
    if (!/^\s/.test(raw)) { cur = { pattern: raw.trim(), headers: [] }; rules.push(cur); continue; }
    const i = raw.indexOf(':'); cur.headers.push([raw.slice(0, i).trim(), raw.slice(i + 1).trim()]);
  }
  return rules;
}
function matches(pattern, p) {
  if (pattern.endsWith('/*')) return p.startsWith(pattern.slice(0, -1)) || p === pattern.slice(0, -2);
  return pattern === p;
}

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  let p = decodeURIComponent(url.pathname);
  if (p === '/app') { res.writeHead(308, { Location: '/app/' + url.search }); return res.end(); }
  const headers = {};
  for (const r of parseHeaders()) if (matches(r.pattern, p)) for (const [k, v] of r.headers) headers[k] = v;
  if (headers['Content-Security-Policy']) {
    if (NO_CSP) delete headers['Content-Security-Policy'];
    else if (MOCK) headers['Content-Security-Policy'] = headers['Content-Security-Policy'].replace(PROD_SUPABASE, MOCK);
  }
  let file = path.join(DOCS, p);
  if (!file.startsWith(DOCS)) { res.writeHead(403); return res.end(); }
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
  if (!fs.existsSync(file)) { res.writeHead(404, headers); return res.end('not found'); }
  let body = fs.readFileSync(file);
  if (MOCK && p === '/app/app.js') {
    const src = body.toString('utf8');
    const out = src.replace(`const SUPABASE_URL = '${PROD_SUPABASE}';`, `const SUPABASE_URL = '${MOCK}';`);
    if (out === src) { res.writeHead(500); return res.end('mock rewrite failed'); }
    body = Buffer.from(out);
  }
  headers['Content-Type'] = TYPES[path.extname(file)] || 'application/octet-stream';
  headers['Cache-Control'] = 'no-store';
  res.writeHead(200, headers); res.end(body);
}).listen(Number(process.env.PORT || 8788), '127.0.0.1');
