# Build Scripts

## set-api-url.sh

Automatically sets the API base URL based on the current git branch name.

### Behavior

- **Staging branches** (branches starting with "staging"): Uses `https://staging.bpmtracker.app`
- **Production branches**: Uses `https://bpmtracker.app`

### Setup in Xcode

1. Open the project in Xcode
2. Select the **BPM** target (not the project)
3. Go to **Build Phases** tab
4. Click the **+** button at the top and select **New Run Script Phase**
5. Drag the new script phase to run **before** "Compile Sources"
6. Expand the script phase and paste:

```bash
"${SRCROOT}/scripts/set-api-url.sh"
```

7. Make sure "Show environment variables in build log" is unchecked (optional, for cleaner logs)

### How It Works

The script:
1. Detects the current git branch name
2. Sets `BPM_API_BASE_URL` in `Info.plist` based on the branch
3. The app reads this value at runtime (see `SharingService.swift`)

### Priority Order

The app checks for API URL in this order:
1. **UserDefaults** (`BPM_API_BASE_URL`) - Runtime override
2. **Info.plist** (`BPM_API_BASE_URL`) - Set by build script
3. **Default** - `https://bpmtracker.app` (production)

### Testing

You can test the script manually:
```bash
./scripts/set-api-url.sh
```

This will update `BPM/Info.plist` with the appropriate URL based on your current branch.

