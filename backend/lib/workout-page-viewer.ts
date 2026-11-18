import type { WorkoutPageExport, WorkoutPageSample, WorkoutPageZone } from './workout-page-schema';
import { validWorkoutDate } from './workout-page-schema';

export type DescriptionBlock = { kind: 'paragraph'; text: string }
  | { kind: 'unordered' | 'ordered'; items: { text: string; number?: number }[] };

// Plain text only. React renders the text nodes, so HTML and Markdown links stay literal.
export function descriptionBlocks(description: string): DescriptionBlock[] {
  const blocks: DescriptionBlock[] = [];
  let current: DescriptionBlock | null = null;
  const finish = () => { if (current) blocks.push(current); current = null; };
  for (const line of description.replace(/\r\n?/g, '\n').split('\n')) {
    if (!line.trim()) { finish(); continue; }
    const marker = /^\s*(?:([-*•])|(\d{1,4})[.)])\s+(.+)$/.exec(line);
    if (marker) {
      const kind = marker[2] ? 'ordered' : 'unordered';
      if (!current || current.kind !== kind) { finish(); current = { kind, items: [] }; }
      current.items.push({ text: marker[3], ...(marker[2] ? { number: Number(marker[2]) } : {}) });
    } else if (current && current.kind !== 'paragraph' && /^[\t ]+/.test(line)) {
      current.items[current.items.length - 1].text += `\n${line.trimStart()}`;
    } else {
      if (!current || current.kind !== 'paragraph') { finish(); current = { kind: 'paragraph', text: line }; }
      else current.text += `\n${line}`;
    }
  }
  finish();
  return blocks;
}

export function workoutDateLabel(workout: Pick<WorkoutPageExport, 'workoutDate' | 'recordedAt'>, locale?: string): string | null {
  const fallback = workout.recordedAt && Number.isFinite(Date.parse(workout.recordedAt)) ? workout.recordedAt.slice(0, 10) : null;
  const value = validWorkoutDate(workout.workoutDate) ? workout.workoutDate : fallback;
  if (!validWorkoutDate(value)) return null;
  // Date-only values must never shift when viewed in another timezone.
  return new Date(`${value}T00:00:00Z`).toLocaleDateString(locale, { dateStyle: 'long', timeZone: 'UTC' });
}

export function workoutPreviewImageURL(pageID: unknown, capability: unknown): string | null {
  if (typeof pageID === 'string' && /^[A-Za-z0-9_-]{21}[AQgw]$/.test(pageID)) {
    return `https://bpmtracker.app/api/workout-pages/${pageID}/preview`;
  }
  if (typeof pageID !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(pageID)
    || typeof capability !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(capability)) return null;
  return `https://bpmtracker.app/api/workout-pages/${pageID}/preview?p=${capability}`;
}

export type WorkoutRange = { start: number; end: number };
export type TimelinePoint = WorkoutPageSample & { index: number; validUntil: number; segment: number };
export type RangeMetrics = {
  duration: number;
  coveredDuration: number;
  average: number | null;
  minimum: number | null;
  maximum: number | null;
  zoneDurations: Record<number, number> | null;
  unassignedDuration: number | null;
};

export const ZONE_COLORS = ['#e6ebe7', '#43e275', '#ffb14a', '#c08aff', '#ff6672'];
const finite = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value);

export function clampRange(range: WorkoutRange, duration: number): WorkoutRange {
  const limit = finite(duration) ? Math.max(0, duration) : 0;
  const start = Math.min(limit, Math.max(0, finite(range.start) ? range.start : 0));
  return { start, end: Math.min(limit, Math.max(start, finite(range.end) ? range.end : limit)) };
}

// Dragging the plotted line right reveals earlier time. Preserve zoom width at both bounds.
export function panWorkoutViewport(viewport: WorkoutRange, duration: number, deltaPixels: number, plotWidth: number): WorkoutRange {
  const current = clampRange(viewport, duration);
  const width = current.end - current.start;
  if (!finite(deltaPixels) || !finite(plotWidth) || plotWidth <= 0 || width <= 0) return current;
  const start = Math.max(0, Math.min(Math.max(0, duration - width), current.start - deltaPixels / plotWidth * width));
  return { start, end: start + width };
}

export function rangeMetricsAvailable(workout: WorkoutPageExport): boolean {
  return workout.calculationVersion === 1 && workout.quality.sampleFidelity === 'full'
    && workout.quality.rangeMetricsAvailable;
}

