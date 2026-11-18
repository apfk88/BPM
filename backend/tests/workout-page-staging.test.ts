import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { PAGE_PREFIX, WorkoutPages, hash } from '../lib/workout-pages';
import { WorkoutPageError } from '../lib/workout-page-validation';
import { redisTestAvailable, startRedisTestServer } from './redis-test-server';
import { createBody, MemoryWorkoutBlobs, startTestHTTP, testEnvironment, testKey, workoutFixture } from './workout-page-test-support';

const skip = redisTestAvailable ? false : 'Install redis-server to run atomic workout page staging tests';
const errorCode = (code: string) => (error: unknown) => error instanceof WorkoutPageError && error.code === code;
const day = 24 * 60 * 60 * 1000;

test('background upload stays private until an owner explicitly activates the exact draft', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs);
  const owner = testKey(), body = { ...createBody(), staged: true };
  const draft = await pages.create(owner, body);
  assert.equal(draft.staged, true); assert.ok(draft.stageID); assert.ok(draft.stageExpiresAt);
  assert.equal(draft.version, 1);
  assert.deepEqual(await pages.create(owner, body), draft);
  assert.equal(blobs.writes, 1);
  assert.equal(await redis.get(`${PAGE_PREFIX}page:${body.pageID}`), null);
  assert.deepEqual(await pages.list(owner), { pages: [], nextCursor: null });
  await assert.rejects(pages.read(body.pageID, body.viewKey), errorCode('PAGE_NOT_FOUND'));
  assert.equal(blobs.reads, 0);
  const persisted = await redis.get(`${PAGE_PREFIX}stage:${body.pageID}`) as string;
  for (const privateValue of [owner, body.viewKey, body.workout.description, 'avgBPM', 'samples']) {
    assert.ok(!persisted.includes(String(privateValue)));
  }
  const ttl = await redis.command('PTTL', `${PAGE_PREFIX}stage:${body.pageID}`);
  assert.ok(ttl > day - 10000 && ttl <= day);
  await assert.rejects(pages.activate(body.pageID, body.viewKey, { stageID: draft.stageID }), errorCode('PAGE_NOT_FOUND'));
  const activated = await pages.activate(body.pageID, owner, { stageID: draft.stageID });
  assert.equal(activated.version, 1); assert.equal(activated.staged, undefined); assert.equal(activated.stageID, undefined);
  assert.deepEqual(await pages.activate(body.pageID, owner, { stageID: draft.stageID }), activated);
  assert.deepEqual(await pages.create(owner, body), activated); // Lost activation response is recoverable by either retry.
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), body.workout);
  assert.deepEqual(await pages.list(owner), { pages: [activated], nextCursor: null });
  assert.equal(await redis.get(`${PAGE_PREFIX}stage:${body.pageID}`), null);
  assert.equal(await redis.command('TTL', `${PAGE_PREFIX}page:${body.pageID}`), -1);
  const usage = await pages.usage();
  assert.equal(usage.stagedUploads, 1); assert.equal(usage.publishes, 1); assert.equal(usage.pagesCreated, 1);
});

