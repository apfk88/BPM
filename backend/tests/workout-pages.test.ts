import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, X509Certificate } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { Readable } from 'node:stream';
import cbor from 'cbor';
import { WorkoutPages, PAGE_PREFIX, hash, admitUpload, enforceRate } from '../lib/workout-pages';
import { validateWorkoutPage, WorkoutPageError, MAX_COMPRESSED_BYTES, canonicalJSON } from '../lib/workout-page-validation';
import { readWorkoutPageBody } from '../lib/workout-page-api';
import { appleVerifier, assertionMessage, verifyAppExtensions, WorkoutPageAttestation } from '../lib/workout-page-attestation';
import { workoutPageConfiguration } from '../lib/workout-page-runtime';
import { verifyAppleReceipt } from '../lib/workout-page-receipt';
import { validateSharedText } from '../lib/workout-page-moderation';
import { redisTestAvailable, startRedisTestServer } from './redis-test-server';
import { createBody, MemoryWorkoutBlobs, signingFixture, startTestHTTP, TEST_APP, testEnvironment, testKey, workoutFixture } from './workout-page-test-support';
import appleFixture from './fixtures/apple-attestation.json';

const skipRedis = redisTestAvailable ? false : 'Install redis-server to run atomic workout page integration tests';
const errorCode = (code: string) => (error: unknown) => error instanceof WorkoutPageError && error.code === code;

test('local text policy rejects explicit abuse without blocking normal training language', () => {
  for (const text of ['I will kill you', 'send me nudes', 'pornographic videos', 'fuck you']) {
    assert.throws(() => validateSharedText(text, ''), errorCode('CONTENT_NOT_ALLOWED'));
  }
  for (const text of ['Killer workout', 'Deadlift and snatch', 'Assault bike intervals', 'Chest and clean practice', 'I will kill this workout']) {
    validateSharedText(text, 'A hard session with my coach.');
  }
  assert.throws(() => validateSharedText('Custom prohibited phrase', '', ['prohibited phrase']), errorCode('CONTENT_NOT_ALLOWED'));
});

test('export allowlist rejects identifying fields, forged fidelity and oversized totals', () => {
  assert.deepEqual(validateWorkoutPage(workoutFixture()), workoutFixture());
  for (const workoutDate of ['2026-11-11', '2024-02-29', null]) {
    const dated = workoutFixture({ workoutDate });
    assert.deepEqual(validateWorkoutPage(dated), dated);
  }
  const unknown = workoutFixture({ quality: { sampleFidelity: 'unknown', exportedSampleCount: 4, rangeMetricsAvailable: false } });
  unknown.samples = unknown.samples.map(({ validUntilElapsedSeconds, ...sample }) => sample);
  assert.deepEqual(validateWorkoutPage(unknown), unknown);
  for (const edit of [
    { workoutID: 'local-private-uuid' }, { healthKitID: 'sensitive' }, { title: '' }, { description: 'a'.repeat(8001) },
    { durationSeconds: 71 }, { elapsedDurationSeconds: Infinity }, { recordedAt: 'yesterday' },
    { workoutDate: '2026-02-29' }, { workoutDate: '2024-02-30' }, { workoutDate: '2026-13-01' },
    { workoutDate: '2026-1-1' }, { workoutDate: '2026-11-11T00:00:00Z' }, { workoutDate: '0000-01-01' },
    { summary: { age: 40 } }, { summary: { minBPM: 140, maxBPM: 120 } },
    { quality: { sampleFidelity: 'full', exportedSampleCount: 4, originalSampleCount: 99, rangeMetricsAvailable: true } },
    { quality: { sampleFidelity: 'unknown', exportedSampleCount: 4, rangeMetricsAvailable: true } },
    { samples: [{ elapsedSeconds: 0, activeSeconds: 0, bpm: 400.5 }] },
    { zones: [{ zone: 1, durationSeconds: 60 }, { zone: 2, durationSeconds: 60 }] },
    { zones: [{ zone: 1, durationSeconds: 10, lowerBPM: 130, upperBPM: 120 }] },
  ]) assert.throws(() => validateWorkoutPage({ ...workoutFixture(), ...edit }), WorkoutPageError);
  assert.equal(canonicalJSON({ b: 2, a: [{ z: 1, f: 2 }] }), canonicalJSON({ a: [{ f: 2, z: 1 }], b: 2 }));
});

