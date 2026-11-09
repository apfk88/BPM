export const SHARE_LIFETIME_MS = 90 * 60 * 1000;
export const CONTROL_LIFETIME_MS = 5000;
const MAX_SNAPSHOT_BYTES = 1024 * 1024;
const MAX_TIME = 7 * 24 * 60 * 60;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const WORKOUT_ACTIONS = ['work', 'rest', 'start', 'startIncludingHistory', 'pause', 'resume', 'end', 'reset', 'cool', 'loadPreset', 'clearPreset'];
const HRV_ACTIONS = ['hrvStart', 'hrvCancel', 'hrvReset'];
const CONTROL_ACTIONS = [...WORKOUT_ACTIONS, ...HRV_ACTIONS];

export interface ShareRedis {
  get(key: string): Promise<unknown>;
  eval(script: string, keys: string[], args: unknown[]): Promise<unknown>;
}

export class ShareRequestError extends Error {
  constructor(public status: number, message: string, public code: string) {
    super(message);
  }
}

type ObjectValue = Record<string, unknown>;
type ScriptResult = Record<string, any> & { status: number };

function invalid(message = 'Invalid sharing request'): never {
  throw new ShareRequestError(400, message, 'INVALID_SHARE_REQUEST');
}

function object(value: unknown): ObjectValue {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid();
  return value as ObjectValue;
}

function number(value: unknown, max: number, min = 0, integer = false): boolean {
  return typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max && (!integer || Number.isSafeInteger(value));
}

function text(value: unknown, max: number, min = 1): value is string {
  return typeof value === 'string' && value.length >= min && value.length <= max && !/[\u0000-\u001f]/.test(value);
}

function optionalNumber(value: unknown, max: number, min = 0, integer = false): boolean {
  return value === undefined || value === null || number(value, max, min, integer);
}

function member(value: unknown, values: readonly unknown[]): boolean { return values.includes(value); }
function bpm(value: unknown): boolean { return optionalNumber(value, 400, 1, true); }
function exactKeys(value: ObjectValue, keys: string[]): void {
  if (Object.keys(value).some(key => !keys.includes(key))) invalid('Unknown workout field');
}
function array(value: unknown, max: number, validate: (item: unknown) => void): void {
  if (!Array.isArray(value) || value.length > max) invalid('Workout contains too many entries');
  value.forEach(validate);
}

export function validatePreset(value: unknown): ObjectValue {
  const preset = object(value);
  exactKeys(preset, ['id', 'name', 'workDuration', 'restDuration', 'numberOfSets', 'includeCooldown', 'playSound']);
  if (typeof preset.id !== 'string' || !UUID.test(preset.id) || !text(preset.name, 80) || !preset.name.trim()
      || !number(preset.workDuration, 86400, Number.MIN_VALUE) || !number(preset.restDuration, 86400)
      || !number(preset.numberOfSets, 1000, 1, true) || typeof preset.includeCooldown !== 'boolean'
      || typeof preset.playSound !== 'boolean') invalid('Invalid workout preset');
  const total = (preset.workDuration as number) * (preset.numberOfSets as number)
    + (preset.restDuration as number) * ((preset.numberOfSets as number) - 1) + (preset.includeCooldown ? 120 : 0);
  if (!number(total, MAX_TIME)) invalid('Workout preset is too long');
  return preset;
}

