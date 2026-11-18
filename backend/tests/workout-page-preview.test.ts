import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createWorkoutPageHandler } from '../lib/workout-page-api';
import { workoutPageFixture } from '../lib/workout-page-fixture';
import { previewPlotPoints, previewTitle, renderWorkoutPreview } from '../lib/workout-page-preview';
import { WorkoutPages, hash, workoutPreviewToken, PAGE_PREFIX } from '../lib/workout-pages';
import { WorkoutPageError } from '../lib/workout-page-validation';
import { createBody, testEnvironment, testKey, MemoryWorkoutBlobs, startTestHTTP } from './workout-page-test-support';
import { redisTestAvailable, startRedisTestServer } from './redis-test-server';

const skipRedis = !redisTestAvailable && 'Install redis-server or set BPM_TEST_REDIS_SERVER to run service/HTTP integration tests';
const notFound = (error: unknown) => error instanceof WorkoutPageError && error.status === 404 && error.code === 'PAGE_NOT_FOUND';
const previewURL = (origin: string, id: string, token?: string) => `${origin}/api/workout-pages/${id}/preview${token === undefined ? '' : `?p=${token}`}`;

function privateHeaders(response: Response) {
  assert.match(response.headers.get('cache-control') || '', /no-store/);
  assert.equal(response.headers.get('cdn-cache-control'), 'no-store');
  assert.equal(response.headers.get('vercel-cdn-cache-control'), 'no-store');
  assert.match(response.headers.get('x-robots-tag') || '', /noindex/);
  assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
}

function isPNG(bytes: Buffer) {
  assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.equal(bytes.readUInt32BE(16), 1080);
  assert.equal(bytes.readUInt32BE(20), 1350);
}

test('image capability agrees with native HMAC vector and binds the page and view-key hash', () => {
  const id = '11111111-1111-4111-8111-111111111111', key = 'A'.repeat(43);
  const capability = workoutPreviewToken(id, hash(key));
  assert.equal(capability, 'U1TUNiJYjihwjgiN76XDJIBul9E8PhR7xHQSljF-jZ4');
  assert.notEqual(capability, workoutPreviewToken('22222222-2222-4222-8222-222222222222', hash(key)));
  assert.notEqual(capability, workoutPreviewToken(id, hash(testKey())));
});

test('preview drawing has a hard 1000-point budget even with a gap between every sample', () => {
  const workout = workoutPageFixture();
  workout.samples = Array.from({ length: 5000 }, (_, index) => ({ activeSeconds: index * 4, elapsedSeconds: index * 4,
    bpm: index % 7 === 0 ? 190 : 80 + index % 50, validUntilElapsedSeconds: index * 4 + 1 }));
  workout.durationSeconds = workout.elapsedDurationSeconds = 20000;
  workout.intervals = [];
  const plotted = previewPlotPoints(workout);
  assert.ok(plotted.length <= 1000);
  assert.equal(Math.min(...plotted.map(point => point.bpm)), 80);
  assert.equal(Math.max(...plotted.map(point => point.bpm)), 190);
  assert.equal(new Set(plotted.map(point => point.segment)).size, plotted.length, 'gaps must retain distinct segment IDs');
});

test('preview renders a real PNG without outbound font, emoji, or image requests', async () => {
  const originalFetch = globalThis.fetch;
  let outbound = 0;
  globalThis.fetch = async () => { outbound += 1; throw new Error('Preview must not fetch external assets'); };
  try {
    isPNG(await renderWorkoutPreview(workoutPageFixture()));
    isPNG(await renderWorkoutPreview({ ...workoutPageFixture(), title: '秘密 💪 workout' }));
    isPNG(await renderWorkoutPreview({ ...workoutPageFixture(), title: 'A very long but realistic workout title with multiple words to check card cropping' }));
    assert.equal(previewTitle('Café recovery'), 'Cafe recovery');
    assert.equal(previewTitle('Morning 💪 intervals'), 'Morning intervals');
    assert.equal(previewTitle('秘密 💪 workout'), 'workout');
    assert.equal(previewTitle('秘密 💪'), 'Workout');
    assert.equal(outbound, 0);
  } finally { globalThis.fetch = originalFetch; }
});

test('existing pages accept derived previews without rewriting content, and the capability cannot read full data', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs), owner = testKey(), body = createBody();
  await pages.create(owner, body);
  const capability = workoutPreviewToken(body.pageID, hash(body.viewKey));
  assert.equal((await pages.readPreview(body.pageID, capability)).title, body.workout.title);
  assert.equal(blobs.writes, 1, 'preview must use the existing private workout object');
  await assert.rejects(pages.read(body.pageID, capability), notFound);
  const other = createBody(); await pages.create(owner, other);
  await assert.rejects(pages.readPreview(other.pageID, capability), notFound);
  for (const invalid of [undefined, '', testKey(), body.viewKey, [capability], { p: capability }]) {
    await assert.rejects(pages.readPreview(body.pageID, invalid), notFound);
  }
  assert.equal(await redis.get(`${PAGE_PREFIX}rate:preview:${hash(body.pageID)}:hour`), '1');
  assert.equal(blobs.reads, 1, 'unauthorized requests must not read Blob or spend the page quota');
});

