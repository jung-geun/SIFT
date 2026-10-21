import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest, type FastifyServerOptions } from 'fastify';
import multipart from '@fastify/multipart';
import websocket from '@fastify/websocket';
import { createHash } from 'node:crypto';
import canonicalize from 'canonicalize';
import { getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getAppCheck } from 'firebase-admin/app-check';
import { authenticateRequest, FirebaseAdminAuthVerifier, type MeetingAuthVerifier, uidHash } from './auth.js';
import { MAX_PART_BYTES, MAX_REQUEST_BYTES, canonicalManifest, validateFlacAudio, validateManifest } from './media.js';
import { InMemoryMeetingBlobStore, InMemoryMeetingRepository, type MeetingBlobStore, type MeetingJob, type MeetingJobCreation, type MeetingRepository, type MeetingRecord, type PartUploadRecord } from './repository.js';
import { defaultProviderConfig, ProviderConfigSchema, providerIsEnabled, type ProviderConfig } from './provider-config.js';
import { ExtractionSchema, FinalizeManifestSchema, MeetingCreateSchema, PartFieldsSchema, ProviderMeetingExtractionSchema, deriveActionId, normalizeExtraction, validateSegments, type MeetingSegment, type ProviderMeetingExtraction } from './schema.js';

export interface ExtractionAdapter {
  extract(input: { meetingId: string; languageTag: string; timezoneIdentifier: string; segments: MeetingSegment[] }): Promise<ProviderMeetingExtraction>;
}
export interface TranscriptionAdapter {
  transcribe(input: { ownerUid: string; meetingId: string; provider: 'openAI' | 'google'; parts: PartUploadRecord[] }): Promise<MeetingSegment[]>;
}

export interface MeetingServerOptions {
  auth: MeetingAuthVerifier;
  repository?: MeetingRepository;
  blobStore?: MeetingBlobStore;
  providerConfig?: ProviderConfig;
  extractionAdapter?: ExtractionAdapter;
  transcriptionAdapter?: TranscriptionAdapter;
  logger?: FastifyServerOptions['logger'];
}

class HttpError extends Error {
  constructor(readonly statusCode: number, readonly code: string) { super(code); }
}

function fail(statusCode: number, code: string): never { throw new HttpError(statusCode, code); }

function parseBody<T>(schema: { safeParse(value: unknown): { success: true; data: T } | { success: false } }, value: unknown): T {
  const result = schema.safeParse(value);
  if (!result.success) fail(400, 'INVALID_REQUEST');
  return result.data;
}

function meetingView(record: MeetingRecord): Record<string, unknown> {
  return { meetingId: record.meetingId, provider: record.provider, disclosureVersionID: record.disclosureVersionID, languageTag: record.languageTag, timezoneIdentifier: record.timezoneIdentifier, sampleRate: record.sampleRate, expectedSpeakerRange: record.expectedSpeakerRange ?? null, status: record.status, currentTranscriptRevision: record.currentTranscriptRevision, meetingSampleCount: record.meetingSampleCount, expectedPartCount: record.expectedPartCount, frozenManifestDigest: record.frozenManifestDigest, createdAt: record.createdAt, updatedAt: record.updatedAt };
}

function jobView(job: MeetingJob): Record<string, unknown> {
  return { status: job.status, transcriptRevision: job.transcriptRevision, transcriptSegments: job.transcriptSegments, result: job.result, errorCode: job.errorCode };
}

function ensureOwnerMeeting(repository: MeetingRepository, ownerUid: string, meetingId: string): Promise<MeetingRecord> {
  return repository.getMeeting(ownerUid, meetingId).then(record => record ?? fail(404, 'RESOURCE_NOT_FOUND'));
}


