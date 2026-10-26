import test from 'node:test';
import assert from 'node:assert/strict';
import { decodeRecording, generateRecap, parseRecap, RecapError } from '../lib/workout-recap';
import { admitRecap } from '../lib/workout-recap-limits';
import handler from '../pages/api/workout-recap';

function wav(seconds = 1, amplitude = 2000): Buffer {
  const size = seconds * 32000;
  const data = Buffer.alloc(44 + size);
  data.write('RIFF'); data.writeUInt32LE(36 + size, 4); data.write('WAVEfmt ', 8);
  data.writeUInt32LE(16, 16); data.writeUInt16LE(1, 20); data.writeUInt16LE(1, 22);
  data.writeUInt32LE(16000, 24); data.writeUInt32LE(32000, 28);
  data.writeUInt16LE(2, 32); data.writeUInt16LE(16, 34);
  data.write('data', 36); data.writeUInt32LE(size, 40);
  for (let i = 44; i < data.length; i += 2) data.writeInt16LE(amplitude, i);
  return data;
}
const body = (data: Buffer) => ({ audio: data.toString('base64') });

test('validates actual audio format, duration, silence and size', () => {
  assert.deepEqual(decodeRecording(body(wav(60))), wav(60));
  for (const data of [wav(60.001), wav(61), wav(0.1), wav(1, 0), Buffer.from('bad audio'), wav().subarray(0, 400)]) {
    assert.throws(() => decodeRecording(body(data)), RecapError);
  }
  const stereo = wav(); stereo.writeUInt16LE(2, 22);
  assert.throws(() => decodeRecording(body(stereo)), RecapError);
  for (const invalid of [null, {}, { audio: 'a'.repeat(2800000) }, { audio: '%%%=' }]) {
    assert.throws(() => decodeRecording(invalid), RecapError);
  }
});

test('rejects empty, oversized and invalid generated fields', () => {
  const entries = [{ exercise: 'Run', details: '10 minutes' }];
  for (const result of [null, {}, { title: '', entries }, { title: 'a'.repeat(81), entries },
    { title: 'Run', entries: [] }, { title: 'Run', entries: [null] },
    { title: 'Run', entries: [{ exercise: '', details: '10 minutes' }] },
    { title: 'Run', entries: [{ exercise: 'Run', details: '' }] },
    { title: 'Run', entries: [{ exercise: 'Run', details: 'x'.repeat(6000) }] }]) {
    assert.throws(() => parseRecap(result), RecapError);
  }
});

test('renders one bullet per exercise with all details and no embedded paragraphs', () => {
  assert.deepEqual(parseRecap({
    title: 'Snatches, Deadlifts, and Abs',
    entries: [
      { exercise: 'Snatches', details: '204 reps @ 24 kg in 10 min.' },
      { exercise: 'Deadlifts', details: '3 sets @ 225 (unit unspecified).\nLast set felt heavy.' },
      { exercise: 'Abs', details: 'Standard ab circuit.' },
    ],
  }), {
    title: 'Snatches, Deadlifts, and Abs',
    description: '- Snatches: 204 reps @ 24 kg in 10 min.\n- Deadlifts: 3 sets @ 225 (unit unspecified). Last set felt heavy.\n- Abs: Standard ab circuit.',
  });
});

