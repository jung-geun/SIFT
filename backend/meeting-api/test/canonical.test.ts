import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { actionId, idCanonicalJSON, normalizeText, replacementSegmentId } from '../src/canonical.js';
import { canonicalManifest, expectedPartBounds, validateFlacAudio, validateManifest, validatePartFields } from '../src/media.js';
import { ExtractionSchema, MeetingCreateSchema, MeetingSegmentSchema, PartFieldsSchema, ProviderMeetingExtractionSchema, validateSegments } from '../src/schema.js';

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

describe('hostile JSON boundaries', () => {
  const create = { meetingId, provider: 'onDevice', disclosureVersionID: 'cfg-1', languageTag: 'en', timezoneIdentifier: 'UTC', sampleRate: 16000 };
  it('accepts ordinary and null-prototype inputs but rejects inherited fields and prototype keys', () => {
    expect(MeetingCreateSchema.safeParse(create).success).toBe(true);
    expect(MeetingCreateSchema.safeParse(Object.assign(Object.create(null), create)).success).toBe(true);
    expect(MeetingCreateSchema.safeParse(Object.create(create)).success).toBe(false);
    for (const key of ['__proto__', 'constructor', 'prototype']) {
      const input = JSON.parse(JSON.stringify(create).replace(/}$/, `,"${key}":{}}`));
      expect(MeetingCreateSchema.safeParse(input).success).toBe(false);
      expect(() => idCanonicalJSON(input)).toThrow('INVALID_INPUT_PROPERTIES');
    }
  });
  it('rejects accessors without executing them and rejects unsupported canonical objects', () => {
    let reads = 0;
    const input = { ...create };
    Object.defineProperty(input, 'meetingId', { enumerable: true, get() { reads += 1; return meetingId; } });
    expect(MeetingCreateSchema.safeParse(input).success).toBe(false);
    expect(() => idCanonicalJSON(input)).toThrow('INVALID_INPUT_PROPERTIES');
    expect(reads).toBe(0);
    expect(() => idCanonicalJSON(new Date())).toThrow('INVALID_INPUT_PROTOTYPE');
    expect(() => idCanonicalJSON(new Array(2))).toThrow('INVALID_INPUT_PROPERTIES');
    const cycle: { child?: unknown } = {};
    cycle.child = cycle;
    expect(() => idCanonicalJSON(cycle)).toThrow('CYCLIC_INPUT');
  });
  it('bounds strings, array work, nesting and decimal conversion before processing', () => {
    expect(() => normalizeText('x'.repeat(65_537))).toThrow('INPUT_TEXT_LIMIT');
    let nested: unknown = 0;
    for (let index = 0; index < 34; index += 1) nested = [nested];
    expect(() => idCanonicalJSON(nested)).toThrow('INPUT_COMPLEXITY_LIMIT');
    expect(ExtractionSchema.safeParse({ transcriptionJobId: 'job', transcriptRevision: 0, languageTag: 'en', timezoneIdentifier: 'UTC', segments: Array(20_001).fill(null) }).success).toBe(false);
    const part = { meetingId, languageTag: 'en', timezoneIdentifier: 'UTC', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '1', meetingSampleCount: '1', audioSha256: 'a'.repeat(64) };
    expect(PartFieldsSchema.safeParse({ ...part, meetingSampleCount: '9'.repeat(1024) }).success).toBe(false);
    expect(MeetingCreateSchema.safeParse({ ...create, timezoneIdentifier: 'Not/AZone' }).success).toBe(false);
    expect(MeetingSegmentSchema.safeParse({ id: 'bad id', startMs: 0, endMs: 1, speakerIDs: [], text: 'x', isFinal: false, confidence: null }).success).toBe(false);
    expect(MeetingSegmentSchema.safeParse({ id: 'a', startMs: 0, endMs: 1, speakerIDs: [], text: '\ud800', isFinal: true, confidence: null }).success).toBe(false);
    expect(ProviderMeetingExtractionSchema.safeParse({ title: 'x', summary: 'x'.repeat(65_537), decisions: [], unresolvedQuestions: [], actionDrafts: [] }).success).toBe(false);
  });
});

