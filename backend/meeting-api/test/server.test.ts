import { createHash } from 'node:crypto';
import { afterEach, describe, expect, it } from 'vitest';
import { createMeetingServer } from '../src/server.js';
import { InMemoryMeetingBlobStore, InMemoryMeetingRepository, type PartUploadRecord } from '../src/repository.js';
import type { ProviderConfig } from '../src/provider-config.js';

const meetingId = '123e4567-e89b-12d3-a456-426614174000';
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
    const audio = Buffer.from('f');
    const digest = createHash('sha256').update(audio).digest('hex');
    const manifest = { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: digest, byteCount: 1 }] };
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
    class UniqueBlobStore extends InMemoryMeetingBlobStore {
      private next = 0;
      override async put(ownerUid: string, currentMeetingId: string, partIndex: number, digest: string, bytes: Buffer) {
        const objectRef = `race/${ownerUid}/${currentMeetingId}/${partIndex}/${digest}/${this.next++}`;
        this.objects.set(objectRef, Buffer.from(bytes));
        return objectRef;
      }
    }
    const repository = new RacingRepository();
    const blobStore = new UniqueBlobStore();
    let transcriptionCalls = 0;
    const app = createMeetingServer({ auth: auth(), repository, blobStore, providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => { transcriptionCalls += 1; return []; } }, logger: false }); apps.push(app);
    await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers(), 'content-type': 'application/json' }, payload: createInput('openAI') });
    const audio = Buffer.from('race');
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
    const repository = new InMemoryMeetingRepository();
    const app = createMeetingServer({ auth: auth(), repository, providerConfig: validConfig, logger: false }); apps.push(app);
    await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers(), 'content-type': 'application/json' }, payload: createInput('openAI') });
    const audio = Buffer.from('x');
    const digest = createHash('sha256').update(audio).digest('hex');
    const manifest = { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: digest, byteCount: 1 }] };
    await app.inject({ method: 'POST', url: `/v1/meetings/${meetingId}/finalize-manifest`, headers: { ...headers(), 'content-type': 'application/json' }, payload: manifest });
    await repository.savePart('user-a', meetingId, { partIndex: 0, digest: '0'.repeat(64), objectRef: 'stale-object', byteCount: 1, fields: { partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, meetingSampleCount: 16000 }, uploadedAt: new Date().toISOString() });
    const form = multipart({ meetingId, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '16000', meetingSampleCount: '16000', audioSha256: digest }, audio);
    const response = await app.inject({ method: 'POST', url: '/v1/openai/parts', headers: { ...headers(), 'content-type': form.contentType }, payload: form.payload });
    expect(response.statusCode).toBe(409);
    expect(response.json().errorCode).toBe('PART_DIGEST_CONFLICT');
  });

  it('accepts revisioned extraction only after transcription handoff and transitions jobs to ready', async () => {
    const repository = new InMemoryMeetingRepository();
    const baseSegment = { id: 'segment-1', startMs: 0, endMs: 500, speakerIDs: [], text: '민수님이 견적서를 보내주세요', isFinal: true, confidence: null };
    const app = createMeetingServer({ auth: auth(), repository, providerConfig: validConfig, transcriptionAdapter: { transcribe: async () => [baseSegment] }, logger: false }); apps.push(app);
    const input = createInput('google');
    await app.inject({ method: 'POST', url: '/v1/meetings', headers: { ...headers(), 'content-type': 'application/json' }, payload: input });
    const audio = Buffer.from('g'); const digest = createHash('sha256').update(audio).digest('hex');
    const manifest = { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: digest, byteCount: 1 }] };
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
    const audio = Buffer.from('i'); const digest = createHash('sha256').update(audio).digest('hex');
    const manifest = { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16000, sha256: digest, byteCount: 1 }] };
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