test('staged edits preserve the active snapshot and only the latest draft can replace it', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs);
  const owner = testKey(), body = createBody(), active = await pages.create(owner, body);
  const firstBody = { expectedVersion: 1, staged: true, workout: workoutFixture({ title: 'Unshared first draft' }) };
  const first = await pages.update(body.pageID, owner, firstBody);
  assert.equal(first.version, 2);
  assert.deepEqual(await pages.update(body.pageID, owner, firstBody), first);
  assert.equal(blobs.writes, 2);
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), body.workout);
  assert.deepEqual((await pages.list(owner)).pages, [active]);
  const lastWorkout = workoutFixture({ title: 'Final shared draft' });
  const last = await pages.update(body.pageID, owner, { expectedVersion: 1, staged: true, workout: lastWorkout });
  assert.notEqual(last.stageID, first.stageID);
  await assert.rejects(pages.activate(body.pageID, owner, { stageID: first.stageID }), errorCode('STAGE_CONFLICT'));
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), body.workout);
  const activated = await pages.activate(body.pageID, owner, { stageID: last.stageID });
  assert.equal(activated.version, 2);
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), lastWorkout);
  assert.deepEqual(await pages.activate(body.pageID, owner, { stageID: last.stageID }), activated);
  const writes = blobs.writes;
  assert.deepEqual(await pages.update(body.pageID, owner, { expectedVersion: 1, staged: true, workout: lastWorkout }), activated);
  assert.equal(blobs.writes, writes); // Unchanged active content needs neither another upload nor activation.
  assert.deepEqual(await pages.cleanup(), { deleted: 2, pending: 0 });
  assert.equal(blobs.objects.size, 1);
  const usage = await pages.usage(); assert.equal(usage.publishes, 2); assert.equal(usage.pagesUpdated, 1);
});

test('returning to an abandoned first draft can replace its content without publishing either upload early', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs);
  const owner = testKey(), original = { ...createBody(), staged: true };
  const first = await pages.create(owner, original);
  const edited = { ...original, workout: workoutFixture({ title: 'Edited before the first share' }) };
  const latest = await pages.create(owner, edited);
  assert.notEqual(latest.stageID, first.stageID); assert.equal(latest.version, 1);
  assert.deepEqual(await pages.create(owner, edited), latest); assert.equal(blobs.writes, 2);
  assert.deepEqual((await pages.list(owner)).pages, []);
  await assert.rejects(pages.read(original.pageID, original.viewKey), errorCode('PAGE_NOT_FOUND'));
  await assert.rejects(pages.activate(original.pageID, owner, { stageID: first.stageID }), errorCode('STAGE_CONFLICT'));
  await assert.rejects(pages.create(testKey(), edited), errorCode('PAGE_CONFLICT'));
  assert.deepEqual(await pages.cleanup(), { deleted: 1, pending: 1 });
  await pages.activate(original.pageID, owner, { stageID: latest.stageID });
  assert.deepEqual(await pages.read(original.pageID, original.viewKey), edited.workout);
  assert.equal(blobs.objects.size, 1);
});

test('abandoned new pages and staged edits expire without changing a previously shared page', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  let now = Date.now(); const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs, () => now);
  const owner = testKey(), body = createBody(), abandoned = createBody();
  const active = await pages.create(owner, body);
  const edit = await pages.update(body.pageID, owner, { expectedVersion: 1, staged: true, workout: workoutFixture({ title: 'Abandoned edit' }) });
  const draft = await pages.create(owner, { ...abandoned, staged: true });
  now += day + 1;
  for (const candidate of [edit, draft]) {
    await assert.rejects(pages.activate(candidate.pageID, owner, { stageID: candidate.stageID }), errorCode('STAGE_EXPIRED'));
  }
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), body.workout);
  await assert.rejects(pages.read(abandoned.pageID, abandoned.viewKey), errorCode('PAGE_NOT_FOUND'));
  assert.deepEqual((await pages.list(owner)).pages, [active]);
  assert.deepEqual(await pages.cleanup(), { deleted: 2, pending: 0 });
  assert.equal(blobs.objects.size, 1);
  assert.equal(await redis.get(`${PAGE_PREFIX}stage:${abandoned.pageID}`), null);
  assert.equal(await redis.get(`${PAGE_PREFIX}stage:${body.pageID}`), null);
  const replacement = await pages.create(owner, { ...abandoned, staged: true });
  assert.notEqual(replacement.stageID, draft.stageID);
  await pages.activate(abandoned.pageID, owner, { stageID: replacement.stageID });
  assert.deepEqual(await pages.read(abandoned.pageID, abandoned.viewKey), abandoned.workout);
});

