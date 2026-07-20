import { describe, expect, it } from 'vitest';
import { InMemoryMeetingRepository } from '../src/repository.js';
import { expectedPartBounds } from '../src/media.js';

const meetingId = '123e4567-e89b-12d3-a456-426614174000';
const createInput = { meetingId, provider: 'google' as const, disclosureVersionID: 'cfg-1', languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', sampleRate: 16000 as const };

describe('in-memory meeting repository transitions', () => {
  it('guards failed jobs and advances deletion only after the adapter confirms cleanup', async () => {
    const repository = new InMemoryMeetingRepository();
    await repository.createMeeting('alice', createInput, 'uid-hash');
    const digest = 'a'.repeat(64);
    await repository.freezeManifest('alice', meetingId, { meetingSampleCount: 16000, partCount: 1, parts: [{ partIndex: 0, ...expectedPartBounds(0, 16000), sha256: digest, byteCount: 1 }] }, 'manifest-digest');
    const transcription = await repository.createOrGetTranscriptionJob('alice', meetingId);
    await repository.advanceJob('alice', transcription.job.jobId, 'awaiting_client_extraction');
    const extraction = await repository.createOrGetExtractionJob('alice', meetingId, 0, 'input-digest', []);
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
});