function validateHRV(value: unknown): void {
  const hrv = object(value);
  exactKeys(hrv, ['revision', 'isPresented', 'state', 'remainingTime', 'hrvValue', 'avgHeartRate', 'minHeartRate',
    'maxHeartRate', 'currentBPM', 'readinessReason', 'errorMessage', 'allowsRemoteControl']);
  if (typeof hrv.revision !== 'string' || !UUID.test(hrv.revision)
      || typeof hrv.isPresented !== 'boolean' || typeof hrv.allowsRemoteControl !== 'boolean'
      || !member(hrv.state, ['idle', 'measuring', 'completed', 'error'])
      || !number(hrv.remainingTime, 120) || !optionalNumber(hrv.hrvValue, 5000)
      || !bpm(hrv.avgHeartRate) || !bpm(hrv.minHeartRate) || !bpm(hrv.maxHeartRate) || !bpm(hrv.currentBPM)
      || !member(hrv.readinessReason, ['ready', 'monitor_disconnected', 'sensor_contact_lost', 'waiting_for_heart_rate',
        'waiting_for_rr', 'stale_rr', 'shared_data_unavailable'])
      || (hrv.errorMessage !== undefined && hrv.errorMessage !== null && !text(hrv.errorMessage, 512, 0))) {
    invalid('Invalid shared HRV state');
  }
}

export function validateSnapshot(value: unknown): ObjectValue {
  const snapshot = object(value);
  if (Buffer.byteLength(JSON.stringify(snapshot)) > MAX_SNAPSHOT_BYTES) invalid('Workout snapshot is too large');
  exactKeys(snapshot, ['schemaVersion', 'sequence', 'workoutID', 'controlRevision', 'screen', 'page', 'state', 'isCompleted',
    'isPresetMode', 'canWork', 'canRest', 'totalTime', 'setTime', 'totalTimeAdvances', 'setTimeDirection', 'showTenths', 'isEmpty',
    'avgWorkTime', 'avgBPM', 'maxBPM', 'minBPM', 'zone', 'setNumber', 'calories', 'primaryBPM', 'rows', 'chart', 'segments', 'chartMaxTime', 'zones',
    'allowedActions', 'activePreset', 'recoverableHistorySeconds', 'hrv']);
  if (snapshot.schemaVersion !== 1 || !number(snapshot.sequence, Number.MAX_SAFE_INTEGER, 0, true)
      || typeof snapshot.workoutID !== 'string' || !UUID.test(snapshot.workoutID)
      || !text(snapshot.controlRevision, 128)
      || !member(snapshot.screen, ['home', 'workout']) || !member(snapshot.page, ['table', 'bpm', 'stats', 'chart'])
      || !member(snapshot.state, ['idle', 'running', 'paused', 'cooldown', 'cooldownPaused'])
      || !member(snapshot.setTimeDirection, [-1, 0, 1]) || !member(snapshot.primaryBPM, ['avg', 'max'])
      || !text(snapshot.setNumber, 32, 0) || !text(snapshot.calories, 32, 0)) invalid('Invalid workout state');
  for (const key of ['isCompleted', 'isPresetMode', 'canWork', 'canRest', 'totalTimeAdvances', 'showTenths', 'isEmpty']) {
    if (typeof snapshot[key] !== 'boolean') invalid('Invalid workout flag');
  }
  for (const key of ['totalTime', 'setTime', 'chartMaxTime']) if (!number(snapshot[key], MAX_TIME)) invalid('Invalid workout time');
  if (!optionalNumber(snapshot.avgWorkTime, MAX_TIME) || !bpm(snapshot.avgBPM) || !bpm(snapshot.maxBPM) || !bpm(snapshot.minBPM)
      || !optionalNumber(snapshot.zone, 5, 1, true)) invalid('Invalid workout measurement');
  array(snapshot.rows, 2048, value => {
    const row = object(value);
    exactKeys(row, ['id', 'label', 'kind', 'isActive', 'duration', 'totalTime', 'avgBPM', 'maxBPM', 'minBPM']);
    if (!text(row.id, 128) || !text(row.label, 32) || !member(row.kind, ['work', 'rest', 'cooldown', 'placeholder', 'empty'])
        || typeof row.isActive !== 'boolean' || !number(row.duration, MAX_TIME) || !number(row.totalTime, MAX_TIME)
        || !bpm(row.avgBPM) || !bpm(row.maxBPM) || !bpm(row.minBPM)) invalid('Invalid workout row');
  });
  array(snapshot.chart, 8192, value => {
    const point = object(value);
    exactKeys(point, ['time', 'bpm', 'segment', 'validUntil']);
    if (!number(point.time, MAX_TIME) || !number(point.bpm, 400, 1, true)
        || !number(point.segment, Number.MAX_SAFE_INTEGER, 0, true) || !number(point.validUntil, MAX_TIME)
        || (point.validUntil as number) < (point.time as number)) invalid('Invalid workout chart point');
  });
  array(snapshot.segments, 2048, value => {
    const segment = object(value);
    exactKeys(segment, ['startTime', 'endTime', 'kind']);
    if (!number(segment.startTime, MAX_TIME) || !number(segment.endTime, MAX_TIME)
        || (segment.endTime as number) < (segment.startTime as number)
        || !member(segment.kind, ['work', 'rest', 'cooldown'])) invalid('Invalid workout segment');
  });
  array(snapshot.zones, 5, value => {
    const zone = object(value);
    exactKeys(zone, ['zone', 'duration']);
    if (!number(zone.zone, 5, 1, true) || !number(zone.duration, MAX_TIME)) invalid('Invalid workout zone');
  });
  if (snapshot.allowedActions !== undefined && snapshot.allowedActions !== null) {
    array(snapshot.allowedActions, WORKOUT_ACTIONS.length, value => {
      if (!member(value, WORKOUT_ACTIONS)) invalid('Unsupported workout control');
    });
    if (new Set(snapshot.allowedActions as string[]).size !== (snapshot.allowedActions as string[]).length) invalid('Duplicate workout control');
  }
  if (snapshot.activePreset !== undefined && snapshot.activePreset !== null) validatePreset(snapshot.activePreset);
  if (!optionalNumber(snapshot.recoverableHistorySeconds, 3600)) invalid('Invalid recoverable history duration');
  if (snapshot.hrv !== undefined && snapshot.hrv !== null) validateHRV(snapshot.hrv);
  return snapshot;
}

