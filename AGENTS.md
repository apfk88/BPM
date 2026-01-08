# Repository Guidelines

## Project Structure & Module Organization
- `BPM/`: SwiftUI iOS app (Bluetooth heart rate display, sharing, HRV, timers).
- `BPMActivityExtension/`: Live Activity extension.
- `Shared/`: Shared Swift models/utilities (e.g., activity models).
- `BPMTests/` and `BPMUITests/`: XCTest unit/UI test targets.
- `backend/`: Next.js sharing API and static marketing site.
  - `backend/pages/api/`: API routes.
  - `backend/public/`: Marketing site + privacy policy.
- `scripts/`: Build helper scripts (e.g., API URL injection).
- `docs/`: Policy and supporting documentation.
- `BPM.xcodeproj`: Xcode project file.

## Build, Test, and Development Commands
- iOS app: open `BPM.xcodeproj` in Xcode, select a real device, `Cmd+R` to run (BLE does not work in the simulator).
- Tests: Xcode `Product → Test` (or `Cmd+U`).
- Backend:
  - `cd backend && npm install` — install dependencies.
  - `npm run dev` — local dev server.
  - `npm run build` — production build.
  - `npm run start` — run built server.
  - `npm run lint` — Next.js linting.
- Script: `./scripts/set-api-url.sh` — updates `BPM/Info.plist` based on git branch.

## Coding Style & Naming Conventions
- Swift: 4-space indentation, Swift API design guidelines, SwiftUI for UI, prefer `@MainActor` for UI code, and use `#if canImport(ActivityKit)` for ActivityKit features.
- Naming: files/types in PascalCase, properties/functions in camelCase (match existing files).
- Backend TS/JS/JSON: 2-space indentation, single quotes, semicolons, file names in lower-case (e.g., `share.ts`).
- No repo-wide Swift formatter; rely on Xcode defaults and existing file style.

## Testing Guidelines
- Use XCTest (`BPMTests/`, `BPMUITests/`). Prefer `*Tests` naming and mirroring the source file structure when adding coverage.
- Backend currently has no test harness; if you add complex logic, consider adding tests and document how to run them.

## Commit & Pull Request Guidelines
- Commit history favors short, imperative summaries (e.g., “Add reset confirmation alert…”, “bump version”).
- PRs should describe changes and testing performed, and link an issue for non-trivial work (README recommends opening an issue first).
- Include screenshots or short clips for UI changes; note any backend/env updates.

## Security & Configuration Tips
- This is a public repo; do not commit secrets or sensitive data.
- Backend requires `KV_REST_API_URL` and `KV_REST_API_TOKEN` in Vercel or `backend/.env.local`.
- API URL selection: staging branches (prefix `staging`) use `https://staging.bpmtracker.app`; other branches use `https://bpmtracker.app`.
- Manual override: set `UserDefaults.standard.set(\"https://your-custom-url.com\", forKey: \"BPM_API_BASE_URL\")`.
- Build phase: add `${SRCROOT}/scripts/set-api-url.sh` before “Compile Sources”.

## Agent-Specific Instructions
- Local agent allowlist (if enforced): `xcodebuild`, `git add`, `git push`, `ls`, `find`. Request additional permissions if needed.

## Note: App Store Connect CLI upload (BPM)
- Archive: `xcodebuild -project BPM.xcodeproj -scheme BPM -configuration Release -destination 'generic/platform=iOS' -archivePath build/BPM.xcarchive archive -allowProvisioningUpdates`
- Export (App Store):
  - ExportOptions.plist:
    - method = app-store (Xcode warns deprecated; can use app-store-connect)
    - signingStyle = automatic
    - stripSwiftSymbols = true
    - uploadSymbols = true
  - `xcodebuild -exportArchive -archivePath build/BPM.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates`
- Upload (ASC API key):
  - Place key at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`
  - `xcrun altool --upload-app -f build/export/BPM.ipa -t ios --apiKey <KEYID> --apiIssuer <ISSUER_ID>`
