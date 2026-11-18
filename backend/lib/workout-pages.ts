import { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { gzipSync, gunzipSync } from 'node:zlib';
import type { ShareRedis } from './share-workout';
import type { WorkoutPageExport, WorkoutPageMetadata } from './workout-page-schema';
import { canonicalJSON, exactObject, invalid, MAX_COMPRESSED_BYTES, MAX_DECODED_BYTES,
  validKey, validPageID, validRecovery, validateWorkoutPage, WorkoutPageError } from './workout-page-validation';

export interface WorkoutBlobStore {
  put(path: string, data: Buffer): Promise<void>;
  get(path: string): Promise<Buffer | null>;
  delete(path: string): Promise<void>;
}
interface PageRecord extends WorkoutPageMetadata {
  ownerHash: string;
  viewHash: string;
  blobPath: string;
  contentHash: string;
  creationHash: string;
  compressedBytes: number;
  status: 'active' | 'deleted';
  activatedStageID?: string;
}
interface StageRecord {
  stageID: string;
  expiresAt: number;
  expectedVersion: number;
  page: PageRecord;
}
export const PAGE_PREFIX = 'workout-pages:v1:';
export const hash = (value: string | Buffer): string => createHash('sha256').update(value).digest('hex');
// Derive a separate, page-bound image capability from the existing stored view-key hash.
// It never authorizes the workout JSON and needs no migration or second uploaded object.
export const workoutPreviewToken = (id: string, viewHash: string): string => createHmac('sha256', Buffer.from(viewHash, 'hex'))
  .update(`BPM-Workout-Preview|${id}`).digest('base64url');
// A 128-bit, image-only capability replaces the UUID and preview query in shared URLs.
// Full workout access still requires the independent 256-bit fragment key.
export const workoutLinkCode = (id: string, viewHash: string): string => createHmac('sha256', Buffer.from(viewHash, 'hex'))
  .update(`BPM-Workout-Link|${id}`).digest().subarray(0, 16).toString('base64url');
export const validLinkCode = (value: unknown): value is string => typeof value === 'string'
  && /^[A-Za-z0-9_-]{21}[AQgw]$/.test(value);
const linkKey = (code: string) => `${PAGE_PREFIX}link:${hash(code)}`;
const pageKey = (id: string) => `${PAGE_PREFIX}page:${id}`;
const stageKey = (id: string) => `${PAGE_PREFIX}stage:${id}`;
const ownerKey = (owner: string) => `${PAGE_PREFIX}owner:${owner}`;
const cleanupKey = `${PAGE_PREFIX}cleanup`;
const blockedKey = (owner: string) => `${PAGE_PREFIX}blocked:${owner}`;
const pausedKey = `${PAGE_PREFIX}uploads-paused`;
const lockKey = (id: string) => `${PAGE_PREFIX}lock:${id}`;
const usageKey = (now: number) => `${PAGE_PREFIX}usage:${new Date(now).toISOString().slice(0, 7)}`;
const cancellationKey = (id: string, owner: string) => `${PAGE_PREFIX}cancel:${owner}:${id}`;
// Requests are capped at 60 seconds. This also covers cancellation before a delayed request reserves its page.
const CANCELLATION_SECONDS = 86400;
const STAGE_MILLISECONDS = 24 * 60 * 60 * 1000;

export function credential(value: unknown): string {
  if (!validKey(value)) throw new WorkoutPageError(401, 'A valid access key is required', 'INVALID_ACCESS_KEY');
  return value;
}
export function pageIdentifier(value: unknown): string {
  if (!validPageID(value)) throw new WorkoutPageError(404, 'Workout page not found', 'PAGE_NOT_FOUND');
  return value;
}
export async function redisJSON<T>(redis: ShareRedis, key: string): Promise<T | null> {
  const value = await redis.get(key);
  return typeof value === 'string' ? JSON.parse(value) as T : value as T | null;
}
export async function evalJSON<T>(redis: ShareRedis, script: string, keys: string[], args: unknown[]): Promise<T> {
  const result = await redis.eval(script, keys, args);
  return (typeof result === 'string' ? JSON.parse(result) : result) as T;
}
function metadata(page: PageRecord): WorkoutPageMetadata {
  return { pageID: page.pageID, version: page.version, createdAt: page.createdAt,
    updatedAt: page.updatedAt, viewKeyRecovery: page.viewKeyRecovery };
}
function stagedMetadata(stage: StageRecord): WorkoutPageMetadata {
  return { ...metadata(stage.page), staged: true, stageID: stage.stageID, stageExpiresAt: new Date(stage.expiresAt).toISOString() };
}
function validateStaged(value: unknown): boolean {
  if (value !== undefined && typeof value !== 'boolean') invalid('Invalid staging option');
  return value === true;
}
function notFound(): never { throw new WorkoutPageError(404, 'Workout page not found', 'PAGE_NOT_FOUND'); }
function conflict(message = 'This page changed. Refresh it before trying again.'): never {
  throw new WorkoutPageError(409, message, 'PAGE_CONFLICT');
}
export async function enforceRate(redis: ShareRedis, bucket: string, limit: number, seconds: number): Promise<void> {
  const count = Number(await redis.eval(`local count=redis.call('INCR',KEYS[1]); if count==1 then redis.call('EXPIRE',KEYS[1],ARGV[1]) end; return count`,
    [`${PAGE_PREFIX}rate:${bucket}`], [seconds]));
  if (count > limit) throw new WorkoutPageError(429, 'Please try again later', 'RATE_LIMITED');
}
export async function assertOwnerAllowed(redis: ShareRedis, ownerHash: string): Promise<void> {
  if (await redis.get(blockedKey(ownerHash))) throw new WorkoutPageError(403, 'Uploading is unavailable for this installation', 'OWNER_BLOCKED');
}
export async function admitUpload(redis: ShareRedis, ownerHash: string, ipHash: string, globalLimit: number): Promise<void> {
  await assertOwnerAllowed(redis, ownerHash);
  if (await redis.get(pausedKey)) throw new WorkoutPageError(503, 'New workout uploads are temporarily paused', 'UPLOADS_PAUSED');
  const day = new Date().toISOString().slice(0, 10);
  // Global admission only runs after attestation. Invalid public traffic cannot spend the daily upload quota.
  const allowed = await redis.eval(`
    for i=1,#KEYS do if tonumber(redis.call('GET',KEYS[i]) or '0')>=tonumber(ARGV[i]) then return 0 end end
    for i=1,#KEYS do local count=redis.call('INCR',KEYS[i]); if count==1 then redis.call('EXPIRE',KEYS[i],172800) end end
    return 1`, [`${PAGE_PREFIX}uploads:${day}:owner:${ownerHash}`, `${PAGE_PREFIX}uploads:${day}:ip:${ipHash}`,
    `${PAGE_PREFIX}uploads:${day}:global`], [30, 300, globalLimit]);
  if (Number(allowed) !== 1) throw new WorkoutPageError(429, 'The workout upload limit has been reached. Try again tomorrow.', 'UPLOAD_LIMIT');
}

export class WorkoutPages {
  constructor(private redis: ShareRedis, private blobs: WorkoutBlobStore, private now = () => Date.now()) {}

  private async publishedMetadata(page: PageRecord): Promise<WorkoutPageMetadata> {
    const result = metadata(page);
    const code = workoutLinkCode(page.pageID, page.viewHash);
    // Never overwrite another page's alias, or advertise one before it exists. Legacy
    // URLs remain usable if indexing is unavailable, collides, or races a revocation.
    const registered = await this.redis.eval(`local raw=redis.call('GET',KEYS[1]); if not raw then return 0 end
      local page=cjson.decode(raw); if page.status~='active' or page.viewHash~=ARGV[2] then return 0 end
      local existing=redis.call('GET',KEYS[2]); if existing and existing~=ARGV[1] then return 0 end
      redis.call('SET',KEYS[2],ARGV[1]); return 1`, [pageKey(page.pageID), linkKey(code)], [page.pageID, page.viewHash]).catch(() => 0);
    return Number(registered) === 1 ? { ...result, linkCode: code } : result;
  }

  private async linkedPage(code: string): Promise<PageRecord> {
    if (!validLinkCode(code)) notFound();
    const id = await this.redis.get(linkKey(code));
    if (!validPageID(id)) notFound();
    const page = await redisJSON<PageRecord>(this.redis, pageKey(id));
    if (!page || page.status !== 'active'
      || !timingSafeEqual(Buffer.from(code), Buffer.from(workoutLinkCode(page.pageID, page.viewHash)))) notFound();
    return page;
  }

  private async ownerPage(id: string, owner: string): Promise<PageRecord> {
    const page = await redisJSON<PageRecord>(this.redis, pageKey(pageIdentifier(id)));
    if (!page || page.ownerHash !== hash(credential(owner))) notFound();
    return page;
  }

  async list(owner: string, cursor?: string): Promise<{ pages: WorkoutPageMetadata[]; nextCursor: string | null }> {
    const ownerHash = hash(credential(owner));
    if (cursor !== undefined && !validPageID(cursor)) invalid('Invalid page cursor');
    const ids = await this.redis.eval(`return redis.call('ZRANGEBYLEX',KEYS[1],ARGV[1],'+','LIMIT',0,101)`,
      [ownerKey(ownerHash)], [cursor ? `(${cursor}` : '-']) as string[];
    const pages = await Promise.all(ids.slice(0, 100).map(id => redisJSON<PageRecord>(this.redis, pageKey(id))));
    return { pages: await Promise.all(pages.filter((page): page is PageRecord => !!page && page.status === 'active' && page.ownerHash === ownerHash)
      .map(page => this.publishedMetadata(page))),
      nextCursor: ids.length > 100 ? ids[99] : null };
  }

  async read(id: string, viewKey: string): Promise<WorkoutPageExport> {
    if (validLinkCode(id)) id = (await this.linkedPage(id)).pageID;
    pageIdentifier(id);
    if (!validKey(viewKey)) notFound();
    const page = await redisJSON<PageRecord>(this.redis, pageKey(id));
    if (!page || page.status !== 'active' || page.viewHash !== hash(viewKey)) notFound();
    // A public page ID alone cannot exhaust a legitimate viewer's per-page allowance.
    await enforceRate(this.redis, `page:${hash(id)}:hour`, 1200, 3600);
    return this.readContent(page, false);
  }

  private async previewPage(id: string, capability: unknown): Promise<PageRecord> {
    if (validLinkCode(id)) {
      const page = await this.linkedPage(id);
      id = page.pageID;
      capability = workoutPreviewToken(id, page.viewHash);
    }
    pageIdentifier(id);
    if (!validKey(capability)) notFound();
    const page = await redisJSON<PageRecord>(this.redis, pageKey(id));
    if (!page || page.status !== 'active'
      || !timingSafeEqual(Buffer.from(capability), Buffer.from(workoutPreviewToken(id, page.viewHash)))) notFound();
    return page;
  }

  async readPreview(id: string, capability: unknown): Promise<WorkoutPageExport> {
    const page = await this.previewPage(id, capability);
    // Image rendering has a tighter allowance than the interactive viewer. Only valid capabilities spend it.
    await enforceRate(this.redis, `preview:${hash(page.pageID)}:hour`, 120, 3600);
    return this.readContent(page, true);
  }

  async assertPreviewAvailable(id: string, capability: unknown): Promise<void> {
    // Rendering is asynchronous. A deletion or key rotation during rendering must still win.
    await this.previewPage(id, capability);
  }

  private async readContent(page: PageRecord, preview: boolean): Promise<WorkoutPageExport> {
    const data = await this.blobs.get(page.blobPath);
    if (!data) throw new WorkoutPageError(503, 'This workout is temporarily unavailable', 'PAGE_DATA_UNAVAILABLE');
    if (data.length > MAX_COMPRESSED_BYTES) throw new Error('Stored workout size exceeded');
    const decoded = gunzipSync(data, { maxOutputLength: MAX_DECODED_BYTES });
    const workout = validateWorkoutPage(JSON.parse(decoded.toString('utf8')));
    await this.redis.eval(preview
      ? `redis.call('HINCRBY',KEYS[1],'previews',1); redis.call('HINCRBY',KEYS[1],'previewCompressedBytes',ARGV[1]); return 1`
      : `redis.call('HINCRBY',KEYS[1],'views',1); redis.call('HINCRBY',KEYS[1],'viewCompressedBytes',ARGV[1]); return 1`,
    [usageKey(this.now())], [data.length]).catch(() => undefined);
    // Last awaited operation before returning data: revocation during storage/usage I/O must win.
    const current = await redisJSON<PageRecord>(this.redis, pageKey(page.pageID));
    if (!current || current.status !== 'active' || current.viewHash !== page.viewHash || current.blobPath !== page.blobPath) notFound();
    return workout;
  }

  private encode(workout: unknown): { data: Buffer; contentHash: string } {
    const json = canonicalJSON(validateWorkoutPage(workout));
    if (Buffer.byteLength(json) > MAX_DECODED_BYTES) throw new WorkoutPageError(413, 'Workout is too large', 'WORKOUT_TOO_LARGE');
    const data = gzipSync(json);
    if (data.length > MAX_COMPRESSED_BYTES) throw new WorkoutPageError(413, 'Workout is too large', 'WORKOUT_TOO_LARGE');
    return { data, contentHash: hash(json) };
  }

  async create(owner: string, value: unknown): Promise<WorkoutPageMetadata> {
    const body = exactObject(value, ['pageID', 'viewKey', 'viewKeyRecovery', 'workout', 'staged']);
    const staged = validateStaged(body.staged);
    if (!validPageID(body.pageID) || !validKey(body.viewKey) || !validRecovery(body.viewKeyRecovery)) invalid();
    const ownerHash = hash(credential(owner));
    if (await this.redis.get(cancellationKey(body.pageID, ownerHash))) throw new WorkoutPageError(410, 'This page was deleted', 'PAGE_DELETED');
    const { data, contentHash } = this.encode(body.workout);
    const creationHash = hash(`${contentHash}|${hash(body.viewKey)}|${body.viewKeyRecovery}`);
    const existing = await redisJSON<PageRecord>(this.redis, pageKey(body.pageID));
    if (existing) {
      if (existing.ownerHash !== ownerHash || existing.creationHash !== creationHash) conflict();
      if (existing.status !== 'active') throw new WorkoutPageError(410, 'This page was deleted', 'PAGE_DELETED');
      return this.publishedMetadata(existing);
    }
    const now = new Date(this.now()).toISOString();
    const record: PageRecord = { pageID: body.pageID, ownerHash, viewHash: hash(body.viewKey), viewKeyRecovery: body.viewKeyRecovery,
      contentHash, creationHash, createdAt: now, updatedAt: now, version: 1, blobPath: '', compressedBytes: data.length, status: 'active' };
    return staged ? this.stage(record, data, null) : this.write(record, data, null);
  }

  async update(id: string, owner: string, value: unknown): Promise<WorkoutPageMetadata> {
    const body = exactObject(value, ['expectedVersion', 'workout', 'staged']);
    const staged = validateStaged(body.staged);
    if (!Number.isSafeInteger(body.expectedVersion) || body.expectedVersion < 1) invalid();
    const existing = await this.ownerPage(id, owner);
    if (existing.status !== 'active') throw new WorkoutPageError(410, 'This page was deleted', 'PAGE_DELETED');
    const { data, contentHash } = this.encode(body.workout);
    // A lost update response is recoverable without another object upload.
    if (existing.contentHash === contentHash) return this.publishedMetadata(existing);
    if (existing.version !== body.expectedVersion) conflict();
    const changed = { ...existing, activatedStageID: undefined, contentHash, compressedBytes: data.length,
      version: existing.version + 1, updatedAt: new Date(this.now()).toISOString() };
    return staged ? this.stage(changed, data, existing) : this.write(changed, data, existing);
  }

  private async stage(record: PageRecord, data: Buffer, previous: PageRecord | null): Promise<WorkoutPageMetadata> {
    const lease = randomBytes(24).toString('base64url');
    const acquired = await this.redis.eval(`return redis.call('SET',KEYS[1],ARGV[1],'NX','PX',120000)`, [lockKey(record.pageID)], [lease]);
    if (!acquired) conflict('This page is being saved. Please retry shortly.');
    try {
      const pending = await redisJSON<StageRecord>(this.redis, stageKey(record.pageID));
      if (pending && pending.page.ownerHash !== record.ownerHash) conflict();
      // Response-loss retries recover the same draft. Staging never changes the active record or its owner index.
      if (pending && pending.expiresAt > this.now() && pending.expectedVersion === (previous?.version || 0)
        && pending.page.contentHash === record.contentHash && pending.page.viewHash === record.viewHash
        && pending.page.viewKeyRecovery === record.viewKeyRecovery) return stagedMetadata(pending);
      record.blobPath = `workout-pages/${record.pageID}/${randomUUID()}.json.gz`;
      const stage: StageRecord = { stageID: randomUUID(), expectedVersion: previous?.version || 0,
        expiresAt: this.now() + STAGE_MILLISECONDS, page: record };
      await this.redis.eval(`return redis.call('ZADD',KEYS[1],ARGV[1],ARGV[2])`, [cleanupKey], [this.now() + 15 * 60000, record.blobPath]);
      await this.blobs.put(record.blobPath, data);
      const committed = Number(await this.redis.eval(`
        if redis.call('GET',KEYS[3])~=ARGV[1] then return 0 end
        if redis.call('EXISTS',KEYS[8])==1 then return -3 end
        local raw=redis.call('GET',KEYS[1]); local expected=tonumber(ARGV[3])
        if expected==0 then
          if raw then return 0 end
          if redis.call('ZCARD',KEYS[2])>=10000 then return -1 end
        else
          if not raw then return 0 end
          local current=cjson.decode(raw)
          if current.status~='active' or current.version~=expected or current.ownerHash~=ARGV[4] then return 0 end
        end
        if redis.call('EXISTS',KEYS[5])==1 or redis.call('EXISTS',KEYS[6])==1 then return -2 end
        local old=redis.call('GET',KEYS[9])
        if old then
          local draft=cjson.decode(old)
          if draft.page.ownerHash~=ARGV[4] then return 0 end
          redis.call('ZADD',KEYS[4],ARGV[8],draft.page.blobPath)
        end
        redis.call('SET',KEYS[9],ARGV[2],'PX',ARGV[10]); redis.call('ZADD',KEYS[4],ARGV[7],ARGV[6])
        redis.call('HINCRBY',KEYS[7],'stagedUploads',1); redis.call('HINCRBY',KEYS[7],'uploadedCompressedBytes',ARGV[9])
        return 1`, [pageKey(record.pageID), ownerKey(record.ownerHash), lockKey(record.pageID), cleanupKey,
        blockedKey(record.ownerHash), pausedKey, usageKey(this.now()), cancellationKey(record.pageID, record.ownerHash), stageKey(record.pageID)],
      [lease, JSON.stringify(stage), stage.expectedVersion, record.ownerHash, record.pageID, record.blobPath,
        stage.expiresAt, this.now(), data.length, Math.max(1, stage.expiresAt - this.now())]));
      if (committed === -1) throw new WorkoutPageError(429, 'Your shared page limit has been reached', 'OWNER_PAGE_LIMIT');
      if (committed === -2) throw new WorkoutPageError(503, 'New workout uploads are temporarily unavailable', 'UPLOADS_PAUSED');
      if (committed === -3) throw new WorkoutPageError(410, 'This page was deleted', 'PAGE_DELETED');
      if (committed !== 1) conflict();
      return stagedMetadata(stage);
    } finally {
      await this.redis.eval(`if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('DEL',KEYS[1]) end return 0`, [lockKey(record.pageID)], [lease]);
    }
  }

  async activate(id: string, owner: string, value: unknown): Promise<WorkoutPageMetadata> {
    pageIdentifier(id);
    const body = exactObject(value, ['stageID']);
    if (!validPageID(body.stageID)) invalid('Invalid draft identifier');
    const ownerHash = hash(credential(owner));
    const result = await evalJSON<{ status: number; page?: PageRecord }>(this.redis, `
      if redis.call('EXISTS',KEYS[8])==1 then return cjson.encode({status=-3}) end
      local raw=redis.call('GET',KEYS[1]); local current=nil
      if raw then
        current=cjson.decode(raw)
        if current.ownerHash~=ARGV[1] then return cjson.encode({status=-4}) end
        if current.status~='active' then return cjson.encode({status=-3}) end
        if current.activatedStageID==ARGV[2] then return cjson.encode({status=1,page=current}) end
      end
      if redis.call('EXISTS',KEYS[3])==1 then return cjson.encode({status=0}) end
      local pending=redis.call('GET',KEYS[9])
      if not pending then return cjson.encode({status=-5}) end
      local draft=cjson.decode(pending)
      if draft.page.ownerHash~=ARGV[1] then return cjson.encode({status=-4}) end
      if draft.stageID~=ARGV[2] then return cjson.encode({status=0}) end
      if draft.expiresAt<=tonumber(ARGV[3]) then return cjson.encode({status=-5}) end
      if draft.expectedVersion==0 then
        if current then return cjson.encode({status=0}) end
        if redis.call('ZCARD',KEYS[2])>=10000 then return cjson.encode({status=-1}) end
      elseif not current or current.version~=draft.expectedVersion then return cjson.encode({status=0}) end
      if redis.call('EXISTS',KEYS[5])==1 or redis.call('EXISTS',KEYS[6])==1 then return cjson.encode({status=-2}) end
      local page=draft.page; page.activatedStageID=draft.stageID; page.updatedAt=ARGV[4]
      redis.call('SET',KEYS[1],cjson.encode(page)); redis.call('ZADD',KEYS[2],0,ARGV[5])
      redis.call('DEL',KEYS[9]); redis.call('ZREM',KEYS[4],page.blobPath)
      if current then redis.call('ZADD',KEYS[4],ARGV[3],current.blobPath) end
      redis.call('HINCRBY',KEYS[7],'publishes',1)
      if current then redis.call('HINCRBY',KEYS[7],'pagesUpdated',1) else redis.call('HINCRBY',KEYS[7],'pagesCreated',1) end
      return cjson.encode({status=1,page=page})`,
    [pageKey(id), ownerKey(ownerHash), lockKey(id), cleanupKey, blockedKey(ownerHash), pausedKey, usageKey(this.now()),
      cancellationKey(id, ownerHash), stageKey(id)], [ownerHash, body.stageID, this.now(), new Date(this.now()).toISOString(), id]);
    if (result.status === -1) throw new WorkoutPageError(429, 'Your shared page limit has been reached', 'OWNER_PAGE_LIMIT');
    if (result.status === -2) throw new WorkoutPageError(503, 'New workout uploads are temporarily unavailable', 'UPLOADS_PAUSED');
    if (result.status === -3) throw new WorkoutPageError(410, 'This page was deleted', 'PAGE_DELETED');
    if (result.status === -4) notFound();
    if (result.status === -5) throw new WorkoutPageError(410, 'This draft expired. Prepare it again before sharing.', 'STAGE_EXPIRED');
    if (result.status !== 1 || !result.page) throw new WorkoutPageError(409, 'This draft changed. Prepare it again before sharing.', 'STAGE_CONFLICT');
    return this.publishedMetadata(result.page);
  }

  private async write(record: PageRecord, data: Buffer, previous: PageRecord | null): Promise<WorkoutPageMetadata> {
    const lease = randomBytes(24).toString('base64url');
    const acquired = await this.redis.eval(`return redis.call('SET',KEYS[1],ARGV[1],'NX','PX',120000)`, [lockKey(record.pageID)], [lease]);
    if (!acquired) conflict('This page is being saved. Please retry shortly.');
    const path = `workout-pages/${record.pageID}/${randomUUID()}.json.gz`;
    record.blobPath = path;
    try {
      // Persist the cleanup intent before writing the object. Crashes cannot leave an untracked upload.
      await this.redis.eval(`return redis.call('ZADD',KEYS[1],ARGV[1],ARGV[2])`, [cleanupKey], [this.now() + 15 * 60000, path]);
      await this.blobs.put(path, data);
      const committed = Number(await this.redis.eval(`
        if redis.call('GET',KEYS[3])~=ARGV[1] then return 0 end
        if redis.call('EXISTS',KEYS[8])==1 then return -3 end
        local current=redis.call('GET',KEYS[1]); local expected=tonumber(ARGV[3])
        if expected==0 then
          if current then return 0 end
          if redis.call('ZCARD',KEYS[2])>=10000 then return -1 end
        else
          if not current then return 0 end
          local old=cjson.decode(current)
          if old.status~='active' or old.version~=expected or old.ownerHash~=ARGV[4] then return 0 end
        end
        if redis.call('EXISTS',KEYS[5])==1 or redis.call('EXISTS',KEYS[6])==1 then return -2 end
        local staged=redis.call('GET',KEYS[9])
        if staged then
          local draft=cjson.decode(staged)
          if draft.page.ownerHash~=ARGV[4] then return 0 end
          redis.call('ZADD',KEYS[4],ARGV[8],draft.page.blobPath); redis.call('DEL',KEYS[9])
        end
        redis.call('SET',KEYS[1],ARGV[2]); redis.call('ZADD',KEYS[2],0,ARGV[5]); redis.call('ZREM',KEYS[4],ARGV[6])
        if ARGV[7]~='' then redis.call('ZADD',KEYS[4],ARGV[8],ARGV[7]) end
        redis.call('HINCRBY',KEYS[7],'publishes',1); redis.call('HINCRBY',KEYS[7],'uploadedCompressedBytes',ARGV[9])
        if expected==0 then redis.call('HINCRBY',KEYS[7],'pagesCreated',1) else redis.call('HINCRBY',KEYS[7],'pagesUpdated',1) end
        return 1`, [pageKey(record.pageID), ownerKey(record.ownerHash), lockKey(record.pageID), cleanupKey,
        blockedKey(record.ownerHash), pausedKey, usageKey(this.now()), cancellationKey(record.pageID, record.ownerHash), stageKey(record.pageID)], [lease, JSON.stringify(record), previous?.version || 0, record.ownerHash,
        record.pageID, path, previous?.blobPath || '', this.now(), data.length]));
      if (committed === -1) throw new WorkoutPageError(429, 'Your shared page limit has been reached', 'OWNER_PAGE_LIMIT');
      if (committed === -2) throw new WorkoutPageError(503, 'New workout uploads are temporarily unavailable', 'UPLOADS_PAUSED');
      if (committed === -3) throw new WorkoutPageError(410, 'This page was deleted', 'PAGE_DELETED');
      if (committed !== 1) conflict();
      return this.publishedMetadata(record);
    } finally {
      await this.redis.eval(`if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('DEL',KEYS[1]) end return 0`, [lockKey(record.pageID)], [lease]);
    }
  }

  async rotate(id: string, owner: string, value: unknown): Promise<WorkoutPageMetadata> {
    const body = exactObject(value, ['expectedVersion', 'viewKey', 'viewKeyRecovery']);
    if (!Number.isSafeInteger(body.expectedVersion) || body.expectedVersion < 1 || !validKey(body.viewKey) || !validRecovery(body.viewKeyRecovery)) invalid();
    const page = await this.ownerPage(id, owner);
    if (page.status !== 'active') throw new WorkoutPageError(410, 'This page was deleted', 'PAGE_DELETED');
    if (page.viewHash === hash(body.viewKey) && page.viewKeyRecovery === body.viewKeyRecovery) return this.publishedMetadata(page);
    if (page.version !== body.expectedVersion) conflict();
    const changed = { ...page, activatedStageID: undefined, version: page.version + 1, viewHash: hash(body.viewKey), viewKeyRecovery: body.viewKeyRecovery,
      updatedAt: new Date(this.now()).toISOString() };
    const succeeded = await this.redis.eval(`local raw=redis.call('GET',KEYS[1]); if not raw then return 0 end
      local old=cjson.decode(raw); if old.status~='active' or old.version~=tonumber(ARGV[1]) or old.ownerHash~=ARGV[2] then return 0 end
      local staged=redis.call('GET',KEYS[3])
      if staged then redis.call('ZADD',KEYS[4],ARGV[4],cjson.decode(staged).page.blobPath); redis.call('DEL',KEYS[3]) end
      redis.call('SET',KEYS[1],ARGV[3]); redis.call('HINCRBY',KEYS[2],'linksRotated',1); return 1`,
      [pageKey(id), usageKey(this.now()), stageKey(id), cleanupKey], [page.version, page.ownerHash, JSON.stringify(changed), this.now()]);
    if (Number(succeeded) !== 1) conflict();
    return this.publishedMetadata(changed);
  }

  async delete(id: string, owner: string): Promise<{ success: true }> {
    pageIdentifier(id);
    const ownerHash = hash(credential(owner));
    return this.revoke(id, ownerHash, false);
  }

  /** Operator-only entry point, intentionally absent from the public HTTP router. */
  async moderate(id: string, blockOwner = false): Promise<{ success: true }> {
    const page = await redisJSON<PageRecord>(this.redis, pageKey(pageIdentifier(id)))
      || (await redisJSON<StageRecord>(this.redis, stageKey(id)))?.page;
    if (!page) notFound();
    return this.revoke(id, page.ownerHash, blockOwner);
  }

  private async revoke(id: string, ownerHash: string, blockOwner: boolean): Promise<{ success: true }> {
    const day = new Date(this.now()).toISOString().slice(0, 10);
    const status = Number(await this.redis.eval(`local raw=redis.call('GET',KEYS[1]); local staged=redis.call('GET',KEYS[9])
      local draft=nil; if staged then draft=cjson.decode(staged) end
      if not raw then
        if draft and draft.page.ownerHash==ARGV[1] then
          redis.call('ZADD',KEYS[3],ARGV[4],draft.page.blobPath); redis.call('DEL',KEYS[9])
          if ARGV[5]=='1' then redis.call('SET',KEYS[4],'1') end
        elseif redis.call('EXISTS',KEYS[6])==0 then
          if tonumber(redis.call('GET',KEYS[7]) or '0')>=100 or tonumber(redis.call('GET',KEYS[8]) or '0')>=5000 then return -1 end
          for i=7,8 do local count=redis.call('INCR',KEYS[i]); if count==1 then redis.call('EXPIRE',KEYS[i],172800) end end
        end
        redis.call('SET',KEYS[6],'1','EX',ARGV[6]); return 1
      end
      local page=cjson.decode(raw); if page.ownerHash~=ARGV[1] then return 0 end
      if ARGV[5]=='1' then redis.call('SET',KEYS[4],'1') end
      if draft then redis.call('ZADD',KEYS[3],ARGV[4],draft.page.blobPath); redis.call('DEL',KEYS[9]) end
      if page.status=='deleted' then return 1 end
      page.status='deleted'; page.version=page.version+1; page.viewHash=''; page.viewKeyRecovery=''; page.updatedAt=ARGV[3]
      redis.call('SET',KEYS[1],cjson.encode(page)); redis.call('ZREM',KEYS[2],ARGV[2]);
      redis.call('ZADD',KEYS[3],ARGV[4],page.blobPath); redis.call('HINCRBY',KEYS[5],'pagesDeleted',1); return 1`,
      [pageKey(id), ownerKey(ownerHash), cleanupKey, blockedKey(ownerHash), usageKey(this.now()), cancellationKey(id, ownerHash),
        `${PAGE_PREFIX}cancellations:${day}:owner:${ownerHash}`, `${PAGE_PREFIX}cancellations:${day}:global`, stageKey(id)],
      [ownerHash, id, new Date(this.now()).toISOString(), this.now(), blockOwner ? '1' : '0', CANCELLATION_SECONDS]));
    if (status === -1) throw new WorkoutPageError(429, 'Please retry deleting this pending page later', 'CANCELLATION_LIMIT');
    if (status !== 1) notFound();
    // Access is already revoked. Cleanup failure must not report a failed deletion or restore visibility.
    await this.cleanup(4).catch(() => undefined);
    return { success: true };
  }

  async cleanup(limit = 50): Promise<{ deleted: number; pending: number }> {
    const paths = await this.redis.eval(`return redis.call('ZRANGEBYSCORE',KEYS[1],'-inf',ARGV[1],'LIMIT',0,ARGV[2])`,
      [cleanupKey], [this.now(), Math.min(100, limit)]) as string[];
    let deleted = 0;
    for (const path of paths) {
      const match = /^workout-pages\/([0-9a-f-]{36})\/[0-9a-f-]{36}\.json\.gz$/.exec(path);
      if (!match || !validPageID(match[1])) continue;
      // Claim expired drafts atomically before deleting their objects. Activation either wins first
      // and preserves the object, or observes the removed draft and cannot publish a deleted object.
      const removable = Number(await this.redis.eval(`
        local raw=redis.call('GET',KEYS[1])
        if raw then local page=cjson.decode(raw); if page.status=='active' and page.blobPath==ARGV[1] then
          redis.call('ZREM',KEYS[3],ARGV[1]); return 0 end end
        local staged=redis.call('GET',KEYS[2])
        if staged then local draft=cjson.decode(staged); if draft.page.blobPath==ARGV[1] then
          if draft.expiresAt>tonumber(ARGV[2]) then redis.call('ZADD',KEYS[3],draft.expiresAt,ARGV[1]); return 0 end
          redis.call('DEL',KEYS[2])
        end end
        return 1`, [pageKey(match[1]), stageKey(match[1]), cleanupKey], [path, this.now()]));
      if (removable !== 1) continue;
      try {
        await this.blobs.delete(path);
        await this.redis.eval(`local removed=redis.call('ZREM',KEYS[1],ARGV[1]); if removed==1 then redis.call('HINCRBY',KEYS[2],'objectsDeleted',1) end; return removed`,
          [cleanupKey, usageKey(this.now())], [path]);
        deleted++;
      } catch {
        // Keep deletion retryable across server restarts without retaining content in a queue.
        await this.redis.eval(`return redis.call('ZADD',KEYS[1],ARGV[1],ARGV[2])`, [cleanupKey], [this.now() + 60000, path]);
      }
    }
    return { deleted, pending: Number(await this.redis.eval(`return redis.call('ZCARD',KEYS[1])`, [cleanupKey], [])) };
  }

  async usage(month = new Date(this.now()).toISOString().slice(0, 7)): Promise<Record<string, number>> {
    if (!/^\d{4}-(?:0[1-9]|1[012])$/.test(month)) invalid('Invalid usage month');
    return evalJSON(this.redis, `local entries=redis.call('HGETALL',KEYS[1]); local result={};
      for i=1,#entries,2 do result[entries[i]]=tonumber(entries[i+1]) end; return cjson.encode(result)`,
    [`${PAGE_PREFIX}usage:${month}`], []);
  }
}