export function validateControl(value: unknown): ObjectValue {
  const command = object(value);
  exactKeys(command, ['code', 'id', 'workoutID', 'controlRevision', 'action', 'preset']);
  validateCode(command.code);
  if (typeof command.id !== 'string' || !UUID.test(command.id)
      || typeof command.workoutID !== 'string' || !UUID.test(command.workoutID)
      || !text(command.controlRevision, 128) || !member(command.action, CONTROL_ACTIONS)) invalid('Unsupported workout control');
  if (command.action === 'loadPreset') validatePreset(command.preset);
  else if (command.preset !== undefined && command.preset !== null) invalid('Preset payload is only supported when loading a preset');
  return command;
}

export function validateRRStream(value: unknown): ObjectValue {
  const snapshot = object(value);
  exactKeys(snapshot, ['schemaVersion', 'sequence', 'streamID', 'supportsRRIntervals', 'sourceTicks', 'intervals']);
  if (snapshot.schemaVersion !== 1 || !number(snapshot.sequence, Number.MAX_SAFE_INTEGER, 0, true)
      || typeof snapshot.streamID !== 'string' || !UUID.test(snapshot.streamID)
      || typeof snapshot.supportsRRIntervals !== 'boolean'
      || !number(snapshot.sourceTicks, Number.MAX_SAFE_INTEGER)) invalid('Invalid RR stream');
  const ids = new Set<string>();
  let previousTicks = -1;
  array(snapshot.intervals, 128, value => {
    const interval = object(value);
    exactKeys(interval, ['id', 'value', 'receivedTicks']);
    if (typeof interval.id !== 'string' || !UUID.test(interval.id) || ids.has(interval.id)
        || !number(interval.value, 64000)
        || !number(interval.receivedTicks, snapshot.sourceTicks as number)
        || (interval.receivedTicks as number) < previousTicks
        || (snapshot.sourceTicks as number) - (interval.receivedTicks as number) > 15) invalid('Invalid RR interval');
    ids.add(interval.id);
    previousTicks = interval.receivedTicks as number;
  });
  if (!snapshot.supportsRRIntervals && (snapshot.intervals as unknown[]).length) invalid('Unsupported RR stream must be empty');
  return snapshot;
}