test('bounded body reader verifies bytes before allocation and rejects gzip bombs or corrupt UTF8', async () => {
  function body(bytes: Buffer, headers: Record<string, string>) { return Object.assign(Readable.from([bytes]), { headers: { 'content-type': 'application/json', ...headers } }); }
  const raw = gzipSync(JSON.stringify(createBody()));
  const result = await readWorkoutPageBody(body(raw, { 'content-encoding': 'gzip' }));
  assert.ok(result.raw.equals(raw));
  assert.equal((result.value as any).workout.title, 'Intervals');
  await assert.rejects(readWorkoutPageBody(body(raw, { 'content-length': String(MAX_COMPRESSED_BYTES + 1), 'content-encoding': 'gzip' })), errorCode('WORKOUT_TOO_LARGE'));
  await assert.rejects(readWorkoutPageBody(body(gzipSync(Buffer.alloc(17 * 1024 * 1024)), { 'content-encoding': 'gzip' })), errorCode('WORKOUT_TOO_LARGE'));
  await assert.rejects(readWorkoutPageBody(body(Buffer.from([0xff, 0xff]), {})), errorCode('INVALID_JSON'));
  await assert.rejects(readWorkoutPageBody(body(Buffer.from('{}'), { 'content-type': 'text/plain' })), errorCode('UNSUPPORTED_CONTENT_TYPE'));
});

test('configuration is off by default and cannot enable development attestation in production', () => {
  assert.equal(workoutPageConfiguration({}).uploadsEnabled, false);
  assert.equal(workoutPageConfiguration({ WORKOUT_PAGES_UPLOADS_ENABLED: 'true' }).appAttestConfigured, false);
  assert.equal(workoutPageConfiguration({ NODE_ENV: 'production' }).production, true);
  assert.equal(workoutPageConfiguration({ NODE_ENV: 'production', VERCEL_ENV: 'preview' }).production, false);
});

test('App Attest extension handling permits older OS and enforces newer distribution/build metadata', () => {
  const oldAssertion = Buffer.alloc(37);
  verifyAppExtensions(oldAssertion, false, TEST_APP);
  function extension(category: number, version = '25') {
    const value = Buffer.alloc(4); value.writeUInt32LE(category);
    return Buffer.concat([oldAssertion, cbor.encode({ apple_validation_category_01: value, apple_bundle_version_01: version })]);
  }
  verifyAppExtensions(extension(2), false, TEST_APP);
  verifyAppExtensions(extension(4), false, TEST_APP);
  verifyAppExtensions(extension(3), false, TEST_APP);
  verifyAppExtensions(extension(3), false, { ...TEST_APP, allowDevelopmentEnvironment: true });
  assert.throws(() => verifyAppExtensions(extension(0), false, TEST_APP));
  assert.throws(() => verifyAppExtensions(extension(1), false, TEST_APP));
  assert.throws(() => verifyAppExtensions(extension(4, '5'), false, { ...TEST_APP, minimumBundleVersion: 24 }));
  assert.throws(() => verifyAppExtensions(extension(4, 'not-a-version'), false, TEST_APP));
});

test('production Apple verifier rejects malformed certificates and receipts', async () => {
  const verifier = appleVerifier(TEST_APP);
  await assert.rejects(verifier.registration(cbor.encode({ fmt: 'apple-appattest', authData: Buffer.alloc(90),
    attStmt: { x5c: [Buffer.from('not-cert'), Buffer.from('not-cert')], receipt: Buffer.from('not-receipt') } }), 'challenge', randomBytes(32).toString('base64')));
  await assert.rejects(verifyAppleReceipt(Buffer.from('not-signed-data'), '1234567890.com.example', 'not-a-key'));
});

