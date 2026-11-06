// LOCAL ONLY. Stand-in for Supabase PostgREST with hostile data in every field the page shows.
// Every payload, if it ever ran as HTML or script, sets window.__xss (checked by run_e2e.mjs).
import http from 'node:http';

const X = '<img src=x onerror="window.__xss=(window.__xss||0)+1">';
const S = '<script>window.__xss=(window.__xss||0)+1</script>';
const SVG = '<svg onload="window.__xss=(window.__xss||0)+1"></svg>';
export const PAYLOADS = [X, S, SVG];

const profiles = [{
  id: 'evil', name: 'Evil ' + X, role: 'python ' + S, industry: ['python ' + SVG], skills: ['python ' + X],
  offers: ['python ' + X], seeks: ['python ' + S], bio: X, linkedin_url: 'javascript:window.__xss=1'
}, { id: 'plain', name: 'Plain Person', role: 'Marketing', industry: ['SaaS'], skills: ['seo'], offers: ['marketing help'], seeks: [] }];
const feed = [{ id: 'p1', avatar_emoji: X, assistant_name: 'Bot ' + S, assistant_slug: 'bot' + SVG, human_name: X,
  content: 'Line one\n' + X + '\n' + S, tags: ['ai' + X, 'win'], comments_count: 2, published_at: '2026-11-05T10:00:00Z' }];
const reactions = [{ reaction: '🔥' }, { reaction: '🔥' }, { reaction: X }];
const assistants = [{ avatar_emoji: X, name: 'Asst ' + S, slug: 'asst' + SVG, bio: 'bio\n' + X, posts_count: 1,
  followers_count: 0, human_profile_id: X, is_active: true }];
const logs = [{ query: X, results_count: 0 }, { query: X, results_count: 0 }, { query: 'python', results_count: 2 }];

export const seen = [];
http.createServer((req, res) => {
  const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'apikey, authorization, accept-profile, content-profile, content-type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Content-Type': 'application/json' };
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
  let body = ''; req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const u = new URL(req.url, 'http://x'); seen.push(req.method + ' ' + u.pathname + u.search);
    const send = (o) => { res.writeHead(200, cors); res.end(JSON.stringify(o)); };
    if (req.headers.apikey !== 'sb_publishable_is3sCrJ6f6z_P1Up9IPjiQ_FuI9IUaB' || req.headers['accept-profile'] !== 'public') {
      res.writeHead(401, cors); return res.end('{}');
    }
    const t = u.pathname.replace('/rest/v1/', '');
    if (t === 'profiles') return send(profiles);
    if (t === 'assistant_feed') return send(feed);
    if (t === 'post_reactions') return send(reactions);
    if (t === 'assistant_profiles') return send(assistants);
    if (t === 'search_logs') return send(logs);
    if (t === 'rpc/get_email_status') return send({ found: true, name: 'N ' + X, has_email: true, email_verified: false });
    if (t === 'rpc/verify_email_token') {
      const b = JSON.parse(body || '{}');
      if (b.p_token === 'good-token') return send({ success: true, email: 'me@example.com' + X });
      return send({ success: false, error: 'Invalid ' + S });
    }
    res.writeHead(404, cors); res.end('{}');
  });
}).listen(Number(process.env.MOCK_PORT || 8790), '127.0.0.1');
