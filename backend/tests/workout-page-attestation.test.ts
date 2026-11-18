import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, createSign, generateKeyPairSync } from 'node:crypto';
import cbor from 'cbor';
import { appleVerifier, verifyAttestationEnvironment, WorkoutPageAttestation } from '../lib/workout-page-attestation';
import { WorkoutPageError } from '../lib/workout-page-validation';
import { signingFixture, TEST_APP, testKey } from './workout-page-test-support';
import { redisTestAvailable, startRedisTestServer } from './redis-test-server';

const errorCode = (code: string) => (error: unknown) => error instanceof WorkoutPageError && error.code === code;

test('development signing is distinct from production App Attest and cannot relax environment enforcement', () => {
  verifyAttestationEnvironment('production', TEST_APP);
  verifyAttestationEnvironment('production', { ...TEST_APP, allowDevelopmentEnvironment: true });
  verifyAttestationEnvironment('development', { ...TEST_APP, allowDevelopmentEnvironment: true });
  assert.throws(() => verifyAttestationEnvironment('development', TEST_APP), errorCode('ATTEST_ENVIRONMENT_MISMATCH'));
  assert.throws(() => verifyAttestationEnvironment('unknown', { ...TEST_APP, allowDevelopmentEnvironment: true }));
});

test('production assertions accept our development-signed app but reject wrong team, bundle, environment and tampering', () => {
  const pair = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const payload = 'Synthetic exact request bytes, owner, method and pathname';
  const header = Buffer.alloc(37);
  createHash('sha256').update(`${TEST_APP.teamIdentifier}.${TEST_APP.bundleIdentifier}`).digest().copy(header);
  header.writeUInt32BE(1, 33);
  const category = Buffer.alloc(4); category.writeUInt32LE(3);
  const authenticatorData = Buffer.concat([header, cbor.encode({
    apple_validation_category_01: category, apple_bundle_version_01: '25',
  })]);
  const nonce = createHash('sha256').update(Buffer.concat([authenticatorData, createHash('sha256').update(payload).digest()])).digest();
  const signature = createSign('SHA256').update(nonce).sign(pair.privateKey);
  const proof = cbor.encode({ authenticatorData, signature });
  const key = { ownerHash: 'synthetic-owner', publicKey: pair.publicKey.export({ format: 'pem', type: 'spki' }).toString(),
    signCount: 0, receipt: 'synthetic-receipt', environment: 'production' };
  assert.equal(appleVerifier(TEST_APP).assertion(proof, payload, key), 1);
  assert.throws(() => appleVerifier({ ...TEST_APP, teamIdentifier: '0000000000' }).assertion(proof, payload, key));
  assert.throws(() => appleVerifier({ ...TEST_APP, bundleIdentifier: 'com.example.other' }).assertion(proof, payload, key));
  assert.throws(() => appleVerifier(TEST_APP).assertion(proof, `${payload}-changed`, key));
  assert.throws(() => appleVerifier(TEST_APP).assertion(proof, payload, { ...key, environment: 'development' }),
    errorCode('ATTEST_ENVIRONMENT_MISMATCH'));
  assert.throws(() => appleVerifier(TEST_APP).assertion(proof, payload, { ...key, signCount: 1 }));
});

test('expired challenges stay rejected and fresh registration preserves single-use authorization', {
  skip: redisTestAvailable ? false : 'Install redis-server to run attestation challenge integration tests',
}, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const signing = signingFixture();
  let now = Date.now();
  const attestation = new WorkoutPageAttestation(redis, signing.verifier, () => now);
  const owner = testKey();
  const expired = await attestation.challenge(owner, { purpose: 'register' });
  const proof = Buffer.from('synthetic-apple-registration').toString('base64');
  now += 300001;
  await assert.rejects(attestation.register(owner, { challengeID: expired.challengeID, keyID: signing.keyID, attestation: proof }),
    errorCode('ATTEST_CHALLENGE_EXPIRED'));
  const fresh = await attestation.challenge(owner, { purpose: 'register' });
  await attestation.register(owner, { challengeID: fresh.challengeID, keyID: signing.keyID, attestation: proof });
  const request = await attestation.challenge(owner, { purpose: 'request', keyID: signing.keyID });
  now += 300001;
  await assert.rejects(attestation.authorize(owner, 'POST', '/api/workout-pages', Buffer.from('{}'), {
    keyID: signing.keyID, challengeID: request.challengeID, assertion: proof,
  }), errorCode('ATTEST_CHALLENGE_EXPIRED'));
});