// Use recorded active time. The wall-clock offsets are only used to stop support at pauses/loss.
export function workoutTimeline(workout: WorkoutPageExport): TimelinePoint[] {
  const pauses: { startElapsedSeconds: number; endElapsedSeconds: number }[] = [];
  for (const pause of workout.intervals.filter(interval => interval.kind === 'pause')
    .sort((a, b) => a.startElapsedSeconds - b.startElapsedSeconds)) {
    const previous = pauses[pauses.length - 1];
    if (previous && pause.startElapsedSeconds <= previous.endElapsedSeconds) previous.endElapsedSeconds = Math.max(previous.endElapsedSeconds, pause.endElapsedSeconds);
    else pauses.push({ ...pause });
  }
  const intervalStarts = workout.intervals.map(interval => interval.startElapsedSeconds).sort((a, b) => a - b);
  const firstAtOrAfter = (values: number[], target: number) => {
    let low = 0;
    let high = values.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (values[middle] < target) low = middle + 1;
      else high = middle;
    }
    return low;
  };
  const pauseEnds = pauses.map(pause => pause.endElapsedSeconds);
  const pauseStarts = pauses.map(pause => pause.startElapsedSeconds);
  const inPause = (time: number) => {
    let index = firstAtOrAfter(pauseEnds, time);
    if (pauseEnds[index] === time) index += 1;
    return pauses[index] != null && pauses[index].startElapsedSeconds <= time;
  };
  const ordered = workout.samples.map((sample, index) => ({ ...sample, index }))
    .filter(sample => finite(sample.activeSeconds) && finite(sample.elapsedSeconds) && sample.bpm > 0
      && sample.activeSeconds >= 0 && sample.activeSeconds <= workout.durationSeconds
      && !inPause(sample.elapsedSeconds))
    .sort((a, b) => a.activeSeconds - b.activeSeconds || a.elapsedSeconds - b.elapsedSeconds || a.index - b.index);
  let segment = 0;
  const trusted = rangeMetricsAvailable(workout);
  return ordered.map((sample, index) => {
    const previous = ordered[index - 1];
    const nextPause = previous ? pauses[firstAtOrAfter(pauseStarts, previous.elapsedSeconds)] : undefined;
    if (previous && (previous.invalidatedAtElapsedSeconds != null
      && previous.invalidatedAtElapsedSeconds <= sample.elapsedSeconds
      || nextPause != null && nextPause.endElapsedSeconds <= sample.elapsedSeconds
      || trusted && (sample.activeSeconds - previous.activeSeconds > 3
        || sample.elapsedSeconds - previous.elapsedSeconds > 3
        || previous.validUntilElapsedSeconds != null && previous.validUntilElapsedSeconds < sample.elapsedSeconds))) segment += 1;
    const next = ordered[index + 1];
    let endElapsed = Math.min(sample.elapsedSeconds + 3, workout.elapsedDurationSeconds,
      sample.validUntilElapsedSeconds ?? Infinity, sample.invalidatedAtElapsedSeconds ?? Infinity);
    endElapsed = Math.min(endElapsed, intervalStarts[firstAtOrAfter(intervalStarts, sample.elapsedSeconds)] ?? Infinity);
    const validUntil = Math.max(sample.activeSeconds, Math.min(workout.durationSeconds,
      next?.activeSeconds ?? workout.durationSeconds, sample.activeSeconds + Math.max(0, endElapsed - sample.elapsedSeconds)));
    return { ...sample, segment, validUntil };
  });
}

export function resolvedZone(bpm: number, zones: WorkoutPageZone[]): number | null {
  if (bpm <= 0) return null;
  const ordered = [...zones].sort((a, b) => b.zone - a.zone);
  for (const zone of ordered) {
    if (zone.zone === 5 && finite(zone.lowerBPM) && bpm >= zone.lowerBPM) return 5;
    if (zone.zone > 1 && zone.zone < 5 && finite(zone.lowerBPM) && finite(zone.upperBPM)
      && bpm >= zone.lowerBPM && bpm < zone.upperBPM) return zone.zone;
    if (zone.zone === 1 && finite(zone.upperBPM) && bpm < zone.upperBPM) return 1;
  }
  return null;
}

export function hasZoneThresholds(workout: WorkoutPageExport): boolean {
  return [1, 2, 3, 4, 5].every(number => {
    const zone = workout.zones.find(value => value.zone === number);
    return zone != null && finite(zone.lowerBPM) && finite(zone.upperBPM);
  });
}

export function calculateRange(workout: WorkoutPageExport, range: WorkoutRange,
  points = workoutTimeline(workout)): RangeMetrics | null {
  if (!rangeMetricsAvailable(workout)) return null;
  const { start, end } = clampRange(range, workout.durationSeconds);
  let weighted = 0;
  let covered = 0;
  const visible: number[] = [];
  const zoneDurations: Record<number, number> | null = hasZoneThresholds(workout) ? { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 } : null;
  for (const point of points) {
    const weight = Math.max(0, Math.min(end, point.validUntil) - Math.max(start, point.activeSeconds));
    if (point.activeSeconds >= start && point.activeSeconds <= end || point.activeSeconds < start && start < point.validUntil) visible.push(point.bpm);
    if (weight <= 0) continue;
    weighted += point.bpm * weight;
    covered += weight;
    const zone = zoneDurations ? resolvedZone(point.bpm, workout.zones) : null;
    if (zone != null && zoneDurations) zoneDurations[zone] += weight;
  }
  return {
    duration: end - start, coveredDuration: covered,
    average: covered > 0 ? Math.round(weighted / covered) : visible.length ? visible[visible.length - 1] : null,
    minimum: visible.length ? visible.reduce((a, b) => Math.min(a, b)) : null,
    maximum: visible.length ? visible.reduce((a, b) => Math.max(a, b)) : null,
    zoneDurations,
    unassignedDuration: zoneDurations ? Math.max(0, covered - Object.values(zoneDurations).reduce((a, b) => a + b, 0)) : null,
  };
}

