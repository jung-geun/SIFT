import { describe, expect, it } from 'vitest';
import { actionId, idCanonicalJSON, normalizeText, replacementSegmentId } from '../src/canonical.js';
import { canonicalManifest, expectedPartBounds, validateManifest, validatePartFields } from '../src/media.js';
import { MeetingSegmentSchema, PartFieldsSchema, validateSegments } from '../src/schema.js';

const meetingId = '123e4567-e89b-12d3-a456-426614174000';

describe('IDCanonicalJSON vectors', () => {
  it('matches authoritative segment vectors byte-for-byte', () => {
    const vectors = [
      { revision: 0, start: 0, end: 1000, text: '  민수님이 다음 주 화요일까지 견적서를 보내주세요\r\n', canonical: String.raw`{"meetingId":"123e4567-e89b-12d3-a456-426614174000","transcriptRevision":0,"startMs":0,"endMs":1000,"text":"민수님이 다음 주 화요일까지 견적서를 보내주세요"}`, id: 'b1d9ec713d8164418c29c9fa85b30423' },
      { revision: 1, start: 1000, end: 2000, text: '회의 내용', canonical: String.raw`{"meetingId":"123e4567-e89b-12d3-a456-426614174000","transcriptRevision":1,"startMs":1000,"endMs":2000,"text":"회의 내용"}`, id: '22a82fb8c90b4004e05a13c5671738ee' },
      { revision: 2, start: 2000, end: 3000, text: '"\\/\b\t\n\f\r\u0001  ', canonical: String.raw`{"meetingId":"123e4567-e89b-12d3-a456-426614174000","transcriptRevision":2,"startMs":2000,"endMs":3000,"text":"\"\\/\b\t\n\f\n\u0001"}`, id: '3804ba789cb1d8d3cce071aa17251af5' },
      { revision: 9007199254740991, start: 0, end: 9007199254740991, text: '앞 중간 끝', canonical: String.raw`{"meetingId":"123e4567-e89b-12d3-a456-426614174000","transcriptRevision":9007199254740991,"startMs":0,"endMs":9007199254740991,"text":"앞 중간 끝"}`, id: '029e3179e11f497b4342bcb902c98b20' }
    ];
    for (const vector of vectors) {
      const canonical = idCanonicalJSON({ meetingId, transcriptRevision: vector.revision, startMs: vector.start, endMs: vector.end, text: normalizeText(vector.text) });
      expect(canonical).toBe(vector.canonical);
      expect(replacementSegmentId({ meetingId, transcriptRevision: vector.revision, startMs: vector.start, endMs: vector.end, text: vector.text })).toBe(vector.id);
    }
  });

  it('matches action vectors and rejects invalid canonical inputs', () => {
    expect(idCanonicalJSON({ n: 9007199254740991 })).toBe('{"n":9007199254740991}');
    expect(actionId({ meetingId, sourceSegmentIds: ['bbbb', 'aaaa', 'bbbb'], title: '  견적서 제출  ', assignee: null, dueAt: null })).toBe('ea912f8e12cf7512daa4ea43a2fe958f');
    expect(actionId({ meetingId, sourceSegmentIds: ['0001', '0002'], title: '\t정산  자료\n공유 ', assignee: ' 민수 님 ', dueAt: '2026-07-14T00:00:00.000Z' })).toBe('1441a82b6dcff9b5de1388f3db781c87');
    expect(() => idCanonicalJSON({ n: 9007199254740992 })).toThrow('INVALID_INTEGER');
    expect(() => replacementSegmentId({ meetingId: meetingId.toUpperCase(), transcriptRevision: 0, startMs: 0, endMs: 1, text: 'x' })).toThrow('INVALID_MEETING_ID');
    expect(() => actionId({ meetingId, sourceSegmentIds: ['bad id'], title: 'x', assignee: null, dueAt: null })).toThrow('INVALID_SOURCE_SEGMENT_ID');
    expect(() => actionId({ meetingId, sourceSegmentIds: ['a'], title: 'x', assignee: null, dueAt: '2026-07-14T00:00:00Z' })).toThrow('INVALID_DUE_AT');
    expect(() => actionId({ meetingId, sourceSegmentIds: ['a'], title: 'x', assignee: null, dueAt: '2026-02-29T00:00:00.000Z' })).toThrow('INVALID_DUE_AT');
    expect(actionId({ meetingId, sourceSegmentIds: ['a'], title: 'x', assignee: null, dueAt: '2024-02-29T00:00:00.000Z' })).toHaveLength(32);
    expect(() => idCanonicalJSON({ value: String.fromCharCode(0xd800) })).toThrow('UNPAIRED_SURROGATE');
    expect(() => idCanonicalJSON({ value: String.fromCharCode(0xdfff) })).toThrow('UNPAIRED_SURROGATE');
  });
});

