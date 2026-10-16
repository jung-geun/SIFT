import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { afterEach, before, beforeEach, test } from 'node:test';
import { build } from 'esbuild';
import { Miniflare } from 'miniflare';
import { assertFreeSubscriptions, assertProductionConfig } from '../scripts/free-guard.mjs';

let script;
let mf;
let db;
const adminToken = randomBytes(32).toString('hex');
const networkSecret = randomBytes(32).toString('hex');
const origin = 'https://sift.pieroot.xyz';
const app = { version: '1.0.10', build: '6', platform: 'iOS', osVersion: '27.0', language: 'en' };
const payload = (extra = {}) => ({ schemaVersion: 1, submissionID: randomUUID(), kind: 'bug', title: ' Report ', message: ' Something happened. ', app, ...extra });
const auth = { Authorization: `Bearer ${adminToken}`, Origin: origin };

function runtimeOptions(bindings = { ADMIN_TOKEN: adminToken, NETWORK_HMAC_SECRET: networkSecret, INTAKE_ENABLED: 'true', ENVIRONMENT: 'production' }) {
  return { workers: [{ config: {
    name: 'feedback-test', compatibilityDate: '2026-01-14',
    manifest: { mainModule: 'worker.mjs', modules: { 'worker.mjs': { type: 'esm', contents: script } } },
    env: { DB: { type: 'd1', id: 'feedback-test' }, ...Object.fromEntries(Object.entries(bindings).map(([key, value]) => [key, { type: 'text', value }])) },
  } }] };
}

