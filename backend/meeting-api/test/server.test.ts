import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Writable } from 'node:stream';
import type { FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { createMeetingServer } from '../src/server.js';
import { InMemoryMeetingBlobStore, InMemoryMeetingRepository, type PartUploadRecord } from '../src/repository.js';
import type { ProviderConfig } from '../src/provider-config.js';

const meetingId = '123e4567-e89b-12d3-a456-426614174000';
const silence = readFileSync(new URL('./silence.flac', import.meta.url));
const validConfig: ProviderConfig = {
  configurationVersion: 'cfg-1', keyID: 'key-1', issuedAt: '2026-01-01T00:00:00.000Z', expiresAt: '2099-01-01T00:00:00.000Z', signature: 'sig',
  providers: [
    { provider: 'openAI', enabled: true, endpointClasses: ['realtime', 'parts'], documentationURLs: ['https://platform.openai.com/docs'], reviewedAt: '2026-01-01T00:00:00.000Z', processingRegion: 'global', paidTier: true, categoriesSent: ['audio', 'transcript'], appTemporaryRetentionHours: 24, providerRetentionStatementKey: 'openai-retention', trainingLoggingStatementKey: 'openai-training', termsURL: 'https://openai.com/policies/terms-of-use' },
    { provider: 'google', enabled: true, endpointClasses: ['stream', 'parts'], documentationURLs: ['https://cloud.google.com/speech-to-text'], reviewedAt: '2026-01-01T00:00:00.000Z', processingRegion: 'global', paidTier: true, categoriesSent: ['audio', 'transcript'], appTemporaryRetentionHours: 24, providerRetentionStatementKey: 'google-retention', trainingLoggingStatementKey: 'google-training', termsURL: 'https://ai.google.dev/gemini-api/terms' },
  ],
};

function auth() {
  return { verifyIdToken: async (token: string) => ({ uid: token }), verifyAppCheckToken: async (token: string) => { if (token !== 'app-check') throw new Error('invalid'); } };
}
function headers(token = 'user-a'): Record<string, string> { return { authorization: `Bearer ${token}`, 'x-firebase-appcheck': 'app-check' }; }
function createInput(provider: 'onDevice' | 'openAI' | 'google' = 'onDevice') { return { meetingId, provider, disclosureVersionID: 'cfg-1', languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', sampleRate: 16000 }; }
function multipart(fields: Record<string, string>, audio: Buffer): { payload: Buffer; contentType: string } {
  const boundary = 'meeting-test-boundary';
  const chunks: Buffer[] = [];
  for (const [name, value] of Object.entries(fields)) chunks.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`));
  chunks.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="part.flac"\r\nContent-Type: audio/flac\r\n\r\n`));
  chunks.push(audio);
  chunks.push(Buffer.from(`\r\n--${boundary}--\r\n`));
  return { payload: Buffer.concat(chunks), contentType: `multipart/form-data; boundary=${boundary}` };
}

async function prepareUpload(app: FastifyInstance, audio = silence) {
  const digest = createHash('sha256').update(audio).digest('hex');
  await app.inject({ method: 'POST', url: '/v1/meetings', headers: headers(), payload: createInput('google') });
  await app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/finalize-manifest`, headers: headers(), payload: { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: digest, byteCount: audio.length }] } });
  return multipart({ meetingId, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '16000', meetingSampleCount: '16000', audioSha256: digest }, audio);
}

const apps: Array<{ close(): Promise<void> }> = [];
afterEach(async () => { while (apps.length) await apps.pop()?.close(); });

describe('meeting Fastify API', () => {
  it('authenticates every route and exposes provider configuration without content logs', async () => {
    const app = createMeetingServer({ auth: auth(), providerConfig: validConfig, logger: false }); apps.push(app);
    const unauthorized = await app.inject({ method: 'GET', url: '/v1/provider-config' });
    expect(unauthorized.statusCode).toBe(401);
    const response = await app.inject({ method: 'GET', url: '/v1/provider-config', headers: headers() });
    expect(response.statusCode).toBe(200);
    expect(response.json().configurationVersion).toBe('cfg-1');
  });

  it('keeps meetings owner-scoped and makes create retries idempotent', async () => {
    const repository = new InMemoryMeetingRepository();
    const app = createMeetingServer({ auth: auth(), repository, logger: false }); apps.push(app);
    const created = await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers('alice'), 'content-type': 'application/json' }, payload: createInput() });
    expect(created.statusCode).toBe(201);
    const replay = await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers('alice'), 'content-type': 'application/json' }, payload: createInput() });
    expect(replay.statusCode).toBe(200);
    const conflict = await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers('alice'), 'content-type': 'application/json' }, payload: { ...createInput(), timezoneIdentifier: 'UTC' } });
    expect(conflict.statusCode).toBe(409);
    const otherDelete = await app.inject({ method: 'DELETE', url: `/v1/meetings/${meetingId}`, headers: headers('bob') });
    expect(otherDelete.statusCode).toBe(404);
  });

  it('freezes a manifest, validates multipart digests, and creates one stable transcription job', async () => {
    const repository = new InMemoryMeetingRepository();
    const blobStore = new InMemoryMeetingBlobStore();
    let transcriptionCalls = 0;
    const app = createMeetingServer({ auth: auth(), repository, blobStore, providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => { transcriptionCalls += 1; return []; } }, logger: false }); apps.push(app);
    const input = createInput('openAI');
    expect((await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers(), 'content-type': 'application/json' }, payload: input })).statusCode).toBe(201);
    const audio = silence;
    const digest = createHash('sha256').update(audio).digest('hex');
    const manifest = { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: digest, byteCount: audio.length }] };
    expect((await app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/finalize-manifest`, headers: { ...headers(), 'content-type': 'application/json' }, payload: manifest })).statusCode).toBe(201);
    const form = multipart({ meetingId, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '16000', meetingSampleCount: '16000', audioSha256: digest }, audio);
    const upload = await app.inject({ method: 'POST', url: '/v1/openai/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    expect(upload.statusCode).toBe(202);
    const storedPart = await repository.getPart('user-a', meetingId, 0);
    expect(storedPart?.objectRef).toBeTruthy();
    expect(blobStore.objects.get(storedPart?.objectRef ?? '')).toEqual(audio);
    expect(upload.json().status).toBe('awaiting_client_extraction');
    const badForm = multipart({ meetingId, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '16000', meetingSampleCount: '16000', audioSha256: 'b'.repeat(64) }, audio);
    const rejected = await app.inject({ method: 'POST', url: '/v1/openai/parts', headers: { ...headers(), 'content-type': badForm.contentType }, payload: badForm.payload });
    expect(rejected.statusCode).toBe(400);
    const replay = await app.inject({ method: 'POST', url: '/v1/openai/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    expect(replay.statusCode).toBe(200);
    expect(replay.json().jobId).toBe(upload.json().jobId);
    expect(transcriptionCalls).toBe(1);
  });

  it('deduplicates concurrent part uploads and removes the losing blob', async () => {
    class RacingRepository extends InMemoryMeetingRepository {
      private saves = 0;
      private readonly firstSave = Promise.withResolvers<void>();
      private readonly secondSave = Promise.withResolvers<void>();
      private readonly releaseSaves = Promise.withResolvers<void>();

      async waitForFirstSave() { await this.firstSave.promise; }
      async waitForSecondSave() { await this.secondSave.promise; }
      release() { this.releaseSaves.resolve(); }

      override async savePart(ownerUid: string, currentMeetingId: string, part: PartUploadRecord) {
        this.saves += 1;
        if (this.saves === 1) this.firstSave.resolve();
        if (this.saves === 2) this.secondSave.resolve();
        if (this.saves <= 2) await this.releaseSaves.promise;
        return super.savePart(ownerUid, currentMeetingId, part);
      }
    }
    const repository = new RacingRepository();
    const blobStore = new InMemoryMeetingBlobStore();
    let transcriptionCalls = 0;
    const app = createMeetingServer({ auth: auth(), repository, blobStore, providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => { transcriptionCalls += 1; return []; } }, logger: false }); apps.push(app);
    await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers(), 'content-type': 'application/json' }, payload: createInput('openAI') });
    const audio = silence;
    const digest = createHash('sha256').update(audio).digest('hex');
    const manifest = { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: digest, byteCount: audio.length }] };
    await app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/finalize-manifest`, headers: { ...headers(), 'content-type': 'application/json' }, payload: manifest });
    const form = multipart({ meetingId, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '16000', meetingSampleCount: '16000', audioSha256: digest }, audio);
    const first = app.inject({ method: 'POST', url: '/v1/openai/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    await repository.waitForFirstSave();
    const second = app.inject({ method: 'POST', url: '/v1/openai/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    await repository.waitForSecondSave();
    repository.release();
    const responses = await Promise.all([first, second]);
    expect(responses.map(response => response.statusCode).sort()).toEqual([200, 202]);
    expect(transcriptionCalls).toBe(1);
    expect(blobStore.objects.size).toBe(1);
  });

  it('rejects a manifest-valid retry when stored part digest conflicts', async () => {
    class ConflictingPartRepository extends InMemoryMeetingRepository {
      override async getPart(...args: Parameters<InMemoryMeetingRepository['getPart']>) {
        const part = await super.getPart(...args);
        return part ? { ...part, digest: '0'.repeat(64) } : undefined;
      }
    }
    const repository = new ConflictingPartRepository();
    const app = createMeetingServer({ auth: auth(), repository, providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => [] }, logger: false }); apps.push(app);
    await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers(), 'content-type': 'application/json' }, payload: createInput('openAI') });
    const audio = silence;
    const digest = createHash('sha256').update(audio).digest('hex');
    const manifest = { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: digest, byteCount: audio.length }] };
    await app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/finalize-manifest`, headers: { ...headers(), 'content-type': 'application/json' }, payload: manifest });
    await repository.savePart('user-a', meetingId, { partIndex: 0, digest, objectRef: 'stale-object', byteCount: audio.length, fields: { partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, meetingSampleCount: 16000 }, uploadedAt: new Date().toISOString() });
    const form = multipart({ meetingId, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '16000', meetingSampleCount: '16000', audioSha256: digest }, audio);
    const response = await app.inject({ method: 'POST', url: '/v1/openai/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    expect(response.statusCode).toBe(409);
    expect(response.json().errorCode).toBe('PART_DIGEST_CONFLICT');
  });

  it('accepts revisioned extraction only after transcription handoff and transitions jobs to ready', async () => {
    const repository = new InMemoryMeetingRepository();
    const baseSegment = { id: 'segment-1', startMs: 0, endMs: 500, speakerIDs: [], text: '민수님이 견적서를 보내주세요', isFinal: true, confidence: null };
    const app = createMeetingServer({ auth: auth(), repository, providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => [baseSegment] }, extractionAdapter: { extract: async () => ({ title: 'Meeting', summary: '', decisions: [], unresolvedQuestions: [], actionDrafts: [] }) }, logger: false }); apps.push(app);
    const input = createInput('google');
    await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers(), 'content-type': 'application/json' }, payload: input });
    const audio = silence; const digest = createHash('sha256').update(audio).digest('hex');
    const manifest = { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: digest, byteCount: audio.length }] };
    await app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/finalize-manifest`, headers: { ...headers(), 'content-type': 'application/json' }, payload: manifest });
    const form = multipart({ meetingId, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '16000', meetingSampleCount: '16000', audioSha256: digest }, audio);
    const upload = await app.inject({ method: 'POST', url: '/v1/google/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    const transcriptionJobId = upload.json().jobId as string;
    const extraction = await app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/extractions`, headers: { ...headers(), 'content-type': 'application/json' }, payload: { transcriptionJobId, transcriptRevision: 0, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', segments: [{ ...baseSegment, speakerIDs: ['speaker-1'] }] } });
    expect(extraction.statusCode).toBe(202);
    const job = await app.inject({ method: 'GET', url: `/v1/jobs/${extraction.json().jobId}`, headers: headers() });
    expect(job.statusCode).toBe(200);
    expect(job.json().status).toBe('ready');
    const changed = await app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/extractions`, headers: { ...headers(), 'content-type': 'application/json' }, payload: { transcriptionJobId, transcriptRevision: 0, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', segments: [{ id: 'segment-1', startMs: 0, endMs: 500, speakerIDs: [], text: '수정된 전사', isFinal: true, confidence: null }] } });
    expect(changed.statusCode).toBe(409);
  });

  it('records invalid provider output as a failed extraction job', async () => {
    const repository = new InMemoryMeetingRepository();
    const baseSegment = { id: 'segment-1', startMs: 0, endMs: 500, speakerIDs: [], text: '검증 대상 전사', isFinal: true, confidence: null };
    const extractionAdapter = { extract: async () => ({ title: '제목', summary: '요약', decisions: [], unresolvedQuestions: [], actionDrafts: [{ title: '잘못된 참조', notes: '', assignee: null, dueAtISO8601: null, sourceSegmentIDs: ['unknown-segment'], confidence: 0.5, requiresReview: true }] }) };
    const app = createMeetingServer({ auth: auth(), repository, providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => [baseSegment] }, extractionAdapter, logger: false }); apps.push(app);
    await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers(), 'content-type': 'application/json' }, payload: createInput('google') });
    const audio = silence; const digest = createHash('sha256').update(audio).digest('hex');
    const manifest = { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: digest, byteCount: audio.length }] };
    await app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/finalize-manifest`, headers: { ...headers(), 'content-type': 'application/json' }, payload: manifest });
    const form = multipart({ meetingId, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '16000', meetingSampleCount: '16000', audioSha256: digest }, audio);
    const upload = await app.inject({ method: 'POST', url: '/v1/google/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    const rejected = await app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/extractions`, headers: { ...headers(), 'content-type': 'application/json' }, payload: { transcriptionJobId: upload.json().jobId, transcriptRevision: 0, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', segments: [baseSegment] } });
    expect(rejected.statusCode).toBe(502);
    const extractionJob = [...repository.jobs.values()].find(job => job.meetingId === meetingId && job.stage === 'extraction');
    expect(extractionJob?.jobId).toBeTruthy();
    const job = await app.inject({ method: 'GET', url: `/v1/jobs/${extractionJob?.jobId}`, headers: headers() });
    expect(job.json()).toMatchObject({ status: 'failed', errorCode: 'INVALID_PROVIDER_RESULT' });
  });

  it('creates an idempotent deletion receipt and hides the meeting', async () => {
    const repository = new InMemoryMeetingRepository();
    const app = createMeetingServer({ auth: auth(), repository, logger: false }); apps.push(app);
    await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers(), 'content-type': 'application/json' }, payload: createInput() });
    const deleted = await app.inject({ method: 'DELETE', url: `/v1/meetings/${meetingId}`, headers: headers() });
    expect(deleted.statusCode).toBe(202);
    expect(deleted.json().applicationVisibleStateDeleted).toBe(true);
    const replay = await app.inject({ method: 'DELETE', url: `/v1/meetings/${meetingId}`, headers: headers() });
    expect(replay.json().deleteRequestedAt).toBe(deleted.json().deleteRequestedAt);
    const status = await app.inject({ method: 'GET', url: `/v1/deletions/${meetingId}`, headers: headers() });
    expect(status.statusCode).toBe(200);
    const recreate = await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers(), 'content-type': 'application/json' }, payload: createInput() });
    expect(recreate.statusCode).toBe(409);
  });
});

