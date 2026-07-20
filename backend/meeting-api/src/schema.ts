import { z } from 'zod';
import { actionId, normalizeText, replacementSegmentId } from './canonical.js';

export const UUID = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
export const MeetingProcessingMode = z.enum(['onDevice', 'openAI', 'google']);
export type MeetingProcessingMode = z.infer<typeof MeetingProcessingMode>;
export const MeetingStatus = z.enum(['recording', 'paused', 'interrupted', 'stopping', 'finalizingTranscript', 'extractingActions', 'ready', 'failed', 'cancelled']);

const finiteConfidence = z.number().finite().min(0).max(1);
const sortedUniqueSpeakers = z.array(z.string()).refine(speakers => speakers.every((speaker, index) => index === 0 || speakers[index - 1] < speaker), { message: 'SPEAKER_IDS_NOT_SORTED_UNIQUE' });
export const MeetingSegmentSchema = z.object({ id: z.string().min(1), startMs: z.number().int().nonnegative(), endMs: z.number().int().nonnegative(), speakerIDs: sortedUniqueSpeakers, text: z.string(), isFinal: z.boolean(), confidence: finiteConfidence.nullable() }).strict();
export type MeetingSegment = z.infer<typeof MeetingSegmentSchema>;

export const ProviderActionDraftInputSchema = z.object({ title: z.string(), notes: z.string(), assignee: z.string().nullable(), dueAtISO8601: z.string().nullable(), sourceSegmentIDs: z.array(z.string()), confidence: finiteConfidence, requiresReview: z.boolean() }).strict();
export type ProviderActionDraftInput = z.infer<typeof ProviderActionDraftInputSchema>;
export const ProviderMeetingExtractionSchema = z.object({ title: z.string(), summary: z.string(), decisions: z.array(z.string()), unresolvedQuestions: z.array(z.string()), actionDrafts: z.array(ProviderActionDraftInputSchema) }).strict();
export type ProviderMeetingExtraction = z.infer<typeof ProviderMeetingExtractionSchema>;

export const MeetingCreateSchema = z.object({ meetingId: UUID, provider: MeetingProcessingMode, disclosureVersionID: z.string().min(1), languageTag: z.string().regex(/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+$/), timezoneIdentifier: z.string().min(1), sampleRate: z.literal(16000), expectedSpeakerRange: z.object({ min: z.number().int().min(1).max(16), max: z.number().int().min(1).max(16) }).refine(r => r.min <= r.max).optional() }).strict();
export type MeetingCreate = z.infer<typeof MeetingCreateSchema>;

const MAX_UINT64 = 18_446_744_073_709_551_615n;
const decimalUInt = z.string().regex(/^(0|[1-9][0-9]*)$/).transform(value => BigInt(value)).refine(value => value <= MAX_UINT64, { message: 'UINT64_LIMIT' });
const decimalUIntNumber = z.string().regex(/^(0|[1-9][0-9]*)$/).transform(value => Number(value));
export const PartFieldsSchema = z.object({ meetingId: UUID, languageTag: z.string().min(2), timezoneIdentifier: z.string().min(1), disclosureVersionID: z.string().min(1), partIndex: decimalUIntNumber.pipe(z.number().int().min(0).max(35)), partCount: decimalUIntNumber.pipe(z.number().int().min(1).max(36)), partStartSample: decimalUInt, ownedStartSample: decimalUInt, ownedEndSample: decimalUInt, meetingSampleCount: decimalUInt, audioSha256: z.string().regex(/^[0-9a-f]{64}$/) }).strict();
export type PartFields = z.infer<typeof PartFieldsSchema>;

export const ManifestPartSchema = z.object({ partIndex: z.number().int().min(0).max(35), partStartSample: z.number().int().nonnegative(), ownedStartSample: z.number().int().nonnegative(), ownedEndSample: z.number().int().nonnegative(), sha256: z.string().regex(/^[0-9a-f]{64}$/), byteCount: z.number().int().positive().max(23_000_000) }).strict();
export type ManifestPart = z.infer<typeof ManifestPartSchema>;
export const FinalizeManifestSchema = z.object({ meetingSampleCount: z.number().int().positive().max(345_600_000), partCount: z.number().int().min(1).max(36), parts: z.array(ManifestPartSchema).min(1).max(36) }).strict();
export type FinalizeManifest = z.infer<typeof FinalizeManifestSchema>;

export const ExtractionSchema = z.object({ transcriptionJobId: z.string().min(1), transcriptRevision: z.number().int().nonnegative(), languageTag: z.string().min(2), timezoneIdentifier: z.string().min(1), segments: z.array(MeetingSegmentSchema) }).strict();

export function validateSegments(segments: MeetingSegment[], totalMs?: number): void {
  const ids = new Set<string>(); let previousStart = -1; let previousEnd = -1; let previousId = '';
  for (const segment of segments) {
    const tupleOutOfOrder = segment.startMs < previousStart || (segment.startMs === previousStart && segment.endMs < previousEnd) || (segment.startMs === previousStart && segment.endMs === previousEnd && segment.id <= previousId);
    if (segment.endMs <= segment.startMs || tupleOutOfOrder || (totalMs !== undefined && segment.endMs > totalMs)) throw new Error('INVALID_SEGMENT_BOUNDS');
    if (ids.has(segment.id)) throw new Error('DUPLICATE_SEGMENT_ID');
    ids.add(segment.id); previousStart = segment.startMs; previousEnd = segment.endMs; previousId = segment.id;
    if (segment.speakerIDs.some(speaker => !speaker)) throw new Error('INVALID_SPEAKER_ID');
    if (segment.confidence !== null && (!Number.isFinite(segment.confidence) || segment.confidence < 0 || segment.confidence > 1)) throw new Error('INVALID_CONFIDENCE');
  }
}

export function normalizeExtraction(extraction: ProviderMeetingExtraction): ProviderMeetingExtraction {
  return { title: normalizeText(extraction.title, true), summary: normalizeText(extraction.summary), decisions: extraction.decisions.map(item => normalizeText(item)), unresolvedQuestions: extraction.unresolvedQuestions.map(item => normalizeText(item)), actionDrafts: extraction.actionDrafts.map(action => ({ ...action, title: normalizeText(action.title, true), notes: normalizeText(action.notes), assignee: action.assignee === null ? null : normalizeText(action.assignee, true), sourceSegmentIDs: [...new Set(action.sourceSegmentIDs)].sort() })) };
}

export function deriveActionId(meetingId: string, draft: ProviderActionDraftInput): string { return actionId({ meetingId, sourceSegmentIds: draft.sourceSegmentIDs, title: draft.title, assignee: draft.assignee, dueAt: draft.dueAtISO8601 }); }
export function deriveSegmentId(meetingId: string, revision: number, segment: Omit<MeetingSegment, 'id'>): string { return replacementSegmentId({ meetingId, transcriptRevision: revision, startMs: segment.startMs, endMs: segment.endMs, text: segment.text }); }