test('cleanup and activation cannot race into publishing a deleted draft object', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  let now = Date.now(); const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs, () => now);
  const owner = testKey(), body = createBody();
  const draft = await pages.create(owner, { ...body, staged: true });
  const blobPath = Array.from(blobs.objects.keys())[0];
  await redis.command('ZADD', `${PAGE_PREFIX}cleanup`, now, blobPath);
  assert.deepEqual(await pages.cleanup(), { deleted: 0, pending: 1 }); // A premature cleanup preserves a live draft.
  now += day - 1;
  await pages.activate(body.pageID, owner, { stageID: draft.stageID });
  await redis.command('ZADD', `${PAGE_PREFIX}cleanup`, now, blobPath);
  assert.deepEqual(await pages.cleanup(), { deleted: 0, pending: 0 }); // A queued object that became active is preserved.
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), body.workout);

  const expiring = createBody(), expiringDraft = await pages.create(owner, { ...expiring, staged: true });
  now += day + 1;
  const remove = blobs.delete.bind(blobs);
  blobs.delete = async path => {
    // Cleanup has atomically invalidated the expired draft before touching Blob storage.
    await assert.rejects(pages.activate(expiring.pageID, owner, { stageID: expiringDraft.stageID }), errorCode('STAGE_EXPIRED'));
    await remove(path);
  };
  assert.deepEqual(await pages.cleanup(), { deleted: 1, pending: 0 });
  assert.equal(blobs.objects.size, 1);
});

test('deleting an unshared page cancels its draft and deletion also wins over in-flight staging', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  let now = Date.now(); const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs, () => now);
  const owner = testKey(), body = createBody();
  const draft = await pages.create(owner, { ...body, staged: true });
  // Knowing a page identifier does not let another installation remove its pending draft.
  await pages.delete(body.pageID, testKey());
  assert.deepEqual(await pages.create(owner, { ...body, staged: true }), draft);
  await pages.delete(body.pageID, owner);
  await assert.rejects(pages.activate(body.pageID, owner, { stageID: draft.stageID }), errorCode('PAGE_DELETED'));
  await assert.rejects(pages.create(owner, { ...body, staged: true }), errorCode('PAGE_DELETED'));
  assert.equal(blobs.objects.size, 0);

  for (const update of [false, true]) {
    const racing = createBody();
    if (update) await pages.create(owner, racing);
    let finish!: () => void, started!: () => void;
    const begun = new Promise<void>(resolve => { started = resolve; });
    blobs.beforePut = async () => { started(); await new Promise<void>(resolve => { finish = resolve; }); };
    const staging = update
      ? pages.update(racing.pageID, owner, { expectedVersion: 1, staged: true, workout: workoutFixture({ title: 'Racing draft' }) })
      : pages.create(owner, { ...racing, staged: true });
    await begun; await pages.delete(racing.pageID, owner); finish();
    await assert.rejects(staging, errorCode(update ? 'PAGE_CONFLICT' : 'PAGE_DELETED'));
    blobs.beforePut = undefined;
    await assert.rejects(pages.read(racing.pageID, racing.viewKey), errorCode('PAGE_NOT_FOUND'));
    now += 16 * 60000; await pages.cleanup();
    assert.equal(blobs.objects.size, 0);
  }
});

