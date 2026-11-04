import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { createClient } from '@vercel/kv';
import { createShareSession, deleteShareSession, publishWorkout, queueWorkoutControl, readSharedSession,
  recordHeartBeat, publishRRStream, ShareRequestError, validateControl, validateSnapshot, validateRRStream, SHARE_LIFETIME_MS } from '../lib/share-workout';
import { redisTestAvailable, startRedisTestServer } from './redis-test-server';

function snapshot(overrides: Record<string, unknown> = {}) {
  return { schemaVersion: 1, sequence: 1, workoutID: '6ced3f02-a9be-4606-bd4c-9949fe1b53f2', controlRevision: 'revision-1',
    screen: 'workout', page: 'table', state: 'running', isCompleted: false, isPresetMode: false, canWork: true, canRest: true,
    totalTime: 15, setTime: 15, totalTimeAdvances: true, setTimeDirection: 1, showTenths: true, isEmpty: false,
    avgWorkTime: null, avgBPM: 135, maxBPM: 150, minBPM: 120, zone: 2, setNumber: '1', calories: '---', primaryBPM: 'avg',
    rows: [], chart: [], segments: [], chartMaxTime: 15, zones: [], ...overrides };
}
function control(code: string, overrides: Record<string, unknown> = {}) {
  return { code, id: randomUUID(), workoutID: snapshot().workoutID, controlRevision: 'revision-1', action: 'work', ...overrides };
}
function preset(overrides: Record<string, unknown> = {}) {
  return { id: 'e5ed6441-4da2-4d65-954c-80be0cce690b', name: 'Trainer intervals', workDuration: 45, restDuration: 15,
    numberOfSets: 4, includeCooldown: true, playSound: false, ...overrides };
}
function rrStream(overrides: Record<string, unknown> = {}) {
  return { schemaVersion: 1, sequence: 1, streamID: 'e5ed6441-4da2-4d65-954c-80be0cce690b', supportsRRIntervals: true,
    sourceTicks: 100, intervals: [{ id: 'da4c9b07-1453-4fd3-9acd-4cc2ab544088', value: 833.984375, receivedTicks: 99 }], ...overrides };
}
function errorStatus(status: number, code?: string) {
  return (error: unknown) => error instanceof ShareRequestError && error.status === status && (!code || error.code === code);
}

