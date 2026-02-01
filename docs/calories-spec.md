# Calories Estimation Spec (HR-only)

Status: draft

## Goals
- HR-only calories estimate (no accelerometer)
- Use detailed user info if provided; work with minimal inputs
- Provide confidence score and method used

## Non-goals
- No motion fusion
- No medical-grade claims
- No required VO2max/RMR/body fat inputs

## Required inputs
- weight_kg
- age_years
- hr_samples: list of {timestamp, bpm}

## Optional inputs (used if present)
- sex_at_birth (for sex-specific HR regression)
- height_cm
- hr_rest_bpm
- hr_max_bpm (measured)
- vo2max_ml_kg_min
- rmr_kcal_day (measured)
- body_fat_pct
- activity_type (Compendium code or label)
- meds_affecting_hr (beta blockers, etc)

## Data sources
- Manual entry in app
- HealthKit read (opt-in): weight, height, resting HR, VO2max, body fat, RMR

## Preprocessing
- Drop HR outliers (<30 bpm or >230 bpm) unless user opts into athlete range
- Smooth: 5s rolling median, then 15s EMA
- Mark gaps >30s; do not interpolate across gaps

## Defaults
- hr_max_bpm: use measured; else fallback 208 - 0.7 * age_years
- hr_rest_bpm: use measured; else nightly lowest rolling 5-min avg (7-day window)
- vo2_rest_ml_kg_min: if rmr_kcal_day provided, convert; else 3.5 (1 MET)

## Model selection (priority)
1) Model A: HRR -> %VO2R (requires hr_rest, hr_max, vo2max)
2) Model B: HR regression (requires age, weight, HR; sex optional)
3) Optional sanity check: activity_type MET_ref to clamp/blend

## Model A (HRR -> VO2 -> MET)
- HRR = hr_max_bpm - hr_rest_bpm
- pctHRR = clamp((HR - hr_rest_bpm) / HRR, 0..1)
- VO2 = vo2_rest + pctHRR * (vo2max - vo2_rest)
- MET = VO2 / vo2_rest
- kcal_min_gross = MET * 3.5 * weight_kg / 200
- kcal_min_net = kcal_min_gross - (1 * 3.5 * weight_kg / 200)

## Model B (HR regression)
Sex-specific coefficients if sex_at_birth known; else average M/F and lower confidence.

Example form:
if male:
  kcal_min = 0.239 * (-55.097 + 0.631*HR + 0.199*weight_kg + 0.202*age_years)
else:
  kcal_min = 0.239 * (-20.402 + 0.447*HR - 0.126*weight_kg + 0.070*age_years)

## Optional MET sanity check
- If activity_type provided, compute MET_ref from Compendium
- If HR-based MET is far outside expected range, clamp or lightly blend toward MET_ref

## Outputs
- active_kcal (gross - resting)
- total_kcal (gross)
- method_used: hrr_vo2 | hr_regression | hr_regression_unsexed
- confidence: 0..1
- hr_sample_count, gap_count

## Confidence scoring (example)
- Base 0.5
- +0.2 if measured hr_max_bpm
- +0.2 if vo2max_ml_kg_min
- +0.1 if rmr_kcal_day
- -0.2 if sex_at_birth missing for regression
- -0.2 if meds_affecting_hr
- clamp 0..1

## Storage
- UserEnergyProfile (local): required + optional inputs
- CaloriesSession: start_at, end_at, totals, method_used, confidence

## UI/UX
- Settings -> Calories: required fields + Advanced (optional fields)
- Hint: "More detail = better accuracy"
- Confidence label: Low/Med/High with "why" sheet

## Edge cases
- hr_max_bpm <= hr_rest_bpm: block HRR model, fallback
- Missing required fields: disable calories, show prompt
- Sparse HR (<5 min usable): show "insufficient data"

## Testing
- Unit: model selection, HRR math, regression math, confidence
- Regression fixtures with known outputs
- UI: required/optional gating