// Independent bitwise CRC implementation for format fixtures, not the production tables.
function flacCRC(bytes: Buffer, width: 8 | 16): number {
  let crc = 0;
  const mask = width === 8 ? 0xff : 0xffff;
  for (const byte of bytes) {
    crc ^= byte << (width - 8);
    for (let bit = 0; bit < 8; bit += 1) crc = ((crc << 1) ^ (crc & (1 << (width - 1)) ? width === 8 ? 0x07 : 0x8005 : 0)) & mask;
  }
  return crc;
}

// Complete native mono16 FLAC with an actual, CRC-protected silent frame.
function silentFlac(count: number, coding: 'constant' | 'verbatim' | 'fixed' | 'lpc' = 'constant'): Buffer {
  const streaminfo = Buffer.alloc(42);
  streaminfo.write('fLaC');
  streaminfo[4] = 0x80;
  streaminfo.writeUIntBE(34, 5, 3);
  streaminfo.writeUInt16BE(Math.max(16, count), 8);
  streaminfo.writeUInt16BE(Math.max(16, count), 10);
  streaminfo.writeBigUInt64BE((16000n << 44n) | (15n << 36n) | BigInt(count), 18);
  const header = Buffer.from([0xff, 0xf8, 0x75, 0x08, 0, (count - 1) >> 8, (count - 1) & 0xff]);
  let bits = coding === 'constant' ? '0'.repeat(24) : coding === 'verbatim' ? '00000010' + '0'.repeat(count * 16) : coding === 'fixed' ? '00010000' + '000000111100000' : '01000000' + '0'.repeat(16 + 4 + 5 + 1) + '000000111100000';
  bits = bits.padEnd(Math.ceil(bits.length / 8) * 8, '0');
  const payload = Buffer.alloc(bits.length / 8);
  for (let index = 0; index < payload.length; index += 1) payload[index] = Number.parseInt(bits.slice(index * 8, index * 8 + 8), 2);
  const frame = Buffer.concat([header, Buffer.from([flacCRC(header, 8)]), payload]);
  const footer = Buffer.alloc(2);
  footer.writeUInt16BE(flacCRC(frame, 16));
  return Buffer.concat([streaminfo, frame, footer]);
}

