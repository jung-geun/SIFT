export const MAX_BODY_BYTES = 786432;
export const MAX_DIAGNOSTIC_BYTES = 524288;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export const STATUSES = ['new', 'in_progress', 'resolved', 'declined'] as const;
export type Status = typeof STATUSES[number];
export type AppMetadata = { version: string; build: string; platform: 'iOS' | 'iPadOS' | 'macOS'; osVersion: string; language: string };
export type Submission = { schemaVersion: 1; submissionID: string; kind: 'bug' | 'feature'; title: string; message: string; app: AppMetadata; diagnostics?: string };
export class HTTPError extends Error {
  constructor(public status: number, public errorCode: string, public retryAfter?: number) { super(errorCode); }
}
export function invalid(): never { throw new HTTPError(400, 'INVALID_REQUEST'); }
export function object(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) invalid();
  return value as Record<string, unknown>;
}
export function keys(value: Record<string, unknown>, required: string[], optional: string[] = []): void {
  if (required.some(key => !Object.hasOwn(value, key)) || Object.keys(value).some(key => !required.includes(key) && !optional.includes(key))) invalid();
}
function unicode(value: string): boolean {
  // Reject lone surrogates: JSON accepts them but they have no exact UTF-8 text.
  return !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value);
}
export function text(value: unknown, maximum: number, minimum = 1, trimmed = true): string {
  if (typeof value !== 'string' || !unicode(value)) invalid();
  const normalized = trimmed ? value.trim() : value;
  let count = 0;
  for (const _ of normalized) { if (++count > maximum) invalid(); }
  if (count < minimum) invalid();
  return normalized;
}
export function submission(value: unknown): Submission {
  const input = object(value);
  keys(input, ['schemaVersion', 'submissionID', 'kind', 'title', 'message', 'app'], ['diagnostics']);
  if (input.schemaVersion !== 1 || typeof input.submissionID !== 'string' || !UUID.test(input.submissionID) || (input.kind !== 'bug' && input.kind !== 'feature')) invalid();
  const app = object(input.app);
  keys(app, ['version', 'build', 'platform', 'osVersion', 'language']);
  if (!['iOS', 'iPadOS', 'macOS'].includes(app.platform as string)) invalid();
  const result: Submission = {
    schemaVersion: 1, submissionID: input.submissionID, kind: input.kind,
    title: text(input.title, 120), message: text(input.message, 8000),
    app: { version: text(app.version, 32), build: text(app.build, 32), platform: app.platform as AppMetadata['platform'], osVersion: text(app.osVersion, 64), language: text(app.language, 32) },
  };
  if (Object.hasOwn(input, 'diagnostics')) {
    if (result.kind !== 'bug' || typeof input.diagnostics !== 'string' || !unicode(input.diagnostics)) invalid();
    if (new TextEncoder().encode(input.diagnostics).byteLength > MAX_DIAGNOSTIC_BYTES) throw new HTTPError(413, 'REQUEST_TOO_LARGE');
    try { object(JSON.parse(input.diagnostics)); } catch { invalid(); }
    // SQLite JSON has a 1,000-container nesting limit. Count structural tokens
    // outside strings after syntax validation, without reserializing the report.
    let depth = 0;
    let quoted = false;
    let escaped = false;
    for (const character of input.diagnostics) {
      if (quoted) {
        if (escaped) escaped = false;
        else if (character === '\\') escaped = true;
        else if (character === '"') quoted = false;
      } else if (character === '"') quoted = true;
      else if (character === '{' || character === '[') { if (++depth > 1000) invalid(); }
      else if (character === '}' || character === ']') depth--;
    }
    result.diagnostics = input.diagnostics; // Never reserialize, normalize, or redact previewed text.
  }
  return result;
}
export function patch(value: unknown): {status: Status; notes: string} {
  const input = object(value);
  keys(input, ['status', 'notes']);
  if (!STATUSES.includes(input.status as Status)) invalid();
  return { status: input.status as Status, notes: text(input.notes, 8000, 0, false) };
}
export async function boundedJSON(request: Request, maximum = MAX_BODY_BYTES): Promise<unknown> {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers.get('Content-Type') ?? '') || request.headers.has('Content-Encoding')) invalid();
  const declared = request.headers.get('Content-Length');
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > maximum)) throw new HTTPError(413, 'REQUEST_TOO_LARGE');
  if (!request.body) invalid();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    for (;;) {
      const part = await reader.read();
      if (part.done) break;
      bytes += part.value.byteLength;
      if (bytes > maximum) { await reader.cancel(); throw new HTTPError(413, 'REQUEST_TOO_LARGE'); }
      chunks.push(part.value);
    }
  } finally { reader.releaseLock(); }
  const buffer = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) { buffer.set(chunk, offset); offset += chunk.byteLength; }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(buffer)); } catch { invalid(); }
}