async function readMultipart(request: FastifyRequest): Promise<{ fields: Record<string, string>; digest: string; byteCount: number; bytes: Buffer }> {
  const fields: Record<string, string> = Object.create(null) as Record<string, string>;
  const audioChunks: Buffer[] = [];
  let digest: string | undefined;
  let byteCount = 0;
  let fileCount = 0;
  try {
    for await (const part of request.parts()) {
      if (part.type === 'field') {
        if (!['meetingId', 'languageTag', 'timezoneIdentifier', 'disclosureVersionID', 'partIndex', 'partCount', 'partStartSample', 'ownedStartSample', 'ownedEndSample', 'meetingSampleCount', 'audioSha256'].includes(part.fieldname) || part.fieldnameTruncated || part.valueTruncated || typeof part.value !== 'string' || !/^[\x00-\x7F]*$/.test(part.value) || Object.hasOwn(fields, part.fieldname)) fail(400, 'INVALID_MULTIPART_FIELD');
        fields[part.fieldname] = part.value;
        continue;
      }
      fileCount += 1;
      if (fileCount !== 1 || part.fieldname !== 'audio' || (part.mimetype !== 'audio/flac' && part.mimetype !== 'application/octet-stream')) fail(400, 'INVALID_AUDIO_PART');
      const hash = createHash('sha256');
      for await (const chunk of part.file) {
        const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        byteCount += bytes.length;
        if (byteCount > MAX_PART_BYTES) fail(413, 'PART_SIZE_LIMIT');
        hash.update(bytes);
        audioChunks.push(bytes);
      }
      if (part.file.truncated) fail(413, 'PART_SIZE_LIMIT');
      digest = hash.digest('hex');
    }
  } catch (error) {
    if (error instanceof HttpError) throw error;
    if (typeof error === 'object' && error !== null && 'code' in error && error.code === 'FST_REQ_FILE_TOO_LARGE') fail(413, 'PART_SIZE_LIMIT');
    fail(400, 'INVALID_MULTIPART');
  }
  if (fileCount !== 1 || !digest || byteCount <= 0) fail(400, 'AUDIO_REQUIRED');
  return { fields, digest, byteCount, bytes: Buffer.concat(audioChunks) };
}

