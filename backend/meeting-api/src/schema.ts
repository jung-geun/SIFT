import { z } from 'zod';
import { actionId, assertSafeInput, MAX_ARRAY_LENGTH, MAX_TEXT_LENGTH, normalizeText, replacementSegmentId } from './canonical.js';

export const UUID = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
export const MeetingProcessingMode = z.enum(['onDevice', 'openAI', 'google']);
export type MeetingProcessingMode = z.infer<typeof MeetingProcessingMode>;
export const MeetingStatus = z.enum(['recording', 'paused', 'interrupted', 'stopping', 'finalizingTranscript', 'extractingActions', 'ready', 'failed', 'cancelled']);


function safeObject<T extends z.ZodRawShape>(shape: T) {
  return z.preprocess((value, context) => {
    try { assertSafeInput(value); } catch (error) {
      context.addIssue({ code: 'custom', message: error instanceof Error ? error.message : 'INVALID_INPUT' });
      return z.NEVER;
    }
    return value;
  }, z.object(shape).strict());
}
const text = z.string().max(MAX_TEXT_LENGTH);
const identifier = z.string().min(1).max(128).regex(/^[\x21-\x7E]+$/);
const languageTag = z.string().max(64).regex(/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/);
const timezoneIdentifier = z.string().min(1).max(128).refine(value => {
  try { new Intl.DateTimeFormat('en', { timeZone: value }); return true; } catch { return false; }
});
const samples = z.number().int().nonnegative().max(345_600_000);
const finiteConfidence = z.number().finite().min(0).max(1);
const sortedUniqueSpeakers = z.array(identifier).max(16).refine(speakers => speakers.every((speaker, index) => index === 0 || speakers[index - 1] < speaker), { message: 'SPEAKER_IDS_NOT_SORTED_UNIQUE' });
export const MeetingSegmentSchema = safeObject({ id: identifier, startMs: z.number().int().nonnegative().max(21_600_000), endMs: z.number().int().nonnegative().max(21_600_000), speakerIDs: sortedUniqueSpeakers, text, isFinal: z.boolean(), confidence: finiteConfidence.nullable() });
export type MeetingSegment = z.infer<typeof MeetingSegmentSchema>;

export const ProviderActionDraftInputSchema = safeObject({ title: text, notes: text, assignee: text.nullable(), dueAtISO8601: z.string().max(24).nullable(), sourceSegmentIDs: z.array(identifier).max(MAX_ARRAY_LENGTH), confidence: finiteConfidence, requiresReview: z.boolean() });
export type ProviderActionDraftInput = z.infer<typeof ProviderActionDraftInputSchema>;
export const ProviderMeetingExtractionSchema = safeObject({ title: text, summary: text, decisions: z.array(text).max(1024), unresolvedQuestions: z.array(text).max(1024), actionDrafts: z.array(ProviderActionDraftInputSchema).max(1024) });
export type ProviderMeetingExtraction = z.infer<typeof ProviderMeetingExtractionSchema>;

export const MeetingCreateSchema = safeObject({ meetingId: UUID, provider: MeetingProcessingMode, disclosureVersionID: identifier, languageTag, timezoneIdentifier, sampleRate: z.literal(16000), expectedSpeakerRange: safeObject({ min: z.number().int().min(1).max(16), max: z.number().int().min(1).max(16) }).refine(r => r.min <= r.max).optional() });
export type MeetingCreate = z.infer<typeof MeetingCreateSchema>;

const MAX_UINT64 = 18_446_744_073_709_551_615n;
const decimalUInt = z.string().max(20).regex(/^(0|[1-9][0-9]*)$/).transform(value => BigInt(value)).refine(value => value <= MAX_UINT64, { message: 'UINT64_LIMIT' });
const decimalUIntNumber = z.string().max(2).regex(/^(0|[1-9][0-9]*)$/).transform(value => Number(value));
export const PartFieldsSchema = safeObject({ meetingId: UUID, languageTag, timezoneIdentifier, disclosureVersionID: identifier, partIndex: decimalUIntNumber.pipe(z.number().int().min(0).max(35)), partCount: decimalUIntNumber.pipe(z.number().int().min(1).max(36)), partStartSample: decimalUInt, ownedStartSample: decimalUInt, ownedEndSample: decimalUInt, meetingSampleCount: decimalUInt, audioSha256: z.string().regex(/^[0-9a-f]{64}$/) });
export type PartFields = z.infer<typeof PartFieldsSchema>;

