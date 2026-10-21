import { createHash, randomBytes } from 'node:crypto';
import type { FinalizeManifest, MeetingCreate, MeetingProcessingMode, MeetingSegment } from './schema.js';

export type JobStatus = 'uploading' | 'queued' | 'transcribing' | 'awaiting_client_extraction' | 'extracting' | 'ready' | 'failed' | 'deleting';

export interface MeetingBlobStore {
  /** Returns an immutable, unique reference per write; rejects writes after deleteMeeting. */
  put(ownerUid: string, meetingId: string, partIndex: number, digest: string, bytes: Buffer): Promise<string>;
  deleteObject(objectRef: string): Promise<void>;
  /** Permanently fences subsequent writes for this owner/meeting before removing objects. */
  deleteMeeting(ownerUid: string, meetingId: string): Promise<void>;
}

export class InMemoryMeetingBlobStore implements MeetingBlobStore {
  private readonly storedObjects = new Map<string, Buffer>();
  private readonly deletedMeetings = new Set<string>();

  get objects(): Map<string, Buffer> {
    return new Map([...this.storedObjects].map(([ref, bytes]) => [ref, Buffer.from(bytes)]));
  }

  async put(ownerUid: string, meetingId: string, partIndex: number, digest: string, bytes: Buffer): Promise<string> {
    if (this.deletedMeetings.has(ownerKey(ownerUid, meetingId))) throw new Error('MEETING_DELETED');
    const ownerHash = createHash('sha256').update(JSON.stringify(ownerUid), 'utf8').digest('hex').slice(0, 32);
    const objectRef = `meetings/${ownerHash}/${encodeURIComponent(meetingId)}/parts/${partIndex}-${digest}-${opaqueId()}.flac`;
    this.storedObjects.set(objectRef, Buffer.from(bytes));
    return objectRef;
  }

  async deleteObject(objectRef: string): Promise<void> {
    this.storedObjects.delete(objectRef);
  }

  async deleteMeeting(ownerUid: string, meetingId: string): Promise<void> {
    this.deletedMeetings.add(ownerKey(ownerUid, meetingId));
    const ownerHash = createHash('sha256').update(JSON.stringify(ownerUid), 'utf8').digest('hex').slice(0, 32);
    const prefix = `meetings/${ownerHash}/${encodeURIComponent(meetingId)}/`;
    for (const objectRef of this.storedObjects.keys()) {
      if (objectRef.startsWith(prefix)) this.storedObjects.delete(objectRef);
    }
  }
}

export interface PartUploadRecord {
  partIndex: number;
  digest: string;
  objectRef: string;
  byteCount: number;
  fields: {
    partStartSample: number;
    ownedStartSample: number;
    ownedEndSample: number;
    meetingSampleCount: number;
  };
  uploadedAt: string;
}

