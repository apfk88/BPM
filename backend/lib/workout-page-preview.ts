import { createElement as h, type CSSProperties, type ReactNode } from 'react';
import { ImageResponse } from 'next/og';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { WorkoutPageExport } from './workout-page-schema';
import { formatDuration, rangeMetricsAvailable, workoutDateLabel, workoutTimeline, type TimelinePoint } from './workout-page-viewer';

export const WORKOUT_PREVIEW_WIDTH = 1080;
export const WORKOUT_PREVIEW_HEIGHT = 1350;
const MUTED = '#a1a8b3';
let iconData: Promise<string> | undefined;

function appIcon(): Promise<string> {
  // The bundled asset is byte-identical to the iOS AppIcon-1024.png. Next traces this
  // local file into the function; rendering never requests a URL or private third party.
  return iconData ||= readFile(join(process.cwd(), 'public', 'app-icon.png')).then(data => `data:image/png;base64,${data.toString('base64')}`);
}

/** A fixed rendering budget, retaining local extrema and never joining separate signal segments. */
export function previewPlotPoints(workout: WorkoutPageExport): TimelinePoint[] {
  const points = workoutTimeline(workout);
  if (points.length <= 1000) return points;
  const buckets: TimelinePoint[][] = Array.from({ length: 250 }, () => []);
  for (const point of points) {
    const bucket = buckets[Math.min(249, Math.floor(point.activeSeconds / Math.max(1, workout.durationSeconds) * 250))];
    if (!bucket.length) bucket.push(point, point, point, point);
    else {
      if (point.bpm < bucket[1].bpm) bucket[1] = point;
      if (point.bpm > bucket[2].bpm) bucket[2] = point;
      bucket[3] = point;
    }
  }
  return Array.from(new Map(buckets.flat().map(point => [point.index, point])).values())
    .sort((a, b) => a.activeSeconds - b.activeSeconds || a.elapsedSeconds - b.elapsedSeconds || a.index - b.index);
}

// Next's renderer fetches fonts/emoji for missing glyphs and sends their text to an external
// provider. Keep this image local: transliterate accented Latin and omit unsupported glyphs.
// The private page and the native share card keep the full title.
export function previewTitle(title: string): string {
  const local = title.normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[\u2018\u2019]/g, "'").replace(/[\u201c\u201d]/g, '"')
    .replace(/[\u2013\u2014]/g, '-').replace(/\u2026/g, '...')
    .replace(/[^\x20-\x7e]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!local) return 'Workout';
  return local.length > 76 ? `${local.slice(0, 73).trimEnd()}...` : local;
}

function box(style: CSSProperties, ...children: ReactNode[]) {
  return h('div', { style: { display: 'flex', ...style } }, ...children);
}

