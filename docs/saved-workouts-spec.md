# Saved Workouts Spec

Status: draft

## Goals
- Let users save completed workouts from timer end screen
- Provide history list from Timer view (top icon)
- Expandable workout rows with full detail + share actions
- Export detailed history for LLM use (JSON)
- Optional HealthKit sync for workouts, HR samples, and calories (phase 2)
- Optional account (Sign in with Apple) for cloud sync (phase 3)

## Non-goals
- No social feeds or leaderboards
- No auto-save without user consent (initially)
- No required account to use core app
- No HealthKit import (out of scope)

## Entry points
- Timer end screen: "Save workout" CTA
- Timer view top icon: open History menu
- Settings: Login/Logout + History management
- Settings: HealthKit sync toggle + permissions
- Optional startup screen: “Want to save workouts?” with Sign in with Apple

## Save flow
1) Workout ends -> show summary + "Save workout"
2) If not logged in:
   - Show lightweight prompt: "Save locally" or "Sign in to sync"
3) Prompt for optional title
4) Persist workout locally immediately
5) If HealthKit enabled (phase 2), write workout + samples to HealthKit
6) If logged in (phase 3), queue for cloud sync

## History UI (Timer top icon)
- Icon opens a sheet/menu with list of past workouts
- Row shows: date, duration, avg HR, max HR, calories (if enabled)
- Tap row expands for details:
  - Start/end time
  - Duration
  - Avg/Max HR
  - HRV (if recorded)
  - Calories (if enabled)
  - Time in zones (if available)
  - Notes (optional)
  - Share: image summary + JSON export + CSV (optional)
- Search/filter (phase 2): by date range, type, duration

## Data model
Workout
- id (uuid)
- start_at, end_at
- duration_seconds
- title (optional)
- avg_hr, max_hr
- hrv (optional)
- calories_total, calories_active (optional)
- hr_samples: [{t, bpm}] (optional; may be chunked)
- hrv_samples (optional)
- notes (optional)
- source: phone | watch
- app_version
- healthkit_workout_id (optional)
- healthkit_sync_status: pending | synced | failed
- healthkit_last_sync_at (optional)
- created_at, updated_at

## Storage
Local (default)
- Store workouts in local database/file (CoreData or SQLite)
- Keep 30–90 days by default; user can change retention

Cloud (phase 3)
- Sign in with Apple for account creation
- Cloud sync via backend (KV/DB) or CloudKit (decision needed)
- Conflict strategy: last-write-wins on metadata; merge samples by timestamp
- Background sync when app opens + on manual refresh

HealthKit (phase 2)
- If enabled, write workouts to HealthKit after local save
- HealthKit is not the source of truth; local DB remains canonical
- Retry failed HealthKit writes on next app launch or manual retry

## HealthKit sync (phase 2)
Permissions (opt-in)
- Write: Workouts, Heart Rate, Active Energy Burned
- Read (phase 2): Workouts, Heart Rate, Active Energy Burned

Write mapping
- Workout: HKWorkout with start/end time, activity type (default: .other)
- Heart rate samples: HKQuantitySample(.heartRate) with timestamps
- Calories: HKQuantitySample(.activeEnergyBurned) using calories_active when available
- Metadata: store workout id + app version as HK metadata

Import
- Not planned

## Auth UX
- Settings -> Account
  - Sign in with Apple / Sign out
  - Sync status + last sync time
- Startup optional screen (one-time):
  - "Save workouts across devices?"
  - Actions: "Not now" | "Sign in with Apple"
- Gate history viewing/saving:
  - If not logged in: allow local history
  - If logged in: enable cross-device

## Export
- JSON export (primary)
  - Full workout list or selected workout
  - Include schema version
  - One file per export
- Optional CSV export (summary fields only)
- Share sheet from expanded workout view or history menu

## Settings additions
- Calorie Tracking (existing)
- Workouts
  - Save workouts: always on (no toggle)
  - Retention: fixed 365 days (no setting)
  - Export history
- Account
  - Sign in/out (Apple)
  - Sync status
- HealthKit
  - Sync to HealthKit: On/Off
  - Permissions status

## Edge cases
- User deletes workout locally: remove from cloud if logged in
- User deletes workout locally: remove HealthKit record if synced (best-effort)
- Large HR sample sets: chunk storage and export
- Low storage: show warning before saving
- HealthKit permission denied/revoked: mark status, disable sync

## Testing
- Unit: save/restore, export JSON schema, retention cleanup
- UI: save flow, history expand/collapse, login gating
- Sync: offline save -> later upload
- HealthKit: permission flow + write failures
