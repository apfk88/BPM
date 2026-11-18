# Private workout pages: validation and release status

## November 12 local sharing changes

Share Chart and Share Stats now open the native share sheet directly. A narrower Customize action appears beside Share for those two card formats; text and logs retain a single Share action. Accessibility text stacks the actions. The optional link, editor-specific title/range changes, successful-share dismissal, and cancellation behavior are preserved.

Short URLs use `/w/<22-character image alias>#<43-character workout key>`, reducing production links from 151 to 91 characters. They retain the existing full-data authorization strength and old URL compatibility. Registration is advertised through optional metadata, so the updated app falls back to legacy URLs on older servers.

The backend production build and all 88 backend tests passed locally with isolated Redis, including alias authorization, staging, old URLs, rotation/deletion, collisions, migration and revocation during reads. A real Chrome session loaded the synthetic workout through the built Next.js short route, confirmed the server-rendered `og:image` alias endpoint, and showed the incomplete-link error when the viewing fragment was removed. These changes have not been deployed or released by this task.

Native verification on the iPhone 18 Pro / iOS 27 simulator passed 25 service tests and 10 unique UI tests across the focused runs. Coverage includes direct chart/stats PNG export, optional short-link creation, saved-link copy/deletion, Customize navigation, format-specific controls, stable consent layout, successful dismissal, cancellation preserving edits, landscape and accessibility text. The native Close test now waits for the sheet's actual close control to settle before tapping once. Pending-upload assertions verify unchanged page identity and private key across activation, allowing the URL to acquire its registered short alias.

Result bundles: `test_sim_2026-11-12T15-45-40-690Z_pid45425_1d04e046.xcresult` (initial UI coverage), `test_sim_2026-11-12T15-49-26-987Z_pid45425_a36f23fd.xcresult` (all six selected UI tests passed; six obsolete pending-URL assertions failed and were then corrected), and `test_sim_2026-11-12T15-52-57-138Z_pid45425_5ad04e50.xcresult` (final 25/25 service tests). The initial UI run's direct-cancel timing failure passed in the second run. The simulator build passed; physical-device receiving-app behavior was not exercised in this task.

November 11, 2026. Hosting and the web viewer are live at `https://bpmtracker.app`. BPM 2.3 (26), including the native UI, staging, development-verification, preview, and history refinements below, is Waiting for Review with manual release. It replaces the earlier build 25 submission. See the [release record](app-store/2.3/release.md).

## Implemented behavior

- The share drawer and card editor share one consent draft. The checkbox defaults off for each new drawer. Its fixed supporting sentence is “Anyone with the link can view and download your workout until you delete it.” There is no Review page or expanding content. Enabling starts a private background upload; the final Share activates it and appends the link. Unactivated drafts expire after 24 hours. Upload errors offer retry or an explicit share-without-link choice. The Share button uses readable progress text: “Uploading workout…” then “Preparing link…”.
- Pages include the full saved workout, title, description, and calendar date; exact workout time is omitted by the current share UI. The published calendar day survives resharing, recovery, and page-detail edits. Card title/range edits remain separate. Settings → Shared Pages provides later shared title/description edits.
- The webpage supports pointer/touch and keyboard scrubbing, zoom, drag pan while zoomed, recorded zones, set focus, and JSON/heart-rate CSV/sets CSV downloads. It preserves known pauses and signal loss and uses saved whole-workout totals. Range inspection and the recording-completeness banner were removed; reduced/unknown histories remain discrete saved samples.
- History shows a private-link status badge and workout-detail URL with Open, Copy, Manage, and Delete. Pending uploads and deletions show status/retry controls without a usable link. Settings → Shared Pages provides open/copy, detail updates, link replacement, deletion, pending upload retry, and recovery-code backup/restore. Page ownership outlives local history. Deleting a workout with a hosted page offers local-only or combined deletion.
- Separate viewing and management keys, encrypted recovery envelopes, App Attest, bounded compressed uploads, immutable private objects, atomic metadata updates, cleanup retries, upload/read limits, operator moderation, and aggregate usage counters are implemented. Uploads fail closed until configured.

## Verified locally