before(async () => {
  const result = await build({ entryPoints: [new URL('../src/index.ts', import.meta.url).pathname], bundle: true, write: false, format: 'esm', target: 'es2022' });
  script = result.outputFiles[0].text;
});
beforeEach(async () => {
  mf = new Miniflare(runtimeOptions());
  db = await mf.getD1Database('DB');
  const migration = await readFile(new URL('../migrations/0001_feedback.sql', import.meta.url), 'utf8');
  // Complete SQL statements, including trigger bodies, go through the actual D1
  // binding. This deliberately does not mock quotas, transactions or SQL.
  let statement = '';
  let trigger = false;
  for (const raw of migration.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('--')) continue;
    if (line.startsWith('CREATE TRIGGER')) trigger = true;
    statement += `${line}\n`;
    if ((!trigger && line.endsWith(';')) || (trigger && line === 'END;')) {
      await db.prepare(statement).run();
      statement = ''; trigger = false;
    }
  }
  assert.equal(statement, '');
});
afterEach(async () => { await mf?.dispose(); });
async function send(value = payload(), ip = '203.0.113.7') {
  return mf.dispatchFetch('https://feedback.test/v1/feedback', { method: 'POST', headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': ip }, body: JSON.stringify(value) });
}
async function getDetail(id, headers = auth) { return mf.dispatchFetch(`https://feedback.test/v1/admin/feedback/${id}`, { headers }); }
async function update(id, value) {
  return mf.dispatchFetch(`https://feedback.test/v1/admin/feedback/${id}`, { method: 'PATCH', headers: { ...auth, 'Content-Type': 'application/json' }, body: JSON.stringify(value) });
}
async function total() { return (await db.prepare('SELECT count(*) AS count FROM feedback').first()).count; }

test('durably acknowledges one report, preserves exact private diagnostic text and never lists body', async () => {
  const diagnosticText = '{\n  "message": "한글 😀", "order": [2, 1]\n}\n';
  const request = payload({ diagnostics: diagnosticText });
  const created = await send(request);
  assert.equal(created.status, 201);
  assert.equal(created.headers.get('Cache-Control'), 'no-store');
  const receipt = await created.json();
  assert.match(receipt.ticketID, /^[0-9a-f-]{36}$/);
  assert.equal(new Date(receipt.receivedAt).toISOString(), receipt.receivedAt);
  const stored = await db.prepare('SELECT diagnostics,day,network_hash FROM feedback').first();
  assert.equal(stored.diagnostics, diagnosticText);
  assert.equal(stored.day, null);
  assert.equal(stored.network_hash, null);
  const detail = await (await getDetail(receipt.ticketID)).json();
  assert.equal(detail.title, 'Report');
  assert.equal(detail.message, 'Something happened.');
  assert.equal(detail.diagnostics, diagnosticText);
  assert.equal(detail.notes, '');
  assert.equal(detail.status, 'new');
  const list = await mf.dispatchFetch('https://feedback.test/v1/admin/feedback', { headers: auth });
  const items = (await list.json()).items;
  assert.equal(items[0].hasDiagnostics, true);
  for (const key of ['diagnostics', 'message', 'notes', 'submissionID', 'payload_hash', 'network_hash']) assert.equal(Object.hasOwn(items[0], key), false);
});

test('diagnostics honor the SQLite nesting boundary without counting quoted brackets', async () => {
  const leaf = JSON.stringify('quoted braces { [ and escaped quote " then backslash \\');
  const diagnostics = '{"nested":' + '['.repeat(999) + leaf + ']'.repeat(999) + '}';
  const accepted = await send(payload({ diagnostics }));
  assert.equal(accepted.status, 201);
  assert.equal((await (await getDetail((await accepted.json()).ticketID)).json()).diagnostics, diagnostics);
  const rejected = await send(payload({ diagnostics: '{"nested":' + '['.repeat(1000) + '0' + ']'.repeat(1000) + '}' }));
  assert.equal(rejected.status, 400);
  assert.deepEqual(await rejected.json(), { errorCode: 'INVALID_REQUEST' });
  assert.equal(await total(), 1);
  assert.equal((await db.prepare('SELECT accepted FROM daily_global').first()).accepted, 1);
});

test('concurrent identical submissions consume exactly one quota and return one receipt', async () => {
  const value = payload();
  const responses = await Promise.all(Array.from({ length: 12 }, () => send(value)));
  assert.equal(responses.filter(result => result.status === 201).length, 1);
  assert.equal(responses.filter(result => result.status === 200).length, 11);
  const receipts = await Promise.all(responses.map(result => result.json()));
  assert.equal(new Set(receipts.map(receipt => JSON.stringify(receipt))).size, 1);
  assert.equal(await total(), 1);
  assert.equal((await db.prepare('SELECT accepted FROM daily_global').first()).accepted, 1);
  const conflict = await send({ ...value, message: 'Changed content' });
  assert.equal(conflict.status, 409);
  assert.deepEqual(await conflict.json(), { errorCode: 'SUBMISSION_CONFLICT' });
});

test('canonical field order and trimmed input replay, but exact diagnostic bytes participate in identity', async () => {
  const value = payload({ diagnostics: '{ "x": 1 }' });
  const first = await (await send(value)).json();
  const reordered = { app: { language: 'en', osVersion: '27.0', platform: 'iOS', build: '6', version: '1.0.10' }, message: value.message.trim(), title: value.title.trim(), kind: value.kind, submissionID: value.submissionID, schemaVersion: 1, diagnostics: value.diagnostics };
  const replay = await send(reordered);
  assert.equal(replay.status, 200);
  assert.deepEqual(await replay.json(), first);
  assert.equal((await send({ ...value, diagnostics: '{"x":1}' })).status, 409);
});

test('network quota is race-safe and replays still work at full quota', async () => {
  const initial = payload();
  assert.equal((await send(initial)).status, 201);
  const responses = await Promise.all(Array.from({ length: 15 }, () => send()));
  assert.equal(responses.filter(result => result.status === 201).length, 9);
  assert.equal(responses.filter(result => result.status === 429).length, 6);
  const rejected = responses.find(result => result.status === 429);
  assert.ok(Number(rejected.headers.get('Retry-After')) > 0);
  assert.deepEqual(await rejected.json(), { errorCode: 'RATE_LIMITED' });
  assert.equal(await total(), 10);
  assert.equal((await send(initial)).status, 200);
  assert.equal((await send(payload(), '203.0.113.8')).status, 201);
  const network = await db.prepare('SELECT network_hash FROM daily_network LIMIT 1').first();
  assert.match(network.network_hash, /^[0-9a-f]{64}$/);
  assert.notEqual(network.network_hash, '203.0.113.7');
});

test('global quota admits exactly remaining capacity across racing networks and delete does not refund quota', async () => {
  const day = new Date().toISOString().slice(0, 10);
  await db.prepare('INSERT INTO daily_global(day,accepted) VALUES (?,98)').bind(day).run();
  const responses = await Promise.all(Array.from({ length: 8 }, (_, index) => send(payload(), `198.51.100.${index + 1}`)));
  assert.equal(responses.filter(result => result.status === 201).length, 2);
  assert.equal(responses.filter(result => result.status === 429).length, 6);
  assert.equal((await db.prepare('SELECT accepted FROM daily_global').first()).accepted, 100);
  const id = (await responses.find(result => result.status === 201).json()).ticketID;
  assert.equal((await mf.dispatchFetch(`https://feedback.test/v1/admin/feedback/${id}`, { method: 'DELETE', headers: auth })).status, 204);
  assert.equal((await send(payload(), '192.0.2.5')).status, 429);
});

test('retained-content cap is atomic, rolls back quota and includes note updates', async () => {
  const max = 104857600;
  const firstPayload = payload();
  const accepted = await (await send(firstPayload)).json();
  await db.prepare('UPDATE storage_usage SET retained_bytes=?').bind(max - 1).run();
  const deniedUpdate = await update(accepted.ticketID, { status: 'resolved', notes: '😀' });
  assert.equal(deniedUpdate.status, 503);
  assert.deepEqual(await deniedUpdate.json(), { errorCode: 'CAPACITY_REACHED' });
  assert.equal((await (await getDetail(accepted.ticketID)).json()).status, 'new');
  const responses = await Promise.all(Array.from({ length: 6 }, (_, index) => send(payload(), `192.0.2.${index + 1}`)));
  for (const result of responses) { assert.equal(result.status, 503); assert.deepEqual(await result.json(), { errorCode: 'CAPACITY_REACHED' }); }
  assert.equal(await total(), 1);
  assert.equal((await db.prepare('SELECT accepted FROM daily_global').first()).accepted, 1);
  assert.equal((await send(firstPayload)).status, 200);
});

test('simultaneous last-slot storage admissions admit only one report', async () => {
  const value = payload();
  // Canonical validator trims only title and message in this fixture.
  const bytes = Buffer.byteLength(JSON.stringify({ ...value, title: value.title.trim(), message: value.message.trim() }));
  await db.prepare('UPDATE storage_usage SET retained_bytes=?').bind(104857600 - bytes - 1024).run();
  const responses = await Promise.all(Array.from({ length: 5 }, (_, index) => send({ ...value, submissionID: randomUUID() }, `192.0.2.${index + 1}`)));
  assert.equal(responses.filter(result => result.status === 201).length, 1);
  assert.equal(responses.filter(result => result.status === 503).length, 4);
  assert.equal((await db.prepare('SELECT retained_bytes FROM storage_usage').first()).retained_bytes, 104857600);
});

test('strict schema rejects extras, invalid Unicode, excessive code points and feature attachments without persistence', async () => {
  const cases = [payload({ email: 'not accepted' }), payload({ schemaVersion: 2 }), payload({ submissionID: randomUUID().toUpperCase() }), payload({ title: '  ' }), payload({ title: '😀'.repeat(121) }), payload({ message: '\ud800' }), payload({ app: { ...app, token: 'not accepted' } }), payload({ diagnostics: '[]' }), payload({ diagnostics: 'not JSON' }), payload({ kind: 'feature', diagnostics: '{}' }), payload({ diagnostics: null })];
  for (const value of cases) {
    const result = await send(value);
    assert.equal(result.status, 400);
    assert.deepEqual(await result.json(), { errorCode: 'INVALID_REQUEST' });
  }
  assert.equal(await total(), 0);
  assert.equal((await send(payload({ kind: 'feature', title: '😀'.repeat(120), message: 'a'.repeat(8000) }))).status, 201);
});

test('body and attachment byte limits reject streamed oversize even without Content-Length', async () => {
  const attachment = await send(payload({ diagnostics: JSON.stringify({ value: '한'.repeat(180000) }) }));
  assert.equal(attachment.status, 413);
  const result = await mf.dispatchFetch('https://feedback.test/v1/feedback', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '203.0.113.7' },
    body: new ReadableStream({ start(controller) { for (let index = 0; index < 13; ++index) controller.enqueue(new Uint8Array(65536).fill(32)); controller.close(); } }), duplex: 'half',
  });
  assert.equal(result.status, 413);
  assert.deepEqual(await result.json(), { errorCode: 'REQUEST_TOO_LARGE' });
  assert.equal(await total(), 0);
});

