import type { FastifyRequest } from 'fastify';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { authenticateRequest, FirebaseAdminAuthVerifier } from '../src/auth.js';
import { defaultProviderConfig, ProviderConfigSchema, providerIsEnabled } from '../src/provider-config.js';
import { createMeetingServer } from '../src/server.js';

function request(headers: FastifyRequest['headers']): FastifyRequest {
  return { headers } as FastifyRequest;
}

function verifier() {
  return {
    verifyIdToken: vi.fn(async (_token: string) => ({ uid: 'alice' })),
    verifyAppCheckToken: vi.fn(async (_token: string) => {}),
  };
}

const validHeaders = { authorization: 'Bearer id-token', 'x-firebase-appcheck': 'app-check' };

describe('meeting authentication', () => {
  it.each([
    { name: 'both credentials absent', headers: {} },
    { name: 'ID token absent', headers: { 'x-firebase-appcheck': 'app-check' } },
    { name: 'App Check absent', headers: { authorization: 'Bearer id-token' } },
    { name: 'ID token empty', headers: { ...validHeaders, authorization: 'Bearer ' } },
    { name: 'ID token whitespace', headers: { ...validHeaders, authorization: 'Bearer   ' } },
    { name: 'wrong authorization scheme', headers: { ...validHeaders, authorization: 'Basic id-token' } },
    { name: 'App Check empty', headers: { ...validHeaders, 'x-firebase-appcheck': '' } },
    { name: 'App Check repeated', headers: { ...validHeaders, 'x-firebase-appcheck': ['one', 'two'] } },
  ])('requires both credentials: $name', async ({ headers }) => {
    const auth = verifier();
    await expect(authenticateRequest(request(headers), auth)).rejects.toThrow('AUTH_REQUIRED');
    expect(auth.verifyIdToken).not.toHaveBeenCalled();
    expect(auth.verifyAppCheckToken).not.toHaveBeenCalled();
  });

  it('returns only the verified identity after checking both tokens', async () => {
    const auth = verifier();
    await expect(authenticateRequest(request(validHeaders), auth)).resolves.toEqual({ uid: 'alice' });
    expect(auth.verifyIdToken).toHaveBeenCalledWith('id-token');
    expect(auth.verifyAppCheckToken).toHaveBeenCalledWith('app-check');
  });

  it('fails closed on ID verification errors without exposing SDK details', async () => {
    const auth = verifier();
    auth.verifyIdToken.mockRejectedValue(new Error('private Firebase credential details'));
    await expect(authenticateRequest(request(validHeaders), auth)).rejects.toThrow(/^AUTH_INVALID$/);
    expect(auth.verifyAppCheckToken).not.toHaveBeenCalled();
  });

  it('fails closed on App Check verification errors without exposing SDK details', async () => {
    const auth = verifier();
    auth.verifyAppCheckToken.mockRejectedValue(new Error('private App Check credential details'));
    await expect(authenticateRequest(request(validHeaders), auth)).rejects.toThrow(/^AUTH_INVALID$/);
  });
});

describe('Firebase Admin verifier', () => {
  it('requires Firebase revocation checking and delegates App Check verification', async () => {
    const firebaseAuth = { verifyIdToken: vi.fn(async (_token: string, _checkRevoked?: boolean) => ({ uid: 'alice', email: 'private@example.com' })) };
    const firebaseAppCheck = { verifyToken: vi.fn(async (_token: string) => ({ appId: 'app-id' })) };
    const auth = new FirebaseAdminAuthVerifier(firebaseAuth, firebaseAppCheck);
    await expect(authenticateRequest(request(validHeaders), auth)).resolves.toEqual({ uid: 'alice' });
    expect(firebaseAuth.verifyIdToken).toHaveBeenCalledWith('id-token', true);
    expect(firebaseAppCheck.verifyToken).toHaveBeenCalledWith('app-check');
  });

  it.each(['auth/id-token-revoked', 'auth/user-disabled'])('rejects %s instead of accepting an unexpired ID token', async errorCode => {
    const firebaseAuth = {
      verifyIdToken: vi.fn(async (_token: string, checkRevoked?: boolean) => {
        if (checkRevoked) throw new Error(errorCode);
        return { uid: 'alice' };
      }),
    };
    const firebaseAppCheck = { verifyToken: vi.fn(async (_token: string) => ({})) };
    const auth = new FirebaseAdminAuthVerifier(firebaseAuth, firebaseAppCheck);
    await expect(authenticateRequest(request(validHeaders), auth)).rejects.toThrow(/^AUTH_INVALID$/);
    expect(firebaseAuth.verifyIdToken).toHaveBeenCalledWith('id-token', true);
    expect(firebaseAppCheck.verifyToken).not.toHaveBeenCalled();
  });

  it('rejects a decoded token without an owner UID', async () => {
    const auth = new FirebaseAdminAuthVerifier(
      { verifyIdToken: async () => ({ uid: '' }) },
      { verifyToken: async () => ({}) },
    );
    await expect(authenticateRequest(request(validHeaders), auth)).rejects.toThrow(/^AUTH_INVALID$/);
  });
});

