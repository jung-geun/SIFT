import type { FastifyRequest } from 'fastify';
import { createHash } from 'node:crypto';

export interface VerifiedIdentity {
  uid: string;
}

export interface MeetingAuthVerifier {
  verifyIdToken(token: string): Promise<VerifiedIdentity>;
  verifyAppCheckToken(token: string): Promise<void>;
}

export class FirebaseAdminAuthVerifier implements MeetingAuthVerifier {
  private readonly auth: { verifyIdToken(token: string): Promise<{ uid: string }> };
  private readonly appCheck: { verifyToken(token: string): Promise<unknown> };

  constructor(firebaseAuth: { verifyIdToken(token: string): Promise<{ uid: string }> }, firebaseAppCheck: { verifyToken(token: string): Promise<unknown> }) {
    this.auth = firebaseAuth;
    this.appCheck = firebaseAppCheck;
  }

  async verifyIdToken(token: string): Promise<VerifiedIdentity> {
    const decoded = await this.auth.verifyIdToken(token);
    if (!decoded.uid) throw new Error('AUTH_INVALID');
    return { uid: decoded.uid };
  }

  async verifyAppCheckToken(token: string): Promise<void> {
    await this.appCheck.verifyToken(token);
  }
}

export function uidHash(uid: string): string {
  return createHash('sha256').update(uid, 'utf8').digest('hex').slice(0, 32);
}

export async function authenticateRequest(request: FastifyRequest, verifier: MeetingAuthVerifier): Promise<VerifiedIdentity> {
  const authorization = request.headers.authorization;
  if (!authorization?.startsWith('Bearer ')) throw new Error('AUTH_REQUIRED');
  const token = authorization.slice('Bearer '.length).trim();
  const appCheck = request.headers['x-firebase-appcheck'];
  if (!token || typeof appCheck !== 'string' || appCheck.length === 0) throw new Error('AUTH_REQUIRED');
  try {
    const identity = await verifier.verifyIdToken(token);
    await verifier.verifyAppCheckToken(appCheck);
    return identity;
  } catch {
    throw new Error('AUTH_INVALID');
  }
}