test('Apple published receipt verifies its real signature, pinned chain, app, freshness and attested key', async () => {
  const attestation = cbor.decodeAllSync(Buffer.from(appleFixture.attestation, 'base64'))[0];
  const receipt = Buffer.from(attestation.attStmt.receipt);
  const publicKey = new X509Certificate(attestation.attStmt.x5c[0]).publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const appID = `${appleFixture.teamIdentifier}.${appleFixture.bundleIdentifier}`;
  // The documented synthetic fixture was issued in April. Test at its issuance time, not today's date.
  const issuedAt = Date.parse('2026-04-21T18:13:13Z');
  await verifyAppleReceipt(receipt, appID, publicKey, issuedAt);
  await assert.rejects(verifyAppleReceipt(receipt, '1234567890.other-app', publicKey, issuedAt));
  await assert.rejects(verifyAppleReceipt(receipt, appID, publicKey, issuedAt + 360000));
  await assert.rejects(verifyAppleReceipt(receipt, appID, signingFixture().publicKey, issuedAt));
  const tampered = Buffer.from(receipt); tampered[tampered.length - 20] ^= 1;
  await assert.rejects(verifyAppleReceipt(tampered, appID, publicKey, issuedAt));
});

test('private page lifecycle is atomic and raw content never enters Redis metadata', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs();
  let now = Date.now(); const pages = new WorkoutPages(redis, blobs, () => now);
  const owner = testKey(); const body = createBody();
  const first = await pages.create(owner, body);
  assert.equal(first.version, 1);
  assert.deepEqual(await pages.create(owner, body), first);
  assert.equal(blobs.writes, 1);
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), body.workout);
  assert.deepEqual(await pages.list(owner), { pages: [first], nextCursor: null });
  assert.deepEqual(await pages.list(testKey()), { pages: [], nextCursor: null });
  const persisted = await redis.get(`${PAGE_PREFIX}page:${body.pageID}`) as string;
  for (const privateString of [body.viewKey, owner, body.workout.description, 'avgBPM', 'samples']) assert.ok(!persisted.includes(String(privateString)));
  assert.equal(await redis.command('TTL', `${PAGE_PREFIX}page:${body.pageID}`), -1);
  await assert.rejects(pages.read(body.pageID, testKey()), errorCode('PAGE_NOT_FOUND'));
  await assert.rejects(pages.update(body.pageID, body.viewKey, { expectedVersion: 1, workout: body.workout }), errorCode('PAGE_NOT_FOUND'));
  const changed = workoutFixture({ title: 'Updated intervals' });
  const update = await pages.update(body.pageID, owner, { expectedVersion: 1, workout: changed });
  assert.equal(update.version, 2);
  assert.deepEqual(await pages.update(body.pageID, owner, { expectedVersion: 1, workout: changed }), update);
  assert.equal((await pages.read(body.pageID, body.viewKey)).title, 'Updated intervals');
  assert.equal(blobs.objects.size, 2);
  await pages.cleanup(); assert.equal(blobs.objects.size, 1);
  await assert.rejects(pages.update(body.pageID, owner, { expectedVersion: 1, workout: workoutFixture({ title: 'Stale' }) }), errorCode('PAGE_CONFLICT'));
  const replacement = testKey(), envelope = randomBytes(90).toString('base64url');
  const rotation = await pages.rotate(body.pageID, owner, { expectedVersion: 2, viewKey: replacement, viewKeyRecovery: envelope });
  assert.equal(rotation.version, 3);
  await assert.rejects(pages.read(body.pageID, body.viewKey), errorCode('PAGE_NOT_FOUND'));
  assert.equal((await pages.read(body.pageID, replacement)).title, 'Updated intervals');
  const reads = blobs.reads;
  blobs.failDeletes = true;
  assert.deepEqual(await pages.delete(body.pageID, owner), { success: true });
  assert.deepEqual(await pages.delete(body.pageID, owner), { success: true });
  await assert.rejects(pages.read(body.pageID, replacement), errorCode('PAGE_NOT_FOUND'));
  assert.equal(blobs.reads, reads);
  assert.deepEqual(await pages.list(owner), { pages: [], nextCursor: null });
  await assert.rejects(pages.create(owner, body), errorCode('PAGE_DELETED'));
  now += 61000; blobs.failDeletes = false;
  assert.deepEqual(await pages.cleanup(), { deleted: 1, pending: 0 });
  assert.equal(blobs.objects.size, 0);
  const usage = await pages.usage();
  assert.equal(usage.pagesCreated, 1); assert.equal(usage.pagesUpdated, 1); assert.equal(usage.pagesDeleted, 1);
  assert.equal(usage.linksRotated, 1); assert.equal(usage.publishes, 2); assert.ok(usage.uploadedCompressedBytes > 0);
});

