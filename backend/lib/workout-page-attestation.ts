import { randomBytes, randomUUID, X509Certificate } from 'node:crypto';
import cbor from 'cbor';
import { verifyAttestation, verifyAssertion } from 'node-app-attest';
import type { ShareRedis } from './share-workout';
import { credential, hash, PAGE_PREFIX, redisJSON, assertOwnerAllowed } from './workout-pages';
import { exactObject, invalid, WorkoutPageError } from './workout-page-validation';
import { verifyAppleReceipt } from './workout-page-receipt';

interface Challenge {
  challenge: string;
  ownerHash: string;
  purpose: 'register' | 'request';
  keyID?: string;
  expiresAt: string;
}
interface AttestedKey {
  ownerHash: string;
  publicKey: string;
  signCount: number;
  receipt: string;
  environment: string;
}
export interface AttestationConfiguration {
  teamIdentifier: string;
  bundleIdentifier: string;
  allowDevelopmentEnvironment: boolean;
  minimumBundleVersion?: number;
}
export interface AttestationVerifier {
  registration(bytes: Buffer, challenge: string, keyID: string): Promise<{ publicKey: string; receipt: string; environment: string }>;
  assertion(bytes: Buffer, payload: string, key: AttestedKey): number;
}
const challengeKey = (id: string) => `${PAGE_PREFIX}challenge:${id}`;
const attestKey = (keyID: string) => `${PAGE_PREFIX}attest:${hash(keyID)}`;
const challengeIDPattern = /^[0-9a-f-]{36}$/;
function keyIdentifier(value: unknown): string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(value) || Buffer.from(value, 'base64').length !== 32) invalid('Invalid attestation key');
  return value;
}
function encodedProof(value: unknown, maxBytes: number): Buffer {
  if (typeof value !== 'string' || value.length > Math.ceil(maxBytes / 3) * 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) invalid('Invalid attestation proof');
  const bytes = Buffer.from(value, 'base64');
  if (!bytes.length || bytes.length > maxBytes || bytes.toString('base64') !== value) invalid('Invalid attestation proof');
  return bytes;
}
function singleCBOR(bytes: Buffer): any {
  const decoded = cbor.decodeAllSync(bytes, { max_depth: 12, preventDuplicateKeys: true });
  if (decoded.length !== 1) throw new Error('One CBOR object required');
  return decoded[0];
}

export function verifyAppExtensions(authData: Buffer, registration: boolean, config: AttestationConfiguration): void {
  const offset = registration ? 55 + authData.readUInt16BE(53) : 37;
  const values = authData.length > offset ? cbor.decodeAllSync(authData.subarray(offset), { max_depth: 8, preventDuplicateKeys: true }) : [];
  // Attestations include the COSE public key first. Newer Apple versions append their extension dictionary;
  // Apple's published sample appends it without setting ED, so do not rely on that bit alone.
  const extra = registration ? values.slice(1) : values;
  if (registration && values.length < 1) throw new Error('Missing attested key');
  if (!extra.length && !(authData[32] & 0x80)) return; // Older OS versions have no extension dictionary.
  if (extra.length !== 1 || !extra[0] || typeof extra[0] !== 'object' || Buffer.isBuffer(extra[0])) throw new Error('Invalid app extensions');
  const extensions = extra[0];
  const rawCategory = extensions.apple_validation_category_01 ?? extensions.validationCategory;
  const category = Buffer.isBuffer(rawCategory) && rawCategory.length === 4 ? rawCategory.readUInt32LE() : rawCategory;
  const bundleVersion = extensions.apple_bundle_version_01 ?? extensions.bundleVersion;
  // The launch category describes code signing, not the App Attest environment.
  // Our own development-signed app may use Apple's production service. Its chain,
  // App ID and production aaguid are still verified independently below.
  const allowed = [2, 3, 4];
  if (!allowed.includes(category) || typeof bundleVersion !== 'string' || !/^\d+(?:\.\d+){0,3}$/.test(bundleVersion)
      || bundleVersion.length > 40 || Number(bundleVersion.split('.')[0]) < (config.minimumBundleVersion || 1)) {
    throw new Error('Untrusted app distribution or build');
  }
}

export function verifyAttestationEnvironment(environment: string, config: AttestationConfiguration): void {
  if (environment === 'production' || environment === 'development' && config.allowDevelopmentEnvironment) return;
  if (environment === 'development') throw new WorkoutPageError(401,
    'This build uses development device verification. Rebuild with production App Attest or use a development server.',
    'ATTEST_ENVIRONMENT_MISMATCH');
  throw new Error('Invalid attestation environment');
}

