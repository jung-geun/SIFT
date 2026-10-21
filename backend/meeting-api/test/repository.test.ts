import { describe, expect, it } from 'vitest';
import { InMemoryMeetingBlobStore, InMemoryMeetingRepository, type MeetingJob, type PartUploadRecord } from '../src/repository.js';
import { expectedPartBounds } from '../src/media.js';
import type { FinalizeManifest, MeetingSegment } from '../src/schema.js';

const meetingId = '123e4567-e89b-12d3-a456-426614174000';
const createInput = { meetingId, provider: 'google' as const, disclosureVersionID: 'cfg-1', languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', sampleRate: 16000 as const };
const digest = 'a'.repeat(64);
const segments: MeetingSegment[] = [{ id: 's1', startMs: 0, endMs: 1000, text: 'Meeting transcript', speakerIDs: ['speaker-1'], isFinal: true, confidence: null }];

function manifest(): FinalizeManifest {
  return { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, ...expectedPartBounds(0, 16000), sha256: digest, byteCount: 1 }] };
}

function uploadedPart(objectRef = 'object-ref'): PartUploadRecord {
  return { partIndex: 0, digest, objectRef, byteCount: 1, fields: { ...expectedPartBounds(0, 16000), meetingSampleCount: 16000 }, uploadedAt: '2026-01-01T00:00:00.000Z' };
}

async function startTranscription(repository: InMemoryMeetingRepository, ownerUid = 'alice'): Promise<MeetingJob> {
  await repository.createMeeting(ownerUid, createInput, 'uid-hash');
  await repository.freezeManifest(ownerUid, meetingId, manifest(), 'manifest-digest');
  await repository.savePart(ownerUid, meetingId, uploadedPart(`${ownerUid}-object`));
  return (await repository.createOrGetTranscriptionJob(ownerUid, meetingId)).job;
}

async function finishTranscription(repository: InMemoryMeetingRepository, ownerUid = 'alice'): Promise<MeetingJob> {
  const job = await startTranscription(repository, ownerUid);
  return (await repository.completeTranscriptionJob(ownerUid, job.jobId, segments))!;
}