test('operator removal can block new uploads without exposing an admin HTTP capability', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs), owner = testKey(), body = createBody();
  await pages.create(owner, body); await pages.moderate(body.pageID, true);
  await assert.rejects(pages.read(body.pageID, body.viewKey), errorCode('PAGE_NOT_FOUND'));
  await assert.rejects(admitUpload(redis, hash(owner), 'test', 1000), errorCode('OWNER_BLOCKED'));
});

test('deletion wins against an in-flight update and orphan cleanup is durable', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  let now = Date.now(); const blobs = new MemoryWorkoutBlobs(); const pages = new WorkoutPages(redis, blobs, () => now);
  const owner = testKey(), body = createBody(); await pages.create(owner, body);
  let finish!: () => void, started!: () => void;
  const begun = new Promise<void>(resolve => { started = resolve; });
  blobs.beforePut = async () => { started(); await new Promise<void>(resolve => { finish = resolve; }); };
  const updating = pages.update(body.pageID, owner, { expectedVersion: 1, workout: workoutFixture({ title: 'Racing update' }) });
  await begun;
  await pages.delete(body.pageID, owner);
  finish();
  await assert.rejects(updating, errorCode('PAGE_CONFLICT'));
  await assert.rejects(pages.read(body.pageID, body.viewKey), errorCode('PAGE_NOT_FOUND'));
  now += 16 * 60000;
  await pages.cleanup(); assert.equal(blobs.objects.size, 0);
});

test('pending deletion cancels first creation both before service entry and during its Blob write', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  let now = Date.now(); const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs, () => now);
  const owner = testKey(), delayed = createBody();
  assert.deepEqual(await pages.delete(delayed.pageID, owner), { success: true });
  await assert.rejects(pages.create(owner, delayed), errorCode('PAGE_DELETED'));
  assert.equal(blobs.writes, 0);
  const cancellation = `${PAGE_PREFIX}cancel:${hash(owner)}:${delayed.pageID}`;
  const ttl = await redis.command('TTL', cancellation); assert.ok(ttl > 86000 && ttl <= 86400);
  await redis.command('EXPIRE', cancellation, 1);
  assert.deepEqual(await pages.delete(delayed.pageID, owner), { success: true });
  assert.ok(await redis.command('TTL', cancellation) > 86000); // Latest acknowledgment starts a fresh cancellation window.

  // An unrelated owner cannot preempt a page by canceling its public identifier.
  const unrelated = createBody(); await pages.delete(unrelated.pageID, testKey());
  await pages.create(owner, unrelated);
  assert.equal((await pages.read(unrelated.pageID, unrelated.viewKey)).title, 'Intervals');

  const racing = createBody();
  let finish!: () => void, started!: () => void;
  const begun = new Promise<void>(resolve => { started = resolve; });
  blobs.beforePut = async () => { started(); await new Promise<void>(resolve => { finish = resolve; }); };
  const creating = pages.create(owner, racing);
  await begun;
  assert.equal(await redis.get(`${PAGE_PREFIX}page:${racing.pageID}`), null);
  assert.deepEqual(await pages.delete(racing.pageID, owner), { success: true });
  finish();
  await assert.rejects(creating, errorCode('PAGE_DELETED'));
  await assert.rejects(pages.read(racing.pageID, racing.viewKey), errorCode('PAGE_NOT_FOUND'));
  assert.equal((await pages.list(owner)).pages.some(page => page.pageID === racing.pageID), false);
  now += 16 * 60000; await pages.cleanup();
  assert.equal(blobs.objects.size, 1); // Only the unrelated, legitimate page remains.

  await redis.command('SET', `${PAGE_PREFIX}cancellations:${new Date(now).toISOString().slice(0, 10)}:owner:${hash(owner)}`, 100);
  const overLimit = createBody();
  await assert.rejects(pages.delete(overLimit.pageID, owner), errorCode('CANCELLATION_LIMIT'));
  assert.equal(await redis.get(`${PAGE_PREFIX}cancel:${hash(owner)}:${overLimit.pageID}`), null);
});

