# BPM 2.1.1 (19)

Prepared October 30, 2026 for App Store Connect app `6754830191`, bundle `kvamme.BPM`.

## Scope

Heart-rate acquisition/freshness, HRV summaries and coverage, calorie formulas and time accounting, pause/contact-loss boundaries, timestamp precision, saved summaries, sharing freshness, custom zones, and Apple Health export. See `docs/measurement-accuracy.md` for defects, fixes, and remaining physical validation.

## Validation and distribution

- Final measurement suite: 233 tests passed, zero failures/skips. Result: `/Users/kvamme/Library/Developer/XcodeBuildMCP/workspaces/BPM-1a5198e4ed5c/result-bundles/test_sim_2026-10-30T13-33-28-307Z_pid83587_d0a730a0.xcresult`.
- Unsigned device Release build passed; simulator build/run and affected settings screens checked.
- Signed archive succeeded: `build/BPM-2.1.1-19.xcarchive`. App and activity extension verified as 2.1.1 (19), production API URL, ten sounds, and privacy manifest.
- Archived production source matches `build/release-accuracy-20261030/source-manifest.json`.
- App Store Connect version 2.1 was verified Ready for Distribution. Created 2.1.1, saved release/review notes, and retained automatic release after approval and immediate rollout.
- Upload succeeded October 30 at 6:43 AM PDT; log `/tmp/BPM-2.1.1-19-Upload.log`. Apple made build 19 Ready to Submit; build ID `66118e8d-f5e4-461c-acd0-57e4a326a945`. Build 19 attached and saved to version 2.1.1.
- Submitted October 30 at 6:53 AM PDT and verified **Waiting for Review**, with automatic release after approval. Submission ID: `4b791929-4f8b-4a4b-9b66-acdc4042befc`.
- Review page: https://appstoreconnect.apple.com/apps/6754830191/distribution/reviewsubmissions/details/4b791929-4f8b-4a4b-9b66-acdc4042befc
- No Git commit/push or backend deployment performed. Physical strap acceptance remains outstanding.

## What's New

• Improved heart-rate handling during sensor changes, pauses, and connection loss.
• More consistent heart-rate averages, HRV summaries, and saved workout charts.
• Corrected calorie calculations and clearer calorie-estimate labeling.
• Improved saved timing precision and Apple Health export.
