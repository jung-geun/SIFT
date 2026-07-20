import { createHash, randomBytes } from 'node:crypto';
import type { FinalizeManifest, MeetingCreate, MeetingProcessingMode, MeetingSegment } from './schema.js';

export type JobStatus = 'uploading' | 'queued' | 'transcribing' | 'awaiting_client_extraction' | 'extracting' | 'ready' | 'failed' | 'deleting';

export interface MeetingBlobStore {
  put(ownerUid: string, meetingId: string, partIndex: number, digest: string, bytes: Buffer): Promise<string>;
  deleteObject(objectRef: string): Promise<void>;
  deleteMeeting(ownerUid: string, meetingId: string): Promise<void>;
}

export class InMemoryMeetingBlobStore implements MeetingBlobStore {
  readonly objects = new Map<string, Buffer>();

  async put(ownerUid: string, meetingId: string, partIndex: number, digest: string, bytes: Buffer): Promise<string> {
    const ownerHash = createHash('sha256').update(ownerUid, 'utf8').digest('hex').slice(0, 32);
    const objectRef = `meetings/${ownerHash}/${meetingId}/parts/${partIndex}-${digest}.flac`;
    this.objects.set(objectRef, Buffer.from(bytes));
    return objectRef;
  }

  async deleteObject(objectRef: string): Promise<void> {
    this.objects.delete(objectRef);
  }