test('workout payload validation bounds all arrays, fields, measurements and actions', () => {
  assert.deepEqual(validateSnapshot(snapshot()), snapshot());
  const initialHome = snapshot({ screen: 'home', state: 'idle', canWork: false, canRest: false, totalTime: 0, setTime: 0,
    totalTimeAdvances: false, setTimeDirection: 0, isEmpty: true, avgBPM: null, maxBPM: null, minBPM: null, zone: null,
    setNumber: '---', rows: [{ id: 'empty', label: '1', kind: 'empty', isActive: false, duration: 0, totalTime: 0 }], chartMaxTime: 0 });
  assert.deepEqual(validateSnapshot(initialHome), initialHome);
  for (const patch of [
    { schemaVersion: 2 }, { sequence: -1 }, { sequence: 1.1 }, { sequence: Number.MAX_SAFE_INTEGER + 1 },
    { workoutID: 'bad' }, { controlRevision: '' }, { state: 'ended' }, { screen: 'settings' }, { page: 'unknown' },
    { isCompleted: 'true' }, { setTimeDirection: 2 }, { totalTime: Infinity }, { totalTime: -1 }, { totalTime: 604801 },
    { avgBPM: 0 }, { maxBPM: 401 }, { zone: 6 }, { token: 'must-not-be-shared' }, { setNumber: 'x'.repeat(33) },
    { rows: Array(2049).fill({}) }, { chart: Array(8193).fill({}) }, { segments: Array(2049).fill({}) },
    { zones: Array(6).fill({ zone: 1, duration: 1 }) }, { chart: [{ time: 3, bpm: 130, segment: 1, validUntil: 2 }] },
    { rows: [{ id: '1', label: '1', kind: 'pause', isActive: false, duration: 1, totalTime: 1 }] },
  ]) assert.throws(() => validateSnapshot(snapshot(patch)), errorStatus(400));
  for (const value of [null, [], {}, { snapshot: snapshot() }]) assert.throws(() => validateSnapshot(value), errorStatus(400));
  for (const action of ['save', 'clear', 'delete', 'WORK', null]) {
    assert.throws(() => validateControl(control('123456', { action })), errorStatus(400));
  }
  assert.equal(validateControl(control('123456', { action: 'rest' })).action, 'rest');
  for (const action of ['start', 'pause', 'resume', 'end', 'reset', 'cool', 'clearPreset']) {
    assert.equal(validateControl(control('123456', { action })).action, action);
  }
  assert.deepEqual(validateControl(control('123456', { action: 'loadPreset', preset: preset() })).preset, preset());
  assert.throws(() => validateControl(control('123456', { action: 'loadPreset' })), errorStatus(400));
  assert.throws(() => validateControl(control('123456', { action: 'start', preset: preset() })), errorStatus(400));
  for (const patch of [{ name: '' }, { name: 'x'.repeat(81) }, { name: 'bad\nname' }, { workDuration: 0 },
    { workDuration: 86401 }, { restDuration: -1 }, { numberOfSets: 1001 }, { numberOfSets: 2.1 }, { playSound: 1 },
    { workDuration: 86400, restDuration: 86400, numberOfSets: 1000 }, { token: 'extra-field' }]) {
    assert.throws(() => validateControl(control('123456', { action: 'loadPreset', preset: preset(patch) })), errorStatus(400));
  }
  assert.throws(() => validateSnapshot(snapshot({ allowedActions: ['save'] })), errorStatus(400));
  assert.throws(() => validateSnapshot(snapshot({ allowedActions: ['work', 'work'] })), errorStatus(400));
});

test('raw RR transport preserves original interval values and rejects malformed or discontinuous payloads', () => {
  assert.deepEqual(validateRRStream(rrStream()), rrStream());
  assert.equal((validateRRStream(rrStream({ intervals: [{ id: randomUUID(), value: 0, receivedTicks: 100 }] })).intervals as any[])[0].value, 0);
  assert.deepEqual(validateRRStream(rrStream({ supportsRRIntervals: false, intervals: [] })).intervals, []);
  for (const patch of [{ sequence: -1 }, { sequence: 1.5 }, { schemaVersion: 2 }, { streamID: 'bad' },
    { sourceTicks: Infinity }, { supportsRRIntervals: false }, { intervals: Array(129).fill(rrStream().intervals[0]) },
    { intervals: [rrStream().intervals[0], rrStream().intervals[0]] },
    { intervals: [{ id: randomUUID(), value: 64001, receivedTicks: 99 }] },
    { intervals: [{ id: randomUUID(), value: 800, receivedTicks: 101 }] },
    { intervals: [{ id: randomUUID(), value: 800, receivedTicks: 84.9 }] },
    { intervals: [{ id: randomUUID(), value: 800, receivedTicks: 99 }, { id: randomUUID(), value: 810, receivedTicks: 98 }] }]) {
    assert.throws(() => validateRRStream(rrStream(patch)), errorStatus(400));
  }
});

