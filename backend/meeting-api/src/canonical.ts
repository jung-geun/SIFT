import { createHash } from 'node:crypto';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const UTC_MS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const ASCII_ID_RE = /^[\x21-\x7E]+$/;
const TRIM_RE = /[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]/u;
const TRIM_START = new RegExp(`^${TRIM_RE.source}+`, 'u');
const TRIM_END = new RegExp(`${TRIM_RE.source}+$`, 'u');
const COLLAPSE = new RegExp(`${TRIM_RE.source}+`, 'gu');

function validateMeetingId(meetingId: string): void {
  if (!UUID_RE.test(meetingId)) throw new Error('INVALID_MEETING_ID');
}

export function normalizeText(value: string, collapse = false): string {
  rejectSurrogates(value);
  const normalized = value.normalize('NFC').replace(/\r\n?/g, '\n').replace(TRIM_START, '').replace(TRIM_END, '');
  return collapse ? normalized.replace(COLLAPSE, ' ') : normalized;
}

export function rejectSurrogates(value: string): void {
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(i + 1);
      if (i + 1 >= value.length || next < 0xdc00 || next > 0xdfff) throw new Error('UNPAIRED_SURROGATE');
      i += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) throw new Error('UNPAIRED_SURROGATE');
  }
}

function escapeString(value: string): string {
  rejectSurrogates(value);
  let out = '"';
  for (const ch of value) {
    const code = ch.codePointAt(0)!;
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else if (code === 0x08) out += '\\b';
    else if (code === 0x09) out += '\\t';
    else if (code === 0x0a) out += '\\n';
    else if (code === 0x0c) out += '\\f';
    else if (code === 0x0d) out += '\\r';
    else if (code < 0x20) out += `\\u00${code.toString(16).padStart(2, '0')}`;
    else out += ch;
  }
  return `${out}"`;
}

/** Deterministic IDCanonicalJSON. Object insertion order is part of each contract. */
export function idCanonicalJSON(value: unknown): string {
  if (value === null) return 'null';
  if (typeof value === 'string') return escapeString(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value) || value < 0) throw new Error('INVALID_INTEGER');
    return String(value);
  }
  if (Array.isArray(value)) return `[${value.map(idCanonicalJSON).join(',')}]`;
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>);
    return `{${entries.map(([key, val]) => `${escapeString(key)}:${idCanonicalJSON(val)}`).join(',')}}`;
  }
  throw new Error('UNSUPPORTED_CANONICAL_VALUE');
}

export function sha256Id(canonical: string): string {
  return createHash('sha256').update(Buffer.from(canonical, 'utf8')).digest('hex').slice(0, 32);
}

export type SegmentForId = { meetingId: string; transcriptRevision: number; startMs: number; endMs: number; text: string };
export function replacementSegmentId(input: SegmentForId): string {
  validateMeetingId(input.meetingId);
  const value = { meetingId: input.meetingId, transcriptRevision: input.transcriptRevision, startMs: input.startMs, endMs: input.endMs, text: normalizeText(input.text) };
  return sha256Id(idCanonicalJSON(value));
}

export type ActionForId = { meetingId: string; sourceSegmentIds: string[]; title: string; assignee: string | null; dueAt: string | null };
export function actionId(input: ActionForId): string {
  validateMeetingId(input.meetingId);
  if (input.dueAt !== null) {
    if (!UTC_MS_RE.test(input.dueAt)) throw new Error('INVALID_DUE_AT');
    const dueMs = Date.parse(input.dueAt);
    if (!Number.isFinite(dueMs) || new Date(dueMs).toISOString() !== input.dueAt) throw new Error('INVALID_DUE_AT');
  }
  if (input.sourceSegmentIds.some(id => !ASCII_ID_RE.test(id))) throw new Error('INVALID_SOURCE_SEGMENT_ID');
  const sourceSegmentIds = [...new Set(input.sourceSegmentIds)].sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
  const value = { meetingId: input.meetingId, sourceSegmentIds, title: normalizeText(input.title, true), assignee: input.assignee === null ? null : normalizeText(input.assignee, true), dueAt: input.dueAt };
  return sha256Id(idCanonicalJSON(value));
}