describe('in-memory meeting repository transitions', () => {
  it('guards failed jobs and advances deletion only after the adapter confirms cleanup', async () => {
    const repository = new InMemoryMeetingRepository();
    await finishTranscription(repository);
    const extraction = await repository.createOrGetExtractionJob('alice', meetingId, 0, 'input-digest', segments);
    const failed = await repository.setJobResult('alice', extraction.job.jobId, { errorCode: 'EXTRACTION_FAILED' }, 'failed');
    expect(failed?.status).toBe('failed');
    expect((await repository.getMeeting('alice', meetingId))?.status).toBe('failed');
    const receipt = await repository.createDeletion('alice', meetingId);
    expect(receipt?.remoteCleanupComplete).toBe(false);
    const complete = await repository.completeDeletion('alice', meetingId);
    expect(complete?.remoteCleanupComplete).toBe(true);
    expect(complete?.deletionStatus).toBe('complete');
    expect(await repository.getMeeting('alice', meetingId)).toBeUndefined();
  });

  it('isolates meetings, parts, jobs and deletion receipts for the same ID across owners', async () => {
    const repository = new InMemoryMeetingRepository();
    const alice = await finishTranscription(repository);
    const bob = await finishTranscription(repository, 'bob');
    expect(alice.jobId).not.toBe(bob.jobId);
    expect(await repository.getJob('bob', alice.jobId)).toBeUndefined();
    expect(await repository.setJobResult('bob', alice.jobId, {}, 'failed')).toBeUndefined();
    expect(await repository.advanceJob('bob', alice.jobId, 'transcribing')).toBeUndefined();
    expect(await repository.completeTranscriptionJob('bob', alice.jobId, [])).toBeUndefined();
    await repository.createDeletion('alice', meetingId);
    expect(await repository.getMeeting('alice', meetingId)).toBeUndefined();
    expect((await repository.getMeeting('bob', meetingId))?.deleted).toBe(false);
    expect((await repository.getPart('bob', meetingId, 0))?.objectRef).toBe('bob-object');
    expect((await repository.getJob('bob', bob.jobId))?.status).toBe('awaiting_client_extraction');
    expect(await repository.getDeletion('bob', meetingId)).toBeUndefined();
  });

  it('does not alias owner/meeting tuples containing the old separator', async () => {
    const repository = new InMemoryMeetingRepository();
    const first = await repository.createMeeting('alice', { ...createInput, meetingId: `other\u0000${meetingId}` }, 'first');
    const second = await repository.createMeeting('alice\u0000other', createInput, 'second');
    expect(first.created).toBe(true);
    expect(second.created).toBe(true);
    expect((await repository.getMeeting('alice\u0000other', meetingId))?.uidHash).toBe('second');
  });

  it('atomically replays meeting creation and rejects conflicting metadata', async () => {
    const repository = new InMemoryMeetingRepository();
    const results = await Promise.all([
      repository.createMeeting('alice', createInput, 'uid-hash'),
      repository.createMeeting('alice', createInput, 'uid-hash'),
    ]);
    expect(results.map(result => result.created)).toEqual([true, false]);
    await expect(repository.createMeeting('alice', { ...createInput, languageTag: 'en-US' }, 'uid-hash')).rejects.toThrow('MEETING_METADATA_CONFLICT');
    expect((await repository.getMeeting('alice', meetingId))?.languageTag).toBe('ko-KR');
  });

  it('freezes one immutable manifest and rejects a different digest', async () => {
    const repository = new InMemoryMeetingRepository();
    await repository.createMeeting('alice', createInput, 'uid-hash');
    const input = manifest();
    const frozen = await repository.freezeManifest('alice', meetingId, input, 'manifest-digest');
    input.parts[0].sha256 = 'b'.repeat(64);
    frozen.record.manifest!.parts[0].sha256 = 'c'.repeat(64);
    const replay = await repository.freezeManifest('alice', meetingId, manifest(), 'manifest-digest');
    expect(replay.created).toBe(false);
    expect(replay.record.manifest?.parts[0].sha256).toBe(digest);
    await expect(repository.freezeManifest('alice', meetingId, manifest(), 'different')).rejects.toThrow('MANIFEST_MUTATION_CONFLICT');
  });

  it('atomically chooses one uploaded object and rejects part digest or manifest conflicts', async () => {
    const repository = new InMemoryMeetingRepository();
    await repository.createMeeting('alice', createInput, 'uid-hash');
    await expect(repository.savePart('alice', meetingId, uploadedPart())).rejects.toThrow('MANIFEST_REQUIRED');
    await repository.freezeManifest('alice', meetingId, manifest(), 'manifest-digest');
    const results = await Promise.all([
      repository.savePart('alice', meetingId, uploadedPart('winner')),
      repository.savePart('alice', meetingId, uploadedPart('loser')),
    ]);
    expect(results.map(result => result.created)).toEqual([true, false]);
    expect(results.map(result => result.part.objectRef)).toEqual(['winner', 'winner']);
    await expect(repository.savePart('alice', meetingId, { ...uploadedPart(), digest: 'b'.repeat(64) })).rejects.toThrow('PART_DIGEST_CONFLICT');
    await expect(repository.savePart('alice', meetingId, { ...uploadedPart(), byteCount: 2 })).rejects.toThrow('MANIFEST_PART_MISMATCH');
    expect((await repository.listParts('alice', meetingId)).map(part => part.objectRef)).toEqual(['winner']);
  });

  it('requires all frozen manifest parts before creating one transcription job', async () => {
    const repository = new InMemoryMeetingRepository();
    await repository.createMeeting('alice', createInput, 'uid-hash');
    await expect(repository.createOrGetTranscriptionJob('alice', meetingId)).rejects.toThrow('MANIFEST_REQUIRED');
    await repository.freezeManifest('alice', meetingId, manifest(), 'manifest-digest');
    await expect(repository.createOrGetTranscriptionJob('alice', meetingId)).rejects.toThrow('PARTS_INCOMPLETE');
    expect(repository.jobs.size).toBe(0);
    expect((await repository.getMeeting('alice', meetingId))?.status).toBe('stopping');
    await repository.savePart('alice', meetingId, uploadedPart());
    const jobs = await Promise.all([
      repository.createOrGetTranscriptionJob('alice', meetingId),
      repository.createOrGetTranscriptionJob('alice', meetingId),
    ]);
    expect(jobs.map(job => job.created)).toEqual([true, false]);
    expect(jobs[0].job.jobId).toBe(jobs[1].job.jobId);
    expect(repository.jobs.size).toBe(1);
  });

  it('requires completed transcription before extraction without partially changing state', async () => {
    const repository = new InMemoryMeetingRepository();
    await startTranscription(repository);
    await expect(repository.createOrGetExtractionJob('alice', meetingId, 0, 'input', segments)).rejects.toThrow('TRANSCRIPTION_NOT_READY');
    expect((await repository.getMeeting('alice', meetingId))?.currentTranscriptRevision).toBeNull();
    expect(repository.jobs.size).toBe(1);
  });

  it.each([-1, 1, 2, 0.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1])('rejects invalid initial revision %s atomically', async revision => {
    const repository = new InMemoryMeetingRepository();
    await finishTranscription(repository);
    await expect(repository.createOrGetExtractionJob('alice', meetingId, revision, 'input', segments)).rejects.toThrow('NON_MONOTONIC_REVISION');
    expect((await repository.getMeeting('alice', meetingId))?.currentTranscriptRevision).toBeNull();
    expect(repository.jobs.size).toBe(1);
  });

  it('serializes extraction revision claims while preserving historical idempotent replays', async () => {
    const repository = new InMemoryMeetingRepository();
    await finishTranscription(repository);
    const first = await repository.createOrGetExtractionJob('alice', meetingId, 0, 'revision-0', segments);
    const claims = await Promise.allSettled([
      repository.createOrGetExtractionJob('alice', meetingId, 1, 'revision-1', segments),
      repository.createOrGetExtractionJob('alice', meetingId, 1, 'conflicting', segments),
    ]);
    expect(claims[0].status).toBe('fulfilled');
    expect(claims[1]).toMatchObject({ status: 'rejected', reason: new Error('EXTRACTION_REVISION_CONFLICT') });
    const replay = await repository.createOrGetExtractionJob('alice', meetingId, 0, 'revision-0', segments);
    expect(replay.created).toBe(false);
    expect(replay.job.jobId).toBe(first.job.jobId);
    expect((await repository.getMeeting('alice', meetingId))?.currentTranscriptRevision).toBe(1);
    await expect(repository.createOrGetExtractionJob('alice', meetingId, 0, 'different', segments)).rejects.toThrow('EXTRACTION_REVISION_CONFLICT');
    await expect(repository.createOrGetExtractionJob('alice', meetingId, 3, 'gap', segments)).rejects.toThrow('NON_MONOTONIC_REVISION');
    expect(repository.jobs.size).toBe(3);
  });

  it('creates exactly one job for simultaneous identical extraction requests', async () => {
    const repository = new InMemoryMeetingRepository();
    await finishTranscription(repository);
    const results = await Promise.all([
      repository.createOrGetExtractionJob('alice', meetingId, 0, 'input', segments),
      repository.createOrGetExtractionJob('alice', meetingId, 0, 'input', segments),
    ]);
    expect(results.map(result => result.created)).toEqual([true, false]);
    expect(results[0].job.jobId).toBe(results[1].job.jobId);
  });

  it.each(['ready', 'failed'] as const)('does not project stale revision %s completion onto the current meeting', async status => {
    const repository = new InMemoryMeetingRepository();
    await finishTranscription(repository);
    const old = await repository.createOrGetExtractionJob('alice', meetingId, 0, 'revision-0', segments);
    const current = await repository.createOrGetExtractionJob('alice', meetingId, 1, 'revision-1', segments);
    const before = await repository.getMeeting('alice', meetingId);
    await repository.setJobResult('alice', old.job.jobId, { errorCode: 'OLD_RESULT' }, status);
    expect(await repository.getMeeting('alice', meetingId)).toEqual(before);
    expect((await repository.getJob('alice', old.job.jobId))?.status).toBe(status);
    await repository.setJobResult('alice', current.job.jobId, { title: 'Current' });
    expect(await repository.getMeeting('alice', meetingId)).toMatchObject({ currentTranscriptRevision: 1, status: 'ready' });
  });

  it('never rewrites completed transcripts or reopens a failed transcription job', async () => {
    const repository = new InMemoryMeetingRepository();
    const completed = await finishTranscription(repository);
    expect(await repository.completeTranscriptionJob('alice', completed.jobId, [])).toEqual(completed);
    expect(await repository.setJobResult('alice', completed.jobId, { errorCode: 'LATE_FAILURE' }, 'failed')).toEqual(completed);
    expect(await repository.advanceJob('alice', completed.jobId, 'queued')).toEqual(completed);
    const failedJob = await startTranscription(repository, 'bob');
    const failed = await repository.setJobResult('bob', failedJob.jobId, { errorCode: 'TRANSCRIPTION_FAILED' }, 'failed');
    expect(await repository.completeTranscriptionJob('bob', failedJob.jobId, segments)).toEqual(failed);
    expect(await repository.advanceJob('bob', failedJob.jobId, 'transcribing')).toEqual(failed);
  });

  it('permits only the transcription work transition and stage-appropriate terminal results', async () => {
    const repository = new InMemoryMeetingRepository();
    const job = await startTranscription(repository);
    await expect(repository.advanceJob('alice', job.jobId, 'ready')).rejects.toThrow('INVALID_JOB_TRANSITION');
    await expect(repository.advanceJob('alice', job.jobId, 'awaiting_client_extraction')).rejects.toThrow('INVALID_JOB_TRANSITION');
    await expect(repository.setJobResult('alice', job.jobId, {})).rejects.toThrow('INVALID_JOB_TRANSITION');
    expect((await repository.advanceJob('alice', job.jobId, 'transcribing'))?.status).toBe('transcribing');
    await repository.completeTranscriptionJob('alice', job.jobId, segments);
    const extraction = await repository.createOrGetExtractionJob('alice', meetingId, 0, 'input', segments);
    await expect(repository.setJobResult('alice', extraction.job.jobId, {}, 'queued')).rejects.toThrow('INVALID_JOB_TRANSITION');
    await expect(repository.advanceJob('alice', extraction.job.jobId, 'transcribing')).rejects.toThrow('INVALID_JOB_TRANSITION');
  });

  it.each(['ready', 'failed'] as const)('makes %s extraction results terminal and detached from callers', async status => {
    const repository = new InMemoryMeetingRepository();
    await finishTranscription(repository);
    const extraction = await repository.createOrGetExtractionJob('alice', meetingId, 0, 'input', segments);
    const result = { title: 'Original', errorCode: 'EXTRACTION_FAILED' };
    const terminal = await repository.setJobResult('alice', extraction.job.jobId, result, status);
    const expected = structuredClone(terminal);
    result.title = 'Mutated input';
    (terminal!.result as typeof result).title = 'Mutated return';
    expect(await repository.setJobResult('alice', extraction.job.jobId, { title: 'Late' }, status === 'ready' ? 'failed' : 'ready')).toEqual(expected);
    expect(await repository.advanceJob('alice', extraction.job.jobId, 'extracting')).toEqual(expected);
  });

  it('does not resurrect meetings or return existing jobs after a stale request races deletion', async () => {
    const repository = new InMemoryMeetingRepository();
    const transcription = await finishTranscription(repository);
    const extraction = await repository.createOrGetExtractionJob('alice', meetingId, 0, 'input', segments);
    const stale = await repository.getMeeting('alice', meetingId);
    await repository.createDeletion('alice', meetingId);
    expect(stale).toBeDefined();
    await expect(repository.createMeeting('alice', createInput, 'uid-hash')).rejects.toThrow('MEETING_DELETED');
    await expect(repository.freezeManifest('alice', meetingId, manifest(), 'manifest-digest')).rejects.toThrow('RESOURCE_NOT_FOUND');
    await expect(repository.savePart('alice', meetingId, uploadedPart())).rejects.toThrow('RESOURCE_NOT_FOUND');
    await expect(repository.createOrGetTranscriptionJob('alice', meetingId)).rejects.toThrow('RESOURCE_NOT_FOUND');
    await expect(repository.createOrGetExtractionJob('alice', meetingId, 0, 'input', segments)).rejects.toThrow('RESOURCE_NOT_FOUND');
    expect(await repository.getPart('alice', meetingId, 0)).toBeUndefined();
    expect(await repository.listParts('alice', meetingId)).toEqual([]);
    expect(await repository.getJob('alice', transcription.jobId)).toBeUndefined();
    expect(await repository.completeTranscriptionJob('alice', transcription.jobId, segments)).toBeUndefined();
    expect(await repository.setJobResult('alice', extraction.job.jobId, {})).toBeUndefined();
    expect(await repository.advanceJob('alice', extraction.job.jobId, 'extracting')).toBeUndefined();
    expect(repository.jobs.get(extraction.job.jobId)).toMatchObject({ status: 'deleting', transcriptSegments: null, result: null });
    expect(await repository.getMeeting('alice', meetingId)).toBeUndefined();
  });

  it('keeps deletion final when an already-started job advance completes', async () => {
    const repository = new InMemoryMeetingRepository();
    const job = await startTranscription(repository);
    const advance = repository.advanceJob('alice', job.jobId, 'transcribing');
    const deletion = repository.createDeletion('alice', meetingId);
    await Promise.all([advance, deletion]);
    expect(repository.jobs.get(job.jobId)?.status).toBe('deleting');
    expect(await repository.getJob('alice', job.jobId)).toBeUndefined();
  });

  it('isolates input and output records including nested maps, segments and receipts', async () => {
    const repository = new InMemoryMeetingRepository();
    const input = { ...createInput, expectedSpeakerRange: { min: 1, max: 2 } };
    const created = await repository.createMeeting('alice', input, 'uid-hash');
    input.expectedSpeakerRange.max = 16;
    created.record.expectedSpeakerRange!.min = 2;
    expect((await repository.getMeeting('alice', meetingId))?.expectedSpeakerRange).toEqual({ min: 1, max: 2 });
    await repository.freezeManifest('alice', meetingId, manifest(), 'manifest-digest');
    const part = uploadedPart();
    const saved = await repository.savePart('alice', meetingId, part);
    part.fields.ownedEndSample = 0;
    saved.part.fields.ownedEndSample = 1;
    const read = await repository.getMeeting('alice', meetingId);
    read!.parts.clear();
    const listed = await repository.listParts('alice', meetingId);
    listed[0].fields.ownedEndSample = 2;
    expect((await repository.getPart('alice', meetingId, 0))?.fields.ownedEndSample).toBe(16000);
    const job = await repository.createOrGetTranscriptionJob('alice', meetingId);
    const transcript = structuredClone(segments);
    const completed = await repository.completeTranscriptionJob('alice', job.job.jobId, transcript);
    transcript[0].speakerIDs.push('mutated');
    completed!.transcriptSegments![0].text = 'Changed';
    repository.jobs.get(job.job.jobId)!.status = 'failed';
    repository.meetings.clear();
    expect((await repository.getJob('alice', job.job.jobId))?.transcriptSegments).toEqual(segments);
    const extractionSegments = structuredClone(segments);
    const extraction = await repository.createOrGetExtractionJob('alice', meetingId, 0, 'input', extractionSegments);
    extractionSegments[0].text = 'Changed';
    extraction.job.transcriptSegments![0].text = 'Changed again';
    expect((await repository.getJob('alice', extraction.job.jobId))?.transcriptSegments).toEqual(segments);
    const receipt = await repository.createDeletion('alice', meetingId);
    receipt!.remoteCleanupComplete = true;
    repository.deletions.clear();
    expect((await repository.getDeletion('alice', meetingId))?.remoteCleanupComplete).toBe(false);
    await repository.completeDeletion('alice', meetingId);
    expect((await repository.createDeletion('alice', meetingId))?.deletionStatus).toBe('complete');
  });
});

