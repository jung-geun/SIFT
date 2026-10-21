import { boundedJSON, HTTPError, invalid, patch, STATUSES, submission, UUID, type Status } from './validation';

export interface Env {
  DB: D1Database;
  ADMIN_TOKEN: string;
  NETWORK_HMAC_SECRET: string;
  INTAKE_ENABLED: string;
  ENVIRONMENT?: string;
}
type Row = {
  ticket_id: string; submission_id: string; payload_hash: string; received_at: string;
  kind: string; title: string; message: string; app_json: string; diagnostics: string | null;
  status: Status; notes: string; updated_at: string;
};
const encoder = new TextEncoder();
const DAY = 86400000;
const DETAIL = 'ticket_id,received_at,kind,title,message,app_json,diagnostics,status,notes,updated_at';
const SUMMARY = 'ticket_id,received_at,kind,title,app_json,status,(diagnostics IS NOT NULL) AS has_diagnostics';
const PRODUCTION_ORIGIN = 'https://sift.pieroot.xyz';

function response(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', ...extra };
  return body === null ? new Response(null, { status, headers }) : Response.json(body, { status, headers });
}
function available(env: Env): boolean {
  return !!env.DB && typeof env.ADMIN_TOKEN === 'string' && /^[\x21-\x7e]{32,1024}$/.test(env.ADMIN_TOKEN)
    && typeof env.NETWORK_HMAC_SECRET === 'string' && encoder.encode(env.NETWORK_HMAC_SECRET).length >= 32;
}
function allowedOrigin(origin: string, env: Env): boolean {
  if (origin === PRODUCTION_ORIGIN) return true;
  if (env.ENVIRONMENT !== 'development') return false;
  try {
    const url = new URL(origin);
    return url.origin === origin && url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  } catch { return false; }
}
async function digest(value: string): Promise<ArrayBuffer> { return crypto.subtle.digest('SHA-256', encoder.encode(value)); }
function hex(value: ArrayBuffer): string { return Array.from(new Uint8Array(value), byte => byte.toString(16).padStart(2, '0')).join(''); }
async function authorize(request: Request, env: Env): Promise<void> {
  const header = request.headers.get('Authorization') ?? '';
  // Hash to identical fixed-size buffers before the runtime constant-time compare.
  // Bounds prevent an attacker forcing unbounded hashing/header allocation.
  const candidate = header.startsWith('Bearer ') && header.length <= 1031 ? header.slice(7) : '';
  const [provided, expected] = await Promise.all([digest(candidate), digest(env.ADMIN_TOKEN)]);
  if (!crypto.subtle.timingSafeEqual(provided, expected)) throw new HTTPError(401, 'UNAUTHORIZED');
}
async function networkKey(request: Request, env: Env, day: string): Promise<string> {
  // Never trust X-Forwarded-For/X-Real-IP. Cloudflare supplies this header at its edge.
  let ip = request.headers.get('CF-Connecting-IP');
  if (!ip && env.ENVIRONMENT === 'development') ip = '127.0.0.1';
  if (!ip || ip.length > 45 || !/^[0-9a-fA-F:.]+$/.test(ip)) throw new HTTPError(503, 'INTAKE_UNAVAILABLE');
  const key = await crypto.subtle.importKey('raw', encoder.encode(env.NETWORK_HMAC_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', key, encoder.encode(`${day}\n${ip}`)));
}
function retryAfter(now: Date): number { return Math.max(1, Math.ceil((Date.parse(`${now.toISOString().slice(0, 10)}T00:00:00.000Z`) + DAY - now.getTime()) / 1000)); }
function databaseFailure(error: unknown, now: Date): never {
  const message = error instanceof Error ? error.message : '';
  if (message.includes('FEEDBACK_RATE_LIMITED')) throw new HTTPError(429, 'RATE_LIMITED', retryAfter(now));
  if (message.includes('FEEDBACK_CAPACITY_REACHED')) throw new HTTPError(503, 'CAPACITY_REACHED');
  throw new HTTPError(503, 'INTAKE_UNAVAILABLE');
}
async function create(request: Request, env: Env): Promise<Response> {
  if (env.INTAKE_ENABLED !== 'true') throw new HTTPError(503, 'INTAKE_UNAVAILABLE');
  if (request.headers.has('Authorization') || request.headers.has('Cookie')) invalid();
  const payload = submission(await boundedJSON(request));
  const canonical = JSON.stringify(payload); // Explicit validator field ordering, exact diagnostics string.
  const payloadHash = hex(await digest(canonical));
  const now = new Date();
  const receivedAt = now.toISOString();
  const day = receivedAt.slice(0, 10);
  const networkHash = await networkKey(request, env, day);
  const ticketID = crypto.randomUUID();
  try {
    const result = await env.DB.batch([
      env.DB.prepare(`INSERT INTO feedback(ticket_id,submission_id,payload_hash,received_at,expires_at,kind,title,message,app_json,diagnostics,updated_at,payload_bytes,day,network_hash)
        SELECT ?,?,?,?,?,?,?,?,?,?,?,?,?,? WHERE NOT EXISTS(SELECT 1 FROM feedback WHERE submission_id=?)`)
        .bind(ticketID, payload.submissionID, payloadHash, receivedAt, new Date(now.getTime() + 30 * DAY).toISOString(), payload.kind, payload.title, payload.message, JSON.stringify(payload.app), payload.diagnostics ?? null, receivedAt, encoder.encode(canonical).byteLength, day, networkHash, payload.submissionID),
      env.DB.prepare('SELECT ticket_id,payload_hash,received_at,expires_at FROM feedback WHERE submission_id=?').bind(payload.submissionID),
    ]);
    const stored = result[1].results[0] as unknown as {ticket_id: string; payload_hash: string; received_at: string; expires_at: string} | undefined;
    if (!stored) throw new HTTPError(503, 'INTAKE_UNAVAILABLE');
    // Expired receipt identifiers are not reused before pruning, and old content
    // is never acknowledged as a new delivery after the retention boundary.
    if (stored.payload_hash !== payloadHash || stored.expires_at <= receivedAt) throw new HTTPError(409, 'SUBMISSION_CONFLICT');
    return response({ ticketID: stored.ticket_id, receivedAt: stored.received_at }, stored.ticket_id === ticketID ? 201 : 200);
  } catch (error) {
    if (error instanceof HTTPError) throw error;
    databaseFailure(error, now);
  }
}
function detail(row: Row): Record<string, unknown> {
  return { ticketID: row.ticket_id, receivedAt: row.received_at, kind: row.kind, title: row.title, message: row.message,
    app: JSON.parse(row.app_json), ...(row.diagnostics !== null ? { diagnostics: row.diagnostics } : {}), status: row.status, notes: row.notes, updatedAt: row.updated_at };
}
type Cursor = { receivedAt: string; ticketID: string; status: string | null };
function decodeCursor(value: string, status: string | null): Cursor {
  if (value.length > 512 || !/^[A-Za-z0-9_-]+$/.test(value)) invalid();
  try {
    const parsed = JSON.parse(atob(value.replace(/-/g, '+').replace(/_/g, '/'))) as Cursor;
    if (typeof parsed.receivedAt !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(parsed.receivedAt) || !Number.isFinite(Date.parse(parsed.receivedAt)) || !UUID.test(parsed.ticketID) || parsed.status !== status) invalid();
    return parsed;
  } catch { invalid(); }
}
function encodeCursor(cursor: Cursor): string { return btoa(JSON.stringify(cursor)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
async function list(url: URL, env: Env): Promise<Response> {
  for (const key of url.searchParams.keys()) if (!['status', 'cursor', 'limit'].includes(key) || url.searchParams.getAll(key).length !== 1) invalid();
  const status = url.searchParams.get('status');
  if (status !== null && !STATUSES.includes(status as Status)) invalid();
  const rawLimit = url.searchParams.get('limit') ?? '25';
  if (!/^[1-9]\d?$/.test(rawLimit) || Number(rawLimit) > 50) invalid();
  const limit = Number(rawLimit);
  const cursor = url.searchParams.has('cursor') ? decodeCursor(url.searchParams.get('cursor')!, status) : null;
  // Bound the indexed received-at range as well as expiry, including when a
  // scheduled purge was delayed. Never scan an arbitrary retained history.
  const now = new Date();
  const where = ['received_at > ?', 'expires_at > ?'];
  const bindings: (string | number)[] = [new Date(now.getTime() - 30 * DAY).toISOString(), now.toISOString()];
  if (status) { where.push('status = ?'); bindings.push(status); }
  if (cursor) { where.push('(received_at,ticket_id) < (?,?)'); bindings.push(cursor.receivedAt, cursor.ticketID); }
  const { results } = await env.DB.prepare(`SELECT ${SUMMARY} FROM feedback WHERE ${where.join(' AND ')} ORDER BY received_at DESC,ticket_id DESC LIMIT ?`).bind(...bindings, limit + 1).all();
  const rows = results.slice(0, limit) as unknown as (Row & {has_diagnostics: number})[];
  const last = rows.at(-1);
  return response({ items: rows.map(row => ({ ticketID: row.ticket_id, receivedAt: row.received_at, kind: row.kind, title: row.title, status: row.status, app: JSON.parse(row.app_json), hasDiagnostics: row.has_diagnostics === 1 })),
    nextCursor: results.length > limit && last ? encodeCursor({ receivedAt: last.received_at, ticketID: last.ticket_id, status }) : null });
}
async function admin(request: Request, env: Env, url: URL): Promise<Response> {
  await authorize(request, env); // Authenticate before route parsing or any lookup.
  if (url.pathname === '/v1/admin/feedback' && request.method === 'GET') return list(url, env);
  const match = /^\/v1\/admin\/feedback\/([^/]+)$/.exec(url.pathname);
  if (!match || !UUID.test(match[1])) throw new HTTPError(404, 'NOT_FOUND');
  if (url.search) invalid();
  const id = match[1];
  const now = new Date();
  if (request.method === 'DELETE') {
    const result = await env.DB.prepare('DELETE FROM feedback WHERE ticket_id=? AND expires_at>? RETURNING ticket_id').bind(id, now.toISOString()).all();
    if (result.results.length === 0) throw new HTTPError(404, 'NOT_FOUND');
    return response(null, 204);
  }
  let row: Row | null = null;
  if (request.method === 'GET') {
    row = await env.DB.prepare(`SELECT ${DETAIL} FROM feedback WHERE ticket_id=? AND expires_at>?`).bind(id, now.toISOString()).first<Row>();
  } else if (request.method === 'PATCH') {
    const update = patch(await boundedJSON(request, 65536));
    try {
      // Batch is one transaction: concurrent operators get their own committed
      // update response. The last commit wins; PATCH replaces both fields.
      const result = await env.DB.batch([
        env.DB.prepare('UPDATE feedback SET status=?,notes=?,updated_at=? WHERE ticket_id=? AND expires_at>?').bind(update.status, update.notes, now.toISOString(), id, now.toISOString()),
        env.DB.prepare(`SELECT ${DETAIL} FROM feedback WHERE ticket_id=? AND expires_at>?`).bind(id, now.toISOString()),
      ]);
      row = (result[1].results[0] as unknown as Row | undefined) ?? null;
    } catch (error) { databaseFailure(error, now); }
  } else throw new HTTPError(405, 'METHOD_NOT_ALLOWED');
  if (!row) throw new HTTPError(404, 'NOT_FOUND');
  return response(detail(row));
}
async function prune(env: Env, now = new Date()): Promise<void> {
  if (!env.DB) throw new Error('Missing database binding');
  await env.DB.batch([
    env.DB.prepare('DELETE FROM feedback WHERE expires_at<=?').bind(now.toISOString()),
    env.DB.prepare('DELETE FROM daily_network WHERE day<=?').bind(new Date(now.getTime() - 2 * DAY).toISOString().slice(0, 10)),
    env.DB.prepare('DELETE FROM daily_global WHERE day<=?').bind(new Date(now.getTime() - 2 * DAY).toISOString().slice(0, 10)),
  ]);
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const origin = request.headers.get('Origin');
    let result: Response;
    try {
      const url = new URL(request.url);
      if (origin && !allowedOrigin(origin, env)) throw new HTTPError(403, 'FORBIDDEN_ORIGIN');
      if (request.method === 'OPTIONS') {
        const adminRoute = url.pathname === '/v1/admin/feedback' || url.pathname.startsWith('/v1/admin/feedback/');
        const publicRoute = url.pathname === '/v1/feedback';
        if (!origin || (!adminRoute && !publicRoute)) throw new HTTPError(403, 'FORBIDDEN_ORIGIN');
        const methods = adminRoute ? ['GET', 'PATCH', 'DELETE'] : ['POST'];
        if (!methods.includes(request.headers.get('Access-Control-Request-Method') ?? '')) throw new HTTPError(405, 'METHOD_NOT_ALLOWED');
        const allowedHeaders = adminRoute ? ['authorization', 'content-type'] : ['content-type'];
        const requested = (request.headers.get('Access-Control-Request-Headers') ?? '').split(',').map(value => value.trim().toLowerCase()).filter(Boolean);
        if (requested.some(value => !allowedHeaders.includes(value))) invalid();
        result = response(null, 204, { 'Access-Control-Allow-Methods': methods.join(', '), 'Access-Control-Allow-Headers': allowedHeaders.join(', ') });
      } else {
        if (!available(env)) throw new HTTPError(503, 'INTAKE_UNAVAILABLE');
        if (url.pathname === '/health' && request.method === 'GET') {
          if (env.INTAKE_ENABLED !== 'true' || !await env.DB.prepare('SELECT singleton FROM storage_usage WHERE singleton=1').first()) throw new HTTPError(503, 'INTAKE_UNAVAILABLE');
          result = response({ status: 'ok' });
        } else if (url.pathname.startsWith('/v1/admin/')) result = await admin(request, env, url);
        else if (url.pathname === '/v1/feedback' && request.method === 'POST' && !url.search) result = await create(request, env);
        else throw new HTTPError(404, 'NOT_FOUND');
      }
    } catch (error) {
      const failure = error instanceof HTTPError ? error : new HTTPError(503, 'INTAKE_UNAVAILABLE');
      result = response({ errorCode: failure.errorCode }, failure.status, failure.retryAfter ? { 'Retry-After': String(failure.retryAfter) } : {});
    }
    result.headers.set('Vary', 'Origin');
    if (origin && allowedOrigin(origin, env)) result.headers.set('Access-Control-Allow-Origin', origin);
    return result;
  },
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> { await prune(env); },
} satisfies ExportedHandler<Env>;
