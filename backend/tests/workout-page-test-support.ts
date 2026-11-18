import { createHash, createSign, generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import cbor from 'cbor';
import type { NextApiRequest, NextApiResponse } from 'next';
import { createWorkoutPageHandler } from '../lib/workout-page-api';
import { appleVerifier, assertionMessage, type AttestationVerifier, WorkoutPageAttestation } from '../lib/workout-page-attestation';
import { WorkoutPages, type WorkoutBlobStore } from '../lib/workout-pages';
import type { WorkoutPageExport } from '../lib/workout-page-schema';
import { startRedisTestServer } from './redis-test-server';

export const TEST_APP = { teamIdentifier: '1234567890', bundleIdentifier: 'com.example.bpm', allowDevelopmentEnvironment: false };
export const testKey = () => randomBytes(32).toString('base64url');
export function workoutFixture(overrides: Partial<WorkoutPageExport> = {}): WorkoutPageExport {
  return { schemaVersion: 1, calculationVersion: 1, title: 'Intervals', description: 'A synthetic workout used for verification.',
    durationSeconds: 60, elapsedDurationSeconds: 70, summary: { avgBPM: 130, minBPM: 100, maxBPM: 160, calories: 12, activeCalories: 10 },
    samples: [{ elapsedSeconds: 0, activeSeconds: 0, bpm: 100, validUntilElapsedSeconds: 3 },
      { elapsedSeconds: 19, activeSeconds: 19, bpm: 160, validUntilElapsedSeconds: 20, invalidatedAtElapsedSeconds: 22 },
      { elapsedSeconds: 30, activeSeconds: 20, bpm: 130, validUntilElapsedSeconds: 33 },
      { elapsedSeconds: 69, activeSeconds: 59, bpm: 130, validUntilElapsedSeconds: 70 }],
    intervals: [{ startElapsedSeconds: 20, endElapsedSeconds: 30, kind: 'pause' }, { startElapsedSeconds: 22, endElapsedSeconds: 30, kind: 'signalLoss' }],
    sets: [{ index: 0, label: 'Set 1', kind: 'work', startElapsedSeconds: 0, endElapsedSeconds: 70,
      startActiveSeconds: 0, endActiveSeconds: 60, durationSeconds: 60, avgBPM: 130 }],
    zones: [{ zone: 1, durationSeconds: 30, lowerBPM: 80, upperBPM: 120 }, { zone: 2, durationSeconds: 20, lowerBPM: 120, upperBPM: 150 }],
    quality: { sampleFidelity: 'full', exportedSampleCount: 4, originalSampleCount: 4, rangeMetricsAvailable: true }, ...overrides };
}
export function createBody(workout: WorkoutPageExport = workoutFixture()) {
  return { pageID: randomUUID(), viewKey: testKey(), viewKeyRecovery: randomBytes(90).toString('base64url'), workout };
}
export class MemoryWorkoutBlobs implements WorkoutBlobStore {
  objects = new Map<string, Buffer>();
  reads = 0;
  writes = 0;
  failDeletes = false;
  beforeGet?: () => Promise<void>;
  beforePut?: () => Promise<void>;
  async put(path: string, data: Buffer) { await this.beforePut?.(); this.writes++; this.objects.set(path, Buffer.from(data)); }
  async get(path: string) { this.reads++; await this.beforeGet?.(); return this.objects.get(path) || null; }
  async delete(path: string) { if (this.failDeletes) throw new Error('Synthetic storage outage'); this.objects.delete(path); }
}
export function signingFixture() {
  const pair = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const publicKey = pair.publicKey.export({ format: 'pem', type: 'spki' }).toString();
  const keyID = randomBytes(32).toString('base64');
  const real = appleVerifier(TEST_APP);
  const verifier: AttestationVerifier = {
    async registration(bytes, message) {
      if (bytes.toString() !== 'synthetic-apple-registration' || !message.startsWith('BPM-Workout-Pages|register|')) throw new Error('Invalid test registration');
      return { publicKey, receipt: 'synthetic-receipt', environment: 'production' };
    },
    assertion: real.assertion,
  };
  const sign = (payload: string, counter: number) => {
    const authenticatorData = Buffer.alloc(37);
    createHash('sha256').update(`${TEST_APP.teamIdentifier}.${TEST_APP.bundleIdentifier}`).digest().copy(authenticatorData);
    authenticatorData.writeUInt32BE(counter, 33);
    const clientHash = createHash('sha256').update(payload).digest();
    const nonce = createHash('sha256').update(Buffer.concat([authenticatorData, clientHash])).digest();
    const signature = createSign('SHA256').update(nonce).sign(pair.privateKey);
    return cbor.encode({ authenticatorData, signature }).toString('base64');
  };
  return { keyID, verifier, sign, publicKey };
}

export async function testEnvironment() {
  const redis = await startRedisTestServer();
  const blobs = new MemoryWorkoutBlobs();
  const signing = signingFixture();
  const attestation = new WorkoutPageAttestation(redis, signing.verifier);
  const pages = new WorkoutPages(redis, blobs);
  const handler = createWorkoutPageHandler({ redis, pages, attestation,
    configuration: { uploadsEnabled: true, appAttestConfigured: true, ipSalt: 'synthetic-test-salt-that-is-never-used-in-production',
      production: false, dailyUploadLimit: 1000, cleanupSecret: 'synthetic-cleanup-secret', blockedTerms: ['synthetic blocked phrase'] },
  });
  let counter = 0;
  async function register(owner: string) {
    const challenge = await attestation.challenge(owner, { purpose: 'register', keyID: signing.keyID });
    await attestation.register(owner, { challengeID: challenge.challengeID, keyID: signing.keyID,
      attestation: Buffer.from('synthetic-apple-registration').toString('base64') });
  }
  async function headers(owner: string, method: string, path: string, raw: Buffer) {
    const challenge = await attestation.challenge(owner, { purpose: 'request', keyID: signing.keyID });
    return { authorization: `Bearer ${owner}`, 'content-type': 'application/json', 'x-bpm-attest-key-id': signing.keyID,
      'x-bpm-attest-challenge-id': challenge.challengeID,
      'x-bpm-attest-assertion': signing.sign(assertionMessage(challenge.challenge, owner, method, path, raw), ++counter) };
  }
  return { redis, blobs, signing, attestation, pages, handler, register, headers, stop: redis.stop };
}

export function handleTestAPI(handler: ReturnType<typeof createWorkoutPageHandler>, req: IncomingMessage, res: ServerResponse): void {
  const url = new URL(req.url || '/', 'http://127.0.0.1');
  const query: Record<string, string | string[]> = {};
  url.searchParams.forEach((value, key) => { query[key] = value; });
  query.path = url.pathname.replace(/^\/api\/workout-pages\/?/, '').split('/').filter(Boolean);
  const request = Object.assign(req, { query }) as NextApiRequest;
  const response = Object.assign(res, {
    status(code: number) { res.statusCode = code; return response; },
    json(value: unknown) { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(value)); return response; },
  }) as unknown as NextApiResponse;
  void handler(request, response);
}

export async function startTestHTTP(handler: ReturnType<typeof createWorkoutPageHandler>) {
  const server = createServer((req, res) => handleTestAPI(handler, req, res));
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Expected local server');
  return { url: `http://127.0.0.1:${address.port}`,
    stop: () => new Promise<void>((resolve, reject) => { server.close(error => error ? reject(error) : resolve()); server.closeAllConnections(); }) };
}
