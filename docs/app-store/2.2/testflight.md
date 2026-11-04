# BPM 2.2 (20) TestFlight

Prepared November 4, 2026 from the current working tree for app `6754830191`, bundle `kvamme.BPM`.

- Includes live workout trainer controls, shared unsavable HRV, the consolidated Device menu, green sharing indicators, invitation links, connection lifecycle fixes, and the zone-settings recursion fix.
- Validation before archive: 72 focused unit tests and 10 UI tests passed across final runs; 25 backend tests passed; staged/live API checks and running-app trainer flows passed. Physical-device validation remains outstanding.
- Signed archive: `build/BPM-2.2-20.xcarchive`. App and Live Activity extension both verified as 2.2 (20); app API base URL verified as `https://bpmtracker.app`.
- Source hashes: ignored `build/release-testflight-20/source-manifest.json`.
- Upload succeeded November 4 at 9:16 AM PST. Log: `/private/tmp/BPM-2.2-20-Upload.log`.
- Initial 2.1.1 archive upload was rejected because that approved version's train is closed. The accepted upload uses 2.2, retaining build 20.
- Existing internal Dev group has automatic distribution for Xcode builds. Apple processing completed; build `8b5adcb9-1e1e-4fd6-ab6c-6c4c67bee8c3` was verified **Testing**, expiring in 90 days, in the existing Dev group with one tester.
- This request does not submit the app for public App Review.
