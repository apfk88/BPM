import { createHmac } from 'crypto';
import { kv } from '@vercel/kv';
import { RecapError } from './workout-recap';

// Atomic admission and expiry across serverless instances. No audio/transcript is stored.
const admissionScript = `
local user = tonumber(redis.call('GET', KEYS[1]) or '0')
local total = tonumber(redis.call('GET', KEYS[2]) or '0')
if user >= tonumber(ARGV[1]) or total >= tonumber(ARGV[2]) then return 0 end
redis.call('INCR', KEYS[1])
redis.call('EXPIRE', KEYS[1], 90000)
redis.call('INCR', KEYS[2])
redis.call('EXPIRE', KEYS[2], 90000)
return 1
`;
const localCounts = new Map<string, number>();
let localDay = '';

export async function admitRecap(ip: string, key: string): Promise<void> {
  const day = new Date().toISOString().slice(0, 10);
  const hash = createHmac('sha256', key).update(`${day}:${ip}`).digest('hex').slice(0, 32);
  const keys = [`recap:${day}:${hash}`, `recap:${day}:total`];
  const userLimit = 20;
  const totalLimit = 500;
  let admitted: boolean;
  if (process.env.KV_REST_API_URL && process.env.KV_REST_API_TOKEN) {
    try { admitted = (await kv.eval(admissionScript, keys, [userLimit, totalLimit])) === 1; }
    catch { throw new RecapError(503, 'LIMITER_UNAVAILABLE', 'Voice capture is temporarily unavailable. Try again shortly.'); }
  } else if (process.env.NODE_ENV === 'development' && !process.env.VERCEL) {
    if (localDay !== day) { localCounts.clear(); localDay = day; }
    admitted = (localCounts.get(keys[0]) ?? 0) < userLimit && (localCounts.get(keys[1]) ?? 0) < totalLimit;
    if (admitted) keys.forEach(k => localCounts.set(k, (localCounts.get(k) ?? 0) + 1));
  } else {
    throw new RecapError(503, 'LIMITER_UNAVAILABLE', 'Voice capture is temporarily unavailable. Try again shortly.');
  }
  if (!admitted) throw new RecapError(429, 'DAILY_LIMIT', 'Voice capture has reached its daily limit. You can still type your workout.');
}