export function validateCode(code: unknown): asserts code is string {
  if (typeof code !== 'string' || !/^[0-9]{6}$/.test(code)) invalid('A 6-digit share code is required');
}

function validateToken(token: unknown): asserts token is string {
  if (typeof token !== 'string' || !/^[a-f0-9]{64}$/.test(token)) invalid('Invalid host token');
}

function keys(code: string, token = ''): string[] {
  return [`share:${code}`, `token:${token}`, `workout:${code}`, `workout-queue:${code}`, `workout-receipts:${code}`, `workout-claims:${code}`, `rr:${code}`];
}

// All session existence, authorization, expiry checks and mutations occur inside
// the same Redis script. No write can recreate a deleted or expired session.
const CLOCK = `
local clock = redis.call('TIME')
local now = tonumber(clock[1]) * 1000 + math.floor(tonumber(clock[2]) / 1000)
local function result(status, code, message)
  return cjson.encode({status=status,code=code,message=message,serverTime=now})
end
`;
const SESSION = `
local rawSession = redis.call('GET', KEYS[1])
local ttl = redis.call('PTTL', KEYS[1])
if not rawSession or ttl <= 0 then return result(404,'SESSION_NOT_FOUND','Sharing session has ended') end
local session = cjson.decode(rawSession)
local expiresAt = now + ttl
`;
const AUTH = `
if redis.call('GET', KEYS[2]) ~= ARGV[1] or session.token ~= ARGV[2] then
  return result(401,'INVALID_TOKEN','Invalid host token')
end
`;
const SAVE = `
local function save(key, value)
  redis.call('SET', key, value)
  redis.call('PEXPIREAT', key, expiresAt)
end
local function expire(key)
  redis.call('PEXPIREAT', key, expiresAt)
end
`;

export const createSessionScript = CLOCK + `
if redis.call('EXISTS', KEYS[1]) == 1 or redis.call('EXISTS', KEYS[2]) == 1 then return 0 end
local session = {code=ARGV[1],token=ARGV[2],bpm=cjson.null,max=cjson.null,avg=cjson.null,min=cjson.null,timestamp=now}
redis.call('PSETEX', KEYS[1], ARGV[3], cjson.encode(session))
redis.call('PSETEX', KEYS[2], ARGV[3], ARGV[1])
redis.call('DEL', KEYS[3], KEYS[4], KEYS[5], KEYS[6], KEYS[7])
return 1
`;

const deleteSessionScript = CLOCK + `
local raw = redis.call('GET', KEYS[1])
if raw and cjson.decode(raw).token == ARGV[2] and redis.call('GET', KEYS[2]) == ARGV[1] then
  redis.call('DEL', KEYS[1], KEYS[2], KEYS[3], KEYS[4], KEYS[5], KEYS[6], KEYS[7])
end
return result(200,'OK','Sharing stopped')
`;

const readSessionScript = CLOCK + SESSION + `
local workout = redis.call('GET', KEYS[3])
local rr = redis.call('GET', KEYS[7])
return '{"status":200,"session":' .. rawSession .. ',"workoutState":' .. (workout or 'null') .. ',"rrState":' .. (rr or 'null') .. ',"serverTime":' .. now .. '}'
`;

const beatScript = CLOCK + SESSION + AUTH + `
local beat = cjson.decode(ARGV[3])
session.bpm = beat.bpm
for _, key in ipairs({'max','avg','min'}) do if beat[key] ~= nil then session[key] = beat[key] end end
session.timestamp = now
redis.call('SET', KEYS[1], cjson.encode(session), 'XX', 'KEEPTTL')
return result(200,'OK','Heart rate updated')
`;