| Check | Result |
| --- | --- |
| iOS Debug simulator build | Passed after final Swift changes |
| Export/privacy/fidelity tests | 13 passed after the calendar-date changes, including timezone boundaries, invalid dates, and older exports without dates |
| Upload/recovery/deletion service tests | 23 passed, including unpublished staging, activation, expiry/retry, cancellation while uploading, changed unpublished drafts, response loss, recovery, and deletion acknowledgment |
| Native App Attest tests | 7 passed: same key/hash Apple retries, expiry, lost registration responses, accurate errors, environment-separated keys, invalid keys, and clock skew |
| Workout storage regression cases | 16 passed |
| Share drawer/card UI tests | 6 unique checks passed across refinement runs; final layout checks confirm 260-point portrait cards, unchanged frames when toggling, consent persistence, and landscape/accessibility controls |
| Web production build | Passed |
| Full backend test suite | 83 passed, zero failures or skips, using isolated real Redis; includes staged activation, replacement, expiry, deletion/cleanup races, legacy publication, strict App Attest verification, image-token isolation/revocation, and PNG rendering |
| Desktop and 390 × 844 mobile browser | Scrub, keyboard access, zoom/drag pan, zones, set focus, reduced/unknown data, no-HR/zero-duration handling, missing fragment; latest hosted pass confirms removed range UI/banner and matching homepage branding |
| Download fidelity | Synthetic fixture: 1,779 JSON samples, 1,779 CSV rows, seven sets; every CSV reading matched JSON |
| Browser through actual HTTP API | Production page shell, isolated real Redis, in-memory private-object adapter: authenticated read, downloads, deletion, then unavailable page/404 |

Native test artifacts are under `~/Library/Developer/XcodeBuildMCP/workspaces/BPM-1a5198e4ed5c/`. Browser reports, screenshots, and synthetic downloads are under `build/workout-pages-validation/` (ignored build artifacts). Backend integration tests use real isolated Redis, injected object storage, and code-only test attestation dependencies. No production request header or environment variable bypasses App Attest.

The service/attestation run passed all 29 tests with zero failures or skips: `test_sim_2026-11-11T23-34-57-631Z_pid54909_fa2f0758.xcresult`. The 13 export tests and four existing card tests passed in the earlier refinement run. The final service pass added the background-upload wait/activation case and passed 23/23: `test_sim_2026-11-11T23-43-00-848Z_pid54909_6fad89ca.xcresult`. The final compact drawer geometry test passed with full-size cards and unchanged frames: `test_sim_2026-11-11T23-48-27-562Z_pid10069_742b7424.xcresult`. Share sits 12 layout points below the disclosure. The portrait card remains 260 layout points; UIKit applies its normal slight scale to compact sheets, yielding about 250 screen points on the test device. Test helpers explicitly scroll controls above the Share footer and scope editor queries to avoid its underlying drawer. Screenshot: `build/workout-pages-validation/share-drawer-fixed.png`. In total, 49 unique focused native checks passed across these runs.

The final backend regression pass covers deletion before a delayed create enters the service, deletion during its object upload, deletion racing an update, revocation during object reads and usage bookkeeping, expired abandoned-object cleanup, and invalid view keys leaving legitimate page quotas untouched. Absent-page cancellations are owner-scoped and expire after 24 hours; the API's request duration is capped at 60 seconds. Already-published pages retain durable deletion tombstones.

The backend was upgraded from Next.js 14.2.35 to 15.5.29, with PostCSS 8.5.32. Dependency audits report zero known vulnerabilities. Both the local production build and Vercel build passed; the deployed runtime uses Node 22.

## Production hosting verification

- Promoted the staged production build `dpl_Co79oXYcG51oDkJ3tGLZtDkYgB9j` after hosted verification. Private Blob and functions run in `iad1`; page metadata has no expiry and Redis uses `noeviction`.
- A synthetic 30-minute workout retained all 1,779 readings, seven sets, its calendar date, and six description bullets. The compressed object was 17,219 bytes. Desktop and 390-pixel mobile rendering, keyboard scrub, zoom, JSON/CSV downloads, and absence of viewer analytics were checked on the hosted build.
- Viewing without the correct key failed. Link replacement invalidated the old key. Deletion immediately revoked viewing, and uncached origin reads plus object listing confirmed removal. The private Blob URL itself rejected unauthenticated access with HTTP 403.
- Production challenge creation works, while unsigned uploads are rejected. The fixture was seeded through the administrative server code using synthetic data; real-device App Attest upload is still unverified.
- Vercel Cron is active every six hours and a platform-triggered run returned HTTP 200 at `2026-11-11T18:20:44Z`. No runtime errors were found in the post-deployment scan. No external log/trace drains are configured.
- A synthetic example remains hosted for visual review. Its management credentials are saved only in ignored, mode-0600 `build/workout-pages-validation/private-demo-management.json`. Validation records and screenshots are in the same ignored artifact directory.

