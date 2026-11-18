import { gunzipSync } from 'node:zlib';
import type { NextApiRequest, NextApiResponse } from 'next';
import type { ShareRedis } from './share-workout';
import { sendApiError } from './api-response';
import { WorkoutPages, admitUpload, credential, enforceRate, hash } from './workout-pages';
import { WorkoutPageAttestation } from './workout-page-attestation';
import { MAX_COMPRESSED_BYTES, MAX_DECODED_BYTES, MAX_JSON_REQUEST_BYTES, WorkoutPageError } from './workout-page-validation';
import { validateSharedText } from './workout-page-moderation';
import { renderWorkoutPreview } from './workout-page-preview';

export interface WorkoutPageAPIConfiguration {
  uploadsEnabled: boolean;
  appAttestConfigured: boolean;
  ipSalt: string;
  production: boolean;
  dailyUploadLimit: number;
  cleanupSecret?: string;
  blockedTerms?: string[];
}
export interface WorkoutPageAPIDependencies {
  pages: WorkoutPages;
  attestation: WorkoutPageAttestation;
  redis: ShareRedis;
  configuration: WorkoutPageAPIConfiguration;
  renderPreview?: typeof renderWorkoutPreview;
}
function header(req: NextApiRequest, name: string): string | undefined {
  const value = req.headers[name];
  return typeof value === 'string' ? value : undefined;
}
function token(req: NextApiRequest): string {
  const authorization = header(req, 'authorization');
  if (!authorization?.startsWith('Bearer ')) throw new WorkoutPageError(401, 'An access key is required', 'INVALID_ACCESS_KEY');
  return credential(authorization.slice(7));
}
function ipHash(req: NextApiRequest, config: WorkoutPageAPIConfiguration): string {
  // Vercel overwrites its own forwarded header. Locally, only the socket is trusted.
  const address = config.production ? header(req, 'x-vercel-forwarded-for')?.split(',')[0]?.trim() : req.socket.remoteAddress;
  return hash(`${config.ipSalt}|${address || 'unavailable'}`);
}
function requireUploads(config: WorkoutPageAPIConfiguration): void {
  if (!config.uploadsEnabled || !config.appAttestConfigured) throw new WorkoutPageError(503,
    'Private workout uploads are not available yet. You can still share without a link.', 'UPLOADS_UNAVAILABLE');
}
export async function readWorkoutPageBody(req: AsyncIterable<Uint8Array> & { headers: NextApiRequest['headers'] }, small = false): Promise<{ raw: Buffer; value: unknown }> {
  const encoding = req.headers['content-encoding'];
  if (encoding !== undefined && encoding !== 'gzip' && encoding !== 'identity') throw new WorkoutPageError(415, 'Unsupported request encoding', 'UNSUPPORTED_ENCODING');
  if (typeof req.headers['content-type'] !== 'string' || !/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'])) {
    throw new WorkoutPageError(415, 'Send a JSON workout', 'UNSUPPORTED_CONTENT_TYPE');
  }
  const limit = small ? 65536 : encoding === 'gzip' ? MAX_COMPRESSED_BYTES : MAX_JSON_REQUEST_BYTES;
  const length = req.headers['content-length'];
  if (length && (!/^\d+$/.test(String(length)) || Number(length) > limit)) throw new WorkoutPageError(413, 'Workout is too large', 'WORKOUT_TOO_LARGE');
  const chunks: Buffer[] = [];
  let received = 0;
  for await (const chunk of req) {
    received += chunk.length;
    if (received > limit) throw new WorkoutPageError(413, 'Workout is too large', 'WORKOUT_TOO_LARGE');
    chunks.push(Buffer.from(chunk));
  }
  const raw = Buffer.concat(chunks);
  let decoded: Buffer;
  try { decoded = encoding === 'gzip' ? gunzipSync(raw, { maxOutputLength: small ? 65536 : MAX_DECODED_BYTES }) : raw; }
  catch { throw new WorkoutPageError(413, 'Compressed workout is invalid or too large', 'WORKOUT_TOO_LARGE'); }
  try { return { raw, value: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(decoded)) }; }
  catch { throw new WorkoutPageError(400, 'Invalid workout JSON', 'INVALID_JSON'); }
}
function filterText(value: unknown, terms: string[]): void {
  const workout = (value as { workout?: { title?: unknown; description?: unknown } })?.workout;
  validateSharedText(typeof workout?.title === 'string' ? workout.title : '', typeof workout?.description === 'string' ? workout.description : '', terms);
}

