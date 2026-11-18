import test from 'node:test';
import assert from 'node:assert/strict';
import { calculateRange, clampRange, csvCell, descriptionBlocks, elapsedToActive, formatDuration, heartRateCSV,
  panWorkoutViewport, plotPoints, rangeMetricsAvailable, resolvedZone, sampleAt, setsCSV, workoutDateLabel, workoutJSON, workoutPreviewImageURL, workoutTimeline } from '../lib/workout-page-viewer';
import { workoutPageFixture } from '../lib/workout-page-fixture';
import type { WorkoutPageExport } from '../lib/workout-page-schema';

function workout(overrides: Partial<WorkoutPageExport> = {}): WorkoutPageExport {
  return { ...workoutPageFixture(), durationSeconds: 12, elapsedDurationSeconds: 22, summary: { avgBPM: 177, maxBPM: 190, minBPM: 110 },
    samples: [
      { elapsedSeconds: 0, activeSeconds: 0, bpm: 100, validUntilElapsedSeconds: 1 },
      { elapsedSeconds: 1, activeSeconds: 1, bpm: 120, validUntilElapsedSeconds: 4 },
      { elapsedSeconds: 4, activeSeconds: 4, bpm: 180, validUntilElapsedSeconds: 5, invalidatedAtElapsedSeconds: 5 },
      { elapsedSeconds: 18, activeSeconds: 8, bpm: 140, validUntilElapsedSeconds: 21 },
      { elapsedSeconds: 21, activeSeconds: 11, bpm: 160, validUntilElapsedSeconds: 22 },
    ], intervals: [{ kind: 'pause', startElapsedSeconds: 6, endElapsedSeconds: 16 }], sets: [],
    quality: { sampleFidelity: 'full', rangeMetricsAvailable: true, exportedSampleCount: 5, originalSampleCount: 5 }, ...overrides };
}

test('workout date stays on the shared calendar day and older undated exports stay undated', () => {
  assert.equal(workoutDateLabel({ workoutDate: '2026-11-11', recordedAt: '2026-11-12T05:30:00Z' }, 'en-US'), 'November 11, 2026');
  assert.equal(workoutDateLabel({ workoutDate: '2024-02-29' }, 'en-US'), 'February 29, 2024');
  assert.equal(workoutDateLabel({ recordedAt: '2026-11-11T23:30:00-08:00' }, 'en-US'), 'November 11, 2026');
  assert.equal(workoutDateLabel({}, 'en-US'), null);
  assert.equal(workoutDateLabel({ workoutDate: '2026-02-30', recordedAt: 'invalid' }, 'en-US'), null);
});

test('description formatting groups bullet styles, ordered lists and paragraphs without interpreting HTML', () => {
  assert.deepEqual(descriptionBlocks('Warmup\r\nEasy pace\r\n\r\n- First effort\r\n* Second effort\n• Third effort\n  Easy recovery\n\n3. Cooldown\n4) Stretch\n\n<img src=x onerror=alert(1)>'), [
    { kind: 'paragraph', text: 'Warmup\nEasy pace' },
    { kind: 'unordered', items: [{ text: 'First effort' }, { text: 'Second effort' }, { text: 'Third effort\nEasy recovery' }] },
    { kind: 'ordered', items: [{ text: 'Cooldown', number: 3 }, { text: 'Stretch', number: 4 }] },
    { kind: 'paragraph', text: '<img src=x onerror=alert(1)>' },
  ]);
  assert.deepEqual(descriptionBlocks('  \n\t'), []);
  assert.deepEqual(descriptionBlocks('-5 BPM\n1.5 miles'), [{ kind: 'paragraph', text: '-5 BPM\n1.5 miles' }]);
  const blocks = descriptionBlocks(workoutPageFixture().description!);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind === 'unordered' && blocks[0].items.length, 6);
});