  async deleteMeeting(ownerUid: string, meetingId: string): Promise<void> {
    const ownerHash = createHash('sha256').update(ownerUid, 'utf8').digest('hex').slice(0, 32);
    const prefix = `meetings/${ownerHash}/${meetingId}/`;
    for (const objectRef of this.objects.keys()) {
      if (objectRef.startsWith(prefix)) this.objects.delete(objectRef);
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

/**
 * Adapter seam for a durable Firestore/SQL implementation. The HTTP layer only
 * depends on MeetingRepository, so persistence can be swapped without changing
 * authentication or route contracts.
 */
export interface DurableMeetingRepository extends MeetingRepository {
  flush?(): Promise<void>;
}

function now(): string { return new Date().toISOString(); }
function opaqueId(): string { return randomBytes(16).toString('base64url'); }
function ownerKey(ownerUid: string, meetingId: string): string { return `${ownerUid}\u0000${meetingId}`; }

export class InMemoryMeetingRepository implements MeetingRepository {
  readonly meetings = new Map<string, MeetingRecord>();
  readonly jobs = new Map<string, MeetingJob>();
  readonly deletions = new Map<string, DeletionReceipt>();

  async getMeeting(ownerUid: string, meetingId: string): Promise<MeetingRecord | undefined> {
    const meeting = this.meetings.get(ownerKey(ownerUid, meetingId));
    return meeting && !meeting.deleted ? meeting : undefined;
  }

  async createMeeting(ownerUid: string, input: MeetingCreate, uidHash: string): Promise<{ record: MeetingRecord; created: boolean }> {
    const key = ownerKey(ownerUid, input.meetingId);
    const existing = this.meetings.get(key);
    if (existing && !existing.deleted) return { record: existing, created: false };
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
      expectedSpeakerRange: input.expectedSpeakerRange,
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
    this.meetings.set(key, record);
    return { record, created: true };
  }

  private lookup(ownerUid: string, meetingId: string): MeetingRecord | undefined {
    return this.meetings.get(ownerKey(ownerUid, meetingId));
  }

  async freezeManifest(ownerUid: string, meetingId: string, manifest: FinalizeManifest, digest: string): Promise<{ record: MeetingRecord; created: boolean }> {
    const record = this.lookup(ownerUid, meetingId);
    if (!record || record.deleted) throw new Error('RESOURCE_NOT_FOUND');
    if (record.frozenManifestDigest !== null) return { record, created: false };
    record.meetingSampleCount = manifest.meetingSampleCount;
    record.expectedPartCount = manifest.partCount;
    record.frozenManifestDigest = digest;
    record.manifest = manifest;
    record.status = 'stopping';
    record.updatedAt = now();
    return { record, created: true };
  }

  async getPart(ownerUid: string, meetingId: string, partIndex: number): Promise<PartUploadRecord | undefined> {
    return this.lookup(ownerUid, meetingId)?.parts.get(partIndex);
  }

  async savePart(ownerUid: string, meetingId: string, part: PartUploadRecord): Promise<{ part: PartUploadRecord; created: boolean }> {
    const record = this.lookup(ownerUid, meetingId);
    if (!record || record.deleted) throw new Error('RESOURCE_NOT_FOUND');
    const existing = record.parts.get(part.partIndex);
    if (existing) return { part: existing, created: false };
    record.parts.set(part.partIndex, part);
    record.updatedAt = now();
    return { part, created: true };
  }

  async listParts(ownerUid: string, meetingId: string): Promise<PartUploadRecord[]> {
    return [...(this.lookup(ownerUid, meetingId)?.parts.values() ?? [])].sort((a, b) => a.partIndex - b.partIndex);
  }

  async createOrGetTranscriptionJob(ownerUid: string, meetingId: string): Promise<MeetingJobCreation> {
    const existing = [...this.jobs.values()].find(job => job.ownerUid === ownerUid && job.meetingId === meetingId && job.stage === 'transcription');
    if (existing) return { job: existing, created: false };
    const meeting = this.lookup(ownerUid, meetingId);
    if (!meeting || meeting.deleted) throw new Error('RESOURCE_NOT_FOUND');
    const timestamp = now();
    const job: MeetingJob = { jobId: opaqueId(), ownerUid, meetingId, provider: meeting.provider, stage: 'transcription', status: 'queued', attempt: 0, inputRevision: null, inputDigest: null, transcriptionJobId: null, transcriptSegments: null, transcriptRevision: null, result: null, errorCode: null, createdAt: timestamp, updatedAt: timestamp };
    this.jobs.set(job.jobId, job);
    meeting.status = 'finalizingTranscript';
    meeting.updatedAt = timestamp;
    return { job, created: true };
  }

  async completeTranscriptionJob(ownerUid: string, jobId: string, segments: MeetingSegment[]): Promise<MeetingJob | undefined> {
    const job = await this.getJob(ownerUid, jobId);
    if (!job || job.stage !== 'transcription' || job.status === 'deleting') return undefined;
    job.transcriptSegments = segments;
    job.status = 'awaiting_client_extraction';
    job.updatedAt = now();
    return job;
  }

  async getJob(ownerUid: string, jobId: string): Promise<MeetingJob | undefined> {
    const job = this.jobs.get(jobId);
    if (!job || job.ownerUid !== ownerUid) return undefined;
    return job;
  }

  async createOrGetExtractionJob(ownerUid: string, meetingId: string, inputRevision: number, inputDigest: string, segments: MeetingSegment[]): Promise<MeetingJobCreation> {
    const existing = [...this.jobs.values()].find(job => job.ownerUid === ownerUid && job.meetingId === meetingId && job.stage === 'extraction' && job.inputRevision === inputRevision && job.inputDigest === inputDigest);
    if (existing) return { job: existing, created: false };
    const conflictingRevision = [...this.jobs.values()].find(job => job.ownerUid === ownerUid && job.meetingId === meetingId && job.stage === 'extraction' && job.inputRevision === inputRevision);
    if (conflictingRevision) throw new Error('EXTRACTION_REVISION_CONFLICT');
    const meeting = this.lookup(ownerUid, meetingId);
    if (!meeting || meeting.deleted) throw new Error('RESOURCE_NOT_FOUND');
    const timestamp = now();
    const baseJob = [...this.jobs.values()].find(job => job.ownerUid === ownerUid && job.meetingId === meetingId && job.stage === 'transcription');
    const job: MeetingJob = { jobId: opaqueId(), ownerUid, meetingId, provider: meeting.provider, stage: 'extraction', status: 'extracting', attempt: 0, inputRevision, inputDigest, transcriptionJobId: baseJob?.jobId ?? null, transcriptSegments: segments, transcriptRevision: inputRevision, result: null, errorCode: null, createdAt: timestamp, updatedAt: timestamp };
    this.jobs.set(job.jobId, job);
    meeting.currentTranscriptRevision = inputRevision;
    meeting.status = 'extractingActions';
    meeting.updatedAt = timestamp;
    return { job, created: true };
  }

  async setJobResult(ownerUid: string, jobId: string, result: unknown, status: JobStatus = 'ready'): Promise<MeetingJob | undefined> {
    const job = await this.getJob(ownerUid, jobId);
    if (!job || job.status === 'deleting') return undefined;
    job.result = result;
    job.status = status;
    if (status === 'failed' && typeof result === 'object' && result !== null && 'errorCode' in result && typeof result.errorCode === 'string') job.errorCode = result.errorCode;
    job.updatedAt = now();
    const meeting = this.lookup(ownerUid, job.meetingId);
    if (meeting && status === 'ready') { meeting.status = 'ready'; meeting.updatedAt = job.updatedAt; }
    if (meeting && status === 'failed') { meeting.status = 'failed'; meeting.updatedAt = job.updatedAt; }
    return job;
  }
  async advanceJob(ownerUid: string, jobId: string, status: JobStatus): Promise<MeetingJob | undefined> {
    const job = await this.getJob(ownerUid, jobId);
    if (!job) return undefined;
    job.status = status;
    job.updatedAt = now();
    return job;
  }

  async createDeletion(ownerUid: string, meetingId: string): Promise<DeletionReceipt | undefined> {
    const key = ownerKey(ownerUid, meetingId);
    const existing = this.deletions.get(key);
    if (existing) return existing;
    const record = this.meetings.get(key);
    if (!record) return undefined;
    const timestamp = now();
    const receipt: DeletionReceipt = { ownerUid, meetingId, provider: record.provider, deleteRequestedAt: timestamp, applicationVisibleStateDeleted: true, remoteCleanupComplete: false, deletionStatus: 'pending_provider_terminal', providerCancellationStatus: 'requested', providerRetractionGuaranteed: false, expiresAt: new Date(Date.now() + 72 * 60 * 60 * 1000).toISOString() };
    this.deletions.set(key, receipt);
    record.deleted = true;
    record.status = 'cancelled';
    record.updatedAt = timestamp;
    for (const job of this.jobs.values()) if (job.ownerUid === ownerUid && job.meetingId === meetingId) job.status = 'deleting';
    return receipt;
  }

  async getDeletion(ownerUid: string, meetingId: string): Promise<DeletionReceipt | undefined> {
    return this.deletions.get(ownerKey(ownerUid, meetingId));
  }
  async completeDeletion(ownerUid: string, meetingId: string): Promise<DeletionReceipt | undefined> {
    const receipt = await this.getDeletion(ownerUid, meetingId);
    if (!receipt) return undefined;
    receipt.remoteCleanupComplete = true;
    receipt.deletionStatus = 'complete';
    return receipt;
  }
}
