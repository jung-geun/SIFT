import { createHash } from 'node:crypto';
import canonicalize from 'canonicalize';
import { FinalizeManifestSchema, type FinalizeManifest, type PartFields } from './schema.js';
import { assertSafeInput } from './canonical.js';

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
  assertSafeInput(input);
  if (!Number.isSafeInteger(input.meetingSampleCount) || input.meetingSampleCount <= 0 || input.meetingSampleCount > MAX_SAMPLES) throw new Error('SAMPLE_COUNT_LIMIT');
  const expectedCount = Math.ceil(input.meetingSampleCount / OWNED_SAMPLES_PER_PART);
  if (input.partCount !== expectedCount || input.parts.length !== input.partCount) throw new Error('PART_COUNT_MISMATCH');
  for (const [index, part] of input.parts.entries()) {
    if (part.partIndex !== index) throw new Error('PART_ORDER_MISMATCH');
    const expected = expectedPartBounds(part.partIndex, input.meetingSampleCount);
    if (part.partStartSample !== expected.partStartSample || part.ownedStartSample !== expected.ownedStartSample || part.ownedEndSample !== expected.ownedEndSample) throw new Error('PART_BOUNDS_MISMATCH');
    if (!Number.isSafeInteger(part.byteCount) || part.byteCount <= 0 || part.byteCount > MAX_PART_BYTES) throw new Error('PART_SIZE_LIMIT');
  }
  FinalizeManifestSchema.parse(input);
}

export function validatePartFields(fields: PartFields, audioByteCount: number): void {
  assertSafeInput(fields);
  if (!Number.isSafeInteger(audioByteCount) || audioByteCount > MAX_PART_BYTES || audioByteCount <= 0) throw new Error('PART_SIZE_LIMIT');
  if (fields.meetingSampleCount <= 0n || fields.meetingSampleCount > BigInt(MAX_SAMPLES)) throw new Error('SAMPLE_COUNT_LIMIT');
  const total = Number(fields.meetingSampleCount);
  const expectedCount = Math.ceil(total / OWNED_SAMPLES_PER_PART);
  if (fields.partCount !== expectedCount || fields.partCount < 1) throw new Error('PART_COUNT_MISMATCH');
  if (!Number.isSafeInteger(fields.partIndex) || fields.partIndex < 0 || fields.partIndex >= fields.partCount) throw new Error('PART_ORDER_MISMATCH');
  const expected = expectedPartBounds(fields.partIndex, total);
  if (fields.partStartSample !== BigInt(expected.partStartSample) || fields.ownedStartSample !== BigInt(expected.ownedStartSample) || fields.ownedEndSample !== BigInt(expected.ownedEndSample)) throw new Error('PART_BOUNDS_MISMATCH');
  if (fields.ownedEndSample <= fields.ownedStartSample) throw new Error('EMPTY_OWNED_INTERVAL');
}

