import { createHash } from 'node:crypto';
import canonicalize from 'canonicalize';
import type { FinalizeManifest, PartFields } from './schema.js';

export const OWNED_SAMPLES_PER_PART = 9_600_000;
export const OVERLAP_SAMPLES = 32_000;
export const MAX_SAMPLES = 345_600_000;
export const MAX_PART_BYTES = 23_000_000;
export const MAX_REQUEST_BYTES = 25_000_000;

export function expectedPartBounds(index: number, total: number): { partStartSample: number; ownedStartSample: number; ownedEndSample: number } {
  const ownedStartSample = index * OWNED_SAMPLES_PER_PART;
  const ownedEndSample = Math.min((index + 1) * OWNED_SAMPLES_PER_PART, total);
  return { partStartSample: Math.max(0, ownedStartSample - OVERLAP_SAMPLES), ownedStartSample, ownedEndSample };
}

export function validateManifest(input: FinalizeManifest): void {
  if (input.meetingSampleCount <= 0 || input.meetingSampleCount > MAX_SAMPLES) throw new Error('SAMPLE_COUNT_LIMIT');
  const expectedCount = Math.ceil(input.meetingSampleCount / OWNED_SAMPLES_PER_PART);
  if (input.partCount !== expectedCount || input.parts.length !== input.partCount) throw new Error('PART_COUNT_MISMATCH');
  for (const [index, part] of input.parts.entries()) {
    if (part.partIndex !== index) throw new Error('PART_ORDER_MISMATCH');
    const expected = expectedPartBounds(part.partIndex, input.meetingSampleCount);
    if (part.partStartSample !== expected.partStartSample || part.ownedStartSample !== expected.ownedStartSample || part.ownedEndSample !== expected.ownedEndSample) throw new Error('PART_BOUNDS_MISMATCH');
    if (part.byteCount > MAX_PART_BYTES) throw new Error('PART_SIZE_LIMIT');
  }
}

export function validatePartFields(fields: PartFields, audioByteCount: number): void {
  if (audioByteCount > MAX_PART_BYTES || audioByteCount <= 0) throw new Error('PART_SIZE_LIMIT');
  if (fields.meetingSampleCount <= 0n || fields.meetingSampleCount > BigInt(MAX_SAMPLES)) throw new Error('SAMPLE_COUNT_LIMIT');
  const total = Number(fields.meetingSampleCount);
  const expectedCount = Math.ceil(total / OWNED_SAMPLES_PER_PART);
  if (fields.partCount !== expectedCount || fields.partCount < 1) throw new Error('PART_COUNT_MISMATCH');
  const expected = expectedPartBounds(fields.partIndex, total);
  if (fields.partStartSample !== BigInt(expected.partStartSample) || fields.ownedStartSample !== BigInt(expected.ownedStartSample) || fields.ownedEndSample !== BigInt(expected.ownedEndSample)) throw new Error('PART_BOUNDS_MISMATCH');
  if (fields.ownedEndSample <= fields.ownedStartSample) throw new Error('EMPTY_OWNED_INTERVAL');
}

export function fileSha256(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

export function canonicalManifest(input: FinalizeManifest): string {
  const canonical = canonicalize(input);
  if (canonical === undefined) throw new Error('INVALID_MANIFEST');
  return canonical;
}