const apps: Array<{ close(): Promise<void> }> = [];
afterEach(async () => { while (apps.length) await apps.pop()?.close(); });

const meetingId = '123e4567-e89b-12d3-a456-426614174000';
const protectedRoutes = [
  { method: 'GET', url: '/v1/provider-config' },
  { method: 'POST', url: '/v1/meetings' },
  { method: 'POST', url: `/v1/meetings/${meetingId}/finalize-manifest` },
  { method: 'POST', url: '/v1/openai/parts' },
  { method: 'POST', url: '/v1/google/parts' },
  { method: 'POST', url: `/v1/meetings/${meetingId}/extractions` },
  { method: 'GET', url: '/v1/jobs/job-id' },
  { method: 'DELETE', url: `/v1/meetings/${meetingId}` },
  { method: 'GET', url: `/v1/deletions/${meetingId}` },
  { method: 'GET', url: '/v1/google/stream' },
] as const;

describe('API App Check boundary', () => {
  it.each(protectedRoutes)('requires App Check on $method $url', async route => {
    const auth = verifier();
    const app = createMeetingServer({ auth, logger: false }); apps.push(app);
    const response = await app.inject({ ...route, headers: { authorization: 'Bearer id-token' } });
    expect(response.statusCode).toBe(401);
    expect(response.json()).toEqual({ errorCode: 'AUTH_REQUIRED' });
    expect(auth.verifyIdToken).not.toHaveBeenCalled();
  });

  it.each(protectedRoutes)('rejects invalid App Check on $method $url', async route => {
    const auth = verifier();
    auth.verifyAppCheckToken.mockRejectedValue(new Error('invalid App Check credential'));
    const app = createMeetingServer({ auth, logger: false }); apps.push(app);
    const response = await app.inject({ ...route, headers: validHeaders });
    expect(response.statusCode).toBe(401);
    expect(response.json()).toEqual({ errorCode: 'AUTH_INVALID' });
    expect(auth.verifyAppCheckToken).toHaveBeenCalledWith('app-check');
  });

  it('checks App Check before an attempted websocket upgrade', async () => {
    const app = createMeetingServer({ auth: verifier(), logger: false }); apps.push(app);
    const response = await app.inject({
      method: 'GET', url: '/v1/google/stream',
      headers: {
        authorization: 'Bearer id-token', connection: 'Upgrade', upgrade: 'websocket',
        'sec-websocket-version': '13', 'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==',
      },
    });
    expect(response.statusCode).toBe(401);
    expect(response.json()).toEqual({ errorCode: 'AUTH_REQUIRED' });
  });
});

describe('public provider disclosure configuration', () => {
  it('rejects secret-bearing unknown fields rather than returning them in public configuration', () => {
    expect(ProviderConfigSchema.safeParse({ ...defaultProviderConfig, apiKey: 'secret' }).success).toBe(false);
    expect(ProviderConfigSchema.safeParse({
      ...defaultProviderConfig,
      providers: [{ ...defaultProviderConfig.providers[0], apiKey: 'secret' }],
    }).success).toBe(false);
  });

  it('keeps both default providers unavailable', () => {
    expect(providerIsEnabled(defaultProviderConfig, 'openAI')).toBe(false);
    expect(providerIsEnabled(defaultProviderConfig, 'google')).toBe(false);
  });
});