export function fileSha256(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

export function canonicalManifest(input: FinalizeManifest): string {
  validateManifest(input);
  const canonical = canonicalize(input);
  if (canonical === undefined) throw new Error('INVALID_MANIFEST');
  return canonical;
}

const CRC8 = new Uint8Array(256);
const CRC16 = new Uint16Array(256);
const FRAME_RATES = [16000, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000];
for (let index = 0; index < 256; index += 1) {
  let crc8 = index;
  let crc16 = index << 8;
  for (let bit = 0; bit < 8; bit += 1) {
    crc8 = ((crc8 << 1) ^ (crc8 & 0x80 ? 0x07 : 0)) & 0xff;
    crc16 = ((crc16 << 1) ^ (crc16 & 0x8000 ? 0x8005 : 0)) & 0xffff;
  }
  CRC8[index] = crc8;
  CRC16[index] = crc16;
}

/** RFC 9639 framing/CRC validation; no decoded PCM allocation or decoder execution. */
export function validateFlacAudio(bytes: Buffer, fields: PartFields): void {
  validatePartFields(fields, bytes.length);
  if (bytes.length < 42 || bytes.readUInt32BE(0) !== 0x664c6143) throw new Error('INVALID_FLAC');
  let offset = 4;
  let metadataCount = 0;
  let last = false;
  let minBlock = 0;
  let maxBlock = 0;
  let minFrame = 0;
  let maxFrame = 0;
  const expectedSamples = Number(fields.ownedEndSample - fields.partStartSample);
  const uniqueMetadata: Record<number, true> = {};
  while (!last) {
    if (++metadataCount > 128 || offset + 4 > bytes.length) throw new Error('INVALID_FLAC_METADATA');
    last = (bytes[offset] & 0x80) !== 0;
    const type = bytes[offset] & 0x7f;
    const length = bytes.readUIntBE(offset + 1, 3);
    offset += 4;
    if (type > 6 || offset + length > bytes.length || (metadataCount === 1 ? type !== 0 || length !== 34 : type === 0)) throw new Error('INVALID_FLAC_METADATA');
    if (type === 3 || type === 4 || type === 5) {
      if (uniqueMetadata[type]) throw new Error('INVALID_FLAC_METADATA');
      uniqueMetadata[type] = true;
    }
    if (type === 0) {
      minBlock = bytes.readUInt16BE(offset);
      maxBlock = bytes.readUInt16BE(offset + 2);
      minFrame = bytes.readUIntBE(offset + 4, 3);
      maxFrame = bytes.readUIntBE(offset + 7, 3);
      const format = bytes.readBigUInt64BE(offset + 10);
      const rate = Number(format >> 44n);
      const channels = Number((format >> 41n) & 7n) + 1;
      const depth = Number((format >> 36n) & 31n) + 1;
      const count = Number(format & 0xfffffffffn);
      if (minBlock < 16 || maxBlock < minBlock || (minFrame !== 0 && maxFrame !== 0 && maxFrame < minFrame)) throw new Error('INVALID_FLAC_STREAMINFO');
      if (rate !== 16000 || channels !== 1 || depth !== 16) throw new Error('FLAC_FORMAT_MISMATCH');
      if (count !== expectedSamples) throw new Error('FLAC_SAMPLE_COUNT_MISMATCH');
    } else if ((type === 2 && length < 4) || (type === 3 && length % 18 !== 0)) throw new Error('INVALID_FLAC_METADATA');
    const end = offset + length;
    if (type === 4 || type === 6) {
      let cursor = offset;
      function metadataUInt(): number {
        if (cursor + 4 > end) throw new Error('INVALID_FLAC_METADATA');
        const result = type === 4 ? bytes.readUInt32LE(cursor) : bytes.readUInt32BE(cursor);
        cursor += 4;
        return result;
      }
      function metadataBytes(count: number): void {
        if (cursor + count > end) throw new Error('INVALID_FLAC_METADATA');
        cursor += count;
      }
      if (type === 4) {
        metadataBytes(metadataUInt());
        const comments = metadataUInt();
        if (comments > Math.floor((end - cursor) / 4)) throw new Error('INVALID_FLAC_METADATA');
        for (let index = 0; index < comments; index += 1) metadataBytes(metadataUInt());
      } else {
        metadataUInt(); // Picture type; image contents are never decoded here.
        metadataBytes(metadataUInt());
        metadataBytes(metadataUInt());
        metadataBytes(16); // Width, height, depth, palette count.
        metadataBytes(metadataUInt());
      }
      if (cursor !== end) throw new Error('INVALID_FLAC_METADATA');
    } else if (type === 5) {
      if (length < 396 || bytes[offset + 395] === 0) throw new Error('INVALID_FLAC_METADATA');
      let cursor = offset + 396;
      for (let index = 0; index < bytes[offset + 395]; index += 1) {
        if (cursor + 36 > end) throw new Error('INVALID_FLAC_METADATA');
        const indexes = bytes[cursor + 35];
        cursor += 36 + indexes * 12;
        if (cursor > end) throw new Error('INVALID_FLAC_METADATA');
      }
      if (cursor !== end) throw new Error('INVALID_FLAC_METADATA');
    }
    offset += length;
  }
  let bitOffset = offset * 8;
  const bitLimit = bytes.length * 8;
  function readBits(count: number): number {
    if (count < 0 || count > 32 || bitOffset + count > bitLimit) throw new Error('INVALID_FLAC_FRAME');
    let result = 0;
    while (count > 0) {
      const available = 8 - bitOffset % 8;
      const take = Math.min(available, count);
      result = result * 2 ** take + ((bytes[Math.floor(bitOffset / 8)] >> (available - take)) & ((1 << take) - 1));
      bitOffset += take;
      count -= take;
    }
    return result;
  }
  function skipBits(count: number): void {
    if (!Number.isSafeInteger(count) || count < 0 || bitOffset + count > bitLimit) throw new Error('INVALID_FLAC_FRAME');
    bitOffset += count;
  }
  function unary(): number {
    let count = 0;
    while (bitOffset % 8 !== 0) { if (readBits(1) === 1) return count; count += 1; }
    while (bitOffset < bitLimit && bytes[bitOffset / 8] === 0) { bitOffset += 8; count += 8; }
    while (readBits(1) === 0) count += 1;
    return count;
  }
  let samples = 0;
  let frameIndex = 0;
  let strategy: number | undefined;
  let fixedBlock = 0;
  while (bitOffset < bitLimit) {
    const frameStart = bitOffset / 8;
    if (samples >= expectedSamples || readBits(14) !== 0x3ffe || readBits(1) !== 0) throw new Error('INVALID_FLAC_FRAME');
    const variable = readBits(1);
    if (strategy !== undefined && strategy !== variable) throw new Error('INVALID_FLAC_FRAME');
    strategy = variable;
    const blockCode = readBits(4);
    const rateCode = readBits(4);
    const channelCode = readBits(4);
    const depthCode = readBits(3);
    if (readBits(1) !== 0 || blockCode === 0 || rateCode === 15 || channelCode !== 0 || (depthCode !== 0 && depthCode !== 4)) throw new Error('FLAC_FORMAT_MISMATCH');
    const first = readBits(8);
    let number = first;
    if (first >= 0x80) {
      let width = 0;
      for (let mask = 0x80; (first & mask) !== 0; mask >>= 1) width += 1;
      if (width < 2 || width > 7) throw new Error('INVALID_FLAC_FRAME');
      number = first & ((1 << (7 - width)) - 1);
      for (let index = 1; index < width; index += 1) {
        const next = readBits(8);
        if ((next & 0xc0) !== 0x80) throw new Error('INVALID_FLAC_FRAME');
        number = number * 64 + (next & 0x3f);
      }
      const minimum = width === 2 ? 128 : 2 ** (5 * width - 4);
      if (number < minimum) throw new Error('INVALID_FLAC_FRAME');
    }
    if (number !== (variable ? samples : frameIndex)) throw new Error('INVALID_FLAC_FRAME_SEQUENCE');
    const block = blockCode === 1 ? 192 : blockCode <= 5 ? 576 * 2 ** (blockCode - 2) : blockCode === 6 ? readBits(8) + 1 : blockCode === 7 ? readBits(16) + 1 : 256 * 2 ** (blockCode - 8);
    const rate = rateCode < 12 ? FRAME_RATES[rateCode] : rateCode === 12 ? readBits(8) * 1000 : rateCode === 13 ? readBits(16) : readBits(16) * 10;
    if (rate !== 16000) throw new Error('FLAC_FORMAT_MISMATCH');
    if (block > maxBlock || samples + block > expectedSamples || (samples + block < expectedSamples && block < minBlock)) throw new Error('FLAC_SAMPLE_COUNT_MISMATCH');
    if (!variable) {
      if (frameIndex === 0) fixedBlock = block;
      if (block > fixedBlock || (samples + block < expectedSamples && block !== fixedBlock)) throw new Error('INVALID_FLAC_FRAME_SEQUENCE');
    }
    const headerEnd = bitOffset / 8;
    let headerCRC = 0;
    for (let index = frameStart; index < headerEnd; index += 1) headerCRC = CRC8[headerCRC ^ bytes[index]];
    if (readBits(8) !== headerCRC) throw new Error('INVALID_FLAC_CRC');
    if (readBits(1) !== 0) throw new Error('INVALID_FLAC_SUBFRAME');
    const subframe = readBits(6);
    const wasted = readBits(1) === 1 ? unary() + 1 : 0;
    const depth = 16 - wasted;
    if (depth < 1) throw new Error('INVALID_FLAC_SUBFRAME');
    if (subframe === 0) skipBits(depth);
    else if (subframe === 1) skipBits(block * depth);
    else {
      const order = subframe >= 32 ? (subframe & 31) + 1 : subframe >= 8 && subframe <= 12 ? subframe - 8 : -1;
      if (order < 0 || order >= block) throw new Error('INVALID_FLAC_SUBFRAME');
      skipBits(order * depth);
      if (subframe >= 32) {
        const precisionCode = readBits(4);
        if (precisionCode === 15) throw new Error('INVALID_FLAC_SUBFRAME');
        if (readBits(5) >= 16) throw new Error('INVALID_FLAC_SUBFRAME');
        skipBits(order * (precisionCode + 1));
      }
      const method = readBits(2);
      if (method > 1) throw new Error('INVALID_FLAC_RESIDUAL');
      const partitions = 2 ** readBits(4);
      if (block % partitions !== 0 || block / partitions <= order) throw new Error('INVALID_FLAC_RESIDUAL');
      const parameterBits = method === 0 ? 4 : 5;
      for (let partition = 0; partition < partitions; partition += 1) {
        const parameter = readBits(parameterBits);
        const count = block / partitions - (partition === 0 ? order : 0);
        if (parameter === (1 << parameterBits) - 1) skipBits(count * readBits(5));
        else for (let sample = 0; sample < count; sample += 1) {
          const folded = unary() * 2 ** parameter + readBits(parameter);
          if (folded > 0xfffffffe) throw new Error('INVALID_FLAC_RESIDUAL');
        }
      }
    }
    if (bitOffset % 8 !== 0 && readBits(8 - bitOffset % 8) !== 0) throw new Error('INVALID_FLAC_SUBFRAME');
    const frameEnd = bitOffset / 8;
    let frameCRC = 0;
    for (let index = frameStart; index < frameEnd; index += 1) frameCRC = ((frameCRC << 8) ^ CRC16[(frameCRC >> 8) ^ bytes[index]]) & 0xffff;
    if (readBits(16) !== frameCRC) throw new Error('INVALID_FLAC_CRC');
    const frameLength = bitOffset / 8 - frameStart;
    if ((minFrame !== 0 && frameLength < minFrame) || (maxFrame !== 0 && frameLength > maxFrame)) throw new Error('INVALID_FLAC_STREAMINFO');
    samples += block;
    frameIndex += 1;
  }
  if (samples !== expectedSamples || frameIndex === 0) throw new Error('FLAC_SAMPLE_COUNT_MISMATCH');
}