export const publishWorkoutScript = CLOCK + SESSION + AUTH + SAVE + `
local snapshot = cjson.decode(ARGV[3])
local previous = redis.call('GET', KEYS[3])
if previous and snapshot.sequence <= cjson.decode(previous).snapshot.sequence then
  return result(409,'STALE_SNAPSHOT','A newer workout snapshot already exists')
end
local acknowledged = cjson.decode(ARGV[4])
for _, id in ipairs(acknowledged) do
  local rawReceipt = redis.call('HGET', KEYS[5], id)
  if rawReceipt then
    local receipt = cjson.decode(rawReceipt)
    local claim = receipt.workoutID .. ':' .. receipt.controlRevision
    if receipt.status == 200 and redis.call('HGET', KEYS[6], claim) == id then redis.call('HDEL', KEYS[6], claim) end
  end
  redis.call('HDEL', KEYS[4], id)
end
save(KEYS[3], '{"snapshot":' .. ARGV[3] .. ',"timestamp":' .. now .. '}')
-- Expired commands remain deliverable for the owner to reject and acknowledge.
-- Only the owner can confirm that an unacknowledged command will not run later.
local commands = redis.call('HVALS', KEYS[4])
return '{"status":200,"commands":[' .. table.concat(commands, ',') .. '],"serverTime":' .. now .. '}'
`;

export const controlScript = CLOCK + SESSION + SAVE + `
local command = cjson.decode(ARGV[1])
local validActions = {work=true,rest=true,start=true,startIncludingHistory=true,pause=true,resume=true,['end']=true,reset=true,cool=true,loadPreset=true,clearPreset=true,hrvStart=true,hrvCancel=true,hrvReset=true}
if not validActions[command.action] then return result(400,'INVALID_CONTROL','Unsupported workout control') end
local presetFingerprint = ARGV[2] or ''
local receipt = redis.call('HGET', KEYS[5], command.id)
if receipt then
  local prior = cjson.decode(receipt)
  if prior.workoutID ~= command.workoutID or prior.controlRevision ~= command.controlRevision or prior.action ~= command.action
    or (prior.presetFingerprint or '') ~= presetFingerprint then
    return result(409,'COMMAND_ID_REUSED','This command identifier was already used')
  end
  prior.replayed = true
  prior.serverTime = now
  return cjson.encode(prior)
end
if redis.call('HLEN', KEYS[5]) >= 4096 then return result(409,'COMMAND_LIMIT','Too many controls in this sharing session') end
local function remember(status, code, message)
  local value = {status=status,code=code,message=message,id=command.id,workoutID=command.workoutID,
    controlRevision=command.controlRevision,action=command.action,presetFingerprint=presetFingerprint,serverTime=now,replayed=false}
  redis.call('HSET', KEYS[5], command.id, cjson.encode(value))
  expire(KEYS[5])
  return cjson.encode(value)
end
local rawWorkout = redis.call('GET', KEYS[3])
if not rawWorkout then return remember(409,'WORKOUT_UNAVAILABLE','No live workout is available') end
local workout = cjson.decode(rawWorkout)
local snapshot = workout.snapshot
if now - workout.timestamp >= ${CONTROL_LIFETIME_MS} or workout.timestamp > now then
  return remember(409,'STALE_WORKOUT','Waiting for a fresh workout update')
end
if snapshot.workoutID ~= command.workoutID or snapshot.controlRevision ~= command.controlRevision then
  return remember(409,'STALE_CONTROL','The workout has changed')
end
local allowed = false
if type(snapshot.allowedActions) == 'table' then
  for _, action in ipairs(snapshot.allowedActions) do if action == command.action then allowed = true end end
else
  allowed = command.action == 'work' or command.action == 'rest'
end
local state = snapshot.state
local action = command.action
local stateAllowed = false
if action == 'hrvStart' or action == 'hrvCancel' or action == 'hrvReset' then
  local hrv = snapshot.hrv
  allowed = type(hrv) == 'table' and hrv.allowsRemoteControl == true
  if allowed then
    if action == 'hrvStart' then stateAllowed = (hrv.state == 'idle' or hrv.state == 'completed') and hrv.readinessReason == 'ready'
    elseif action == 'hrvCancel' then stateAllowed = hrv.state == 'measuring'
    else stateAllowed = hrv.state == 'completed' or hrv.state == 'error' end
  end
elseif action == 'work' or action == 'rest' then
  stateAllowed = state == 'running' and not snapshot.isPresetMode and not snapshot.isCompleted
    and ((action == 'work' and snapshot.canWork) or (action == 'rest' and snapshot.canRest))
elseif action == 'start' or action == 'loadPreset' then stateAllowed = state == 'idle' and not snapshot.isCompleted
elseif action == 'startIncludingHistory' then stateAllowed = state == 'idle' and not snapshot.isCompleted and not snapshot.isPresetMode
  and type(snapshot.recoverableHistorySeconds) == 'number' and snapshot.recoverableHistorySeconds > 0
elseif action == 'clearPreset' then stateAllowed = state == 'idle' and not snapshot.isCompleted and snapshot.isPresetMode
elseif action == 'pause' then stateAllowed = state == 'running' or state == 'cooldown'
elseif action == 'resume' then stateAllowed = state == 'paused' or state == 'cooldownPaused' or (state == 'idle' and snapshot.isCompleted)
elseif action == 'end' then stateAllowed = state ~= 'idle' and not snapshot.isCompleted
elseif action == 'reset' then stateAllowed = state ~= 'idle' or not snapshot.isEmpty or snapshot.isPresetMode
elseif action == 'cool' then stateAllowed = (state == 'running' or state == 'paused') and not snapshot.isPresetMode and not snapshot.isCompleted end
if not allowed or not stateAllowed then
  return remember(409,'CONTROL_DISABLED','This workout control is currently unavailable')
end
local claim = command.workoutID .. ':' .. command.controlRevision
if redis.call('HEXISTS', KEYS[6], claim) == 1 then return remember(409,'CONTROL_ALREADY_CLAIMED','A workout change is already pending') end
if redis.call('HLEN', KEYS[4]) >= 32 then return remember(409,'QUEUE_FULL','Too many workout controls are pending') end
command.code = nil
command.createdAt = now
redis.call('HSET', KEYS[4], command.id, cjson.encode(command))
redis.call('HSET', KEYS[6], claim, command.id)
expire(KEYS[4])
expire(KEYS[6])
return remember(200,'QUEUED','Workout control queued')
`;