describe('multipart UInt64 schema', () => {
  const base = { meetingId, languageTag: 'ko-KR', timezoneIdentifier: 'Asia/Seoul', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '1', meetingSampleCount: '1', audioSha256: 'a'.repeat(64) };
  it('accepts canonical decimal and returns bigint samples', () => {
    const parsed = PartFieldsSchema.parse(base);
    expect(parsed.partStartSample).toBe(0n);
    expect(parsed.meetingSampleCount).toBe(1n);
  });
  it.each(['+1', '01', ' 1', '0x1', '1 '])('rejects non-decimal value %s', value => {
    expect(PartFieldsSchema.safeParse({ ...base, meetingSampleCount: value }).success).toBe(false);
  });
  it('enforces uint64 maximum', () => {
    expect(PartFieldsSchema.safeParse({ ...base, meetingSampleCount: '18446744073709551615' }).success).toBe(true);
    expect(PartFieldsSchema.safeParse({ ...base, meetingSampleCount: '18446744073709551616' }).success).toBe(false);
  });
});

describe('segment invariants', () => {
  const segment = (id: string, startMs: number, endMs: number, speakers: string[] = []): unknown => ({ id, startMs, endMs, speakerIDs: speakers, text: 'x', isFinal: true, confidence: null });
  it('requires confidence and sorted unique speaker IDs', () => {
    expect(MeetingSegmentSchema.safeParse({ id: 'a', startMs: 0, endMs: 1, speakerIDs: [], text: 'x', isFinal: true }).success).toBe(false);
    expect(MeetingSegmentSchema.safeParse(segment('a', 0, 1, ['speaker-2', 'speaker-1'])).success).toBe(false);
    expect(MeetingSegmentSchema.safeParse(segment('a', 0, 1, ['speaker-1', 'speaker-1'])).success).toBe(false);
  });
  it('allows overlap while enforcing lexicographic time/id order', () => {
    const parsed = [segment('b', 0, 50, []), segment('a', 0, 100, [])].map(item => MeetingSegmentSchema.parse(item));
    expect(() => validateSegments(parsed)).not.toThrow();
    expect(() => validateSegments([parsed[1], parsed[0]])).toThrow('INVALID_SEGMENT_BOUNDS');
  });
});

describe('media manifest invariants', () => {
  const hash = 'a'.repeat(64);
  const tenMinute = {
    meetingSampleCount: 9_600_000,
    partCount: 1,
    parts: [{ partIndex: 0, ...expectedPartBounds(0, 9_600_000), sha256: hash, byteCount: 1 }],
  };

  it('accepts exact owned bounds and canonicalizes the validated manifest unchanged', () => {
    validateManifest(tenMinute);
    expect(canonicalManifest(tenMinute)).toBe('{"meetingSampleCount":9600000,"partCount":1,"parts":[{"byteCount":1,"ownedEndSample":9600000,"ownedStartSample":0,"partIndex":0,"partStartSample":0,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}');
  });

  it('rejects shuffled manifest parts before canonicalization', () => {
    const total = 9_600_001;
    const parts = [0, 1].map(partIndex => ({ partIndex, ...expectedPartBounds(partIndex, total), sha256: hash, byteCount: 1 }));
    expect(() => validateManifest({ meetingSampleCount: total, partCount: 2, parts: [parts[1], parts[0]] })).toThrow('PART_ORDER_MISMATCH');
  });

  it('rejects zero-sample media and impossible parts', () => {
    expect(() => validateManifest({ ...tenMinute, meetingSampleCount: 0, parts: [{ ...tenMinute.parts[0], ownedEndSample: 0 }] })).toThrow('SAMPLE_COUNT_LIMIT');
    expect(() => validateManifest({ ...tenMinute, parts: [{ ...tenMinute.parts[0], ownedEndSample: 9_599_999 }] })).toThrow('PART_BOUNDS_MISMATCH');
    expect(() => validatePartFields(PartFieldsSchema.parse({
      meetingId,
      languageTag: 'ko-KR',
      timezoneIdentifier: 'Asia/Seoul',
      disclosureVersionID: 'cfg-1',
      partIndex: '0',
      partCount: '1',
      partStartSample: '0',
      ownedStartSample: '0',
      ownedEndSample: '0',
      meetingSampleCount: '0',
      audioSha256: hash,
    }), 1)).toThrow('SAMPLE_COUNT_LIMIT');
  });
});