test('legacy writes and link rotation supersede drafts without changing existing client behavior', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs);
  const owner = testKey(), body = createBody();
  const draft = await pages.create(owner, { ...body, staged: true });
  const legacy = await pages.create(owner, body);
  assert.equal(legacy.staged, undefined); assert.equal(legacy.version, 1);
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), body.workout);
  await assert.rejects(pages.activate(body.pageID, owner, { stageID: draft.stageID }), errorCode('STAGE_EXPIRED'));
  const edit = await pages.update(body.pageID, owner, { expectedVersion: 1, staged: true, workout: workoutFixture({ title: 'Unshared edit' }) });
  const direct = workoutFixture({ title: 'Legacy direct update' });
  await pages.update(body.pageID, owner, { expectedVersion: 1, workout: direct });
  await assert.rejects(pages.activate(body.pageID, owner, { stageID: edit.stageID }), errorCode('STAGE_EXPIRED'));
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), direct);
  const rotatedDraft = await pages.update(body.pageID, owner, { expectedVersion: 2, staged: true, workout: workoutFixture({ title: 'Draft before rotation' }) });
  const replacementKey = testKey();
  await pages.rotate(body.pageID, owner, { expectedVersion: 2, viewKey: replacementKey, viewKeyRecovery: randomBytes(90).toString('base64url') });
  await assert.rejects(pages.activate(body.pageID, owner, { stageID: rotatedDraft.stageID }), errorCode('STAGE_EXPIRED'));
  await assert.rejects(pages.read(body.pageID, body.viewKey), errorCode('PAGE_NOT_FOUND'));
  assert.deepEqual(await pages.read(body.pageID, replacementKey), direct);
  await pages.cleanup(); assert.equal(blobs.objects.size, 1);
});

test('activation rechecks owner blocking and the upload pause before publishing a staged object', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs);
  const owner = testKey(), body = createBody(), draft = await pages.create(owner, { ...body, staged: true });
  for (const gate of [`${PAGE_PREFIX}uploads-paused`, `${PAGE_PREFIX}blocked:${hash(owner)}`]) {
    await redis.command('SET', gate, 1);
    await assert.rejects(pages.activate(body.pageID, owner, { stageID: draft.stageID }), errorCode('UPLOADS_PAUSED'));
    await assert.rejects(pages.read(body.pageID, body.viewKey), errorCode('PAGE_NOT_FOUND'));
    await redis.command('DEL', gate);
  }
  await pages.activate(body.pageID, owner, { stageID: draft.stageID });
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), body.workout);
});

test('HTTP staged upload requires attestation while final owner activation publishes without another upload', { skip }, async t => {
  const env = await testEnvironment(); t.after(env.stop);
  const http = await startTestHTTP(env.handler); t.after(http.stop);
  const owner = testKey(), body = { ...createBody(), staged: true }, base = '/api/workout-pages';
  await env.register(owner);
  async function upload(method: string, route: string, value: unknown) {
    const raw = gzipSync(JSON.stringify(value));
    return fetch(`${http.url}${route}`, { method, headers: { ...await env.headers(owner, method, route, raw), 'content-encoding': 'gzip' }, body: raw });
  }
  const created = await upload('POST', base, body); assert.equal(created.status, 200);
  const draft = await created.json(); assert.equal(draft.staged, true);
  const url = `${http.url}${base}/${body.pageID}`;
  const view = () => fetch(url, { headers: { authorization: `Bearer ${body.viewKey}` } });
  assert.equal((await view()).status, 404);
  const activate = (key: string) => fetch(`${url}/activate`, { method: 'POST',
    headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' }, body: JSON.stringify({ stageID: draft.stageID }) });
  assert.equal((await activate(body.viewKey)).status, 404);
  const response = await activate(owner); assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'private, no-store');
  assert.equal((await response.json()).stageID, undefined);
  assert.equal((await activate(owner)).status, 200); assert.equal(env.blobs.writes, 1);
  assert.deepEqual(await (await view()).json(), body.workout);

  const nextWorkout = workoutFixture({ title: 'Background HTTP edit' });
  const update = await upload('PUT', `${base}/${body.pageID}`, { expectedVersion: 1, staged: true, workout: nextWorkout });
  assert.equal(update.status, 200); const next = await update.json();
  assert.deepEqual(await (await view()).json(), body.workout);
  const publish = await fetch(`${url}/activate`, { method: 'POST', headers: { authorization: `Bearer ${owner}`, 'content-type': 'application/json' }, body: JSON.stringify({ stageID: next.stageID }) });
  assert.equal(publish.status, 200); assert.deepEqual(await (await view()).json(), nextWorkout);
  assert.equal(env.blobs.writes, 2);
});