/** Dependencies are injected only by code, allowing real HTTP integration tests without a production bypass. */
export function createWorkoutPageHandler(deps: WorkoutPageAPIDependencies) {
  return async (req: NextApiRequest, res: NextApiResponse): Promise<void> => {
    res.setHeader('Cache-Control', 'private, no-store');
    res.setHeader('Vercel-CDN-Cache-Control', 'no-store');
    res.setHeader('CDN-Cache-Control', 'no-store');
    res.setHeader('X-Robots-Tag', 'noindex, nofollow, noarchive, nosnippet');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Vary', 'Authorization');
    const { pages, attestation, redis, configuration: config } = deps;
    try {
      if (config.ipSalt.length < 32) throw new WorkoutPageError(503, 'Private workout pages are temporarily unavailable', 'PAGES_UNAVAILABLE');
      const path = req.query.path === undefined ? [] : Array.isArray(req.query.path) ? req.query.path : [req.query.path];
      const method = req.method || 'GET';
      const ip = ipHash(req, config);
      if (path.length === 1 && path[0] === 'cleanup' && (method === 'POST' || method === 'GET')) {
        if (!config.cleanupSecret || header(req, 'authorization') !== `Bearer ${config.cleanupSecret}`) {
          throw new WorkoutPageError(401, 'Unauthorized', 'UNAUTHORIZED');
        }
        res.status(200).json(await pages.cleanup(100)); return;
      }
      // Limit unauthenticated attempts before Redis/Blob authority lookups; credentials never enter rate keys.
      await enforceRate(redis, `ip:${ip}:minute`, 300, 60);
      if (path.length === 2 && path[1] === 'preview' && method === 'GET') {
        const workout = await pages.readPreview(path[0], req.query.p);
        const png = await (deps.renderPreview || renderWorkoutPreview)(workout);
        await pages.assertPreviewAvailable(path[0], req.query.p);
        res.setHeader('Content-Type', 'image/png');
        res.setHeader('Content-Length', png.length);
        res.status(200).end(png); return;
      }
      const isViewer = path.length === 1 && !['challenge', 'attestation'].includes(path[0]) && method === 'GET';
      if (isViewer) {
        const authorization = header(req, 'authorization');
        const viewKey = authorization?.startsWith('Bearer ') ? authorization.slice(7) : '';
        const workout = await pages.read(path[0], viewKey);
        res.status(200).json(workout); return;
      }
      const owner = token(req);
      await enforceRate(redis, `owner:${hash(owner)}:minute`, 120, 60);
      if (path.length === 0 && method === 'GET') {
        if (req.query.cursor !== undefined && typeof req.query.cursor !== 'string') throw new WorkoutPageError(400, 'Invalid cursor');
        res.status(200).json(await pages.list(owner, req.query.cursor as string | undefined)); return;
      }
      if (path.length === 1 && path[0] === 'challenge' && method === 'POST') {
        requireUploads(config);
        await enforceRate(redis, `challenge-ip:${ip}:hour`, 200, 3600);
        await enforceRate(redis, 'challenge-global:hour', 5000, 3600);
        res.status(200).json(await attestation.challenge(owner, (await readWorkoutPageBody(req, true)).value)); return;
      }
      if (path.length === 1 && path[0] === 'attestation' && method === 'POST') {
        requireUploads(config);
        await enforceRate(redis, `register-ip:${ip}:hour`, 40, 3600);
        res.status(200).json(await attestation.register(owner, (await readWorkoutPageBody(req, true)).value)); return;
      }
      if ((path.length === 0 && method === 'POST') || (path.length === 1 && method === 'PUT')) {
        requireUploads(config);
        const { raw, value } = await readWorkoutPageBody(req);
        const pathname = path.length ? `/api/workout-pages/${path[0]}` : '/api/workout-pages';
        await attestation.authorize(owner, method, pathname, raw, {
          keyID: header(req, 'x-bpm-attest-key-id'), challengeID: header(req, 'x-bpm-attest-challenge-id'), assertion: header(req, 'x-bpm-attest-assertion'),
        });
        await admitUpload(redis, hash(owner), ip, config.dailyUploadLimit);
        filterText(value, config.blockedTerms || []);
        const result = path.length ? await pages.update(path[0], owner, value) : await pages.create(owner, value);
        res.status(200).json(result); return;
      }
      if (path.length === 2 && path[1] === 'activate' && method === 'POST') {
        requireUploads(config);
        res.status(200).json(await pages.activate(path[0], owner, (await readWorkoutPageBody(req, true)).value)); return;
      }
      if (path.length === 2 && path[1] === 'rotate' && method === 'POST') {
        res.status(200).json(await pages.rotate(path[0], owner, (await readWorkoutPageBody(req, true)).value)); return;
      }
      if (path.length === 1 && method === 'DELETE') { res.status(200).json(await pages.delete(path[0], owner)); return; }
      throw new WorkoutPageError(405, 'Method not allowed', 'METHOD_NOT_ALLOWED');
    } catch (error) {
      if (error instanceof WorkoutPageError) {
        if (error.status === 429) res.setHeader('Retry-After', '60');
        sendApiError(res, error.status, error.message, error.code); return;
      }
      // Deliberately omit exception objects: provider errors can contain signed URLs or request bodies.
      console.error('Private workout page request failed');
      sendApiError(res, 503, 'Private workout pages are temporarily unavailable. Please retry.', 'PAGES_UNAVAILABLE');
    }
  };
}