function chart(workout: WorkoutPageExport) {
  const points = previewPlotPoints(workout);
  const minimum = points.length ? points.reduce((value, point) => Math.min(value, point.bpm), Infinity) : 60;
  const maximum = points.length ? points.reduce((value, point) => Math.max(value, point.bpm), 0) : 160;
  const low = Math.min(150, Math.max(0, Math.floor((minimum - 10) / 50) * 50));
  const high = maximum > 205 ? maximum + 5 : Math.min(205, Math.max(low + 50, Math.ceil((maximum + 10) / 50) * 50));
  const ticks: number[] = [];
  for (let tick = low; tick <= Math.min(200, high); tick += 50) ticks.push(tick);
  const x = (point: TimelinePoint) => 68 + point.activeSeconds / Math.max(1, workout.durationSeconds) * 830;
  const y = (point: TimelinePoint) => 310 - (point.bpm - low) / (high - low) * 275;
  const trusted = rangeMetricsAvailable(workout);
  const path = points.map((point, index) => `${index && points[index - 1].segment === point.segment ? 'L' : 'M'}${x(point).toFixed(1)},${y(point).toFixed(1)}`).join(' ');
  const groups: TimelinePoint[][] = [];
  for (const point of points) {
    const group = groups[groups.length - 1];
    if (group?.[0].segment === point.segment) group.push(point);
    else groups.push([point]);
  }
  const fill = groups.filter(group => group.length > 1).map(group => `${group.map((point, index) => `${index ? 'L' : 'M'}${x(point).toFixed(1)},${y(point).toFixed(1)}`).join(' ')} L${x(group[group.length - 1]).toFixed(1)},310 L${x(group[0]).toFixed(1)},310 Z`).join(' ');
  const dots = points.filter((point, index) => !trusted
    || points[index - 1]?.segment !== point.segment && points[index + 1]?.segment !== point.segment);
  return box({ flexDirection: 'column', height: 390, marginTop: 54 },
    box({ position: 'relative', height: 340 }, h('svg', { width: 912, height: 340, viewBox: '0 0 912 340' },
      h('defs', null, h('linearGradient', { id: 'preview-fill', x1: '0%', y1: '0%', x2: '0%', y2: '100%' },
        h('stop', { offset: '0%', stopColor: '#fff', stopOpacity: .35 }), h('stop', { offset: '100%', stopColor: '#fff', stopOpacity: .01 }))),
      ...ticks.map(tick => h('line', { key: `grid${tick}`, x1: 68, y1: 310 - (tick - low) / (high - low) * 275, x2: 898,
        y2: 310 - (tick - low) / (high - low) * 275, stroke: '#ffffff', strokeOpacity: .1, strokeWidth: 1.5, strokeDasharray: '9 12' })),
      trusted && h('path', { d: fill, fill: 'url(#preview-fill)' }),
      trusted && h('path', { d: path, fill: 'none', stroke: '#ffffff', strokeWidth: 6, strokeLinecap: 'round', strokeLinejoin: 'round' }),
      ...dots.map(point => h('circle', { key: point.index, cx: x(point), cy: y(point), r: 4, fill: '#fff' }))),
    ...ticks.map(tick => h('span', { key: `label${tick}`, style: { position: 'absolute', left: 0,
      top: 293 - (tick - low) / (high - low) * 275, fontSize: 25, color: MUTED } }, String(tick)))),
    box({ justifyContent: 'space-between', paddingLeft: 68, paddingRight: 14, fontSize: 26, color: MUTED },
      h('span', null, '0:00'), h('span', null, formatDuration(workout.durationSeconds))));
}

export async function renderWorkoutPreview(workout: WorkoutPageExport): Promise<Buffer> {
  const icon = await appIcon();
  const title = previewTitle(workout.title);
  const date = workoutDateLabel(workout, 'en-US');
  const metric = (value: string, label: string) => box({ flexDirection: 'column', alignItems: 'center', flex: 1 },
    h('span', { style: { fontSize: 78, letterSpacing: -2 } }, value),
    h('span', { style: { fontSize: 23, letterSpacing: 3.6, color: MUTED, marginTop: 18 } }, label));
  const response = new ImageResponse(box({ width: '100%', height: '100%', padding: 84, flexDirection: 'column',
    color: '#fff', backgroundColor: '#111317', backgroundImage: 'radial-gradient(circle at 100% 0%, #32353a 0%, #111317 72%)',
    borderRadius: 72, border: '3px solid #303237', fontFamily: 'sans-serif' },
  box({ alignItems: 'center' }, h('img', { src: icon, alt: '', width: 96, height: 96,
    style: { borderRadius: 24, border: '2px solid #555860' } }),
    h('span', { style: { marginLeft: 30, fontSize: 39, letterSpacing: 6, fontWeight: 700 } }, 'BPM'),
    h('span', { style: { marginLeft: 'auto', fontSize: 24, color: MUTED, letterSpacing: 4.5 } }, 'WORKOUT')),
  box({ flexDirection: 'column', marginTop: 66, minHeight: 190 },
    h('span', { style: { fontSize: title.length > 42 ? 63 : 81, lineHeight: 1.15, letterSpacing: -2, fontWeight: 700,
      display: 'block', lineClamp: '2 "..."', overflow: 'hidden' } }, title),
    date && h('span', { style: { marginTop: 21, fontSize: 33, color: MUTED } }, date)),
  chart(workout),
  box({ borderTop: '2px solid #36383c', paddingTop: 51, marginTop: 'auto' },
    metric(formatDuration(workout.durationSeconds), 'TOTAL TIME'),
    metric(workout.summary.avgBPM == null ? '-' : String(Math.round(workout.summary.avgBPM)), 'AVG BPM'),
    metric(workout.summary.maxBPM == null ? '-' : String(Math.round(workout.summary.maxBPM)), 'MAX BPM')),
  h('span', { style: { alignSelf: 'flex-end', marginTop: 66, color: MUTED, fontSize: 27 } }, 'bpmtracker.app')),
  { width: WORKOUT_PREVIEW_WIDTH, height: WORKOUT_PREVIEW_HEIGHT, headers: { 'Cache-Control': 'private, no-store' } });
  return Buffer.from(await response.arrayBuffer());
}