test('invalid view keys do not spend a page quota and revocation during metrics I/O prevents data return', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), owner = testKey(), body = createBody();
  let revokeDuringMetrics = false;
  const wrapped = {
    get: redis.get,
    eval: async (script: string, keys: string[], args: unknown[]) => {
      const result = await redis.eval(script, keys, args);
      if (revokeDuringMetrics && script.includes("'views'")) {
        revokeDuringMetrics = false;
        await pages.rotate(body.pageID, owner, { expectedVersion: 1, viewKey: testKey(), viewKeyRecovery: randomBytes(90).toString('base64url') });
      }
      return result;
    },
  };
  const pages = new WorkoutPages(wrapped, blobs); await pages.create(owner, body);
  for (let index = 0; index < 5; index++) await assert.rejects(pages.read(body.pageID, testKey()), errorCode('PAGE_NOT_FOUND'));
  const quota = `${PAGE_PREFIX}rate:page:${hash(body.pageID)}:hour`;
  assert.equal(await redis.get(quota), null); assert.equal(blobs.reads, 0);
  revokeDuringMetrics = true;
  await assert.rejects(pages.read(body.pageID, body.viewKey), errorCode('PAGE_NOT_FOUND'));
  assert.equal(await redis.get(quota), '1');
});

test('a link revoked during Blob I/O cannot return its previously authorized data', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs);
  const owner = testKey(), body = createBody(); await pages.create(owner, body);
  blobs.beforeGet = async () => { await pages.rotate(body.pageID, owner, { expectedVersion: 1, viewKey: testKey(), viewKeyRecovery: randomBytes(90).toString('base64url') }); };
  await assert.rejects(pages.read(body.pageID, body.viewKey), errorCode('PAGE_NOT_FOUND'));
});

test('App Attest cryptography binds bytes, owner, method and path and counters reject concurrent replay', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const fixture = signingFixture(); const attestation = new WorkoutPageAttestation(redis, fixture.verifier);
  const owner = testKey();
  const registration = await attestation.challenge(owner, { purpose: 'register' });
  const registrationBody = { challengeID: registration.challengeID, keyID: fixture.keyID, attestation: Buffer.from('synthetic-apple-registration').toString('base64') };
  await attestation.register(owner, registrationBody);
  await attestation.register(owner, registrationBody); // response-loss retry
  await assert.rejects(attestation.register(testKey(), registrationBody), errorCode('ATTESTATION_INVALID'));
  const raw = gzipSync('{}'), path = '/api/workout-pages';
  const challenge = await attestation.challenge(owner, { purpose: 'request', keyID: fixture.keyID });
  const headers = { keyID: fixture.keyID, challengeID: challenge.challengeID,
    assertion: fixture.sign(assertionMessage(challenge.challenge, owner, 'POST', path, raw), 1) };
  await assert.rejects(attestation.authorize(owner, 'POST', path, Buffer.from('{}'), headers), errorCode('ATTEST_ASSERTION_INVALID'));
  await assert.rejects(attestation.authorize(owner, 'PUT', path, raw, headers), errorCode('ATTEST_ASSERTION_INVALID'));
  await assert.rejects(attestation.authorize(owner, 'POST', `${path}/other`, raw, headers), errorCode('ATTEST_ASSERTION_INVALID'));
  const results = await Promise.allSettled([attestation.authorize(owner, 'POST', path, raw, headers), attestation.authorize(owner, 'POST', path, raw, headers)]);
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  await assert.rejects(attestation.authorize(owner, 'POST', path, raw, headers), errorCode('ATTEST_CHALLENGE_EXPIRED'));
});

