# Apple Watch App Spec (BPM)

Status: draft

## Goals
- watchOS app supports all core iPhone app features
- Works with HR strap either direct-to-watch or via iPhone relay
- Sharing/streaming only supported when connected to phone
- Timer mode keeps large BPM while letting user pick 1-2 extra stats

## Non-goals
- No new features exclusive to watchOS (initially)
- No accelerometer-based HR estimation

## Feature parity (mirror iPhone)
- Live BPM display
- HR max/avg stats (last hour or session)
- Timers (count up + count down as in iPhone)
- HRV (if present in iPhone app)
- Sharing (only when connected to phone)

## Data sources and modes
1) Direct strap -> watch (CoreBluetooth on watchOS)
2) iPhone relay -> watch (WatchConnectivity)
3) Auto mode: prefer direct; fall back to relay
4) Sharing/streaming: phone-only (watch requires relay)

## Connectivity rules
- If strap supports only one central, direct-to-watch and phone cannot be connected at the same time
- App should detect loss and offer “Switch source” prompt
- Persist last successful mode; retry on launch

## UX flows
### Onboarding
- Pick data source: Auto (default), Direct, iPhone relay
- If Direct: scan, show strap list, connect
- If Relay: ensure phone app running and paired, start session sync

### Main BPM screen
- Very large BPM centered
- Below: 1–2 stats (e.g., max, avg, HRV)
- Tap to cycle stats or use crown to scroll secondary stat

### Timer screen
- Primary area: large BPM (always visible)
- Secondary area: timer controls + optional stats
- Buttons: Start/Pause, Reset, Mode (Up/Down)
- Stat selection: long-press or “Customize” button to choose which stat(s) show in timer mode

### Sharing
- Only available when relay/phone connected
- Phone handles share; watch shows status

## Settings (watch)
- Data source: Auto / Direct / Relay
- Strap selection (Direct mode)
- Timer stat selection (1–2 stats)
- Haptics on thresholds (if in iPhone)

## Settings (phone)
- Optional: choose preferred watch data source
- Show watch connection state

## Data model and sync
- Watch session state: source, strap identifier, connection status
- Direct mode: watch stays local; no sharing/streaming
- Relay: phone sends HR samples and derived stats to watch

## Errors and fallback
- Direct connect fails: prompt to switch to relay
- Relay unavailable: prompt to switch to direct
- Low battery or background restrictions: show “Limited mode”

## Performance and constraints
- Keep BLE scan/connection only when in foreground (watchOS rules)
- Use short sampling windows to reduce compute cost
- Avoid frequent UI updates; target 1Hz for BPM text

## Testing
- Simulated HR stream in watch preview
- Manual QA on hardware: direct strap + relay
- Regression test: mode switching retains timer state
