# Sharing analytics

Workout and HRV exports use the existing TelemetryDeck app and namespace (`com.siav`). Live heart-rate sharing retains its existing `share_on` and `share_off` events.

| Event | Trigger |
| --- | --- |
| `share_picker_opened` | Workout share picker appears for the first time in that presentation |
| `share_format_selected` | Picker selection changes via swipe, dots, or a card tap |
| `share_export_requested` | User taps the final export action, before preparing an image or file |
| `share_export_presented` | Native share sheet appears |
| `share_export_completed` | UIKit completion callback reports success without an error |
| `share_export_cancelled` | UIKit reports cancellation, or SwiftUI removes the sheet without a terminal callback |
| `share_export_failed` | Image/file preparation fails or UIKit reports an error |

Each event contains only fixed `source` and `format` labels:

- Sources: `post_save`, `workout_detail`, `workout_history`, `hrv_detail`, `hrv_history`.
- Formats: `chart_card`, `stats_card`, `plain_text`, `logs`.

Card editors count a request only when their Share button is tapped. Opening an editor does not count as an export. Bulk history exports use the history source; exports of an individual record use the detail source. The picker-open event includes its initial format. Selection changes measure browsing, not export intent.

One export attempt produces at most one presentation event and one terminal outcome. Preparation failures produce requested + failed without a presentation. A successful callback followed by sheet teardown produces completed only. Completion is the native activity result, not proof of recipient delivery.

No titles, descriptions, health values, record IDs, share content, filenames, destinations, or error details are supplied to TelemetryDeck. Existing SDK metadata, test-mode behavior, and analytics-disabled handling are unchanged. Debug builds use TelemetryDeck's test mode; production ingestion must be checked in the dashboard with real build usage.

`AppAnalyticsTests` cover event names, fixed parameters, repeated presentation, completion followed by dismissal, cancellation, preparation failure, and native error precedence. `WorkoutShareCardUITests` exercise chart, stats, text, and JSON native exports.