test('invalid UTF-8, compressed bodies and wrong content type never persist', async () => {
  for (const [headers, body] of [
    [{ 'Content-Type': 'application/json' }, new Uint8Array([0xff])],
    [{ 'Content-Type': 'text/plain' }, JSON.stringify(payload())],
    [{ 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' }, JSON.stringify(payload())],
  ]) {
    const result = await mf.dispatchFetch('https://feedback.test/v1/feedback', { method: 'POST', headers, body });
    assert.equal(result.status, 400);
  }
  assert.equal(await total(), 0);
});

test('admin authenticates before enumeration; public callers cannot retrieve content', async () => {
  const receipt = await (await send()).json();
  for (const path of ['/v1/admin/feedback', `/v1/admin/feedback/${receipt.ticketID}`, '/v1/admin/feedback/not-a-uuid']) {
    for (const Authorization of ['', 'Bearer wrong', `Basic ${adminToken}`]) {
      const result = await mf.dispatchFetch(`https://feedback.test${path}`, { headers: { Authorization } });
      assert.equal(result.status, 401);
      assert.deepEqual(await result.json(), { errorCode: 'UNAUTHORIZED' });
    }
  }
  assert.equal((await mf.dispatchFetch(`https://feedback.test/v1/feedback/${receipt.ticketID}`)).status, 404);
  assert.equal((await getDetail(randomUUID())).status, 404);
});

test('admin updates are atomic last-committed-wins; deletion releases bytes and is persistent', async () => {
  const receipt = await (await send()).json();
  const before = (await db.prepare('SELECT retained_bytes FROM storage_usage').first()).retained_bytes;
  const versions = [{ status: 'in_progress', notes: '첫 번째' }, { status: 'resolved', notes: 'Second 😀' }];
  const updates = await Promise.all(versions.map(version => update(receipt.ticketID, version)));
  for (let index = 0; index < updates.length; ++index) {
    assert.equal(updates[index].status, 200);
    const own = await updates[index].json();
    assert.equal(own.status, versions[index].status);
    assert.equal(own.notes, versions[index].notes);
  }
  const final = await (await getDetail(receipt.ticketID)).json();
  assert.ok(versions.some(version => version.status === final.status && version.notes === final.notes));
  assert.equal((await db.prepare('SELECT retained_bytes FROM storage_usage').first()).retained_bytes, before + Buffer.byteLength(final.notes));
  assert.equal((await update(receipt.ticketID, { status: 'new', notes: 'x'.repeat(8001) })).status, 400);
  assert.equal((await mf.dispatchFetch(`https://feedback.test/v1/admin/feedback/${receipt.ticketID}`, { method: 'DELETE', headers: auth })).status, 204);
  assert.equal((await getDetail(receipt.ticketID)).status, 404);
  assert.equal(await total(), 0);
  assert.equal((await db.prepare('SELECT retained_bytes FROM storage_usage').first()).retained_bytes, 0);
});

test('keyset pagination is bounded and deterministic under timestamp ties and concurrent inserts', async () => {
  const ids = [];
  for (let index = 0; index < 5; ++index) ids.push((await (await send(payload({ title: `Report ${index}` }))).json()).ticketID);
  await db.prepare('UPDATE feedback SET received_at=?').bind(new Date(Date.now() - 86400000).toISOString()).run();
  const page1 = await (await mf.dispatchFetch('https://feedback.test/v1/admin/feedback?limit=2', { headers: auth })).json();
  assert.equal(page1.items.length, 2);
  assert.ok(page1.nextCursor);
  await send(payload({ title: 'Newer concurrent report' }));
  const page2 = await (await mf.dispatchFetch(`https://feedback.test/v1/admin/feedback?limit=2&cursor=${page1.nextCursor}`, { headers: auth })).json();
  const page3 = await (await mf.dispatchFetch(`https://feedback.test/v1/admin/feedback?limit=2&cursor=${page2.nextCursor}`, { headers: auth })).json();
  assert.equal(page3.nextCursor, null);
  const all = [...page1.items, ...page2.items, ...page3.items];
  assert.equal(new Set(all.map(item => item.ticketID)).size, 5);
  assert.deepEqual(all.map(item => item.ticketID), ids.sort().reverse());
  const wrongFilter = await mf.dispatchFetch(`https://feedback.test/v1/admin/feedback?status=new&cursor=${page1.nextCursor}`, { headers: auth });
  assert.equal(wrongFilter.status, 400);
  for (const query of ['limit=51', 'limit=0', 'status=unknown', 'cursor=bad!', 'limit=2&limit=3', 'extra=1']) assert.equal((await mf.dispatchFetch(`https://feedback.test/v1/admin/feedback?${query}`, { headers: auth })).status, 400);
});

test('CORS permits only production origin, never credential cookies or untrusted origin', async () => {
  for (const Origin of ['https://evil.test', 'https://sift.pieroot.xyz.evil.test', 'null', 'http://localhost:4000']) {
    const result = await mf.dispatchFetch('https://feedback.test/v1/admin/feedback', { headers: { ...auth, Origin } });
    assert.equal(result.status, 403);
    assert.equal(result.headers.get('Access-Control-Allow-Origin'), null);
    assert.equal(result.headers.get('Vary'), 'Origin');
  }
  const preflight = await mf.dispatchFetch('https://feedback.test/v1/admin/feedback', { method: 'OPTIONS', headers: { Origin: origin, 'Access-Control-Request-Method': 'PATCH', 'Access-Control-Request-Headers': 'authorization,content-type' } });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('Access-Control-Allow-Origin'), origin);
  assert.equal(preflight.headers.get('Access-Control-Allow-Credentials'), null);
  const publicAuthPreflight = await mf.dispatchFetch('https://feedback.test/v1/feedback', { method: 'OPTIONS', headers: { Origin: origin, 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'authorization' } });
  assert.equal(publicAuthPreflight.status, 400);
});

test('emergency switch closes intake but leaves authenticated admin usable', async () => {
  const receipt = await (await send()).json();
  await mf.setOptions(runtimeOptions({ ADMIN_TOKEN: adminToken, NETWORK_HMAC_SECRET: networkSecret, INTAKE_ENABLED: 'false', ENVIRONMENT: 'production' }));
  assert.equal((await send()).status, 503);
  assert.equal((await mf.dispatchFetch('https://feedback.test/health')).status, 503);
  assert.equal((await getDetail(receipt.ticketID)).status, 200);
});

test('expired content is unavailable before daily pruning; pruning releases storage and old HMAC buckets', async () => {
  const receipt = await (await send()).json();
  const yesterday = new Date(Date.now() - 86400000).toISOString();
  await db.prepare('UPDATE feedback SET expires_at=?').bind(yesterday).run();
  assert.equal((await getDetail(receipt.ticketID)).status, 404);
  assert.equal((await (await mf.dispatchFetch('https://feedback.test/v1/admin/feedback', { headers: auth })).json()).items.length, 0);
  await db.prepare("INSERT INTO daily_network(day,network_hash,accepted) VALUES('2000-01-01','expired',1)").run();
  await db.prepare("INSERT INTO daily_global(day,accepted) VALUES('2000-01-01',1)").run();
  const worker = await mf.getWorker();
  await worker.scheduled({ cron: '0 0 * * *' });
  assert.equal(await total(), 0);
  assert.equal((await db.prepare('SELECT retained_bytes FROM storage_usage').first()).retained_bytes, 0);
  assert.equal(await db.prepare("SELECT * FROM daily_network WHERE day='2000-01-01'").first(), null);
  assert.equal(await db.prepare("SELECT * FROM daily_global WHERE day='2000-01-01'").first(), null);
});

test('missing secrets fail closed and health leaks no private configuration', async () => {
  const healthy = await mf.dispatchFetch('https://feedback.test/health');
  assert.deepEqual(await healthy.json(), { status: 'ok' });
  await mf.setOptions(runtimeOptions({ INTAKE_ENABLED: 'true' }));
  assert.equal((await send()).status, 503);
  assert.equal((await mf.dispatchFetch('https://feedback.test/v1/admin/feedback', { headers: auth })).status, 503);
});

test('Free-only guard refuses unknown, paid, discounted, incomplete and unprovisioned configurations', () => {
  const free = { success: true, errors: [], result: [], result_info: { count: 0, total_count: 0 } };
  assert.doesNotThrow(() => assertFreeSubscriptions(free));
  for (const value of [null, {}, { ...free, success: false }, { ...free, result_info: undefined }, { ...free, result_info: { count: 0, total_count: 1 } }, { ...free, result: [{ price: 0, rate_plan: { id: 'free' } }] }, { ...free, errors: [{ code: 10000 }] }]) assert.throws(() => assertFreeSubscriptions(value));
  const teams = { price: 0, currency: 'USD', trial: null, rate_plan: { id: 'teams_free', currency: 'USD', scope: 'account', is_contract: false, externally_managed: false }, product: { name: 'prod_teams' }, component_values: [{ name: 'users', value: 50 }] };
  const withTeams = { ...free, result: [teams], result_info: { count: 1, total_count: 1, next_page: false } };
  assert.doesNotThrow(() => assertFreeSubscriptions(withTeams));
  for (const changed of [
    { ...teams, price: 5 }, { ...teams, trial: {} }, { ...teams, product: { name: 'workers' } },
    { ...teams, rate_plan: { ...teams.rate_plan, id: 'workers_paid' } },
    { ...teams, rate_plan: { ...teams.rate_plan, is_contract: true } },
    { ...teams, component_values: [...teams.component_values, { name: 'addon', value: 1 }] },
  ]) assert.throws(() => assertFreeSubscriptions({ ...withTeams, result: [changed] }));
  assert.throws(() => assertFreeSubscriptions({ ...withTeams, result_info: { count: 1, total_count: 2, next_page: true } }));
  assert.throws(() => assertFreeSubscriptions({ ...withTeams, result: [teams, { price: 0, rate_plan: { id: 'workers_paid' } }], result_info: { count: 2, total_count: 2 } }));
  assert.throws(() => assertProductionConfig({ name: 'sift-feedback-api', d1_databases: [{ binding: 'DB' }] }, 'a'.repeat(32)));
});