### November 11 indexing and footer update

Deployed and promoted `dpl_J6wgpSgMDrqDcFLbAgBKNAHxTB9M` (`bpm-chiyw5edc-kvamme-team.vercel.app`). The footer now reads: “This workout is private. Only people with the link can view it.” Both `/w/*` and `/join/*` carry robots metadata and `X-Robots-Tag: noindex, nofollow, noarchive, nosnippet`. The response header also covers share APIs, workout-page APIs, and the join page's Next.js JSON data representation, including error responses.

Verified 14 live route/response cases with a crawler user-agent, checked the `www` redirects, and confirmed that the marketing homepage remains indexable. Private pages are absent from public site navigation and there is no sitemap exposing them. The production build and all 61 backend tests passed; the new deployment's runtime-error scan was empty. Details: `build/workout-pages-validation/indexing-validation.json`.

### November 11 background uploads and development verification refinement

Promoted `dpl_ChAAqQUq8tb8JgB562z9tqDVct9S` (`bpm-j9xm5sbq0-kvamme-team.vercel.app`) after the 73-test backend suite and production build passed. The live activation endpoint rejects missing owner credentials and absent drafts, and unsigned uploads remain rejected. Six live route cases retain `noindex`; the public homepage remains indexable. No runtime errors appeared in the immediate deployment log scan. The public privacy explanation now describes opt-in background drafts and final-share activation. Report: `build/workout-pages-validation/staging-hosted-routes.json`.

Both native configurations use production App Attest. The server accepts cryptographically valid development-signed builds for BPM's configured app identity while still rejecting development-environment proofs, wrong app identities, invalid signatures, and replayed assertions. Error handling no longer calls every rejected proof “expired”; Apple temporary retries reuse the same key and client-data hash. A rebuilt physical development app still needs end-to-end verification. The hosted checks did not exercise an actual signed device upload.

### November 11 rich link previews and viewer/history refinement

Promoted `dpl_2Tn3quiQpvcRUQRTegt3Ds79tDvx` (`bpm-en06nszw9-kvamme-team.vercel.app`) after all 83 backend tests and both local/Vercel production builds passed. Staged and live-domain checks each passed nine response cases: generic legacy link, image-capability HTML and Next.js data, valid 1080 × 1350 PNG, invalid/missing preview tokens, preview tokens denied workout JSON, and the original full-workout credential retaining all 1,779 samples. HTML and Next.js data contain no workout payload or full viewing key. Sensitive routes retain no-store, noindex, and no-referrer.

Hosted desktop and 390-pixel mobile checks confirm the warning and range-inspection panel are absent, the logo matches the homepage, zoomed pointer drag preserves the 900-second viewport while moving through the workout, keyboard pan works, and the mobile page has no horizontal overflow. Chart interaction performs no extra workout reads. No page errors or analytics requests occurred, and the post-deployment runtime-error query returned no entries. Reports and images: `build/workout-pages-validation/rich-preview-hosted-production.json`, `rich-viewer-production.json`, `hosted-rich-preview.png`, and `rich-viewer-{desktop,mobile}.png`.

The focused native pass verified 24 service tests, 14 card/snapshot tests, and two drawer tests. All three new history/detail UI flows then passed after removing a container accessibility identifier that masked child controls: published links copy the full URL (verified by pasting inside BPM), open management, and delete the hosted page while retaining the workout; pending creation exposes no link until activation; pending deletion exposes retry without Open/Copy. Latest published-link UI result: `test_sim_2026-11-12T00-16-49-580Z_pid10069_2dc3a869.xcresult`. Pending-state UI results: `test_sim_2026-11-12T00-13-46-588Z_pid10069_82a8d6da.xcresult`. This totals 43 focused native checks across the refinement runs. Screenshots: `build/workout-pages-validation/workout-history-private-link.png` and `workout-detail-private-link.png`.