test('preview cannot reveal staged pages and follows activation, rotation, deletion and the image quota', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs), owner = testKey(), body = createBody();
  const stage = await pages.create(owner, { ...body, staged: true });
  const capability = workoutPreviewToken(body.pageID, hash(body.viewKey));
  await assert.rejects(pages.readPreview(body.pageID, capability), notFound);
  assert.equal(blobs.reads, 0);
  await pages.activate(body.pageID, owner, { stageID: stage.stageID });
  await pages.readPreview(body.pageID, capability);
  const nextKey = testKey(), next = workoutPreviewToken(body.pageID, hash(nextKey));
  await pages.rotate(body.pageID, owner, { expectedVersion: 1, viewKey: nextKey, viewKeyRecovery: randomBytes(90).toString('base64url') });
  await assert.rejects(pages.readPreview(body.pageID, capability), notFound);
  await pages.readPreview(body.pageID, next);
  await redis.command('SET', `${PAGE_PREFIX}rate:preview:${hash(body.pageID)}:hour`, 120);
  await assert.rejects(pages.readPreview(body.pageID, next), error => error instanceof WorkoutPageError && error.status === 429);
  await pages.delete(body.pageID, owner);
  await assert.rejects(pages.readPreview(body.pageID, next), notFound);
});

test('rotation or deletion during preview Blob I/O cannot return previously authorized content', { skip: skipRedis }, async t => {
  const redis = await startRedisTestServer(); t.after(redis.stop);
  for (const action of ['rotate', 'delete'] as const) {
    const blobs = new MemoryWorkoutBlobs(), pages = new WorkoutPages(redis, blobs), owner = testKey(), body = createBody();
    await pages.create(owner, body);
    blobs.failDeletes = true;
    blobs.beforeGet = async () => {
      if (action === 'delete') await pages.delete(body.pageID, owner);
      else await pages.rotate(body.pageID, owner, { expectedVersion: 1, viewKey: testKey(), viewKeyRecovery: randomBytes(90).toString('base64url') });
    };
    await assert.rejects(pages.readPreview(body.pageID, workoutPreviewToken(body.pageID, hash(body.viewKey))), notFound);
  }
});

test('preview HTTP endpoint returns only a private PNG, and rejects page ID or capability as full-data authority', { skip: skipRedis }, async t => {
  const env = await testEnvironment(); t.after(env.stop);
  const server = await startTestHTTP(env.handler); t.after(server.stop);
  const body = createBody(workoutPageFixture()), owner = testKey(); await env.pages.create(owner, body);
  const capability = workoutPreviewToken(body.pageID, hash(body.viewKey));
  const response = await fetch(previewURL(server.url, body.pageID, capability));
  assert.equal(response.status, 200); privateHeaders(response);
  assert.equal(response.headers.get('content-type'), 'image/png');
  isPNG(Buffer.from(await response.arrayBuffer()));
  for (const url of [previewURL(server.url, body.pageID), previewURL(server.url, body.pageID, testKey()),
    previewURL(server.url, createBody().pageID, capability), `${server.url}/api/workout-pages/${body.pageID}?p=${capability}`]) {
    const denied = await fetch(url); assert.equal(denied.status, 404); privateHeaders(denied);
  }
  const deniedBearer = await fetch(`${server.url}/api/workout-pages/${body.pageID}`, { headers: { authorization: `Bearer ${capability}` } });
  assert.equal(deniedBearer.status, 404); privateHeaders(deniedBearer);
  await env.redis.command('SET', `${PAGE_PREFIX}rate:preview:${hash(body.pageID)}:hour`, 120);
  const limited = await fetch(previewURL(server.url, body.pageID, capability));
  assert.equal(limited.status, 429); privateHeaders(limited);
});

test('a revoked preview is rejected after asynchronous rendering before any image bytes leave the API', { skip: skipRedis }, async t => {
  const env = await testEnvironment(); t.after(env.stop);
  for (const action of ['rotate', 'delete', 'render-error'] as const) {
    const body = createBody(), owner = testKey(); await env.pages.create(owner, body);
    const capability = workoutPreviewToken(body.pageID, hash(body.viewKey));
    const handler = createWorkoutPageHandler({ ...env,
      configuration: { uploadsEnabled: true, appAttestConfigured: true, ipSalt: 'a'.repeat(40), production: false, dailyUploadLimit: 1000 },
      renderPreview: async () => {
        if (action === 'render-error') throw new Error('Synthetic renderer failure');
        if (action === 'delete') await env.pages.delete(body.pageID, owner);
        else await env.pages.rotate(body.pageID, owner, { expectedVersion: 1, viewKey: testKey(), viewKeyRecovery: randomBytes(90).toString('base64url') });
        return Buffer.from('image must not leave server');
      },
    });
    const server = await startTestHTTP(handler); t.after(server.stop);
    const response = await fetch(previewURL(server.url, body.pageID, capability));
    assert.equal(response.status, action === 'render-error' ? 503 : 404); privateHeaders(response);
    assert.equal(response.headers.get('content-type'), 'application/json');
    assert.equal((await response.text()).includes('image must not leave server'), false);
  }
});