test('transcribes once then returns structured text with no stored response', async () => {
  const transcript = 'Maybe 3 sets of 8 squats at 62.5 kg. Left knee felt odd.';
  const draft = { title: 'Squat strength session', entries: [{ exercise: 'Squats', details: transcript }] };
  const requests: { url: string; init: RequestInit }[] = [];
  const fetcher = (async (url: any, init: any) => {
    requests.push({ url, init });
    if (requests.length === 1) {
      assert.equal(init.body.get('model'), 'gpt-transcribe');
      assert.equal(init.body.get('file').type, 'audio/wav');
      return Response.json({ text: transcript });
    }
    const payload = JSON.parse(init.body);
    assert.equal(payload.model, 'gpt-5.4');
    assert.equal(payload.reasoning.effort, 'medium');
    assert.deepEqual(payload.text.format.schema.required, ['title', 'entries']);
    assert.equal(payload.store, false);
    assert.equal(payload.text.format.strict, true);
    assert.equal(payload.input[0].content, transcript);
    assert.match(payload.instructions, /Preserve every exercise/);
    return Response.json({ status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text: JSON.stringify(draft) }] }] });
  }) as typeof fetch;
  assert.deepEqual(await generateRecap(wav(), 'test-key', fetcher), { title: draft.title, description: `- Squats: ${transcript}` });
  assert.equal(requests.length, 2);
  assert.equal(requests[0].url, 'https://api.openai.com/v1/audio/transcriptions');
});

test('empty transcription never produces an invented workout', async () => {
  let count = 0;
  await assert.rejects(generateRecap(wav(), 'test-key', (async () => { count++; return Response.json({ text: '' }); }) as typeof fetch), /No speech/);
  assert.equal(count, 1);
});

test('provider errors stay private and malformed/refused outputs fail', async () => {
  await assert.rejects(generateRecap(wav(), 'test-key', (async () => new Response('secret provider details', { status: 401 })) as typeof fetch), /unavailable/);
  for (const response of [
    { status: 'incomplete', output: [] },
    { status: 'completed', output: [{ type: 'message', content: [{ type: 'refusal', refusal: 'No' }] }] },
    { status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text: 'bad json' }] }] },
  ]) {
    let count = 0;
    await assert.rejects(generateRecap(wav(), 'test-key', (async () => Response.json(++count === 1 ? { text: 'Squats' } : response)) as typeof fetch), RecapError);
  }
});

test('rate limits fail closed without production KV and bound local usage', async () => {
  const env = { ...process.env };
  delete process.env.KV_REST_API_URL; delete process.env.KV_REST_API_TOKEN; delete process.env.VERCEL;
  try {
    Object.assign(process.env, { NODE_ENV: 'production' });
    await assert.rejects(admitRecap('test-ip', 'test-key'), /temporarily unavailable/);
    Object.assign(process.env, { NODE_ENV: 'development' });
    for (let i = 0; i < 20; i++) await admitRecap('test-ip', 'test-key');
    await assert.rejects(admitRecap('test-ip', 'test-key'), /daily limit/);
  } finally {
    for (const k of Object.keys(process.env)) if (!(k in env)) delete process.env[k];
    Object.assign(process.env, env);
  }
});

test('HTTP handler returns consistent method, configuration and invalid audio errors', async () => {
  const original = process.env.OPENAI_API_KEY;
  const response = () => ({ statusCode: 0, body: {} as any, headers: {} as Record<string, any>,
    setHeader(k: string, v: any) { this.headers[k] = v; },
    status(n: number) { this.statusCode = n; return this; }, json(body: any) { this.body = body; return this; } });
  try {
    delete process.env.OPENAI_API_KEY;
    let res = response(); await handler({ method: 'GET' } as any, res as any);
    assert.equal(res.statusCode, 405); assert.equal(res.headers.Allow, 'POST');
    res = response(); await handler({ method: 'POST' } as any, res as any);
    assert.equal(res.statusCode, 503); assert.equal(res.body.code, 'AI_NOT_CONFIGURED');
    process.env.OPENAI_API_KEY = 'test-key';
    res = response(); await handler({ method: 'POST', headers: { 'content-type': 'application/json' }, body: {} } as any, res as any);
    assert.equal(res.statusCode, 400); assert.equal(res.body.code, 'INVALID_AUDIO');
    assert.equal(res.headers['Cache-Control'], 'no-store');
  } finally { if (original === undefined) delete process.env.OPENAI_API_KEY; else process.env.OPENAI_API_KEY = original; }
});