describe('native FLAC validation', () => {
  const audio = readFileSync(new URL('./silence.flac', import.meta.url));
  const fields = PartFieldsSchema.parse({ meetingId, languageTag: 'en', timezoneIdentifier: 'UTC', disclosureVersionID: 'cfg-1', partIndex: '0', partCount: '1', partStartSample: '0', ownedStartSample: '0', ownedEndSample: '16000', meetingSampleCount: '16000', audioSha256: 'a'.repeat(64) });
  it('accepts real encoder metadata/padding and all mono subframe families', () => {
    expect(() => validateFlacAudio(audio, fields)).not.toThrow();
    for (const coding of ['constant', 'verbatim', 'fixed', 'lpc'] as const) expect(() => validateFlacAudio(silentFlac(16000, coding), fields)).not.toThrow();
  });
  it('includes the physical overlap in later part sample counts', () => {
    const later = { ...fields, partIndex: 1, partCount: 2, partStartSample: 9_568_000n, ownedStartSample: 9_600_000n, ownedEndSample: 9_600_001n, meetingSampleCount: 9_600_001n };
    expect(() => validateFlacAudio(silentFlac(32_001), later)).not.toThrow();
    expect(() => validateFlacAudio(silentFlac(1), later)).toThrow('FLAC_SAMPLE_COUNT_MISMATCH');
  });
  it('rejects mislabeled content, empty/header-only audio, truncation and appended data', () => {
    expect(() => validateFlacAudio(Buffer.from('not audio'), fields)).toThrow('INVALID_FLAC');
    const complete = silentFlac(16000);
    expect(() => validateFlacAudio(complete.subarray(0, 42), fields)).toThrow('FLAC_SAMPLE_COUNT_MISMATCH');
    expect(() => validateFlacAudio(complete.subarray(0, complete.length - 1), fields)).toThrow('INVALID_FLAC_FRAME');
    expect(() => validateFlacAudio(Buffer.concat([complete, Buffer.from([0])]), fields)).toThrow('INVALID_FLAC_FRAME');
    const highBitMagic = Buffer.from(complete);
    highBitMagic[0] |= 0x80;
    expect(() => validateFlacAudio(highBitMagic, fields)).toThrow('INVALID_FLAC');
  });
  it('rejects inconsistent format, unknown sample count and inconsistent frame totals', () => {
    for (const format of [(48000n << 44n) | (15n << 36n) | 16000n, (16000n << 44n) | (1n << 41n) | (15n << 36n) | 16000n, (16000n << 44n) | (23n << 36n) | 16000n]) {
      const invalid = silentFlac(16000);
      invalid.writeBigUInt64BE(format, 18);
      expect(() => validateFlacAudio(invalid, fields)).toThrow('FLAC_FORMAT_MISMATCH');
    }
    for (const count of [0n, 15999n, 16001n]) {
      const invalid = silentFlac(16000);
      invalid.writeBigUInt64BE((16000n << 44n) | (15n << 36n) | count, 18);
      expect(() => validateFlacAudio(invalid, fields)).toThrow('FLAC_SAMPLE_COUNT_MISMATCH');
    }
    const inconsistent = silentFlac(15999);
    inconsistent.writeBigUInt64BE((16000n << 44n) | (15n << 36n) | 16000n, 18);
    expect(() => validateFlacAudio(inconsistent, fields)).toThrow('FLAC_SAMPLE_COUNT_MISMATCH');
  });
  it('rejects invalid metadata and header/frame checksums', () => {
    const oversized = silentFlac(16000);
    oversized.writeUIntBE(0xffffff, 5, 3);
    expect(() => validateFlacAudio(oversized, fields)).toThrow('INVALID_FLAC_METADATA');
    const invalidBlock = silentFlac(16000);
    invalidBlock.writeUInt16BE(0, 8);
    expect(() => validateFlacAudio(invalidBlock, fields)).toThrow('INVALID_FLAC_STREAMINFO');
    const headerCRC = silentFlac(16000);
    headerCRC[49] ^= 1;
    expect(() => validateFlacAudio(headerCRC, fields)).toThrow('INVALID_FLAC_CRC');
    const frameCRC = silentFlac(16000);
    frameCRC[frameCRC.length - 1] ^= 1;
    expect(() => validateFlacAudio(frameCRC, fields)).toThrow('INVALID_FLAC_CRC');
  });
  it('rejects changed frame format/sequence and forbidden predictor encodings', () => {
    const wrongRate = silentFlac(16000);
    wrongRate[44] = 0x79; // 44.1 kHz, despite canonical STREAMINFO.
    expect(() => validateFlacAudio(wrongRate, fields)).toThrow('FLAC_FORMAT_MISMATCH');
    const wrongChannels = silentFlac(16000);
    wrongChannels[45] = 0x18;
    expect(() => validateFlacAudio(wrongChannels, fields)).toThrow('FLAC_FORMAT_MISMATCH');
    const wrongSequence = silentFlac(16000);
    wrongSequence[46] = 1;
    expect(() => validateFlacAudio(wrongSequence, fields)).toThrow('INVALID_FLAC_FRAME_SEQUENCE');
    const reservedSubframe = silentFlac(16000);
    reservedSubframe[50] = 0x04;
    expect(() => validateFlacAudio(reservedSubframe, fields)).toThrow('INVALID_FLAC_SUBFRAME');
    const negativeShift = silentFlac(16000, 'lpc');
    negativeShift[53] |= 0x08;
    expect(() => validateFlacAudio(negativeShift, fields)).toThrow('INVALID_FLAC_SUBFRAME');
    const reservedResidual = silentFlac(16000, 'fixed');
    reservedResidual[51] |= 0x80;
    expect(() => validateFlacAudio(reservedResidual, fields)).toThrow('INVALID_FLAC_RESIDUAL');
  });
});
