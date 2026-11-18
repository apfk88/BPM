import type { WorkoutPageExport } from './workout-page-schema';

// Synthetic values only. The browser fixture endpoint is disabled outside local development.
export function workoutPageFixture(fidelity: 'full' | 'reduced' | 'unknown' = 'full'): WorkoutPageExport {
  const original = Array.from({ length: 1800 }, (_, second) => ({
    activeSeconds: second, elapsedSeconds: second + (second >= 900 ? 60 : 0),
    bpm: Math.round(112 + Math.sin(second / 85) * 14 + Math.min(36, second / 35) - Math.max(0, second - 1500) / 10),
    validUntilElapsedSeconds: second + 1 + (second >= 900 ? 60 : 0),
    ...(second === 598 ? { invalidatedAtElapsedSeconds: 599 } : {}),
  })).filter(sample => sample.activeSeconds < 599 || sample.activeSeconds >= 620);
  return {
    schemaVersion: 1, calculationVersion: 1, title: 'Intervals & a steady finish',
    workoutDate: '2026-11-11',
    description: '- Three controlled work intervals\n- Easy recovery between efforts\n- Held a steady pace through the middle\n- One short pause for water\n- Five-minute cooldown to finish\n- Synthetic preview. No personal data.',
    durationSeconds: 1800, elapsedDurationSeconds: 1860,
    summary: { avgBPM: 142, minBPM: 111, maxBPM: 162, activeCalories: 312, recoveryBPM: 28 },
    samples: fidelity === 'full' ? original : original.filter((_, index) => index % 15 === 0),
    intervals: [{ kind: 'pause', startElapsedSeconds: 900, endElapsedSeconds: 960 },
      ...(fidelity === 'full' ? [{ kind: 'signalLoss' as const, startElapsedSeconds: 599, endElapsedSeconds: 620 }] : [])],
    sets: Array.from({ length: 7 }, (_, index) => ({ index, label: index === 6 ? 'Easy finish' : `Interval ${Math.floor(index / 2) + 1}`,
      kind: index === 6 ? 'cooldown' as const : index % 2 ? 'rest' as const : 'work' as const,
      startActiveSeconds: index * 250, endActiveSeconds: index === 6 ? 1800 : (index + 1) * 250,
      startElapsedSeconds: index * 250 + (index * 250 >= 900 ? 60 : 0),
      endElapsedSeconds: (index === 6 ? 1800 : (index + 1) * 250) + ((index + 1) * 250 >= 900 ? 60 : 0),
      durationSeconds: index === 6 ? 300 : 250, avgBPM: 132 + index * 2, minBPM: 111 + index, maxBPM: 158 + Math.min(index, 4) })),
    zones: [0, 310, 1049, 420, 0].map((durationSeconds, index) => ({ zone: index + 1, durationSeconds, lowerBPM: 95 + index * 19, upperBPM: 114 + index * 19 })),
    quality: { sampleFidelity: fidelity, rangeMetricsAvailable: fidelity === 'full', originalSampleCount: fidelity === 'unknown' ? undefined : original.length,
      exportedSampleCount: fidelity === 'full' ? original.length : Math.ceil(original.length / 15) },
  };
}