const publishRRScript = CLOCK + SESSION + AUTH + SAVE + `
local snapshot = cjson.decode(ARGV[3])
local previous = redis.call('GET', KEYS[7])
if previous and snapshot.sequence <= cjson.decode(previous).snapshot.sequence then
  return result(409,'STALE_RR_STREAM','A newer RR stream already exists')
end
save(KEYS[7], '{"snapshot":' .. ARGV[3] .. ',"timestamp":' .. now .. '}')
return result(200,'OK','RR stream updated')
`;

async function run(redis: ShareRedis, script: string, scriptKeys: string[], args: unknown[]): Promise<ScriptResult> {
  const raw = await redis.eval(script, scriptKeys, args);
  const result: ScriptResult = typeof raw === 'string' ? JSON.parse(raw) : raw as ScriptResult;
  if (result.status !== 200) throw new ShareRequestError(result.status, result.message, result.code);
  return result;
}

async function hostCode(redis: ShareRedis, token: unknown): Promise<string> {
  validateToken(token);
  const code = mappedCode(await redis.get(`token:${token}`));
  if (code === null) throw new ShareRequestError(401, 'Invalid or expired host token', 'INVALID_TOKEN');
  return code;
}

function mappedCode(value: unknown): string | null {
  // @vercel/kv automatically decodes unquoted numeric strings. Leading-zero
  // codes remain strings; the other six-digit codes can arrive as numbers.
  const code = typeof value === 'number' && Number.isSafeInteger(value) ? String(value) : value;
  return typeof code === 'string' && /^[0-9]{6}$/.test(code) ? code : null;
}