describe('meeting API security boundaries', () => {
  it('authenticates before parsing and rejects malformed/prototype JSON safely', async () => {
    const app = createMeetingServer({ auth: auth(), logger: false }); apps.push(app);
    const malformed = { method: 'POST' as const, url: '/v1/meetings', headers: { 'content-type': 'application/json' }, payload: '{' };
    expect((await app.inject(malformed)).statusCode).toBe(401);
    expect((await app.inject({ ...malformed, headers: { ...malformed.headers, ...headers() } })).statusCode).toBe(400);
    const prototype = JSON.stringify(createInput()).replace(/}$/, ',"__proto__":{"polluted":true}}');
    expect((await app.inject({ ...malformed, headers: { ...malformed.headers, ...headers() }, payload: prototype })).statusCode).toBe(400);
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
    expect((await app.inject({ method: 'GET', url: '/v1/provider-config', headers: { authorization: 'Bearer user-a' } })).statusCode).toBe(401);
  });

  it('fails closed for default providers, missing adapters and websocket upgrades', async () => {
    const disabled = createMeetingServer({ auth: auth(), logger: false }); apps.push(disabled);
    expect((await disabled.inject({ method: 'POST', url: '/v1/meetings', headers: headers(), payload: createInput('google') })).statusCode).toBe(503);
    const app = createMeetingServer({ auth: auth(), providerConfig: validConfig, logger: false }); apps.push(app);
    expect((await app.inject({ method: 'POST', url: '/v1/google/parts', headers: headers() })).statusCode).toBe(503);
    await app.ready();
    await expect(app.injectWS('/v1/google/stream')).rejects.toThrow('401');
    await expect(app.injectWS('/v1/google/stream?token=user-a&appCheck=app-check')).rejects.toThrow('401');
    await expect(app.injectWS('/v1/google/stream', { headers: headers() })).rejects.toThrow('503');
  });

  it('does not serialize credentials, content or URL queries with custom logging', async () => {
    let output = '';
    const stream = new Writable({ write(chunk, _encoding, done) { output += chunk.toString(); done(); } });
    const app = createMeetingServer({ auth: auth(), logger: { level: 'info', stream, serializers: { req: request => ({ headers: request.headers, body: request.body, url: request.url }) } } }); apps.push(app);
    await app.inject({ method: 'POST', url: '/v1/meetings?token=query-secret', headers: { ...headers('identity-secret'), 'x-firebase-appcheck': 'app-check-secret' }, payload: { secret: 'body-secret' } });
    for (const secret of ['identity-secret', 'app-check-secret', 'query-secret', 'body-secret']) expect(output).not.toContain(secret);
  });

  it('rejects MIME-spoofed audio, duplicate/prototype and truncated multipart fields', async () => {
    const app = createMeetingServer({ auth: auth(), providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => [] }, logger: false }); apps.push(app);
    const invalid = await prepareUpload(app, Buffer.from('not-flac'));
    expect((await app.inject({ method: 'POST', url: '/v1/google/parts', headers: { ...headers(), 'content-type': invalid.contentType }, payload: invalid.payload })).statusCode).toBe(400);
    for (const field of ['__proto__', 'meetingId', 'timezoneIdentifier']) {
      const boundary = 'meeting-test-boundary';
      const extra = Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${field}"\r\n\r\n${field === 'timezoneIdentifier' ? 'a'.repeat(1025) : 'x'}\r\n`);
      const response = await app.inject({ method: 'POST', url: '/v1/google/parts', headers: { ...headers(), 'content-type': invalid.contentType }, payload: Buffer.concat([extra, invalid.payload]) });
      expect(response.statusCode).toBe(400);
    }
  });

  it('does not complete a deleted job or expose it to another owner', async () => {
    const entered = Promise.withResolvers<void>();
    const release = Promise.withResolvers<void>();
    const repository = new InMemoryMeetingRepository();
    const blobStore = new InMemoryMeetingBlobStore();
    const app = createMeetingServer({ auth: auth(), repository, blobStore, providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => { entered.resolve(); await release.promise; return []; } }, logger: false }); apps.push(app);
    const form = await prepareUpload(app);
    const pending = app.inject({ method: 'POST', url: '/v1/google/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    await entered.promise;
    const jobId = [...repository.jobs.values()][0].jobId;
    expect((await app.inject({ method: 'GET', url: `/v1/jobs/${jobId}`, headers: headers('other-owner') })).statusCode).toBe(404);
    expect((await app.inject({ method: 'DELETE', url: `/v1/meetings/${meetingId}`, headers: headers() })).statusCode).toBe(202);
    release.resolve();
    expect((await pending).statusCode).toBe(404);
    expect((await app.inject({ method: 'GET', url: `/v1/jobs/${jobId}`, headers: headers() })).statusCode).toBe(404);
    expect(blobStore.objects.size).toBe(0);
  });

  it('cleans up an upload that finishes writing after deletion', async () => {
    const entered = Promise.withResolvers<void>();
    const release = Promise.withResolvers<void>();
    class DelayedBlobStore extends InMemoryMeetingBlobStore {
      override async put(...args: Parameters<InMemoryMeetingBlobStore['put']>) { entered.resolve(); await release.promise; return super.put(...args); }
    }
    const blobStore = new DelayedBlobStore();
    const app = createMeetingServer({ auth: auth(), blobStore, providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => [] }, logger: false }); apps.push(app);
    const form = await prepareUpload(app);
    const pending = app.inject({ method: 'POST', url: '/v1/google/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    await entered.promise;
    expect((await app.inject({ method: 'DELETE', url: `/v1/meetings/${meetingId}`, headers: headers() })).statusCode).toBe(202);
    release.resolve();
    expect((await pending).statusCode).toBe(404);
    expect(blobStore.objects.size).toBe(0);
  });
});