function canonicalExtractionDigest(input: { transcriptionJobId: string; transcriptRevision: number; languageTag: string; timezoneIdentifier: string; segments: MeetingSegment[] }): string {
  const value = { transcriptionJobId: input.transcriptionJobId, transcriptRevision: input.transcriptRevision, languageTag: input.languageTag, timezoneIdentifier: input.timezoneIdentifier, segments: input.segments.map(segment => ({ id: segment.id, startMs: segment.startMs, endMs: segment.endMs, speakerIDs: segment.speakerIDs, text: segment.text, isFinal: segment.isFinal, confidence: segment.confidence })) };
  const serialized = canonicalize(value);
  if (serialized === undefined) throw new HttpError(400, 'INVALID_EXTRACTION');
  return createHash('sha256').update(serialized, 'utf8').digest('hex');
}
export function createMeetingServer(options: MeetingServerOptions): FastifyInstance {
  const repository = options.repository ?? new InMemoryMeetingRepository();
  const blobStore = options.blobStore ?? new InMemoryMeetingBlobStore();
  const config = ProviderConfigSchema.parse(options.providerConfig ?? defaultProviderConfig);
  const extractionAdapter = options.extractionAdapter;
  const transcriptionAdapter = options.transcriptionAdapter;
  const logger = options.logger === false ? false : {
    level: 'warn',
    ...(typeof options.logger === 'object' ? options.logger : {}),
    // Never serialize credentials, user content, URL parameters or provider errors.
    serializers: {
      req: (request: FastifyRequest) => ({ method: request.method }),
      res: (reply: { statusCode: number }) => ({ statusCode: reply.statusCode }),
      err: () => ({ type: 'Error', message: 'REDACTED', stack: '' }),
    },
    redact: ['req.headers.authorization', 'req.headers["x-firebase-appcheck"]', 'headers.authorization', 'headers["x-firebase-appcheck"]'],
  };
  const app = Fastify({ bodyLimit: MAX_REQUEST_BYTES, logger, onProtoPoisoning: 'error', onConstructorPoisoning: 'error' });

  app.register(multipart, { limits: { fileSize: MAX_PART_BYTES, files: 1, fields: 12, parts: 13, fieldSize: 1024 }, attachFieldsToBody: false });
  app.register(websocket);

  app.addHook('onRequest', async request => {
    try {
      request.meetingIdentity = await authenticateRequest(request, options.auth);
    } catch (error) {
      if (error instanceof Error && error.message === 'AUTH_REQUIRED') fail(401, 'AUTH_REQUIRED');
      fail(401, 'AUTH_INVALID');
    }
  });

  app.setErrorHandler((error, request, reply) => {
    if (error instanceof HttpError) {
      request.log.warn({ code: error.code, statusCode: error.statusCode }, 'meeting request rejected');
      void reply.code(error.statusCode).send({ errorCode: error.code });
      return;
    }
    if (error instanceof Error) {
      const statusCode = error.message === 'RESOURCE_NOT_FOUND' ? 404
        : ['MEETING_DELETED', 'MEETING_METADATA_CONFLICT', 'MANIFEST_MUTATION_CONFLICT', 'EXTRACTION_REVISION_CONFLICT', 'NON_MONOTONIC_REVISION', 'PART_DIGEST_CONFLICT', 'TRANSCRIPTION_NOT_READY', 'MANIFEST_REQUIRED', 'MANIFEST_PART_MISMATCH', 'PARTS_INCOMPLETE', 'INVALID_JOB_TRANSITION'].includes(error.message) ? 409 : undefined;
      if (statusCode !== undefined) {
        request.log.warn({ code: error.message, statusCode }, 'meeting request rejected');
        void reply.code(statusCode).send({ errorCode: error.message });
        return;
      }
    }
    if (typeof error === 'object' && error !== null && 'statusCode' in error && error.statusCode === 413) {
      request.log.warn({ code: 'REQUEST_SIZE_LIMIT' }, 'meeting request rejected');
      void reply.code(413).send({ errorCode: 'REQUEST_SIZE_LIMIT' });
      return;
    }
    if (typeof error === 'object' && error !== null && 'name' in error && error.name === 'ZodError') {
      request.log.warn({ code: 'INVALID_REQUEST' }, 'meeting request rejected');
      void reply.code(400).send({ errorCode: 'INVALID_REQUEST' });
      return;
    }
    if (typeof error === 'object' && error !== null && 'statusCode' in error && error.statusCode === 400) {
      request.log.warn({ code: 'INVALID_REQUEST' }, 'meeting request rejected');
      void reply.code(400).send({ errorCode: 'INVALID_REQUEST' });
      return;
    }
    request.log.error({ code: 'INTERNAL_ERROR' }, 'meeting request failed');
    void reply.code(500).send({ errorCode: 'INTERNAL_ERROR' });
  });

  app.get('/v1/provider-config', async (_request, reply) => reply.send(config));

  app.post('/v1/meetings', async (request, reply) => {
    const input = parseBody(MeetingCreateSchema, request.body);
    const ownerUid = request.meetingIdentity.uid;
    if (input.provider !== 'onDevice' && !providerIsEnabled(config, input.provider)) fail(503, 'PROVIDER_UNAVAILABLE');
    const existingDeletion = await repository.getDeletion(ownerUid, input.meetingId);
    if (existingDeletion) fail(409, 'MEETING_DELETED');
    const existing = await repository.getMeeting(ownerUid, input.meetingId);
    if (existing) {
      const same = existing.provider === input.provider && existing.disclosureVersionID === input.disclosureVersionID && existing.languageTag === input.languageTag && existing.timezoneIdentifier === input.timezoneIdentifier && JSON.stringify(existing.expectedSpeakerRange ?? null) === JSON.stringify(input.expectedSpeakerRange ?? null);
      if (!same) fail(409, 'MEETING_METADATA_CONFLICT');
      return reply.code(200).send(meetingView(existing));
    }
    const created = await repository.createMeeting(ownerUid, input, uidHash(ownerUid));
    if (!created.created) {
      const same = created.record.provider === input.provider && created.record.disclosureVersionID === input.disclosureVersionID && created.record.languageTag === input.languageTag && created.record.timezoneIdentifier === input.timezoneIdentifier && JSON.stringify(created.record.expectedSpeakerRange ?? null) === JSON.stringify(input.expectedSpeakerRange ?? null);
      if (!same) fail(409, 'MEETING_METADATA_CONFLICT');
    }
    return reply.code(created.created ? 201 : 200).send(meetingView(created.record));
  });

  app.post('/v1/meetings/:meetingId/finalize-manifest', async (request: FastifyRequest<{ Params: { meetingId: string }; Body: unknown }>, reply) => {
    const ownerUid = request.meetingIdentity.uid;
    const meetingId = request.params.meetingId;
    const meeting = await ensureOwnerMeeting(repository, ownerUid, meetingId);
    const input = parseBody(FinalizeManifestSchema, request.body);
    try { validateManifest(input); } catch (error) { fail(400, error instanceof Error ? error.message : 'INVALID_MANIFEST'); }
    const serialized = canonicalManifest(input);
    const digest = createHash('sha256').update(serialized, 'utf8').digest('hex');
    if (meeting.frozenManifestDigest) {
      if (meeting.frozenManifestDigest !== digest) fail(409, 'MANIFEST_MUTATION_CONFLICT');
      return reply.code(200).send({ meetingId, frozenManifestDigest: digest, meetingSampleCount: meeting.meetingSampleCount, expectedPartCount: meeting.expectedPartCount, status: meeting.status });
    }
    const frozen = await repository.freezeManifest(ownerUid, meetingId, input, digest);
    const canonical = frozen.created ? frozen.record : await repository.getMeeting(ownerUid, meetingId);
    if (!canonical || canonical.frozenManifestDigest !== digest) fail(409, 'MANIFEST_MUTATION_CONFLICT');
    return reply.code(frozen.created ? 201 : 200).send({ meetingId, frozenManifestDigest: canonical.frozenManifestDigest, meetingSampleCount: canonical.meetingSampleCount, expectedPartCount: canonical.expectedPartCount, status: canonical.status });
  });

  const handleUpload = async (request: FastifyRequest<{ Body: unknown }>, reply: FastifyReply, provider: 'openAI' | 'google') => {
    const ownerUid = request.meetingIdentity.uid;
    if (!providerIsEnabled(config, provider) || !transcriptionAdapter) fail(503, 'PROVIDER_UNAVAILABLE');
    const payload = await readMultipart(request);
    const fields = parseBody(PartFieldsSchema, payload.fields);
    const meetingId = fields.meetingId;
    const meeting = await ensureOwnerMeeting(repository, ownerUid, meetingId);
    if (meeting.provider !== provider) fail(409, 'PROVIDER_MISMATCH');
    if (!providerIsEnabled(config, meeting.provider)) fail(503, 'PROVIDER_UNAVAILABLE');
    if (!meeting.manifest || !meeting.frozenManifestDigest) fail(409, 'MANIFEST_REQUIRED');
    if (fields.languageTag !== meeting.languageTag || fields.timezoneIdentifier !== meeting.timezoneIdentifier || fields.disclosureVersionID !== meeting.disclosureVersionID) fail(409, 'MEETING_METADATA_CONFLICT');
    if (fields.audioSha256 !== payload.digest) fail(400, 'AUDIO_DIGEST_MISMATCH');
    try { validateFlacAudio(payload.bytes, fields); } catch (error) { fail(400, error instanceof Error ? error.message : 'INVALID_PART'); }
    const manifestPart = meeting.manifest.parts[fields.partIndex];
    const matchesManifest = manifestPart
      && manifestPart.sha256 === payload.digest
      && manifestPart.byteCount === payload.byteCount
      && fields.partCount === meeting.manifest.partCount
      && fields.partStartSample === BigInt(manifestPart.partStartSample)
      && fields.ownedStartSample === BigInt(manifestPart.ownedStartSample)
      && fields.ownedEndSample === BigInt(manifestPart.ownedEndSample)
      && fields.meetingSampleCount === BigInt(meeting.manifest.meetingSampleCount);
    if (!matchesManifest) fail(409, 'MANIFEST_PART_MISMATCH');
    const existing = await repository.getPart(ownerUid, meetingId, fields.partIndex);
    if (existing && existing.digest !== payload.digest) fail(409, 'PART_DIGEST_CONFLICT');
    const uploadedObject = !existing;
    let objectRef: string;
    try {
      objectRef = existing?.objectRef ?? await blobStore.put(ownerUid, meetingId, fields.partIndex, payload.digest, payload.bytes);
    } catch (error) {
      if (error instanceof Error && error.message === 'MEETING_DELETED') fail(404, 'RESOURCE_NOT_FOUND');
      throw error;
    }
    const uploaded: PartUploadRecord = { partIndex: fields.partIndex, digest: payload.digest, objectRef, byteCount: payload.byteCount, fields: { partStartSample: Number(fields.partStartSample), ownedStartSample: Number(fields.ownedStartSample), ownedEndSample: Number(fields.ownedEndSample), meetingSampleCount: Number(fields.meetingSampleCount) }, uploadedAt: new Date().toISOString() };
    let stored: { part: PartUploadRecord; created: boolean };
    try {
      stored = existing ? { part: existing, created: false } : await repository.savePart(ownerUid, meetingId, uploaded);
    } catch (error) {
      if (uploadedObject) await blobStore.deleteObject(objectRef);
      throw error;
    }
    if (uploadedObject && !stored.created && stored.part.objectRef !== objectRef) await blobStore.deleteObject(objectRef);
    const allParts = await repository.listParts(ownerUid, meetingId);
    let job: MeetingJob | undefined;
    if (allParts.length === meeting.expectedPartCount && allParts.every(part => meeting.manifest?.parts.some(manifestPart => manifestPart.partIndex === part.partIndex && manifestPart.sha256 === part.digest))) {
      if (await repository.getDeletion(ownerUid, meetingId)) fail(404, 'RESOURCE_NOT_FOUND');
      let createdJob: MeetingJobCreation;
      try {
        createdJob = await repository.createOrGetTranscriptionJob(ownerUid, meetingId);
      } catch (error) {
        if (error instanceof Error && error.message === 'RESOURCE_NOT_FOUND') fail(404, 'RESOURCE_NOT_FOUND');
        throw error;
      }
      job = createdJob.job;
      if (createdJob.created) {
        if (job.status === 'deleting' || await repository.getDeletion(ownerUid, meetingId)) fail(404, 'RESOURCE_NOT_FOUND');
        let baseSegments: MeetingSegment[];
        try {
          baseSegments = await transcriptionAdapter.transcribe({ ownerUid, meetingId, provider, parts: allParts });
        } catch {
          const failed = await repository.setJobResult(ownerUid, job.jobId, { errorCode: 'TRANSCRIPTION_FAILED' }, 'failed');
          if (!failed) fail(404, 'RESOURCE_NOT_FOUND');
          job = failed;
          fail(502, 'TRANSCRIPTION_FAILED');
        }
        await ensureOwnerMeeting(repository, ownerUid, meetingId);
        try {
          if (!Array.isArray(baseSegments)) throw new Error('INVALID_PROVIDER_RESULT');
          validateSegments(baseSegments, Math.floor(meeting.meetingSampleCount! * 1000 / 16000));
        } catch {
          await repository.setJobResult(ownerUid, job.jobId, { errorCode: 'INVALID_PROVIDER_RESULT' }, 'failed');
          fail(502, 'INVALID_PROVIDER_RESULT');
        }
        const completed = await repository.completeTranscriptionJob(ownerUid, job.jobId, baseSegments);
        if (!completed) fail(404, 'RESOURCE_NOT_FOUND');
        job = completed;
      }
    }
    await ensureOwnerMeeting(repository, ownerUid, meetingId);
    return reply.code(stored.created ? 202 : 200).send({ jobId: job?.jobId ?? null, acceptedPartIndex: fields.partIndex, acceptedPartCount: allParts.length, expectedPartCount: meeting.expectedPartCount, status: job?.status ?? 'uploading' });
  };

  app.post<{ Body: unknown }>('/v1/openai/parts', async (request, reply) => handleUpload(request, reply, 'openAI'));
  app.post<{ Body: unknown }>('/v1/google/parts', async (request, reply) => handleUpload(request, reply, 'google'));

  app.post('/v1/meetings/:meetingId/extractions', async (request: FastifyRequest<{ Params: { meetingId: string }; Body: unknown }>, reply) => {
    const ownerUid = request.meetingIdentity.uid;
    const meetingId = request.params.meetingId;
    const meeting = await ensureOwnerMeeting(repository, ownerUid, meetingId);
    if (meeting.provider === 'onDevice') fail(409, 'PROVIDER_MISMATCH');
    if (!providerIsEnabled(config, meeting.provider) || !extractionAdapter) fail(503, 'PROVIDER_UNAVAILABLE');
    const input = parseBody(ExtractionSchema, request.body);
    const transcriptionJob = await repository.getJob(ownerUid, input.transcriptionJobId);
    if (!transcriptionJob || transcriptionJob.meetingId !== meetingId || transcriptionJob.stage !== 'transcription') fail(404, 'RESOURCE_NOT_FOUND');
    if (transcriptionJob.status !== 'awaiting_client_extraction') fail(409, 'TRANSCRIPTION_NOT_READY');
    if (input.languageTag !== meeting.languageTag || input.timezoneIdentifier !== meeting.timezoneIdentifier) fail(409, 'MEETING_METADATA_CONFLICT');
    const totalMs = meeting.meetingSampleCount === null ? undefined : Math.floor(meeting.meetingSampleCount * 1000 / 16000);
    try { validateSegments(input.segments, totalMs); } catch (error) { fail(400, error instanceof Error ? error.message : 'INVALID_SEGMENTS'); }
    const digest = canonicalExtractionDigest(input);
    let extraction: MeetingJobCreation;
    if (input.transcriptRevision === 0) {
      const baseSegments = transcriptionJob.transcriptSegments;
      if (!baseSegments || baseSegments.length !== input.segments.length || input.segments.some((segment, index) => {
        const base = baseSegments[index];
        return !base || base.id !== segment.id || base.startMs !== segment.startMs || base.endMs !== segment.endMs || base.text !== segment.text || base.confidence !== segment.confidence || base.isFinal !== segment.isFinal;
      })) fail(409, 'BASE_TRANSCRIPT_MISMATCH');
    }
    try {
      extraction = await repository.createOrGetExtractionJob(ownerUid, meetingId, input.transcriptRevision, digest, input.segments);
    } catch (error) {
      if (error instanceof Error && error.message === 'RESOURCE_NOT_FOUND') fail(404, 'RESOURCE_NOT_FOUND');
      if (error instanceof Error && error.message === 'EXTRACTION_REVISION_CONFLICT') fail(409, 'EXTRACTION_REVISION_CONFLICT');
      throw error;
    }
    if (extraction.created) {
      let extracted: ProviderMeetingExtraction | undefined;
      let adapterReturned = false;
      try {
        extracted = await extractionAdapter.extract({ meetingId, languageTag: input.languageTag, timezoneIdentifier: input.timezoneIdentifier, segments: input.segments });
        adapterReturned = true;
      } catch {
        const failed = await repository.setJobResult(ownerUid, extraction.job.jobId, { errorCode: 'EXTRACTION_FAILED' }, 'failed');
        if (failed) extraction = { job: failed, created: true };
      }
      if (adapterReturned) {
        let parsed: ProviderMeetingExtraction;
        try {
          parsed = normalizeExtraction(ProviderMeetingExtractionSchema.parse(extracted));
        } catch {
          const failed = await repository.setJobResult(ownerUid, extraction.job.jobId, { errorCode: 'INVALID_PROVIDER_RESULT' }, 'failed');
          if (failed) extraction = { job: failed, created: true };
          fail(502, 'INVALID_PROVIDER_RESULT');
        }
        const sourceIDs = new Set(input.segments.map(segment => segment.id));
        if (parsed.actionDrafts.some(draft => draft.sourceSegmentIDs.some(id => !sourceIDs.has(id)))) {
          const failed = await repository.setJobResult(ownerUid, extraction.job.jobId, { errorCode: 'INVALID_PROVIDER_RESULT' }, 'failed');
          if (failed) extraction = { job: failed, created: true };
          fail(502, 'INVALID_PROVIDER_RESULT');
        }
        try {
          const result = { transcriptRevision: input.transcriptRevision, title: parsed.title, summary: parsed.summary, decisions: parsed.decisions, unresolvedQuestions: parsed.unresolvedQuestions, segments: input.segments, actionDrafts: parsed.actionDrafts.map(draft => ({ ...draft, id: deriveActionId(meetingId, draft) })) };
          const ready = await repository.setJobResult(ownerUid, extraction.job.jobId, result, 'ready');
          if (ready) extraction = { job: ready, created: true };
        } catch {
          const failed = await repository.setJobResult(ownerUid, extraction.job.jobId, { errorCode: 'INVALID_PROVIDER_RESULT' }, 'failed');
          if (failed) extraction = { job: failed, created: true };
          fail(502, 'INVALID_PROVIDER_RESULT');
        }
      }
    }
    await ensureOwnerMeeting(repository, ownerUid, meetingId);
    return reply.code(202).send({ jobId: extraction.job.jobId, transcriptionJobId: input.transcriptionJobId, transcriptRevision: input.transcriptRevision, status: extraction.job.status });
  });

  app.get('/v1/jobs/:jobId', async (request: FastifyRequest<{ Params: { jobId: string } }>, reply) => {
    const job = await repository.getJob(request.meetingIdentity.uid, request.params.jobId);
    if (!job || await repository.getDeletion(request.meetingIdentity.uid, job.meetingId)) fail(404, 'RESOURCE_NOT_FOUND');
    return reply.send(jobView(job));
  });

  app.delete('/v1/meetings/:meetingId', async (request: FastifyRequest<{ Params: { meetingId: string } }>, reply) => {
    const ownerUid = request.meetingIdentity.uid;
    const meetingId = request.params.meetingId;
    const existingReceipt = await repository.getDeletion(ownerUid, meetingId);
    if (existingReceipt) {
      if (!existingReceipt.remoteCleanupComplete) {
        await blobStore.deleteMeeting(ownerUid, meetingId);
        if (repository.completeDeletion) await repository.completeDeletion(ownerUid, meetingId);
      }
      return reply.code(202).send((await repository.getDeletion(ownerUid, meetingId)) ?? existingReceipt);
    }
    const meeting = await repository.getMeeting(ownerUid, meetingId);
    if (!meeting) fail(404, 'RESOURCE_NOT_FOUND');
    const receipt = await repository.createDeletion(ownerUid, meetingId);
    if (!receipt) fail(404, 'RESOURCE_NOT_FOUND');
    await blobStore.deleteMeeting(ownerUid, meetingId);
    if (repository.completeDeletion) await repository.completeDeletion(ownerUid, meetingId);
    return reply.code(202).send((await repository.getDeletion(ownerUid, meetingId)) ?? receipt);
  });

  app.get('/v1/deletions/:meetingId', async (request: FastifyRequest<{ Params: { meetingId: string } }>, reply) => {
    const receipt = await repository.getDeletion(request.meetingIdentity.uid, request.params.meetingId);
    if (!receipt) fail(404, 'RESOURCE_NOT_FOUND');
    return reply.send(receipt);
  });

  // Streaming has no provider adapter. Reject before a websocket upgrade instead
  // of acknowledging audio that was never transcribed.
  app.get('/v1/google/stream', { preValidation: async () => fail(503, 'PROVIDER_UNAVAILABLE') }, async () => fail(503, 'PROVIDER_UNAVAILABLE'));

  return app;
}

declare module 'fastify' {
  interface FastifyRequest {
    meetingIdentity: { uid: string };
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const firebaseApp = getApps()[0] ?? initializeApp();
  const server = createMeetingServer({ auth: new FirebaseAdminAuthVerifier(getAuth(firebaseApp), getAppCheck(firebaseApp)) });
  await server.listen({ host: '0.0.0.0', port: Number(process.env.PORT ?? 8080) });
}
