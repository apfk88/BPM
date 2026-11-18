# Website changelog

Public URL: https://bpmtracker.app/changelog

The page is static HTML in `backend/public/changelog.html`, with page-specific styles in `backend/public/changelog.css`. `backend/next.config.js` maps the clean URL to the HTML file. The homepage navigation and the homepage/privacy footers link to it. It remains readable without JavaScript.

## Updating a release

1. Add a newest-first `article.release` with a stable version anchor, such as `v2-2`, and a unique heading ID. Explain changes in user-facing terms, using the actual release scope rather than every intervening commit.
2. Keep submitted builds labeled as awaiting review until App Store Connect or the public App Store confirms distribution. Submission and release dates are separate. Update the pending notice and the latest-release badge when availability changes.
3. Record release dates in Pacific time, consistently with this page. Do not infer a release date from a Git commit or archive.
4. Keep older entries intact. Brief maintenance releases can stay brief when no more specific record exists.
5. Bump the query version for any changed stylesheet because production CSS is cached as immutable. Verify the clean route, homepage links, version anchors, and desktop/320px layouts before publishing. Use the existing BPM Vercel project and verify the live domain after promotion.

## Initial history sources, November 9, 2026

- Apple's public App Store version history supplied notes and release timestamps for the 25 releases from 1.4 through 2.1.1. UTC timestamps were converted to `America/Los_Angeles` dates. Source: https://apps.apple.com/us/app/bpm-heart-rate-monitor/id6754830191.
- App Store Connect History verified 1.3 as Ready for Distribution on November 13, 2025, and 1.1.4 and 1.1.3 on November 8, 2025. Apple's earlier public version history supplied the 1.3 and 1.1.4 notes. Version 1.1.3 is identified only as the first public release; no unsupported feature details were added.
- Recent entries were expanded using `docs/app-store/2.0.10/metadata.md`, the release records from 2.0.11 through 2.2, and `docs/measurement-accuracy.md`.
- Version 2.2 (24) was verified Waiting for Review on November 9. It is shown separately from the 28 shipped releases.
- The original public-history extract and deployment verification are retained under ignored `build/changelog/`.

## Publication verification

Published November 9, 2026 to `bpmtracker.app` through production deployment `dpl_DeU4NYtfvxkcVkTCzfqKs5mTCZo2` (READY). The production build passed. Six public routes matched source on both the staged deployment and the live domain, and the existing sharing API still rejected invalid codes correctly. Desktop and 320px mobile layouts, version anchors, and the homepage-to-changelog link were verified. The initial deployment error scan returned no entries. Evidence: `build/changelog/release-summary.json` and `live-desktop.jpg`.

## Version 2.2 approval

App Store Connect History verified version 2.2 as Ready for Distribution on November 9, 2026 at 2:09 PM PST. The changelog now dates it November 9, labels it the latest release, and removes the review-pending notice. Version 2.1.1 remains in the history. Publication verification for this status update is recorded under `build/changelog-approved/`.

The public App Store listing independently confirmed version 2.2. Website production deployment `dpl_GxAtFTQeL8qUbAA38BgKwcoGF44d` passed its build, staged/live source comparisons, and visual verification. The update changed only `backend/public/changelog.html` in the deployment; there are now 29 released versions. The error scan returned no entries.

## Sharing history and navigation correction

Alex clarified that live sharing has existed since BPM's first release. Version 2.2 rebuilds sharing across the app's features, especially workouts. The 2.2 heading and introduction now explain that distinction, and the first-release entry explicitly includes live heart-rate sharing. The top jump-link row was removed at Alex's request; version permalink anchors remain.

Published and verified on the live domain through production deployment `dpl_2kddGhSwiS34UWwb1GxpohfEVXTy`. The build passed, staged/live routes matched source, and desktop/320px mobile views showed the corrected copy without the jump row or horizontal overflow. Evidence: `build/changelog-sharing/release-summary.json` and `live-desktop.jpg`.