export interface MeetingRecord {
  ownerUid: string;
  uidHash: string;
  meetingId: string;
  provider: MeetingProcessingMode;
  disclosureVersionID: string;
  languageTag: string;
  timezoneIdentifier: string;
  sampleRate: 16000;
  expectedSpeakerRange?: { min: number; max: number };
  status: 'recording' | 'paused' | 'interrupted' | 'stopping' | 'finalizingTranscript' | 'extractingActions' | 'ready' | 'failed' | 'cancelled';
  currentTranscriptRevision: number | null;
  meetingSampleCount: number | null;
  expectedPartCount: number | null;
  frozenManifestDigest: string | null;
  manifest: FinalizeManifest | null;
  parts: Map<number, PartUploadRecord>;
  deleted: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface MeetingJob {
  jobId: string;
  ownerUid: string;
  meetingId: string;
  provider: MeetingProcessingMode;
  stage: 'transcription' | 'extraction';
  status: JobStatus;
  attempt: number;
  inputRevision: number | null;
  inputDigest: string | null;
  transcriptionJobId: string | null;
  transcriptSegments: MeetingSegment[] | null;
  transcriptRevision: number | null;
  result: unknown | null;
  errorCode: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface DeletionReceipt {
  ownerUid: string;
  meetingId: string;
  provider: MeetingProcessingMode;
  deleteRequestedAt: string;
  applicationVisibleStateDeleted: true;
  remoteCleanupComplete: boolean;
  deletionStatus: 'pending_provider_terminal' | 'pending_expiry' | 'complete';
  providerCancellationStatus: 'requested' | 'not_supported' | 'already_terminal' | 'request_failed' | 'provider_state_unknown';
  providerRetractionGuaranteed: false;
  expiresAt: string;
}

export interface MeetingJobCreation {
  job: MeetingJob;
  created: boolean;
}

/**
 * All operations are atomic: implementations must check liveness, idempotency,
 * revision ordering and state transitions in the same transaction as writes.
 * Reads and returned records are detached snapshots, not mutable repository state.
 * Deletion is a permanent owner/meeting tombstone; missing/deleted job updates
 * return undefined. Terminal job updates return the unchanged job. Only the
 * latest extraction revision may project its result status onto the meeting.
 * Durable adapters must preserve these guarantees across concurrent workers.
 */
export interface MeetingRepository {
  getMeeting(ownerUid: string, meetingId: string): Promise<MeetingRecord | undefined>;
  createMeeting(ownerUid: string, input: MeetingCreate, uidHash: string): Promise<{ record: MeetingRecord; created: boolean }>;
  freezeManifest(ownerUid: string, meetingId: string, manifest: FinalizeManifest, digest: string): Promise<{ record: MeetingRecord; created: boolean }>;
  getPart(ownerUid: string, meetingId: string, partIndex: number): Promise<PartUploadRecord | undefined>;
  savePart(ownerUid: string, meetingId: string, part: PartUploadRecord): Promise<{ part: PartUploadRecord; created: boolean }>;
  listParts(ownerUid: string, meetingId: string): Promise<PartUploadRecord[]>;
  createOrGetTranscriptionJob(ownerUid: string, meetingId: string): Promise<MeetingJobCreation>;
  completeTranscriptionJob(ownerUid: string, jobId: string, segments: MeetingSegment[]): Promise<MeetingJob | undefined>;
  getJob(ownerUid: string, jobId: string): Promise<MeetingJob | undefined>;
  createOrGetExtractionJob(ownerUid: string, meetingId: string, inputRevision: number, inputDigest: string, segments: MeetingSegment[]): Promise<MeetingJobCreation>;
  setJobResult(ownerUid: string, jobId: string, result: unknown, status?: JobStatus): Promise<MeetingJob | undefined>;
  createDeletion(ownerUid: string, meetingId: string): Promise<DeletionReceipt | undefined>;
  getDeletion(ownerUid: string, meetingId: string): Promise<DeletionReceipt | undefined>;
  advanceJob?(ownerUid: string, jobId: string, status: JobStatus): Promise<MeetingJob | undefined>;
  completeDeletion?(ownerUid: string, meetingId: string): Promise<DeletionReceipt | undefined>;
}

/** Adapter seam for durable Firestore/SQL persistence. */
export interface DurableMeetingRepository extends MeetingRepository {
  flush?(): Promise<void>;
}

function now(): string { return new Date().toISOString(); }
function opaqueId(): string { return randomBytes(16).toString('base64url'); }
function ownerKey(ownerUid: string, meetingId: string): string { return JSON.stringify([ownerUid, meetingId]); }

export class InMemoryMeetingRepository implements MeetingRepository {
  private readonly meetingState = new Map<string, MeetingRecord>();
  private readonly jobState = new Map<string, MeetingJob>();
  private readonly deletionState = new Map<string, DeletionReceipt>();

  // Diagnostic snapshots cannot bypass the same invariants as API reads.
  get meetings(): Map<string, MeetingRecord> { return structuredClone(this.meetingState); }
  get jobs(): Map<string, MeetingJob> { return structuredClone(this.jobState); }
  get deletions(): Map<string, DeletionReceipt> { return structuredClone(this.deletionState); }

  private lookup(ownerUid: string, meetingId: string): MeetingRecord | undefined {
    const record = this.meetingState.get(ownerKey(ownerUid, meetingId));
    return record && !record.deleted ? record : undefined;
  }

  private requireMeeting(ownerUid: string, meetingId: string): MeetingRecord {
    const record = this.lookup(ownerUid, meetingId);
    if (!record) throw new Error('RESOURCE_NOT_FOUND');
    return record;
  }

  private lookupJob(ownerUid: string, jobId: string): MeetingJob | undefined {
    const job = this.jobState.get(jobId);
    return job && job.ownerUid === ownerUid && this.lookup(ownerUid, job.meetingId) ? job : undefined;
  }

  private transcriptionJob(ownerUid: string, meetingId: string): MeetingJob | undefined {
    for (const job of this.jobState.values()) {
      if (job.ownerUid === ownerUid && job.meetingId === meetingId && job.stage === 'transcription') return job;
    }
    return undefined;
  }

  async getMeeting(ownerUid: string, meetingId: string): Promise<MeetingRecord | undefined> {
    return structuredClone(this.lookup(ownerUid, meetingId));
  }

  async createMeeting(ownerUid: string, input: MeetingCreate, uidHash: string): Promise<{ record: MeetingRecord; created: boolean }> {
    const key = ownerKey(ownerUid, input.meetingId);
    const existing = this.meetingState.get(key);
    if (existing?.deleted || this.deletionState.has(key)) throw new Error('MEETING_DELETED');
    if (existing) {
      if (existing.provider !== input.provider || existing.disclosureVersionID !== input.disclosureVersionID || existing.languageTag !== input.languageTag || existing.timezoneIdentifier !== input.timezoneIdentifier || existing.expectedSpeakerRange?.min !== input.expectedSpeakerRange?.min || existing.expectedSpeakerRange?.max !== input.expectedSpeakerRange?.max) throw new Error('MEETING_METADATA_CONFLICT');
      return { record: structuredClone(existing), created: false };
    }
    const timestamp = now();
    const record: MeetingRecord = {
      ownerUid,
      uidHash,
      meetingId: input.meetingId,
      provider: input.provider,
      disclosureVersionID: input.disclosureVersionID,
      languageTag: input.languageTag,
      timezoneIdentifier: input.timezoneIdentifier,
      sampleRate: 16000,
      expectedSpeakerRange: structuredClone(input.expectedSpeakerRange),
      status: 'recording',
      currentTranscriptRevision: null,
      meetingSampleCount: null,
      expectedPartCount: null,
      frozenManifestDigest: null,
      manifest: null,
      parts: new Map(),
      deleted: false,
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    this.meetingState.set(key, record);
    return { record: structuredClone(record), created: true };
  }

  async freezeManifest(ownerUid: string, meetingId: string, manifest: FinalizeManifest, digest: string): Promise<{ record: MeetingRecord; created: boolean }> {
    const record = this.requireMeeting(ownerUid, meetingId);
    if (record.frozenManifestDigest !== null) {
      if (record.frozenManifestDigest !== digest) throw new Error('MANIFEST_MUTATION_CONFLICT');
      return { record: structuredClone(record), created: false };
    }
    const storedManifest = structuredClone(manifest);
    record.meetingSampleCount = storedManifest.meetingSampleCount;
    record.expectedPartCount = storedManifest.partCount;
    record.frozenManifestDigest = digest;
    record.manifest = storedManifest;
    record.status = 'stopping';
    record.updatedAt = now();
    return { record: structuredClone(record), created: true };
  }

  async getPart(ownerUid: string, meetingId: string, partIndex: number): Promise<PartUploadRecord | undefined> {
    return structuredClone(this.lookup(ownerUid, meetingId)?.parts.get(partIndex));
  }

  async savePart(ownerUid: string, meetingId: string, part: PartUploadRecord): Promise<{ part: PartUploadRecord; created: boolean }> {
    const record = this.requireMeeting(ownerUid, meetingId);
    const existing = record.parts.get(part.partIndex);
    if (existing && existing.digest !== part.digest) throw new Error('PART_DIGEST_CONFLICT');
    if (!record.manifest) throw new Error('MANIFEST_REQUIRED');
    const expected = record.manifest.parts.find(candidate => candidate.partIndex === part.partIndex);
    if (!expected || expected.sha256 !== part.digest || expected.byteCount !== part.byteCount || expected.partStartSample !== part.fields.partStartSample || expected.ownedStartSample !== part.fields.ownedStartSample || expected.ownedEndSample !== part.fields.ownedEndSample || record.manifest.meetingSampleCount !== part.fields.meetingSampleCount) throw new Error('MANIFEST_PART_MISMATCH');
    if (existing) return { part: structuredClone(existing), created: false };
    const storedPart = structuredClone(part);
    record.parts.set(part.partIndex, storedPart);
    record.updatedAt = now();
    return { part: structuredClone(storedPart), created: true };
  }

  async listParts(ownerUid: string, meetingId: string): Promise<PartUploadRecord[]> {
    return structuredClone([...(this.lookup(ownerUid, meetingId)?.parts.values() ?? [])].sort((a, b) => a.partIndex - b.partIndex));
  }

  async createOrGetTranscriptionJob(ownerUid: string, meetingId: string): Promise<MeetingJobCreation> {
    const meeting = this.requireMeeting(ownerUid, meetingId);
    const existing = this.transcriptionJob(ownerUid, meetingId);
    if (existing) return { job: structuredClone(existing), created: false };
    if (!meeting.manifest) throw new Error('MANIFEST_REQUIRED');
    if (meeting.parts.size !== meeting.manifest.partCount || meeting.manifest.parts.some(part => meeting.parts.get(part.partIndex)?.digest !== part.sha256)) throw new Error('PARTS_INCOMPLETE');
    const timestamp = now();
    const job: MeetingJob = { jobId: opaqueId(), ownerUid, meetingId, provider: meeting.provider, stage: 'transcription', status: 'queued', attempt: 0, inputRevision: null, inputDigest: null, transcriptionJobId: null, transcriptSegments: null, transcriptRevision: null, result: null, errorCode: null, createdAt: timestamp, updatedAt: timestamp };
    this.jobState.set(job.jobId, job);
    meeting.status = 'finalizingTranscript';
    meeting.updatedAt = timestamp;
    return { job: structuredClone(job), created: true };
  }

  async completeTranscriptionJob(ownerUid: string, jobId: string, segments: MeetingSegment[]): Promise<MeetingJob | undefined> {
    const job = this.lookupJob(ownerUid, jobId);
    if (!job || job.stage !== 'transcription') return undefined;
    if (job.status !== 'queued' && job.status !== 'transcribing') return structuredClone(job);
    job.transcriptSegments = structuredClone(segments);
    job.status = 'awaiting_client_extraction';
    job.updatedAt = now();
    return structuredClone(job);
  }

  async getJob(ownerUid: string, jobId: string): Promise<MeetingJob | undefined> {
    return structuredClone(this.lookupJob(ownerUid, jobId));
  }

  async createOrGetExtractionJob(ownerUid: string, meetingId: string, inputRevision: number, inputDigest: string, segments: MeetingSegment[]): Promise<MeetingJobCreation> {
    const meeting = this.requireMeeting(ownerUid, meetingId);
    for (const job of this.jobState.values()) {
      if (job.ownerUid !== ownerUid || job.meetingId !== meetingId || job.stage !== 'extraction' || job.inputRevision !== inputRevision) continue;
      if (job.inputDigest !== inputDigest) throw new Error('EXTRACTION_REVISION_CONFLICT');
      return { job: structuredClone(job), created: false };
    }
    const currentRevision = meeting.currentTranscriptRevision;
    if (!Number.isSafeInteger(inputRevision) || inputRevision < 0 || (currentRevision === null ? inputRevision !== 0 : inputRevision < currentRevision || inputRevision > currentRevision + 1)) throw new Error('NON_MONOTONIC_REVISION');
    const baseJob = this.transcriptionJob(ownerUid, meetingId);
    if (!baseJob || baseJob.status !== 'awaiting_client_extraction' || baseJob.transcriptSegments === null) throw new Error('TRANSCRIPTION_NOT_READY');
    const storedSegments = structuredClone(segments);
    const timestamp = now();
    const job: MeetingJob = { jobId: opaqueId(), ownerUid, meetingId, provider: meeting.provider, stage: 'extraction', status: 'extracting', attempt: 0, inputRevision, inputDigest, transcriptionJobId: baseJob.jobId, transcriptSegments: storedSegments, transcriptRevision: inputRevision, result: null, errorCode: null, createdAt: timestamp, updatedAt: timestamp };
    this.jobState.set(job.jobId, job);
    meeting.currentTranscriptRevision = inputRevision;
    meeting.status = 'extractingActions';
    meeting.updatedAt = timestamp;
    return { job: structuredClone(job), created: true };
  }

  async setJobResult(ownerUid: string, jobId: string, result: unknown, status: JobStatus = 'ready'): Promise<MeetingJob | undefined> {
    const job = this.lookupJob(ownerUid, jobId);
    if (!job) return undefined;
    if (job.status === 'ready' || job.status === 'failed' || job.status === 'awaiting_client_extraction') return structuredClone(job);
    if ((status !== 'ready' && status !== 'failed') || (status === 'ready' && job.stage !== 'extraction')) throw new Error('INVALID_JOB_TRANSITION');
    const storedResult = structuredClone(result);
    job.result = storedResult;
    job.status = status;
    job.errorCode = status === 'failed' && typeof storedResult === 'object' && storedResult !== null && 'errorCode' in storedResult && typeof storedResult.errorCode === 'string' ? storedResult.errorCode : null;
    job.updatedAt = now();
    const meeting = this.requireMeeting(ownerUid, job.meetingId);
    if (job.stage === 'transcription' || job.inputRevision === meeting.currentTranscriptRevision) {
      meeting.status = status;
      meeting.updatedAt = job.updatedAt;
    }
    return structuredClone(job);
  }

  async advanceJob(ownerUid: string, jobId: string, status: JobStatus): Promise<MeetingJob | undefined> {
    const job = this.lookupJob(ownerUid, jobId);
    if (!job) return undefined;
    if (job.status === status || job.status === 'ready' || job.status === 'failed' || job.status === 'awaiting_client_extraction') return structuredClone(job);
    if (job.stage !== 'transcription' || job.status !== 'queued' || status !== 'transcribing') throw new Error('INVALID_JOB_TRANSITION');
    job.status = status;
    job.updatedAt = now();
    return structuredClone(job);
  }

  async createDeletion(ownerUid: string, meetingId: string): Promise<DeletionReceipt | undefined> {
    const key = ownerKey(ownerUid, meetingId);
    const existing = this.deletionState.get(key);
    if (existing) return structuredClone(existing);
    const record = this.meetingState.get(key);
    if (!record) return undefined;
    const timestamp = now();
    const receipt: DeletionReceipt = { ownerUid, meetingId, provider: record.provider, deleteRequestedAt: timestamp, applicationVisibleStateDeleted: true, remoteCleanupComplete: false, deletionStatus: 'pending_provider_terminal', providerCancellationStatus: 'requested', providerRetractionGuaranteed: false, expiresAt: new Date(Date.now() + 72 * 60 * 60 * 1000).toISOString() };
    this.deletionState.set(key, receipt);
    record.deleted = true;
    record.status = 'cancelled';
    record.parts.clear();
    record.manifest = null;
    record.updatedAt = timestamp;
    for (const job of this.jobState.values()) {
      if (job.ownerUid !== ownerUid || job.meetingId !== meetingId) continue;
      job.status = 'deleting';
      job.transcriptSegments = null;
      job.result = null;
      job.errorCode = null;
      job.updatedAt = timestamp;
    }
    return structuredClone(receipt);
  }

  async getDeletion(ownerUid: string, meetingId: string): Promise<DeletionReceipt | undefined> {
    return structuredClone(this.deletionState.get(ownerKey(ownerUid, meetingId)));
  }

  async completeDeletion(ownerUid: string, meetingId: string): Promise<DeletionReceipt | undefined> {
    const receipt = this.deletionState.get(ownerKey(ownerUid, meetingId));
    if (!receipt) return undefined;
    receipt.remoteCleanupComplete = true;
    receipt.deletionStatus = 'complete';
    return structuredClone(receipt);
  }
}
