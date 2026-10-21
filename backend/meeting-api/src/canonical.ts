import { createHash } from 'node:crypto';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const UTC_MS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const ASCII_ID_RE = /^[\x21-\x7E]+$/;
const TRIM_RE = /[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]/u;
const TRIM_START = new RegExp(`^${TRIM_RE.source}+`, 'u');
const TRIM_END = new RegExp(`${TRIM_RE.source}+$`, 'u');
const COLLAPSE = new RegExp(`${TRIM_RE.source}+`, 'gu');

// Shared JSON boundary for schemas and ID serialization. Limits apply before
// normalization, recursion, BigInt conversion, or provider-result processing.
export const MAX_TEXT_LENGTH = 65_536;
export const MAX_ARRAY_LENGTH = 20_000;
export function assertSafeInput(value: unknown): void {
  const ancestors = new Set<object>();
  let nodes = 0;
  let characters = 0;
  function visit(item: unknown, depth: number): void {
    if (++nodes > 100_000 || depth > 32) throw new Error('INPUT_COMPLEXITY_LIMIT');
    if (typeof item === 'string') {
      characters += item.length;
      if (item.length > MAX_TEXT_LENGTH || characters > 2_000_000) throw new Error('INPUT_TEXT_LIMIT');
      rejectSurrogates(item);
      return;
    }
    if (item === null || typeof item === 'boolean' || typeof item === 'number' || typeof item === 'bigint') return;
    if (typeof item !== 'object') throw new Error('UNSUPPORTED_CANONICAL_VALUE');
    const array = Array.isArray(item);
    const prototype = Object.getPrototypeOf(item);
    if (array ? prototype !== Array.prototype : prototype !== Object.prototype && prototype !== null) throw new Error('INVALID_INPUT_PROTOTYPE');
    if (ancestors.has(item)) throw new Error('CYCLIC_INPUT');
    if (array && item.length > MAX_ARRAY_LENGTH) throw new Error('INPUT_COMPLEXITY_LIMIT');
    const keys = Reflect.ownKeys(item);
    if (keys.length > MAX_ARRAY_LENGTH || (array && keys.length !== item.length + 1)) throw new Error('INVALID_INPUT_PROPERTIES');
    ancestors.add(item);
    for (const key of keys) {
      if (array && key === 'length') continue;
      if (typeof key !== 'string' || key === '__proto__' || key === 'constructor' || key === 'prototype') throw new Error('INVALID_INPUT_PROPERTIES');
      if (array && (!/^(0|[1-9][0-9]*)$/.test(key) || Number(key) >= item.length)) throw new Error('INVALID_INPUT_PROPERTIES');
      const property = Object.getOwnPropertyDescriptor(item, key)!;
      if (!property.enumerable || !Object.hasOwn(property, 'value')) throw new Error('INVALID_INPUT_PROPERTIES');
      characters += key.length;
      if (key.length > MAX_TEXT_LENGTH || characters > 2_000_000) throw new Error('INPUT_TEXT_LIMIT');
      rejectSurrogates(key);
      visit(property.value, depth + 1);
    }
    ancestors.delete(item);
  }
  visit(value, 0);
}

export function normalizeText(value: string, collapse = false): string {
  rejectSurrogates(value);
  const normalized = value.normalize('NFC').replace(/\r\n?/g, '\n').replace(TRIM_START, '').replace(TRIM_END, '');
  return collapse ? normalized.replace(COLLAPSE, ' ') : normalized;
}

export function rejectSurrogates(value: string): void {
  if (typeof value !== 'string' || value.length > MAX_TEXT_LENGTH) throw new Error('INPUT_TEXT_LIMIT');
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

/** Deterministic IDCanonicalJSON; insertion order is contractual, not sorted. */
export function idCanonicalJSON(value: unknown): string {
  assertSafeInput(value);
  function serialize(item: unknown): string {
    if (item === null) return 'null';
    if (typeof item === 'string') return escapeString(item);
    if (typeof item === 'boolean') return item ? 'true' : 'false';
    if (typeof item === 'number') {
      if (!Number.isSafeInteger(item) || item < 0) throw new Error('INVALID_INTEGER');
      return String(item);
    }
    if (Array.isArray(item)) return `[${item.map(serialize).join(',')}]`;
    if (typeof item === 'object') return `{${Object.entries(item as Record<string, unknown>).map(([key, val]) => `${escapeString(key)}:${serialize(val)}`).join(',')}}`;
    throw new Error('UNSUPPORTED_CANONICAL_VALUE');
  }
  return serialize(value);
}

export function sha256Id(canonical: string): string {
  return createHash('sha256').update(Buffer.from(canonical, 'utf8')).digest('hex').slice(0, 32);
}

export type SegmentForId = { meetingId: string; transcriptRevision: number; startMs: number; endMs: number; text: string };
export function replacementSegmentId(input: SegmentForId): string {
  assertSafeInput(input);
  if (typeof input.meetingId !== 'string' || !UUID_RE.test(input.meetingId)) throw new Error('INVALID_MEETING_ID');
  const value = { meetingId: input.meetingId, transcriptRevision: input.transcriptRevision, startMs: input.startMs, endMs: input.endMs, text: normalizeText(input.text) };
  return sha256Id(idCanonicalJSON(value));
}

export type ActionForId = { meetingId: string; sourceSegmentIds: string[]; title: string; assignee: string | null; dueAt: string | null };
export function actionId(input: ActionForId): string {
  assertSafeInput(input);
  if (typeof input.meetingId !== 'string' || !UUID_RE.test(input.meetingId)) throw new Error('INVALID_MEETING_ID');
  if (input.dueAt !== null) {
    if (!UTC_MS_RE.test(input.dueAt)) throw new Error('INVALID_DUE_AT');
    const dueMs = Date.parse(input.dueAt);
    if (!Number.isFinite(dueMs) || new Date(dueMs).toISOString() !== input.dueAt) throw new Error('INVALID_DUE_AT');
  }
  if (!Array.isArray(input.sourceSegmentIds) || input.sourceSegmentIds.some(id => typeof id !== 'string' || id.length > 128 || !ASCII_ID_RE.test(id))) throw new Error('INVALID_SOURCE_SEGMENT_ID');
  const sourceSegmentIds = [...new Set(input.sourceSegmentIds)].sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
  const value = { meetingId: input.meetingId, sourceSegmentIds, title: normalizeText(input.title, true), assignee: input.assignee === null ? null : normalizeText(input.assignee, true), dueAt: input.dueAt };
  return sha256Id(idCanonicalJSON(value));
}
