import type { WorkoutPageExport } from './workout-page-schema';
import { validWorkoutDate } from './workout-page-schema';

export const MAX_COMPRESSED_BYTES = 2 * 1024 * 1024;
export const MAX_JSON_REQUEST_BYTES = 4 * 1024 * 1024;
export const MAX_DECODED_BYTES = 16 * 1024 * 1024;
export const MAX_DURATION_SECONDS = 7 * 86400;
export class WorkoutPageError extends Error {
  constructor(public status: number, message: string, public code = 'INVALID_WORKOUT_PAGE') { super(message); }
}
export function invalid(message = 'Invalid workout page'): never { throw new WorkoutPageError(400, message); }
export function exactObject(value: unknown, keys: string[]): Record<string, any> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid();
  const object = value as Record<string, any>;
  if (Object.keys(object).some(key => !keys.includes(key))) invalid('Unexpected workout field');
  return object;
}
export function finite(value: unknown, max = MAX_DURATION_SECONDS, min = 0): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max;
}
export function boundedText(value: unknown, max: number, min = 0, multiline = false): value is string {
  return typeof value === 'string' && value.length >= min && value.length <= max
    && !(multiline ? /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f\u202a-\u202e\u2066-\u2069]/ : /[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/).test(value);
}
export function validPageID(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}
export function validKey(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value) && Buffer.from(value, 'base64url').toString('base64url') === value;
}
export function validRecovery(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{40,2048}$/.test(value) && Buffer.from(value, 'base64url').toString('base64url') === value;
}
function optional(value: unknown, max: number, min = 0): boolean { return value == null || finite(value, max, min); }
function entries(value: unknown, max: number): any[] {
  if (!Array.isArray(value) || value.length > max) invalid('Too many workout entries');
  return value;
}
function measurements(value: Record<string, any>): void {
  for (const key of ['avgBPM', 'minBPM', 'maxBPM']) if (!optional(value[key], 400, 1)) invalid('Invalid heart-rate summary');
  if (value.minBPM != null && value.maxBPM != null && value.minBPM > value.maxBPM) invalid('Invalid heart-rate range');
}
export function validateWorkoutPage(value: unknown): WorkoutPageExport {
  const workout = exactObject(value, ['schemaVersion', 'calculationVersion', 'title', 'description', 'workoutDate', 'recordedAt',
    'durationSeconds', 'elapsedDurationSeconds', 'summary', 'samples', 'intervals', 'sets', 'zones', 'quality']);
  if (workout.schemaVersion !== 1 || workout.calculationVersion !== 1 || !boundedText(workout.title, 120, 1)
      || !workout.title.trim() || (workout.description != null && !boundedText(workout.description, 8000, 0, true))
      || !finite(workout.durationSeconds) || !finite(workout.elapsedDurationSeconds)
      || workout.durationSeconds > workout.elapsedDurationSeconds + 0.001) invalid();
  if (workout.workoutDate != null && !validWorkoutDate(workout.workoutDate)) invalid('Invalid workout date');
  if (workout.recordedAt != null && (typeof workout.recordedAt !== 'string' || workout.recordedAt.length > 40
      || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(workout.recordedAt)
      || !Number.isFinite(Date.parse(workout.recordedAt)))) invalid('Invalid optional workout date');
  const summary = exactObject(workout.summary, ['avgBPM', 'minBPM', 'maxBPM', 'calories', 'activeCalories', 'recoveryBPM']);
  measurements(summary);
  if (!optional(summary.calories, 100000) || !optional(summary.activeCalories, 100000)
      || !optional(summary.recoveryBPM, 400, -400)) invalid('Invalid workout summary');
  const quality = exactObject(workout.quality, ['sampleFidelity', 'exportedSampleCount', 'originalSampleCount', 'rangeMetricsAvailable']);
  const samples = entries(workout.samples, 200000);
  if (!['full', 'reduced', 'unknown'].includes(quality.sampleFidelity) || quality.exportedSampleCount !== samples.length
      || (quality.originalSampleCount != null && (!Number.isSafeInteger(quality.originalSampleCount) || quality.originalSampleCount < samples.length))
      || (quality.sampleFidelity === 'full' && quality.originalSampleCount != null && quality.originalSampleCount !== samples.length)
      || typeof quality.rangeMetricsAvailable !== 'boolean'
      || (quality.rangeMetricsAvailable && (quality.sampleFidelity !== 'full' || samples.length === 0))) invalid('Invalid sample provenance');
  let lastElapsed = -1, lastActive = -1;
  for (const item of samples) {
    const sample = exactObject(item, ['elapsedSeconds', 'activeSeconds', 'bpm', 'validUntilElapsedSeconds', 'invalidatedAtElapsedSeconds']);
    if (!finite(sample.elapsedSeconds, workout.elapsedDurationSeconds) || !finite(sample.activeSeconds, workout.durationSeconds)
        || sample.elapsedSeconds < lastElapsed || sample.activeSeconds < lastActive || sample.activeSeconds > sample.elapsedSeconds + 0.001
        || !finite(sample.bpm, 400, 1) || !Number.isInteger(sample.bpm)
        || !optional(sample.validUntilElapsedSeconds, Math.min(workout.elapsedDurationSeconds, sample.elapsedSeconds + 3.001), sample.elapsedSeconds)
        || !optional(sample.invalidatedAtElapsedSeconds, workout.elapsedDurationSeconds, sample.elapsedSeconds)
        || (quality.rangeMetricsAvailable && sample.validUntilElapsedSeconds == null)
        || (sample.invalidatedAtElapsedSeconds != null && sample.validUntilElapsedSeconds != null
          && sample.validUntilElapsedSeconds > sample.invalidatedAtElapsedSeconds + 0.001)) invalid('Invalid recorded sample');
    lastElapsed = sample.elapsedSeconds; lastActive = sample.activeSeconds;
  }
  for (const item of entries(workout.intervals, 10000)) {
    const interval = exactObject(item, ['startElapsedSeconds', 'endElapsedSeconds', 'kind']);
    if (!['pause', 'signalLoss'].includes(interval.kind) || !finite(interval.startElapsedSeconds, workout.elapsedDurationSeconds)
        || !finite(interval.endElapsedSeconds, workout.elapsedDurationSeconds, interval.startElapsedSeconds)) invalid('Invalid workout interval');
  }
  const setIndices = new Set<number>();
  for (const item of entries(workout.sets, 4096)) {
    const set = exactObject(item, ['index', 'label', 'kind', 'startElapsedSeconds', 'endElapsedSeconds', 'startActiveSeconds',
      'endActiveSeconds', 'durationSeconds', 'avgBPM', 'minBPM', 'maxBPM']);
    if (!Number.isInteger(set.index) || !finite(set.index, 4095) || setIndices.has(set.index) || !boundedText(set.label, 80)
        || !['work', 'rest', 'cooldown'].includes(set.kind) || !finite(set.startElapsedSeconds, workout.elapsedDurationSeconds)
        || !finite(set.endElapsedSeconds, workout.elapsedDurationSeconds, set.startElapsedSeconds)
        || !finite(set.startActiveSeconds, workout.durationSeconds) || !finite(set.endActiveSeconds, workout.durationSeconds, set.startActiveSeconds)
        || !finite(set.durationSeconds, workout.durationSeconds)) invalid('Invalid workout set');
    measurements(set); setIndices.add(set.index);
  }
  const zoneIDs = new Set<number>();
  let totalZoneSeconds = 0;
  for (const item of entries(workout.zones, 5)) {
    const zone = exactObject(item, ['zone', 'durationSeconds', 'lowerBPM', 'upperBPM']);
    if (!Number.isInteger(zone.zone) || !finite(zone.zone, 5, 1) || zoneIDs.has(zone.zone)
        || !finite(zone.durationSeconds, workout.durationSeconds + 0.001)
        || !optional(zone.lowerBPM, 500) || !optional(zone.upperBPM, 500)
        || (zone.lowerBPM != null && zone.upperBPM != null && zone.upperBPM < zone.lowerBPM)) invalid('Invalid workout zone');
    zoneIDs.add(zone.zone);
    totalZoneSeconds += zone.durationSeconds;
  }
  if (totalZoneSeconds > workout.durationSeconds + 0.01) invalid('Zone time exceeds workout duration');
  return workout as WorkoutPageExport;
}

// Stable across Swift and JavaScript object insertion order; array order remains meaningful.
export function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().filter(key => object[key] !== undefined)
      .map(key => `${JSON.stringify(key)}:${canonicalJSON(object[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}
