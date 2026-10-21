// Standalone, loopback-only HTTP smoke; no test runner, Firebase credentials,
// remote providers or deployments. Synthetic auth/adapters are confined here.
// Run: node --import tsx scripts/security-smoke.ts
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createConnection } from 'node:net';
import { createMeetingServer } from '../src/server.js';
import { defaultProviderConfig } from '../src/provider-config.js';
import { InMemoryMeetingBlobStore, InMemoryMeetingRepository } from '../src/repository.js';

const audio = readFileSync(new URL('../test/silence.flac', import.meta.url));
const config = {
  ...defaultProviderConfig,
  issuedAt: new Date(0).toISOString(), expiresAt: '2099-01-01T00:00:00.000Z',
  providers: defaultProviderConfig.providers.map(entry => ({ ...entry, enabled: true })),
};
const repository = new InMemoryMeetingRepository();
const blobs = new InMemoryMeetingBlobStore();
const segment = { id: 'segment-1', startMs: 0, endMs: 500, speakerIDs: [], text: 'Synthetic smoke transcript', isFinal: true, confidence: null };
let mode: 'success' | 'fail' | 'block' = 'success';
let calls = 0;
const entered = Promise.withResolvers<void>();
const release = Promise.withResolvers<void>();
const app = createMeetingServer({
  auth: {
    verifyIdToken: async token => { if (!['alice', 'bob'].includes(token)) throw new Error('TOKEN_SECRET'); return { uid: token }; },
    verifyAppCheckToken: async token => { if (token !== 'synthetic-app-check') throw new Error('APP_CHECK_SECRET'); },
  },
  repository, blobStore: blobs, providerConfig: config, logger: false,
  transcriptionAdapter: { transcribe: async () => {
    calls += 1;
    if (mode === 'fail') throw new Error('PROVIDER_SECRET');
    if (mode === 'block') { entered.resolve(); await release.promise; }
    return [segment];
  } },
  extractionAdapter: { extract: async () => ({ title: 'Synthetic meeting', summary: 'Synthetic summary', decisions: [], unresolvedQuestions: [], actionDrafts: [] }) },
});
const base = await app.listen({ host: '127.0.0.1', port: 0 });
const authHeaders = (owner = 'alice') => ({ authorization: `Bearer ${owner}`, 'x-firebase-appcheck': 'synthetic-app-check' });
async function request(path: string, method = 'GET', body?: unknown, owner = 'alice') {
  const response = await fetch(base + path, {
    method, headers: { ...authHeaders(owner), ...(body !== undefined && !(body instanceof FormData) ? { 'content-type': 'application/json' } : {}) },
    body: body instanceof FormData ? body : body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15_000),
  });
  return { status: response.status, body: await response.json() as Record<string, any> };
}
function manifest(bytes: Buffer) {
  return { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: createHash('sha256').update(bytes).digest('hex'), byteCount: bytes.length }] };
}
function form(id: string, bytes = audio) {
  const result = new FormData();
  const fields = { meetingId: id, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', disclosureVersionID: config.configurationVersion, partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '16000', meetingSampleCount: '16000', audioSha256: createHash('sha256').update(bytes).digest('hex') };
  for (const [key, value] of Object.entries(fields)) result.append(key, value);
  result.append('audio', new Blob([new Uint8Array(bytes)], { type: 'audio/flac' }), 'part.flac');
  return result;
}
async function prepare(bytes = audio) {
  const id = randomUUID();
  assert.equal((await request('/v1/meetings', 'POST', { meetingId: id, provider: 'google', disclosureVersionID: config.configurationVersion, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', sampleRate: 16000 })).status, 201);
  assert.equal((await request(`/v1/meetings/${id}/finalize-manifest`, 'POST', manifest(bytes))).status, 201);
  return id;
}
async function upgrade(headers: Record<string, string>) {
  const address = new URL(base);
  return new Promise<number>((resolve, reject) => {
    const socket = createConnection({ host: address.hostname, port: Number(address.port) }, () => {
      socket.write(`GET /v1/google/stream HTTP/1.1\r\nHost: ${address.host}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n${Object.entries(headers).map(([key, value]) => `${key}: ${value}\r\n`).join('')}\r\n`);
    });
    let response = '';
    socket.setTimeout(5_000, () => socket.destroy(new Error('UPGRADE_TIMEOUT')));
    socket.on('error', reject);
    socket.on('data', chunk => {
      response += chunk.toString();
      if (!response.includes('\r\n')) return;
      const match = /^HTTP\/1\.1 (\d{3}) /.exec(response);
      socket.destroy();
      if (!match) reject(new Error('INVALID_UPGRADE_RESPONSE')); else resolve(Number(match[1]));
    });
    socket.on('end', () => reject(new Error('UPGRADE_ENDED_WITHOUT_RESPONSE')));
  });
}
try {
  assert.equal(await upgrade({}), 401);
  assert.equal(await upgrade(authHeaders()), 503);
  const unauthenticated = await fetch(base + '/v1/meetings', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{' });
  assert.equal(unauthenticated.status, 401);
  await unauthenticated.arrayBuffer();
  const noAppCheck = await fetch(base + '/v1/provider-config', { headers: { authorization: 'Bearer alice' } });
  assert.equal(noAppCheck.status, 401); await noAppCheck.arrayBuffer();
  const malformed = await fetch(base + '/v1/meetings', { method: 'POST', headers: { ...authHeaders(), 'content-type': 'application/json' }, body: '{' });
  assert.equal(malformed.status, 400); await malformed.arrayBuffer();
  const prototype = await fetch(base + '/v1/meetings', { method: 'POST', headers: { ...authHeaders(), 'content-type': 'application/json' }, body: '{"__proto__":{"polluted":true}}' });
  assert.equal(prototype.status, 400); await prototype.arrayBuffer();
  assert.equal((await request('/v1/google/stream')).status, 503);

  const badBytes = Buffer.from('MIME is not proof of FLAC');
  const badId = await prepare(badBytes);
  assert.equal((await request('/v1/google/parts', 'POST', form(badId, badBytes))).status, 400);
  const truncated = form(badId, badBytes); truncated.set('timezoneIdentifier', 'a'.repeat(1025));
  assert.equal((await request('/v1/google/parts', 'POST', truncated)).status, 400);
  const duplicate = form(badId, badBytes); duplicate.append('meetingId', badId);
  assert.equal((await request('/v1/google/parts', 'POST', duplicate)).status, 400);
  const poisoned = form(badId, badBytes); poisoned.append('__proto__', 'x');
  assert.equal((await request('/v1/google/parts', 'POST', poisoned)).status, 400);
  const oversized = form(badId); oversized.set('audio', new Blob([new Uint8Array(23_000_001)], { type: 'audio/flac' }), 'oversized.flac');
  assert.equal((await request('/v1/google/parts', 'POST', oversized)).status, 413);

  const id = await prepare();
  assert.equal((await request(`/v1/meetings/${id}/finalize-manifest`, 'POST', manifest(audio), 'bob')).status, 404);
  const upload = await request('/v1/google/parts', 'POST', form(id));
  assert.equal(upload.status, 202); assert.equal(upload.body.status, 'awaiting_client_extraction');
  const replay = await request('/v1/google/parts', 'POST', form(id));
  assert.equal(replay.status, 200); assert.equal(replay.body.jobId, upload.body.jobId); assert.equal(calls, 1);
  assert.equal((await request(`/v1/jobs/${upload.body.jobId}`, 'GET', undefined, 'bob')).status, 404);
  const extractionBody = { transcriptionJobId: upload.body.jobId, transcriptRevision: 0, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', segments: [segment] };
  assert.equal((await request(`/v1/meetings/${id}/extractions`, 'POST', { ...extractionBody, transcriptRevision: 1 })).status, 409);
  const extraction = await request(`/v1/meetings/${id}/extractions`, 'POST', extractionBody);
  assert.equal(extraction.status, 202);
  assert.equal((await request(`/v1/jobs/${extraction.body.jobId}`)).body.status, 'ready');
  const extractionReplay = await request(`/v1/meetings/${id}/extractions`, 'POST', extractionBody);
  assert.equal(extractionReplay.body.jobId, extraction.body.jobId);

  mode = 'fail';
  const failedId = await prepare();
  const failed = await request('/v1/google/parts', 'POST', form(failedId));
  assert.equal(failed.status, 502); assert.equal(failed.body.errorCode, 'TRANSCRIPTION_FAILED');
  assert.ok(!JSON.stringify(failed.body).includes('PROVIDER_SECRET'));
  const failedJob = [...repository.jobs.values()].find(job => job.meetingId === failedId)!;
  assert.equal((await request(`/v1/jobs/${failedJob.jobId}`)).body.status, 'failed');

  mode = 'block';
  const raceId = await prepare();
  const pending = request('/v1/google/parts', 'POST', form(raceId));
  await Promise.race([entered.promise, pending.then(() => { throw new Error('UPLOAD_DID_NOT_REACH_PROVIDER'); })]);
  const raceJob = [...repository.jobs.values()].find(job => job.meetingId === raceId)!;
  const deleted = await request(`/v1/meetings/${raceId}`, 'DELETE');
  assert.equal(deleted.status, 202);
  release.resolve();
  assert.equal((await pending).status, 404);
  assert.equal((await request(`/v1/jobs/${raceJob.jobId}`)).status, 404);
  assert.equal((await request(`/v1/meetings/${raceId}`, 'DELETE')).body.deleteRequestedAt, deleted.body.deleteRequestedAt);
  assert.equal((await request(`/v1/deletions/${raceId}`, 'GET', undefined, 'bob')).status, 404);
  console.log('PASS: real loopback HTTP negative requests, owner isolation, idempotency, queued→handoff→ready/failed, deletion-versus-provider completion. Synthetic adapters only; Firebase/emulator/deployment not exercised.');
} finally {
  release.resolve();
  await app.close();
}