test('rate, blocked-owner and global budget gates fail closed in Redis', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  await enforceRate(redis, 'test', 1, 60);
  await assert.rejects(enforceRate(redis, 'test', 1, 60), errorCode('RATE_LIMITED'));
  const owner = hash(testKey());
  await admitUpload(redis, owner, 'test-ip', 1);
  await assert.rejects(admitUpload(redis, owner, 'test-ip', 1), errorCode('UPLOAD_LIMIT'));
  await redis.command('SET', `${PAGE_PREFIX}blocked:${owner}`, '1');
  await assert.rejects(admitUpload(redis, owner, 'test-ip', 100), errorCode('OWNER_BLOCKED'));
});

test('real HTTP upload/read/retry/update/rotate/delete flow preserves no-store and authority boundaries', { skip: skipRedis }, async t => {
  const env = await testEnvironment(); t.after(env.stop);
  const http = await startTestHTTP(env.handler); t.after(http.stop);
  const owner = testKey(), body = createBody(), path = '/api/workout-pages';
  await env.register(owner);
  async function upload(method: string, route: string, value: unknown) {
    const raw = gzipSync(JSON.stringify(value));
    return fetch(`${http.url}${route}`, { method, headers: { ...await env.headers(owner, method, route, raw), 'content-encoding': 'gzip' }, body: raw });
  }
  const created = await upload('POST', path, body); assert.equal(created.status, 200);
  assert.equal((await created.json()).pageID, body.pageID);
  assert.equal((await upload('POST', path, body)).status, 200); assert.equal(env.blobs.writes, 1);
  const viewer = await fetch(`${http.url}${path}/${body.pageID}`, { headers: { authorization: `Bearer ${body.viewKey}` } });
  assert.equal(viewer.status, 200); assert.equal(viewer.headers.get('cache-control'), 'private, no-store');
  assert.equal(viewer.headers.get('x-robots-tag'), 'noindex, nofollow, noarchive, nosnippet');
  assert.deepEqual(await viewer.json(), body.workout);
  assert.equal((await fetch(`${http.url}${path}/${body.pageID}`)).status, 404);
  assert.equal((await fetch(`${http.url}${path}/${body.pageID}`, { method: 'DELETE', headers: { authorization: `Bearer ${body.viewKey}` } })).status, 404);
  assert.equal((await upload('PUT', `${path}/${body.pageID}`, { expectedVersion: 1, workout: workoutFixture({ title: 'Updated via HTTP' }) })).status, 200);
  const next = testKey();
  const rotated = await fetch(`${http.url}${path}/${body.pageID}/rotate`, { method: 'POST', headers: { authorization: `Bearer ${owner}`, 'content-type': 'application/json' },
    body: JSON.stringify({ expectedVersion: 2, viewKey: next, viewKeyRecovery: randomBytes(90).toString('base64url') }) });
  assert.equal(rotated.status, 200);
  assert.equal((await fetch(`${http.url}${path}/${body.pageID}`, { headers: { authorization: `Bearer ${body.viewKey}` } })).status, 404);
  assert.equal((await fetch(`${http.url}${path}/${body.pageID}`, { method: 'DELETE', headers: { authorization: `Bearer ${owner}` } })).status, 200);
  assert.equal((await fetch(`${http.url}${path}/${body.pageID}`, { headers: { authorization: `Bearer ${next}` } })).status, 404);
});