test('dragging the zoomed chart moves with the pointer and preserves its time span at both bounds', () => {
  const viewport = { start: 300, end: 900 };
  assert.deepEqual(panWorkoutViewport(viewport, 1800, 100, 500), { start: 180, end: 780 });
  assert.deepEqual(panWorkoutViewport(viewport, 1800, -100, 500), { start: 420, end: 1020 });
  assert.deepEqual(panWorkoutViewport(viewport, 1800, 9000, 500), { start: 0, end: 600 });
  assert.deepEqual(panWorkoutViewport(viewport, 1800, -9000, 500), { start: 1200, end: 1800 });
  assert.deepEqual(panWorkoutViewport({ start: 0, end: 1800 }, 1800, -100, 500), { start: 0, end: 1800 });
  assert.deepEqual(panWorkoutViewport({ start: 0, end: 0 }, 0, 100, 500), { start: 0, end: 0 });
  assert.deepEqual(panWorkoutViewport(viewport, 1800, 100, 0), viewport);
  assert.deepEqual(panWorkoutViewport(viewport, 1800, NaN, 500), viewport);
  assert.deepEqual(viewport, { start: 300, end: 900 });
});

test('preview metadata uses only an explicit well-formed capability and the canonical image endpoint', () => {
  const pageID = '01234567-89ab-cdef-0123-456789abcdef', capability = 'a'.repeat(43);
  assert.equal(workoutPreviewImageURL(pageID, capability), `https://bpmtracker.app/api/workout-pages/${pageID}/preview?p=${capability}`);
  for (const token of [undefined, null, '', 'a'.repeat(42), `${'a'.repeat(42)}&`, [capability], { p: capability }]) {
    assert.equal(workoutPreviewImageURL(pageID, token), null);
  }
  for (const id of ['preview', '../api', pageID.toUpperCase(), [pageID], undefined]) {
    assert.equal(workoutPreviewImageURL(id, capability), null);
  }
});

test('range HR is time weighted, clipped to support and preserves invalidity/pause gaps', () => {
  const value = workout();
  const timeline = workoutTimeline(value);
  assert.deepEqual(timeline.map(point => point.validUntil), [1, 4, 5, 11, 12]);
  const metrics = calculateRange(value, { start: .5, end: 11.5 })!;
  assert.equal(metrics.coveredDuration, 8);
  assert.equal(metrics.average, Math.round((50 + 360 + 180 + 420 + 80) / 8));
  assert.equal(metrics.minimum, 100);
  assert.equal(metrics.maximum, 180);
  assert.equal(sampleAt(timeline, 5.5, true), null);
  assert.equal(sampleAt(timeline, 10, true)?.bpm, 140);
  assert.notEqual(timeline[2].segment, timeline[3].segment);
  assert.equal(value.summary.avgBPM, 177, 'saved summaries are never rewritten by browser calculations');
});

test('support cannot bridge a pause or exceed three seconds even if incoming support is longer', () => {
  const value = workout({ samples: [
    { elapsedSeconds: 4.5, activeSeconds: 4.5, bpm: 120, validUntilElapsedSeconds: 20 },
    { elapsedSeconds: 8, activeSeconds: 6, bpm: 130 }, // inside the pause, excluded from analysis
    { elapsedSeconds: 16, activeSeconds: 6, bpm: 160, validUntilElapsedSeconds: 22 },
  ] });
  const timeline = workoutTimeline(value);
  assert.deepEqual(timeline.map(point => [point.activeSeconds, point.validUntil]), [[4.5, 6], [6, 9]]);
  assert.equal(calculateRange(value, { start: 0, end: 12 })!.coveredDuration, 4.5);
});

test('rapid notifications do not overweight averages and boundary reading preserves extrema', () => {
  const value = workout({ durationSeconds: 1, elapsedDurationSeconds: 1, intervals: [], samples: [
    { elapsedSeconds: 0, activeSeconds: 0, bpm: 100 },
    { elapsedSeconds: .1, activeSeconds: .1, bpm: 200 },
    { elapsedSeconds: 1, activeSeconds: 1, bpm: 220 },
  ] });
  const result = calculateRange(value, { start: 0, end: 1 })!;
  assert.equal(result.average, 190);
  assert.equal(result.coveredDuration, 1);
  assert.equal(result.maximum, 220);
});

