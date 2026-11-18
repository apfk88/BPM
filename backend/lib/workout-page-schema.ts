// Public, versioned allowlist. No local UUIDs, HealthKit metadata, or profile inputs.
export interface WorkoutPageSample {
  elapsedSeconds: number;
  activeSeconds: number;
  bpm: number;
  validUntilElapsedSeconds?: number | null;
  invalidatedAtElapsedSeconds?: number | null;
}
export interface WorkoutPageInterval {
  startElapsedSeconds: number;
  endElapsedSeconds: number;
  kind: 'pause' | 'signalLoss';
}
export interface WorkoutPageSet {
  index: number;
  label: string;
  kind: 'work' | 'rest' | 'cooldown';
  startElapsedSeconds: number;
  endElapsedSeconds: number;
  startActiveSeconds: number;
  endActiveSeconds: number;
  durationSeconds: number;
  avgBPM?: number | null;
  minBPM?: number | null;
  maxBPM?: number | null;
}
export interface WorkoutPageZone {
  zone: number;
  durationSeconds: number;
  lowerBPM?: number | null;
  upperBPM?: number | null;
}
export interface WorkoutPageExport {
  schemaVersion: 1;
  calculationVersion: 1;
  title: string;
  description?: string | null;
  workoutDate?: string | null;
  recordedAt?: string | null;
  durationSeconds: number;
  elapsedDurationSeconds: number;
  summary: {
    avgBPM?: number | null;
    minBPM?: number | null;
    maxBPM?: number | null;
    calories?: number | null;
    activeCalories?: number | null;
    recoveryBPM?: number | null;
  };
  samples: WorkoutPageSample[];
  intervals: WorkoutPageInterval[];
  sets: WorkoutPageSet[];
  zones: WorkoutPageZone[];
  quality: {
    sampleFidelity: 'full' | 'reduced' | 'unknown';
    exportedSampleCount: number;
    originalSampleCount?: number | null;
    rangeMetricsAvailable: boolean;
  };
}

export function validWorkoutDate(value: unknown): value is string {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value) || value.startsWith('0000')) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

export interface WorkoutPageMetadata {
  pageID: string;
  version: number;
  createdAt: string;
  updatedAt: string;
  viewKeyRecovery: string;
  linkCode?: string;
  staged?: true;
  stageID?: string;
  stageExpiresAt?: string;
}