Card sharing now sends one URL; native link metadata carries the exact selected PNG. The separate image capability permits a fetched full-workout chart card without authorizing detailed workout data. Existing pages need no migration or new upload; re-sharing derives the preview token and reuses the active page. Receiving apps choose whether to use the selected native image or fetched default card. Actual Messages/Mail receiving behavior and physical touch gestures remain unverified. Cached recipient previews can survive deletion. These native changes are included in build 26, now submitted for review; they were absent from the earlier build 25.

### Earlier BPM 2.3 (25) submission, superseded by build 26

- The archive and Apple upload succeeded. The signed app and extension report version 2.3 build 25. The archive has the production API URL, App Attest entitlement, valid signatures, and both dSYMs.
- All 424 iOS test executions passed, including two workout page UI tests. Evidence: `build/release-appstore-25/release-tests.xcresult`.
- At its original submission, App Store Connect showed **Waiting for Review** for build `faba3fcd-fcdb-4c69-98c7-6f64d711be3f`. This submission was later withdrawn and replaced by build 26. [App Review receipt](https://appstoreconnect.apple.com/apps/6754830191/distribution/reviewsubmissions/details/a59fc4a0-d982-43b6-8661-76c23e8d0ac5). Release notes and the reviewer walkthrough are saved. The existing release remains live while the newer version goes through review and manual release.
- The label already covered Health, Fitness, and Other User Content as linked data used for app functionality. During the later build 26 resubmission, User ID was added for the random page-owner identifier; App Functionality and linked status were added to Device ID for App Attest while preserving Analytics. These corrections are published. Neither identifier is used for tracking.

### BPM 2.3 (26) resubmission

The final signed app and extension are version 2.3 build 26. All 438 unit tests passed with zero failures or skips; the final focused UI checks also passed. Archive and App Store distribution export checks verified production settings, signatures, matching dSYMs, excluded debug fixtures, and 104 unchanged source files. Upload succeeded at 4:40:50 PM PST on November 11.

App Store Connect confirms **Waiting for Review**, build `026241dc-347f-4b75-a001-3e783d8028a4`, with manual release selected. The prior build 25 was withdrawn. Updated reviewer notes, release notes, and privacy answers were saved and verified. [App Review receipt](https://appstoreconnect.apple.com/apps/6754830191/distribution/reviewsubmissions/details/828de2d2-878b-4470-839e-1074e1ad58e0). Physical-device and receiving-app checks below remain separate from successful upload/submission.

## Before release

1. Review provider backup/recovery retention and any dedicated incremental-feature spending alerts using [operations](workout-web-sharing-operations.md). Hosting, private storage, production secrets, App ID prefix, and scheduled cleanup are configured and verified.
2. On a physical supported iPhone, verify real App Attest registration and assertions, upload a synthetic workout, read it from a second browser/device, update it, rotate its link, and delete it. Repeat with the intended TestFlight signing environment. Real Blob reads/removal passed separately; the complete signed-app path remains unverified.
3. Send chart, stats, text, and logs through Messages and Mail. Verify cards send one URL with a preview and that the preview query and viewing fragment survive each destination; test Copy Link. Confirm which destinations honor selected-image metadata versus the fetched full-workout chart card. Simulator automation does not establish receiving-app behavior or physical Safari touch handling.
4. Verify recovery on a second installation, including multiple recovered owners and an unavailable server. Exercise VoiceOver/Dynamic Type on Shared Pages and recovery screens.
5. Measure representative long-workout payloads and production latency/cost, then confirm limits against actual usage.
App Store Connect privacy answers were published and verified during the build 26 resubmission: Health, Fitness, Other User Content, and User ID are linked for App Functionality; Device ID is linked for App Functionality and Analytics. No tracking. See the [2.3 release record](app-store/2.3/release.md).

Reviewer walkthrough: record or open a saved Bluetooth-sensor workout; open Share; enable **Include private workout link**; press Share to activate the uploaded draft; open the link in a browser and download recorded data; open Settings → Shared Pages; replace the link and confirm the old one fails; delete the page and confirm it is unavailable. Explain that shared data is opt-in, is accessible to anyone holding the link, has no automatic expiration, and can be removed independently of local workout history.