test('atomic sharing protocol against isolated Redis', {
  skip: redisTestAvailable ? false : 'Install redis-server or set BPM_TEST_REDIS_SERVER to run atomic integration tests',
}, async t => {
  const redis = await startRedisTestServer();
  t.after(() => redis.stop());
  let nextCode = 0;
  async function session() {
    const code = String(++nextCode).padStart(6, '0');
    const token = randomBytes(32).toString('hex');
    assert.equal(await createShareSession(redis, code, token), true);
    return { code, token };
  }
  async function publish(token: string, overrides: Record<string, unknown> = {}, acknowledgements: string[] = []) {
    return publishWorkout(redis, { token, snapshot: snapshot(overrides), acknowledgedCommandIds: acknowledgements });
  }

  await t.test('old heart-rate clients remain compatible and heartbeat cannot clobber workout', async () => {
    const { code, token } = await session();
    const before = await readSharedSession(redis, code);
    assert.equal(before.bpm, null);
    assert.equal(before.workout, null);
    assert.equal(before.workoutTimestamp, null);
    assert.equal('token' in before, false);
    await Promise.all([publish(token), recordHeartBeat(redis, { token, bpm: 135, max: 160, avg: 140, min: 90 })]);
    const result = await readSharedSession(redis, code);
    assert.equal(result.bpm, 135);
    assert.equal(result.max, 160);
    assert.deepEqual(result.workout, snapshot());
    assert.equal(typeof result.workoutTimestamp, 'number');
    assert.ok((result.serverTime as number) >= (result.workoutTimestamp as number));
    assert.equal(JSON.stringify(result).includes(token), false);
    await recordHeartBeat(redis, { token, bpm: null });
    assert.equal((await readSharedSession(redis, code)).bpm, null);
    assert.deepEqual((await readSharedSession(redis, code)).workout, snapshot());
  });

  await t.test('sessions written by the deployed legacy SDK retain data and expiry after upgrade', async () => {
    // Match the deployed routes' kv.setex(..., JSON.stringify(session)) and
    // kv.setex(..., code), including the SDK's numeric-code deserialization.
    // Route the real SDK commands only to this isolated Redis process.
    const legacyKV = createClient({ url: 'https://isolated-redis.invalid', token: 'test-only', enableTelemetry: false });
    legacyKV.use(async request => {
      assert.ok(Array.isArray(request.body));
      return { result: await redis.command(...request.body as (string | number)[]) };
    });
    for (const code of ['012345', '543210']) {
      const token = randomBytes(32).toString('hex');
      const legacySession = { code, token, bpm: 126, max: 155, avg: 130, min: 82, timestamp: Date.now() };
      await legacyKV.setex(`share:${code}`, 120, JSON.stringify(legacySession));
      await legacyKV.setex(`token:${token}`, 120, code);
      assert.equal(await redis.command('GET', `share:${code}`), JSON.stringify(legacySession));
      assert.equal(await legacyKV.get(`token:${token}`), code.startsWith('0') ? code : Number(code));
      const originalTTL = await redis.command('PTTL', `share:${code}`);

      const initial = await readSharedSession(legacyKV, code);
      for (const key of ['bpm', 'max', 'avg', 'min', 'timestamp'] as const) assert.equal(initial[key], legacySession[key]);
      assert.equal(initial.workout, null);
      assert.equal(initial.rrStream, null);
      assert.equal(JSON.stringify(initial).includes(token), false);
      await recordHeartBeat(legacyKV, { token, bpm: 138 });
      await publishWorkout(legacyKV, { token, snapshot: snapshot(), acknowledgedCommandIds: [] });
      await publishRRStream(legacyKV, { token, snapshot: rrStream() });
      const updated = await readSharedSession(legacyKV, code);
      assert.equal(updated.bpm, 138);
      assert.equal(updated.max, 155);
      assert.equal(updated.avg, 130);
      assert.equal(updated.min, 82);
      assert.deepEqual(updated.workout, snapshot());
      assert.deepEqual(updated.rrStream, rrStream());
      for (const key of [`share:${code}`, `token:${token}`, `workout:${code}`, `rr:${code}`]) {
        const remaining = await redis.command('PTTL', key);
        assert.ok(remaining > originalTTL - 5000 && remaining <= originalTTL, 'Upgrade must preserve original session expiry');
      }
      await deleteShareSession(legacyKV, token);
      await assert.rejects(readSharedSession(legacyKV, code), errorStatus(404));
      assert.equal(await redis.command('EXISTS', `share:${code}`, `token:${token}`, `workout:${code}`, `rr:${code}`), 0);
    }
  });

  await t.test('host token must map to and own the current session', async () => {
    const { code, token } = await session();
    const impostor = randomBytes(32).toString('hex');
    await assert.rejects(publish(impostor), errorStatus(401));
    await redis.command('PSETEX', `token:${impostor}`, 10000, code);
    await assert.rejects(publish(impostor), errorStatus(401));
    await assert.rejects(recordHeartBeat(redis, { token: impostor, bpm: 130 }), errorStatus(401));
    await deleteShareSession(redis, impostor);
    assert.equal((await readSharedSession(redis, code)).workout, null);
    await publish(token);
    assert.equal(await createShareSession(redis, code, randomBytes(32).toString('hex')), false);
    await assert.rejects(publishWorkout(redis, { token, snapshot: snapshot(), acknowledgedCommandIds: ['bad'] }), errorStatus(400));
  });

  await t.test('trainer lifecycle controls require owner capability and matching timer state', async () => {
    const cases: [string, Record<string, unknown>][] = [
      ['startIncludingHistory', { state: 'idle', isEmpty: true, recoverableHistorySeconds: 85 }],
      ['start', { state: 'idle', isEmpty: true }], ['pause', { state: 'running' }],
      ['resume', { state: 'paused' }], ['end', { state: 'running' }],
      ['reset', { state: 'idle', isCompleted: true }], ['cool', { state: 'running' }],
      ['loadPreset', { state: 'idle', isEmpty: true }], ['clearPreset', { state: 'idle', isPresetMode: true, isEmpty: true }],
    ];
    for (const [action, state] of cases) {
      const { code, token } = await session();
      await publish(token, { ...state, allowedActions: [action] });
      const command = control(code, { action, ...(action === 'loadPreset' ? { preset: preset() } : {}) });
      assert.equal((await queueWorkoutControl(redis, command)).queued, true, action);
      const incoming = (await publish(token, { ...state, sequence: 2, allowedActions: [action] })).commands as any[];
      assert.equal(incoming[0].action, action);
      if (action === 'loadPreset') assert.deepEqual(incoming[0].preset, preset());
    }
    const { code, token } = await session();
    await publish(token); // Legacy broadcaster exposes manual sets only.
    await assert.rejects(queueWorkoutControl(redis, control(code, { action: 'pause' })), errorStatus(409, 'CONTROL_DISABLED'));
    await publish(token, { sequence: 2, state: 'paused', allowedActions: ['start'] });
    await assert.rejects(queueWorkoutControl(redis, control(code, { action: 'start' })), errorStatus(409, 'CONTROL_DISABLED'));
    await assert.rejects(queueWorkoutControl(redis, control(code, { action: 'save' })), errorStatus(400));
  });

  await t.test('preset commands retain exact settings and idempotency binds the full payload', async () => {
    const { code, token } = await session();
    await publish(token, { state: 'idle', isEmpty: true, allowedActions: ['start', 'loadPreset'] });
    const command = control(code, { action: 'loadPreset', preset: preset() });
    assert.equal((await queueWorkoutControl(redis, command)).queued, true);
    const reorderedPreset = Object.fromEntries(Object.entries(preset()).reverse());
    assert.equal((await queueWorkoutControl(redis, { ...command, preset: reorderedPreset })).replayed, true);
    await assert.rejects(queueWorkoutControl(redis, { ...command, preset: preset({ workDuration: 60 }) }), errorStatus(409, 'COMMAND_ID_REUSED'));
    const loaded = { sequence: 2, controlRevision: 'loaded', state: 'idle', isEmpty: true, isPresetMode: true,
      activePreset: preset(), allowedActions: ['start', 'loadPreset', 'clearPreset'] };
    await publish(token, loaded, [command.id]);
    assert.deepEqual(((await readSharedSession(redis, code)).workout as any).activePreset, preset());
    assert.equal((await queueWorkoutControl(redis, command)).replayed, true);
    assert.equal(await redis.command('HLEN', `workout-queue:${code}`), 0);
  });

  await t.test('raw RR stream is independent, ordered, owner-only and keeps original measurement values', async () => {
    const { code, token } = await session();
    const initial = await readSharedSession(redis, code);
    assert.equal(initial.rrStream, null);
    const intervals = [0, 833.984375, 64000].map((value, index) => ({ id: randomUUID(), value, receivedTicks: 98 + index }));
    const stream = rrStream({ intervals });
    await Promise.all([publish(token), publishRRStream(redis, { token, snapshot: stream })]);
    const result = await readSharedSession(redis, code);
    assert.deepEqual(result.rrStream, stream);
    assert.equal(result.timestamp, initial.timestamp, 'RR traffic does not refresh BPM');
    assert.equal(result.bpm, null);
    assert.equal(typeof result.rrTimestamp, 'number');
    assert.ok((result.serverTime as number) >= (result.rrTimestamp as number));
    await assert.rejects(publishRRStream(redis, { token, snapshot: stream }), errorStatus(409, 'STALE_RR_STREAM'));
    const changedStream = rrStream({ sequence: 2, streamID: randomUUID(), supportsRRIntervals: false, intervals: [] });
    await publishRRStream(redis, { token, snapshot: changedStream });
    assert.deepEqual((await readSharedSession(redis, code)).rrStream, changedStream);
    const impostor = randomBytes(32).toString('hex');
    await redis.command('PSETEX', `token:${impostor}`, 10000, code);
    await assert.rejects(publishRRStream(redis, { token: impostor, snapshot: rrStream({ sequence: 3 }) }), errorStatus(401));
    assert.equal(JSON.stringify(await readSharedSession(redis, code)).includes(token), false);
  });

  await t.test('numeric KV auto-deserialization supports host updates and deletion', async () => {
    const code = '654321';
    const token = randomBytes(32).toString('hex');
    await createShareSession(redis, code, token);
    const decodedRedis = { eval: redis.eval, get: async (key: string) => {
      const value = await redis.get(key);
      return value === code ? Number(value) : value;
    } };
    await publishWorkout(decodedRedis, { token, snapshot: snapshot(), acknowledgedCommandIds: [] });
    await recordHeartBeat(decodedRedis, { token, bpm: 132 });
    assert.equal((await readSharedSession(redis, code)).bpm, 132);
    await deleteShareSession(decodedRedis, token);
    await assert.rejects(readSharedSession(redis, code), errorStatus(404));
  });

  await t.test('reordered snapshots cannot replace state or acknowledge pending commands', async () => {
    const { code, token } = await session();
    await publish(token, { sequence: 2 });
    const command = control(code);
    await queueWorkoutControl(redis, command);
    await assert.rejects(publish(token, { sequence: 1 }, [command.id]), errorStatus(409, 'STALE_SNAPSHOT'));
    await assert.rejects(publish(token, { sequence: 2 }), errorStatus(409, 'STALE_SNAPSHOT'));
    const received = await publish(token, { sequence: 3 });
    assert.equal((received.commands as any[]).length, 1);
    assert.equal((received.commands as any[])[0].id, command.id);
    assert.deepEqual((await publish(token, { sequence: 4 }, [command.id])).commands, []);
    assert.equal((await readSharedSession(redis, code)).workout && ((await readSharedSession(redis, code)).workout as any).sequence, 4);
  });

  await t.test('duplicate command retry is idempotent before and after acknowledgement', async () => {
    const { code, token } = await session();
    await publish(token);
    const command = control(code);
    const responses = await Promise.all(Array.from({ length: 10 }, () => queueWorkoutControl(redis, command)));
    assert.equal(responses.filter(response => response.replayed === false).length, 1);
    assert.equal(await redis.command('HLEN', `workout-queue:${code}`), 1);
    const incoming = (await publish(token, { sequence: 2 })).commands as any[];
    assert.equal(incoming[0].action, 'work');
    assert.equal(incoming[0].workoutID, command.workoutID);
    assert.equal(typeof incoming[0].createdAt, 'number');
    await publish(token, { sequence: 3, controlRevision: 'revision-2' }, [command.id]);
    assert.equal((await queueWorkoutControl(redis, command)).replayed, true);
    assert.equal(await redis.command('HLEN', `workout-queue:${code}`), 0);
    await assert.rejects(queueWorkoutControl(redis, { ...command, action: 'rest' }), errorStatus(409, 'COMMAND_ID_REUSED'));
  });

  await t.test('concurrent viewers can claim only one set change per control revision', async () => {
    const { code, token } = await session();
    await publish(token);
    const outcomes = await Promise.allSettled(Array.from({ length: 16 }, (_, i) => queueWorkoutControl(redis, control(code, { action: i % 2 ? 'work' : 'rest' }))));
    assert.equal(outcomes.filter(result => result.status === 'fulfilled').length, 1);
    for (const outcome of outcomes) if (outcome.status === 'rejected') assert.equal(outcome.reason.status, 409);
    assert.equal(await redis.command('HLEN', `workout-queue:${code}`), 1);
  });

  await t.test('controls reject stale, completed, preset, paused or disabled states but allow owner Home', async () => {
    const disabled = [{ state: 'paused' }, { state: 'idle' }, { state: 'cooldown' }, { state: 'cooldownPaused' },
      { isCompleted: true }, { isPresetMode: true }, { canWork: false }];
    for (const patch of disabled) {
      const { code, token } = await session();
      await publish(token, patch);
      await assert.rejects(queueWorkoutControl(redis, control(code)), errorStatus(409, 'CONTROL_DISABLED'));
    }
    const { code, token } = await session();
    await publish(token, { screen: 'home' });
    assert.equal((await queueWorkoutControl(redis, control(code))).queued, true);
    await publish(token, { sequence: 2, controlRevision: 'revision-2', canRest: false });
    await assert.rejects(queueWorkoutControl(redis, control(code, { action: 'rest', controlRevision: 'revision-2' })), errorStatus(409, 'CONTROL_DISABLED'));
    await assert.rejects(queueWorkoutControl(redis, control(code)), errorStatus(409, 'STALE_CONTROL'));
    await assert.rejects(queueWorkoutControl(redis, control(code, { workoutID: randomUUID() })), errorStatus(409, 'STALE_CONTROL'));
    const raw = JSON.parse(await redis.command('GET', `workout:${code}`));
    raw.timestamp -= 5000;
    await redis.command('SET', `workout:${code}`, JSON.stringify(raw), 'KEEPTTL');
    await assert.rejects(queueWorkoutControl(redis, control(code, { controlRevision: 'revision-2' })), errorStatus(409, 'STALE_WORKOUT'));
  });

  await t.test('rejected command identifiers keep their original rejection after state changes', async () => {
    const { code, token } = await session();
    await publish(token, { state: 'paused' });
    const command = control(code);
    await assert.rejects(queueWorkoutControl(redis, command), errorStatus(409, 'CONTROL_DISABLED'));
    await publish(token, { sequence: 2, state: 'running' });
    await assert.rejects(queueWorkoutControl(redis, command), errorStatus(409, 'CONTROL_DISABLED'));
    assert.equal(await redis.command('HLEN', `workout-queue:${code}`), 0);
  });

  await t.test('expired controls remain available for rejection and acknowledgement without blocking retries', async () => {
    const { code, token } = await session();
    await publish(token);
    const command = control(code);
    await queueWorkoutControl(redis, command);
    const first = (await publish(token, { sequence: 2 })).commands;
    assert.deepEqual((await publish(token, { sequence: 3 })).commands, first);
    const expired = JSON.parse(await redis.command('HGET', `workout-queue:${code}`, command.id));
    expired.createdAt -= 5000;
    await redis.command('HSET', `workout-queue:${code}`, command.id, JSON.stringify(expired));
    const expiredDelivery = (await publish(token, { sequence: 4 })).commands as any[];
    assert.equal(expiredDelivery.length, 1);
    assert.equal(expiredDelivery[0].createdAt, expired.createdAt);
    assert.equal(await redis.command('HLEN', `workout-claims:${code}`), 1);
    // Owner rejects the stale command and acknowledges it with a fresh snapshot.
    assert.deepEqual((await publish(token, { sequence: 5 }, [command.id])).commands, []);
    assert.equal(await redis.command('HLEN', `workout-claims:${code}`), 0);
    assert.equal((await queueWorkoutControl(redis, command)).replayed, true);
    assert.equal(await redis.command('HLEN', `workout-queue:${code}`), 0);
    const retry = control(code);
    assert.equal((await queueWorkoutControl(redis, retry)).queued, true);
    await publish(token, { sequence: 6 }, [retry.id]);
    for (let i = 0; i < 32; i++) {
      const controlRevision = `revision-${i + 2}`;
      await publish(token, { sequence: i + 7, controlRevision });
      await queueWorkoutControl(redis, control(code, { controlRevision }));
    }
    await publish(token, { sequence: 39, controlRevision: 'revision-full' });
    await assert.rejects(queueWorkoutControl(redis, control(code, { controlRevision: 'revision-full' })), errorStatus(409, 'QUEUE_FULL'));
    assert.equal(await redis.command('HLEN', `workout-queue:${code}`), 32);
  });

  await t.test('all mutations preserve original session expiry and never resurrect ended sessions', async () => {
    const { code, token } = await session();
    const originalExpiry = await redis.command('PEXPIRETIME', `share:${code}`);
    const ttl = await redis.command('PTTL', `share:${code}`);
    assert.ok(ttl > SHARE_LIFETIME_MS - 1000 && ttl <= SHARE_LIFETIME_MS);
    await publish(token);
    await queueWorkoutControl(redis, control(code));
    await recordHeartBeat(redis, { token, bpm: 120 });
    await publishRRStream(redis, { token, snapshot: rrStream() });
    await publish(token, { sequence: 2 });
    assert.equal(await redis.command('PEXPIRETIME', `share:${code}`), originalExpiry);
    for (const prefix of ['workout', 'workout-queue', 'workout-receipts', 'workout-claims', 'rr']) {
      assert.ok(await redis.command('PEXPIRETIME', `${prefix}:${code}`) <= originalExpiry);
    }
    // Simulate expiry/deletion between the outer token lookup and atomic write.
    const racingRedis = { get: redis.get, eval: async (script: string, keys: string[], args: unknown[]) => {
      await redis.command('DEL', `share:${code}`);
      return redis.eval(script, keys, args);
    } };
    await assert.rejects(recordHeartBeat(racingRedis, { token, bpm: 130 }), errorStatus(404));
    await assert.rejects(publish(token, { sequence: 3 }), errorStatus(404));
    await assert.rejects(publishRRStream(redis, { token, snapshot: rrStream({ sequence: 2 }) }), errorStatus(404));
    await assert.rejects(queueWorkoutControl(redis, control(code)), errorStatus(404));
    assert.equal(await redis.command('EXISTS', `share:${code}`), 0);
    const replacement = randomBytes(32).toString('hex');
    assert.equal(await createShareSession(redis, code, replacement), true);
    await assert.rejects(publish(token, { sequence: 4 }), errorStatus(401));
    assert.equal((await readSharedSession(redis, code)).workout, null);
    assert.equal((await readSharedSession(redis, code)).rrStream, null);
    await deleteShareSession(redis, replacement);
    await assert.rejects(readSharedSession(redis, code), errorStatus(404));
    for (const prefix of ['share', 'workout', 'workout-queue', 'workout-receipts', 'workout-claims', 'rr']) assert.equal(await redis.command('EXISTS', `${prefix}:${code}`), 0);
  });
});