/** Wrap the package with strict framing and certificate-time checks absent from its verifier. */
export function appleVerifier(config: AttestationConfiguration): AttestationVerifier {
  return {
    async registration(bytes, challenge, keyID) {
      const decoded = singleCBOR(bytes);
      if (!Buffer.isBuffer(decoded?.authData) || decoded.authData.length < 87
          || !Array.isArray(decoded?.attStmt?.x5c) || decoded.attStmt.x5c.length !== 2
          || !(decoded.authData[32] & 0x40) || decoded.authData.readUInt16BE(53) !== 32) throw new Error('Malformed attestation');
      const certificates = decoded.attStmt.x5c.map((entry: unknown) => {
        if (!Buffer.isBuffer(entry)) throw new Error('Malformed certificate');
        const cert = new X509Certificate(entry);
        if (Date.now() < Date.parse(cert.validFrom) || Date.now() > Date.parse(cert.validTo)) throw new Error('Expired attestation certificate');
        return cert;
      });
      if (certificates[0].ca || !certificates[1].ca) throw new Error('Invalid certificate chain order');
      if (decoded.authData.subarray(37, 53).equals(Buffer.from('appattestdevelop'))) verifyAttestationEnvironment('development', config);
      const result = verifyAttestation({ attestation: bytes, challenge, keyId: keyID, ...config });
      verifyAttestationEnvironment(result.environment, config);
      verifyAppExtensions(decoded.authData, true, config);
      await verifyAppleReceipt(Buffer.from(result.receipt), `${config.teamIdentifier}.${config.bundleIdentifier}`, String(result.publicKey));
      return { publicKey: String(result.publicKey), receipt: Buffer.from(result.receipt).toString('base64'), environment: result.environment };
    },
    assertion(bytes, payload, key) {
      // A preview database must never make a development key valid in production.
      verifyAttestationEnvironment(key.environment, config);
      const decoded = singleCBOR(bytes);
      if (!Buffer.isBuffer(decoded?.authenticatorData) || decoded.authenticatorData.length < 37
          || !Buffer.isBuffer(decoded?.signature) || decoded.signature.length > 128) throw new Error('Malformed assertion');
      verifyAppExtensions(decoded.authenticatorData, false, config);
      return verifyAssertion({ assertion: bytes, payload, publicKey: key.publicKey, signCount: key.signCount, ...config }).signCount;
    },
  };
}

export function registrationMessage(challenge: string, owner: string): string {
  return `BPM-Workout-Pages|register|${challenge}|${hash(owner)}`;
}
export function assertionMessage(challenge: string, owner: string, method: string, pathname: string, rawBody: Buffer): string {
  return `BPM-Workout-Pages|request|${challenge}|${method}|${pathname}|${hash(rawBody)}|${hash(owner)}`;
}

export class WorkoutPageAttestation {
  constructor(private redis: ShareRedis, private verifier: AttestationVerifier, private now = () => Date.now()) {}

  async challenge(owner: string, value: unknown): Promise<{ challengeID: string; challenge: string; expiresAt: string }> {
    const body = exactObject(value, ['purpose', 'keyID']);
    const ownerHash = hash(credential(owner));
    await assertOwnerAllowed(this.redis, ownerHash);
    if (!['register', 'request'].includes(body.purpose)) invalid('Invalid challenge purpose');
    if (body.purpose === 'request') {
      keyIdentifier(body.keyID);
      const key = await redisJSON<AttestedKey>(this.redis, attestKey(body.keyID));
      if (!key || key.ownerHash !== ownerHash) throw new WorkoutPageError(401, 'Register this device before uploading', 'ATTEST_KEY_UNKNOWN');
    } else if (body.keyID !== undefined) keyIdentifier(body.keyID);
    const challengeID = randomUUID();
    const challenge = randomBytes(32).toString('base64url');
    const expiresAt = new Date(this.now() + 300000).toISOString();
    await this.redis.eval(`return redis.call('SET',KEYS[1],ARGV[1],'EX',300)`, [challengeKey(challengeID)],
      [JSON.stringify({ challenge, ownerHash, purpose: body.purpose, keyID: body.keyID, expiresAt })]);
    return { challengeID, challenge, expiresAt };
  }

  private async pending(id: unknown, ownerHash: string, purpose: Challenge['purpose']): Promise<Challenge> {
    if (typeof id !== 'string' || !challengeIDPattern.test(id)) invalid('Invalid challenge');
    const challenge = await redisJSON<Challenge>(this.redis, challengeKey(id));
    if (!challenge || challenge.ownerHash !== ownerHash || challenge.purpose !== purpose || Date.parse(challenge.expiresAt) <= this.now()) {
      throw new WorkoutPageError(401, 'Request a fresh device-verification challenge', 'ATTEST_CHALLENGE_EXPIRED');
    }
    return challenge;
  }