describe('meeting provider result and revision boundaries', () => {
  it('fails the transcription job on invalid adapter output without returning provider content', async () => {
    const repository = new InMemoryMeetingRepository();
    const app = createMeetingServer({ auth: auth(), repository, providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => [{ id: 'bad', startMs: 0, endMs: 1001, speakerIDs: [], text: 'provider-private-content', isFinal: true, confidence: null }] }, logger: false }); apps.push(app);
    const form = await prepareUpload(app);
    const response = await app.inject({ method: 'POST', url: '/v1/google/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    expect(response.statusCode).toBe(502);
    expect(response.json().errorCode).toBe('INVALID_PROVIDER_RESULT');
    expect(response.body).not.toContain('provider-private-content');
    expect([...repository.jobs.values()][0].status).toBe('failed');
  });

  it('requires revision zero first and preserves old exact replays after a newer revision', async () => {
    const baseSegment = { id: 'segment-1', startMs: 0, endMs: 500, speakerIDs: [], text: 'base', isFinal: true, confidence: null };
    const app = createMeetingServer({ auth: auth(), providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => [baseSegment] }, extractionAdapter: { extract: async () => ({ title: '', summary: '', decisions: [], unresolvedQuestions: [], actionDrafts: [] }) }, logger: false }); apps.push(app);
    const form = await prepareUpload(app);
    const upload = await app.inject({ method: 'POST', url: '/v1/google/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    const payload = { transcriptionJobId: upload.json().jobId, transcriptRevision: 0, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', segments: [baseSegment] };
    const extract = (body: typeof payload) => app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/extractions`, headers: headers(), payload: body });
    expect((await extract({ ...payload, transcriptRevision: 1 })).statusCode).toBe(409);
    expect((await extract({ ...payload, segments: [{ ...baseSegment, isFinal: false }] })).statusCode).toBe(409);
    const first = await extract(payload);
    expect(first.statusCode).toBe(202);
    expect((await extract({ ...payload, transcriptRevision: 1, segments: [{ ...baseSegment, text: 'edited' }] })).statusCode).toBe(202);
    const replay = await extract(payload);
    expect(replay.statusCode).toBe(202);
    expect(replay.json().jobId).toBe(first.json().jobId);
  });
});