// Drawing reduction only. Calculations and downloads always use the unmodified export.
export function plotPoints(points: TimelinePoint[], range: WorkoutRange, buckets = 500): TimelinePoint[] {
  const visible = points.filter(point => point.activeSeconds >= range.start && point.activeSeconds <= range.end
    || point.activeSeconds < range.start && point.validUntil > range.start);
  if (visible.length <= buckets * 4 || range.end <= range.start) return visible;
  const groups = new Map<string, TimelinePoint[]>();
  for (const point of visible) {
    const key = `${point.segment}:${Math.floor((point.activeSeconds - range.start) / (range.end - range.start) * buckets)}`;
    const group = groups.get(key);
    if (group) {
      group[1] = point.bpm < group[1].bpm ? point : group[1];
      group[2] = point.bpm > group[2].bpm ? point : group[2];
      group[3] = point;
    } else groups.set(key, [point, point, point, point]);
  }
  return Array.from(groups.values()).flatMap(group => Array.from(new Map(group.map(point => [point.index, point])).values()))
    .sort((a, b) => a.activeSeconds - b.activeSeconds || a.elapsedSeconds - b.elapsedSeconds || a.index - b.index);
}

export function sampleAt(points: TimelinePoint[], time: number, trusted: boolean): TimelinePoint | null {
  if (!points.length) return null;
  let low = 0;
  let high = points.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (points[middle].activeSeconds <= time) low = middle + 1;
    else high = middle;
  }
  const before = points[low - 1];
  if (trusted) return before && (time < before.validUntil || time === before.activeSeconds) ? before : null;
  const after = points[low];
  if (!before) return after ?? null;
  if (!after) return before;
  return time - before.activeSeconds <= after.activeSeconds - time ? before : after;
}

export function elapsedToActive(workout: WorkoutPageExport, elapsed: number): number {
  const pauses = workout.intervals.filter(interval => interval.kind === 'pause')
    .sort((a, b) => a.startElapsedSeconds - b.startElapsedSeconds);
  let removed = 0;
  let previousEnd = 0;
  for (const pause of pauses) {
    const start = Math.max(previousEnd, pause.startElapsedSeconds);
    removed += Math.max(0, Math.min(elapsed, pause.endElapsedSeconds) - start);
    previousEnd = Math.max(previousEnd, pause.endElapsedSeconds);
  }
  return Math.max(0, Math.min(workout.durationSeconds, elapsed - removed));
}

export function formatDuration(seconds: number, tenths = false): string {
  const value = Math.max(0, finite(seconds) ? seconds : 0);
  const total = Math.floor(value);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor(total % 3600 / 60);
  const remainder = String(total % 60).padStart(2, '0');
  return `${hours ? `${hours}:${String(minutes).padStart(2, '0')}` : minutes}:${remainder}${tenths ? `.${Math.floor(value * 10) % 10}` : ''}`;
}

export function csvCell(value: string | number | null | undefined): string {
  if (value == null) return '';
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : '';
  const safe = /^[\t\r\n]|^\s*[=+\-@]/.test(value) ? `'${value}` : value;
  return `"${safe.replace(/"/g, '""')}"`;
}

export function heartRateCSV(workout: WorkoutPageExport): string {
  const header = 'elapsed_seconds,active_seconds,bpm,valid_until_elapsed_seconds,invalidated_at_elapsed_seconds';
  return `${header}\r\n${workout.samples.map(sample => [sample.elapsedSeconds, sample.activeSeconds, sample.bpm,
    sample.validUntilElapsedSeconds, sample.invalidatedAtElapsedSeconds].map(csvCell).join(',')).join('\r\n')}\r\n`;
}

export function setsCSV(workout: WorkoutPageExport): string {
  const header = 'index,label,kind,start_active_seconds,end_active_seconds,duration_seconds,average_bpm,minimum_bpm,maximum_bpm';
  return `${header}\r\n${workout.sets.map(set => [set.index, set.label, set.kind, set.startActiveSeconds,
    set.endActiveSeconds, set.durationSeconds, set.avgBPM, set.minBPM, set.maxBPM].map(csvCell).join(',')).join('\r\n')}\r\n`;
}

export function workoutJSON(workout: WorkoutPageExport): string {
  return `${JSON.stringify(workout, null, 2)}\n`;
}
