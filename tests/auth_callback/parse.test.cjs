// Unit tests for docs/auth-callback.js (ROADMAP #21 points 5-8). No dependencies: node:test only.
// Run: node --test tests/auth_callback/   (also run from pytest: tests/test_auth_callback_js.py)
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const cb = require(path.join(__dirname, '../../docs/auth-callback.js'));

const NOW = 1_800_000_000;
const b64url = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
const jwt = (payload) => `${b64url({ alg: 'HS256', typ: 'JWT' })}.${b64url(payload)}.c2lnbmF0dXJl`;
const run = (hash) => cb.classify(cb.parseHashParams(hash), NOW);

test('valid-looking Supabase token -> success', () => {
  const t = jwt({ sub: 'user-1', exp: NOW + 3600 });
  assert.deepEqual(run(`#access_token=${t}&token_type=bearer&type=magiclink`), { view: 'success', errorCode: null });
});

test('junk access_token does not show success (#21 point 7)', () => {
  for (const junk of ['x', '', 'a.b', 'a.b.c', '%3Cimg%3E', jwt({ sub: 'u' }), jwt({ exp: NOW + 10 }),
    jwt({ sub: 'u', exp: NOW - 1 }), jwt({ sub: 'u', exp: '9999999999' }), 'e30.bm90LWpzb24.x']) {
    const r = run(`#access_token=${junk}`);
    assert.equal(r.view, 'error', `token ${JSON.stringify(junk)}`);
    assert.equal(r.errorCode, 'invalid_request');
  }
});

test('malformed % sequence does not throw (URIError) and gives a fixed error (#21 point 6)', () => {
  for (const h of ['#access_token=%E0%A4%A', '#error=%', '#%zz=1', '#error_description=%E0%A4%A&error=access_denied']) {
    let r;
    assert.doesNotThrow(() => { r = run(h); }, h);
    assert.deepEqual(r, { view: 'error', errorCode: 'invalid_request' }, h);
  }
  assert.equal(cb.safeDecode('%'), null);
  assert.equal(cb.safeDecode('a+b%20c'), 'a b c');
});

test('error_description is never used: only allowlisted codes (#21 point 5)', () => {
  const payload = encodeURIComponent('<img src=x onerror="document.title=1">Call +1-555 support now');
  assert.deepEqual(run(`#error=access_denied&error_code=otp_expired&error_description=${payload}`),
    { view: 'error', errorCode: 'otp_expired' });
  assert.deepEqual(run(`#error_code=${encodeURIComponent('<b>x</b>')}&error_description=${payload}`),
    { view: 'error', errorCode: 'default' });
  assert.deepEqual(run('#error=__proto__'), { view: 'error', errorCode: 'default' });
  assert.deepEqual(run('#error=toString'), { view: 'error', errorCode: 'default' });
  // the description shown comes only from the fixed table
  for (const k of Object.keys(cb.errorMessages)) assert.ok(!cb.errorMessages[k].description.includes('<'));
});

test('no params / unrelated params -> default view', () => {
  assert.deepEqual(run(''), { view: 'default', errorCode: null });
  assert.deepEqual(run('#'), { view: 'default', errorCode: null });
  assert.deepEqual(run('#foo=bar'), { view: 'default', errorCode: null });
});

test('oversized hash is rejected without parsing', () => {
  const r = cb.parseHashParams('#access_token=' + 'a'.repeat(10000));
  assert.equal(r.malformed, true);
  assert.equal(Object.keys(r.params).length, 0);
});

test('parser: first value wins, "=" inside value kept, __proto__ key does not pollute', () => {
  const r = cb.parseHashParams('#a=1&a=2&b=x=y&__proto__=z');
  assert.equal(r.params.a, '1');
  assert.equal(r.params.b, 'x=y');
  assert.equal(({}).z, undefined);
});
