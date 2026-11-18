import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createBody, MemoryWorkoutBlobs, startTestHTTP, testEnvironment, testKey } from './workout-page-test-support';
import { redisTestAvailable, startRedisTestServer } from './redis-test-server';
import { hash, PAGE_PREFIX, workoutLinkCode, workoutPreviewToken, WorkoutPages } from '../lib/workout-pages';
import { WorkoutPageError } from '../lib/workout-page-validation';
import { workoutPreviewImageURL } from '../lib/workout-page-viewer';

const skip = !redisTestAvailable;
const notFound = (error: unknown) => error instanceof WorkoutPageError && error.status === 404;
const indexKey = (code: string) => `${PAGE_PREFIX}link:${hash(code)}`;

test('short link vector retains 128-bit image capability and needs no preview query', () => {
  const id = '11111111-1111-4111-8111-111111111111', key = 'A'.repeat(43);
  const code = workoutLinkCode(id, hash(key));
  assert.equal(code, 'eReZrdBGAlQEUvbRHgNVQg');
  assert.equal(Buffer.from(code, 'base64url').length, 16);
  assert.equal(workoutPreviewImageURL(code, undefined), `https://bpmtracker.app/api/workout-pages/${code}/preview`);
  assert.equal(`https://bpmtracker.app/w/${code}#${key}`.length, 91);
  assert.equal(`https://bpmtracker.app/w/${id}?p=${workoutPreviewToken(id, hash(key))}#${key}`.length, 151);
});

test('short alias grants only a preview; old links and full fragment authorization still work', { skip }, async t => {
  const env = await testEnvironment(); t.after(env.stop);
  const server = await startTestHTTP(env.handler); t.after(server.stop);
  const body = createBody(), owner = testKey();
  const metadata = await env.pages.create(owner, body);
  const code = metadata.linkCode!;
  assert.equal(code.length, 22);
  const endpoint = `${server.url}/api/workout-pages/${code}`;
  const preview = await fetch(`${endpoint}/preview`);
  assert.equal(preview.status, 200);
  assert.equal(preview.headers.get('content-type'), 'image/png');
  assert.match(preview.headers.get('cache-control')!, /no-store/);
  for (const credential of ['', code, testKey(), workoutPreviewToken(body.pageID, hash(body.viewKey))]) {
    const denied = await fetch(endpoint, { headers: { Authorization: `Bearer ${credential}` } });
    assert.equal(denied.status, 404);
  }
  assert.deepEqual(await env.pages.read(code, body.viewKey), body.workout);
  assert.deepEqual(await env.pages.read(body.pageID, body.viewKey), body.workout);
  assert.deepEqual(await env.pages.readPreview(body.pageID, workoutPreviewToken(body.pageID, hash(body.viewKey))), body.workout);
  const ownerDenied = await fetch(endpoint, { method: 'DELETE', headers: { Authorization: `Bearer ${code}` } });
  assert.equal(ownerDenied.status, 401);
});

test('staged, rotated, deleted and unknown aliases remain inaccessible', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const pages = new WorkoutPages(redis, new MemoryWorkoutBlobs()), body = createBody(), owner = testKey();
  const staged = await pages.create(owner, { ...body, staged: true });
  const originalCode = workoutLinkCode(body.pageID, hash(body.viewKey));
  assert.equal(staged.linkCode, undefined);
  await assert.rejects(pages.readPreview(originalCode, undefined), notFound);
  await assert.rejects(pages.read(originalCode, body.viewKey), notFound);
  const activated = await pages.activate(body.pageID, owner, { stageID: staged.stageID });
  assert.equal(activated.linkCode, originalCode);
  assert.deepEqual(await pages.read(originalCode, body.viewKey), body.workout);
  const nextKey = testKey();
  const rotated = await pages.rotate(body.pageID, owner, { expectedVersion: 1, viewKey: nextKey, viewKeyRecovery: randomBytes(90).toString('base64url') });
  assert.notEqual(rotated.linkCode, originalCode);
  await assert.rejects(pages.readPreview(originalCode, undefined), notFound);
  await assert.rejects(pages.read(originalCode, nextKey), notFound);
  assert.deepEqual(await pages.read(rotated.linkCode!, nextKey), body.workout);
  await pages.delete(body.pageID, owner);
  await assert.rejects(pages.readPreview(rotated.linkCode!, undefined), notFound);
  await assert.rejects(pages.read(rotated.linkCode!, nextKey), notFound);
  await assert.rejects(pages.readPreview(randomBytes(16).toString('base64url'), undefined), notFound);
});

test('owner refresh upgrades older pages and alias collisions preserve legacy access without overwriting', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const pages = new WorkoutPages(redis, new MemoryWorkoutBlobs()), owner = testKey(), body = createBody();
  const code = workoutLinkCode(body.pageID, hash(body.viewKey));
  await redis.command('SET', indexKey(code), createBody().pageID);
  const created = await pages.create(owner, body);
  assert.equal(created.linkCode, undefined);
  assert.deepEqual(await pages.read(body.pageID, body.viewKey), body.workout);
  await assert.rejects(pages.readPreview(code, undefined), notFound);
  assert.notEqual(await redis.get(indexKey(code)), body.pageID);
  await redis.command('DEL', indexKey(code));
  const listing = await pages.list(owner);
  assert.equal(listing.pages[0].linkCode, code);
  assert.deepEqual(await pages.read(code, body.viewKey), body.workout);
});

test('revocation during short-link blob reads still wins and preview limits match legacy URLs', { skip }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs), owner = testKey(), body = createBody();
  const code = (await pages.create(owner, body)).linkCode!;
  await redis.command('SET', `${PAGE_PREFIX}rate:preview:${hash(body.pageID)}:hour`, 120);
  await assert.rejects(pages.readPreview(code, undefined), error => error instanceof WorkoutPageError && error.status === 429);
  blobs.beforeGet = async () => { blobs.failDeletes = true; await pages.delete(body.pageID, owner); };
  await assert.rejects(pages.read(code, body.viewKey), notFound);
});
