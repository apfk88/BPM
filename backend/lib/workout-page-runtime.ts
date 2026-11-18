import { kv } from '@vercel/kv';
import { put, get, del } from '@vercel/blob';
import { WorkoutPages, type WorkoutBlobStore } from './workout-pages';
import { appleVerifier, WorkoutPageAttestation } from './workout-page-attestation';
import { createWorkoutPageHandler, type WorkoutPageAPIConfiguration } from './workout-page-api';
import { MAX_COMPRESSED_BYTES } from './workout-page-validation';

export const privateWorkoutBlobs: WorkoutBlobStore = {
  async put(path, data) {
    await put(path, data, { access: 'private', addRandomSuffix: false, allowOverwrite: false,
      contentType: 'application/gzip', cacheControlMaxAge: 60 });
  },
  async get(path) {
    const result = await get(path, { access: 'private' });
    if (!result || result.statusCode !== 200) return null;
    const reader = result.stream.getReader();
    const chunks: Buffer[] = [];
    let size = 0;
    try {
      for (;;) {
        const item = await reader.read();
        if (item.done) break;
        size += item.value.length;
        if (size > MAX_COMPRESSED_BYTES) { await reader.cancel(); throw new Error('Stored workout too large'); }
        chunks.push(Buffer.from(item.value));
      }
    } finally { reader.releaseLock(); }
    return Buffer.concat(chunks);
  },
  async delete(path) { await del(path); },
};

export function workoutPageConfiguration(env: Partial<NodeJS.ProcessEnv> = process.env): WorkoutPageAPIConfiguration {
  const production = env.VERCEL_ENV === 'production' || (env.NODE_ENV === 'production' && env.VERCEL_ENV !== 'preview');
  const daily = Number(env.WORKOUT_PAGES_DAILY_UPLOAD_LIMIT || 1000);
  return {
    uploadsEnabled: env.WORKOUT_PAGES_UPLOADS_ENABLED === 'true',
    appAttestConfigured: /^[A-Z0-9]{10}$/.test(env.WORKOUT_PAGES_APP_ID_PREFIX || '') && !!env.WORKOUT_PAGES_BUNDLE_ID,
    ipSalt: env.WORKOUT_PAGES_IP_SALT || '', production,
    dailyUploadLimit: Number.isSafeInteger(daily) && daily > 0 && daily <= 10000 ? daily : 1000,
    cleanupSecret: env.WORKOUT_PAGES_CLEANUP_SECRET || env.CRON_SECRET,
    blockedTerms: (env.WORKOUT_PAGES_BLOCKED_TERMS || '').split('|').filter(Boolean).slice(0, 100),
  };
}

export function productionWorkoutPageHandler() {
  const configuration = workoutPageConfiguration();
  const verifier = appleVerifier({ teamIdentifier: process.env.WORKOUT_PAGES_APP_ID_PREFIX || '',
    bundleIdentifier: process.env.WORKOUT_PAGES_BUNDLE_ID || '',
    allowDevelopmentEnvironment: !configuration.production && process.env.WORKOUT_PAGES_ALLOW_DEVELOPMENT_ATTESTATION === 'true',
    minimumBundleVersion: Number(process.env.WORKOUT_PAGES_MINIMUM_BUNDLE_VERSION || 1),
  });
  return createWorkoutPageHandler({ pages: new WorkoutPages(kv, privateWorkoutBlobs),
    attestation: new WorkoutPageAttestation(kv, verifier), redis: kv, configuration });
}