export async function createShareSession(redis: ShareRedis, code: string, token: string): Promise<boolean> {
  validateCode(code);
  validateToken(token);
  return await redis.eval(createSessionScript, keys(code, token), [code, token, SHARE_LIFETIME_MS]) === 1;
}

export async function deleteShareSession(redis: ShareRedis, token: unknown): Promise<void> {
  validateToken(token);
  const code = mappedCode(await redis.get(`token:${token}`));
  if (code === null) return;
  await run(redis, deleteSessionScript, keys(code, token), [code, token]);
}

export async function readSharedSession(redis: ShareRedis, code: unknown): Promise<ObjectValue> {
  validateCode(code);
  const result = await run(redis, readSessionScript, keys(code), []);
  const session = result.session;
  return { bpm: session.bpm, max: session.max, avg: session.avg, min: session.min, timestamp: session.timestamp,
    workout: result.workoutState?.snapshot ?? null, workoutTimestamp: result.workoutState?.timestamp ?? null,
    rrStream: result.rrState?.snapshot ?? null, rrTimestamp: result.rrState?.timestamp ?? null, serverTime: result.serverTime };
}

export async function recordHeartBeat(redis: ShareRedis, value: unknown): Promise<void> {
  const body = object(value);
  if (body.bpm !== null && !number(body.bpm, 400, 1, true)) invalid('Invalid heart rate');
  for (const key of ['max', 'avg', 'min']) if (!bpm(body[key])) invalid('Invalid heart rate summary');
  const code = await hostCode(redis, body.token);
  const beat: ObjectValue = { bpm: body.bpm };
  for (const key of ['max', 'avg', 'min']) if (body[key] !== undefined) beat[key] = body[key];
  await run(redis, beatScript, keys(code, body.token as string), [code, body.token, JSON.stringify(beat)]);
}

export async function publishWorkout(redis: ShareRedis, value: unknown): Promise<ObjectValue> {
  const body = object(value);
  exactKeys(body, ['token', 'snapshot', 'acknowledgedCommandIds']);
  const snapshot = validateSnapshot(body.snapshot);
  const acknowledged = body.acknowledgedCommandIds;
  if (!Array.isArray(acknowledged) || acknowledged.length > 32 || acknowledged.some(id => typeof id !== 'string' || !UUID.test(id))) invalid('Invalid command acknowledgements');
  const code = await hostCode(redis, body.token);
  const result = await run(redis, publishWorkoutScript, keys(code, body.token as string), [code, body.token, JSON.stringify(snapshot), JSON.stringify(acknowledged)]);
  return { commands: result.commands, serverTime: result.serverTime };
}

export async function queueWorkoutControl(redis: ShareRedis, value: unknown): Promise<ObjectValue> {
  const command = validateControl(value);
  const preset = command.preset as ObjectValue | undefined;
  const fingerprint = preset ? JSON.stringify([preset.id, preset.name, preset.workDuration, preset.restDuration,
    preset.numberOfSets, preset.includeCooldown, preset.playSound]) : '';
  const result = await run(redis, controlScript, keys(command.code as string), [JSON.stringify(command), fingerprint]);
  return { queued: true, replayed: result.replayed, id: result.id, serverTime: result.serverTime };
}

export async function publishRRStream(redis: ShareRedis, value: unknown): Promise<ObjectValue> {
  const body = object(value);
  exactKeys(body, ['token', 'snapshot']);
  const snapshot = validateRRStream(body.snapshot);
  const code = await hostCode(redis, body.token);
  const result = await run(redis, publishRRScript, keys(code, body.token as string), [code, body.token, JSON.stringify(snapshot)]);
  return { serverTime: result.serverTime };
}