test('zone resolution matches iOS outer zones, shared boundaries and custom gaps', () => {
  const zones = workout().zones;
  assert.equal(resolvedZone(60, zones), 1);
  assert.equal(resolvedZone(114, zones), 2);
  assert.equal(resolvedZone(400, zones), 5);
  const gapped = zones.map(zone => zone.zone === 2 ? { ...zone, upperBPM: 125 } : zone);
  assert.equal(resolvedZone(130, gapped), null);
  const value = workout({ zones: gapped, durationSeconds: 3, elapsedDurationSeconds: 3, intervals: [], samples: [{ elapsedSeconds: 0, activeSeconds: 0, bpm: 130 }] });
  assert.equal(calculateRange(value, { start: 0, end: 3 })!.unassignedDuration, 3);
});

test('missing thresholds retain saved zones but disable range zones', () => {
  const value = workout({ zones: [{ zone: 1, durationSeconds: 3 }] });
  assert.equal(calculateRange(value, { start: 0, end: 4 })!.zoneDurations, null);
  assert.equal(value.zones[0].durationSeconds, 3);
});

test('reduced and unknown fidelity never imply coverage or range metrics', () => {
  for (const fidelity of ['reduced', 'unknown'] as const) {
    const value = workout({ quality: { sampleFidelity: fidelity, rangeMetricsAvailable: true, exportedSampleCount: 5 } });
    assert.equal(rangeMetricsAvailable(value), false);
    assert.equal(calculateRange(value, { start: 0, end: 12 }), null);
    assert.equal(sampleAt(workoutTimeline(value), 7, false)?.activeSeconds, 8);
    assert.equal(JSON.parse(workoutJSON(value)).summary.avgBPM, 177);
  }
});

test('active pause conversion merges overlapping intervals', () => {
  const value = workout({ intervals: [{ kind: 'pause', startElapsedSeconds: 2, endElapsedSeconds: 5 }, { kind: 'pause', startElapsedSeconds: 4, endElapsedSeconds: 8 }] });
  assert.equal(elapsedToActive(value, 6), 2);
  assert.equal(elapsedToActive(value, 10), 4);
});

test('downloads retain every sample, fractional timestamps, invalidity and schema metadata', () => {
  const value = workout();
  value.samples[0].elapsedSeconds = .123456;
  assert.deepEqual(JSON.parse(workoutJSON(value)), value);
  const csv = heartRateCSV(value).trim().split('\r\n');
  assert.equal(csv.length, value.samples.length + 1);
  assert.equal(csv[1], '0.123456,0,100,1,');
  assert.equal(csv[3], '4,4,180,5,5');
});

test('CSV quoting prevents user text formulas and preserves quotes, commas and newlines', () => {
  assert.equal(csvCell('hello,"world"\nnext'), '"hello,""world""\nnext"');
  for (const input of ['=1+1', '+SUM(1)', '-1+2', '@a', '\tformula', '\n=1', '  =1']) assert.equal(csvCell(input).startsWith('"\''), true);
  const value = workoutPageFixture();
  value.sets[0].label = '=HYPERLINK("https://example.com")';
  assert.match(setsCSV(value), /"'=HYPERLINK\(""https:\/\/example.com""\)"/);
});

test('plot reduction retains peaks, troughs and separate signal segments without changing raw samples', () => {
  const value = workoutPageFixture();
  const timeline = workoutTimeline(value);
  const points = plotPoints(timeline, { start: 0, end: 1800 }, 40);
  assert.ok(points.length < timeline.length);
  assert.equal(Math.max(...points.map(point => point.bpm)), Math.max(...timeline.map(point => point.bpm)));
  assert.equal(Math.min(...points.map(point => point.bpm)), Math.min(...timeline.map(point => point.bpm)));
  assert.deepEqual(new Set(points.map(point => point.segment)), new Set(timeline.map(point => point.segment)));
  assert.equal(value.samples.length, 1779);
});

test('zero-duration and empty data do not fabricate measurements', () => {
  const value = workout({ durationSeconds: 0, elapsedDurationSeconds: 0, samples: [] });
  const result = calculateRange(value, { start: 0, end: 0 })!;
  assert.equal(result.average, null);
  assert.equal(result.coveredDuration, 0);
  assert.equal(formatDuration(3661.75, true), '1:01:01.7');
  assert.deepEqual(clampRange({ start: NaN, end: Infinity }, 12), { start: 0, end: 12 });
});