  async register(owner: string, value: unknown): Promise<{ success: true }> {
    const body = exactObject(value, ['challengeID', 'keyID', 'attestation']);
    const keyID = keyIdentifier(body.keyID);
    const ownerHash = hash(credential(owner));
    await assertOwnerAllowed(this.redis, ownerHash);
    const existing = await redisJSON<AttestedKey>(this.redis, attestKey(keyID));
    // A registration whose success response was lost must remain recoverable.
    if (existing?.ownerHash === ownerHash) return { success: true };
    if (existing) throw new WorkoutPageError(401, 'This device key is already registered', 'ATTESTATION_INVALID');
    const challenge = await this.pending(body.challengeID, ownerHash, 'register');
    if (challenge.keyID && challenge.keyID !== keyID) throw new WorkoutPageError(401, 'Invalid device attestation', 'ATTESTATION_INVALID');
    let verified: Awaited<ReturnType<AttestationVerifier['registration']>>;
    try { verified = await this.verifier.registration(encodedProof(body.attestation, 32768), registrationMessage(challenge.challenge, owner), keyID); }
    catch (error) {
      if (error instanceof WorkoutPageError && error.code === 'ATTEST_ENVIRONMENT_MISMATCH') throw error;
      throw new WorkoutPageError(401, 'Unable to verify this app installation', 'ATTESTATION_INVALID');
    }
    const result = await this.redis.eval(`
      local raw=redis.call('GET',KEYS[1]); if not raw then return 0 end
      local challenge=cjson.decode(raw); if challenge.ownerHash~=ARGV[1] or challenge.challenge~=ARGV[2] then return 0 end
      if redis.call('EXISTS',KEYS[2])==1 then return 0 end
      redis.call('SET',KEYS[2],ARGV[3]); redis.call('DEL',KEYS[1]); return 1`,
      [challengeKey(body.challengeID), attestKey(keyID)], [ownerHash, challenge.challenge,
      JSON.stringify({ ...verified, ownerHash, signCount: 0 })]);
    if (Number(result) !== 1) throw new WorkoutPageError(401, 'Request a fresh device-verification challenge', 'ATTEST_CHALLENGE_EXPIRED');
    return { success: true };
  }

  async authorize(owner: string, method: string, pathname: string, rawBody: Buffer,
    headers: { keyID?: string; challengeID?: string; assertion?: string }): Promise<void> {
    const keyID = keyIdentifier(headers.keyID);
    const ownerHash = hash(credential(owner));
    const key = await redisJSON<AttestedKey>(this.redis, attestKey(keyID));
    if (!key || key.ownerHash !== ownerHash) throw new WorkoutPageError(401, 'Register this device before uploading', 'ATTEST_KEY_UNKNOWN');
    const challenge = await this.pending(headers.challengeID, ownerHash, 'request');
    if (challenge.keyID !== keyID) throw new WorkoutPageError(401, 'Invalid device assertion', 'ATTEST_ASSERTION_INVALID');
    let nextCounter: number;
    try {
      nextCounter = this.verifier.assertion(encodedProof(headers.assertion, 8192),
        assertionMessage(challenge.challenge, owner, method, pathname, rawBody), key);
      if (!Number.isSafeInteger(nextCounter) || nextCounter <= key.signCount) throw new Error('Invalid assertion counter');
    } catch (error) {
      if (error instanceof WorkoutPageError && error.code === 'ATTEST_ENVIRONMENT_MISMATCH') throw error;
      throw new WorkoutPageError(401, 'Unable to verify this upload. Please retry.', 'ATTEST_ASSERTION_INVALID');
    }
    // Consume challenge and advance counter in one transaction. Concurrent/replayed assertions cannot both win.
    const accepted = await this.redis.eval(`
      local rawChallenge=redis.call('GET',KEYS[1]); local rawKey=redis.call('GET',KEYS[2])
      if not rawChallenge or not rawKey then return 0 end
      local challenge=cjson.decode(rawChallenge); local key=cjson.decode(rawKey)
      if challenge.ownerHash~=ARGV[1] or challenge.challenge~=ARGV[2] or key.ownerHash~=ARGV[1]
        or key.signCount>=tonumber(ARGV[3]) then return 0 end
      key.signCount=tonumber(ARGV[3]); redis.call('SET',KEYS[2],cjson.encode(key)); redis.call('DEL',KEYS[1]); return 1`,
      [challengeKey(headers.challengeID!), attestKey(keyID)], [ownerHash, challenge.challenge, nextCounter]);
    if (Number(accepted) !== 1) throw new WorkoutPageError(401, 'Request a fresh device-verification challenge', 'ATTEST_CHALLENGE_EXPIRED');
  }
}