describe('in-memory meeting object lifecycle', () => {
  it('keeps identical uploads and deletion owner-separated', async () => {
    const store = new InMemoryMeetingBlobStore();
    const alice = await store.put('alice', meetingId, 0, digest, Buffer.from('a'));
    const bob = await store.put('bob', meetingId, 0, digest, Buffer.from('b'));
    expect(alice).not.toBe(bob);
    await store.deleteMeeting('alice', meetingId);
    expect(store.objects.has(alice)).toBe(false);
    expect(store.objects.get(bob)?.toString()).toBe('b');
    await expect(store.put('alice', meetingId, 0, digest, Buffer.from('late'))).rejects.toThrow('MEETING_DELETED');
    expect(store.objects.size).toBe(1);
  });

  it.each([['\ud800', '\ud801'], ['\ud800', '\ufffd']])('keeps lossy UTF-8 owner encodings %j and %j isolated', async (firstOwner, secondOwner) => {
    const store = new InMemoryMeetingBlobStore();
    const first = await store.put(firstOwner, meetingId, 0, digest, Buffer.from('a'));
    const second = await store.put(secondOwner, meetingId, 0, digest, Buffer.from('b'));
    expect(first.split('/')[1]).not.toBe(second.split('/')[1]);
    await store.deleteMeeting(firstOwner, meetingId);
    expect(store.objects.has(first)).toBe(false);
    expect(store.objects.get(second)?.toString()).toBe('b');
    await expect(store.put(secondOwner, meetingId, 1, digest, Buffer.from('c'))).resolves.toBeTypeOf('string');
  });

  it('gives concurrent retries independent cleanup references and preserves the accepted object', async () => {
    const repository = new InMemoryMeetingRepository();
    const store = new InMemoryMeetingBlobStore();
    await repository.createMeeting('alice', createInput, 'uid-hash');
    await repository.freezeManifest('alice', meetingId, manifest(), 'manifest-digest');
    const [first, retry] = await Promise.all([
      store.put('alice', meetingId, 0, digest, Buffer.from('a')),
      store.put('alice', meetingId, 0, digest, Buffer.from('a')),
    ]);
    expect(first).not.toBe(retry);
    await repository.savePart('alice', meetingId, uploadedPart(first));
    const replay = await repository.savePart('alice', meetingId, uploadedPart(retry));
    expect(replay.created).toBe(false);
    expect(replay.part.objectRef).toBe(first);
    await store.deleteObject(retry);
    expect(store.objects.get(first)?.toString()).toBe('a');
    expect(store.objects.has(retry)).toBe(false);
  });

  it('fences writes started after deletion and removes earlier writes regardless of awaiting', async () => {
    const store = new InMemoryMeetingBlobStore();
    const earlier = store.put('alice', meetingId, 0, digest, Buffer.from('a'));
    const deletion = store.deleteMeeting('alice', meetingId);
    const late = store.put('alice', meetingId, 0, digest, Buffer.from('a'));
    await earlier;
    await deletion;
    await expect(late).rejects.toThrow('MEETING_DELETED');
    expect(store.objects.size).toBe(0);
    await store.deleteMeeting('alice', meetingId);
    await expect(store.put('alice', meetingId, 1, digest, Buffer.from('a'))).rejects.toThrow('MEETING_DELETED');
  });

  it('rejects and cleans up an uploaded object when deletion wins before savePart', async () => {
    const repository = new InMemoryMeetingRepository();
    const store = new InMemoryMeetingBlobStore();
    await repository.createMeeting('alice', createInput, 'uid-hash');
    await repository.freezeManifest('alice', meetingId, manifest(), 'manifest-digest');
    const objectRef = await store.put('alice', meetingId, 0, digest, Buffer.from('a'));
    await repository.createDeletion('alice', meetingId);
    await store.deleteMeeting('alice', meetingId);
    await expect(repository.savePart('alice', meetingId, uploadedPart(objectRef))).rejects.toThrow('RESOURCE_NOT_FOUND');
    await store.deleteObject(objectRef);
    expect(store.objects.size).toBe(0);
    expect(await repository.listParts('alice', meetingId)).toEqual([]);
  });

  it('detaches stored bytes from upload buffers and diagnostic reads', async () => {
    const store = new InMemoryMeetingBlobStore();
    const bytes = Buffer.from('a');
    const ref = await store.put('alice', meetingId, 0, digest, bytes);
    bytes[0] = 98;
    store.objects.get(ref)![0] = 99;
    store.objects.clear();
    expect(store.objects.get(ref)?.toString()).toBe('a');
  });
});