export const ManifestPartSchema = safeObject({ partIndex: z.number().int().min(0).max(35), partStartSample: samples, ownedStartSample: samples, ownedEndSample: samples, sha256: z.string().regex(/^[0-9a-f]{64}$/), byteCount: z.number().int().positive().max(23_000_000) });
export type ManifestPart = z.infer<typeof ManifestPartSchema>;
export const FinalizeManifestSchema = safeObject({ meetingSampleCount: samples.min(1), partCount: z.number().int().min(1).max(36), parts: z.array(ManifestPartSchema).min(1).max(36) });
export type FinalizeManifest = z.infer<typeof FinalizeManifestSchema>;

export const ExtractionSchema = safeObject({ transcriptionJobId: identifier, transcriptRevision: z.number().int().nonnegative(), languageTag, timezoneIdentifier, segments: z.array(MeetingSegmentSchema).max(MAX_ARRAY_LENGTH) });

export function validateSegments(segments: MeetingSegment[], totalMs?: number): void {
  assertSafeInput(segments);
  if (totalMs !== undefined && (!Number.isSafeInteger(totalMs) || totalMs < 0 || totalMs > 21_600_000)) throw new Error('INVALID_SEGMENT_BOUNDS');
  const ids = new Set<string>(); let previousStart = -1; let previousEnd = -1; let previousId = '';
  for (const segment of segments) {
    if (!MeetingSegmentSchema.safeParse(segment).success) throw new Error('INVALID_SEGMENT');
    const tupleOutOfOrder = segment.startMs < previousStart || (segment.startMs === previousStart && segment.endMs < previousEnd) || (segment.startMs === previousStart && segment.endMs === previousEnd && segment.id <= previousId);
    if (segment.endMs <= segment.startMs || tupleOutOfOrder || (totalMs !== undefined && segment.endMs > totalMs)) throw new Error('INVALID_SEGMENT_BOUNDS');
    if (ids.has(segment.id)) throw new Error('DUPLICATE_SEGMENT_ID');
    ids.add(segment.id); previousStart = segment.startMs; previousEnd = segment.endMs; previousId = segment.id;
    if (segment.speakerIDs.some(speaker => !speaker)) throw new Error('INVALID_SPEAKER_ID');
    if (segment.confidence !== null && (!Number.isFinite(segment.confidence) || segment.confidence < 0 || segment.confidence > 1)) throw new Error('INVALID_CONFIDENCE');
  }
}

export function normalizeExtraction(extraction: ProviderMeetingExtraction): ProviderMeetingExtraction {
  ProviderMeetingExtractionSchema.parse(extraction);
  return { title: normalizeText(extraction.title, true), summary: normalizeText(extraction.summary), decisions: extraction.decisions.map(item => normalizeText(item)), unresolvedQuestions: extraction.unresolvedQuestions.map(item => normalizeText(item)), actionDrafts: extraction.actionDrafts.map(action => ({ ...action, title: normalizeText(action.title, true), notes: normalizeText(action.notes), assignee: action.assignee === null ? null : normalizeText(action.assignee, true), sourceSegmentIDs: [...new Set(action.sourceSegmentIDs)].sort() })) };
}

export function deriveActionId(meetingId: string, draft: ProviderActionDraftInput): string { return actionId({ meetingId, sourceSegmentIds: draft.sourceSegmentIDs, title: draft.title, assignee: draft.assignee, dueAt: draft.dueAtISO8601 }); }
export function deriveSegmentId(meetingId: string, revision: number, segment: Omit<MeetingSegment, 'id'>): string { return replacementSegmentId({ meetingId, transcriptRevision: revision, startMs: segment.startMs, endMs: segment.endMs, text: segment.text }); }
