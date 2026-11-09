#!/bin/bash
set -euo pipefail

# Archive the current working tree and upload it to TestFlight using Xcode's
# signed-in account. This does not submit the app for public App Review.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
read -r release_version release_build < <(python3 - <<'PY'
import re
from pathlib import Path
project = Path('BPM.xcodeproj/project.pbxproj').read_text()
versions = set(re.findall(r'MARKETING_VERSION = ([0-9.]+);', project))
builds = set(re.findall(r'CURRENT_PROJECT_VERSION = ([0-9]+);', project))
if len(versions) != 1 or len(builds) != 1:
    raise SystemExit('App and extension versions must match before upload.')
print(versions.pop(), builds.pop())
PY
)
release_dir="$project_root/build/release-testflight-$release_build"
archive_path="$project_root/build/BPM-$release_version-$release_build.xcarchive"
mkdir -p "$release_dir"

cat > "$release_dir/UploadOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>5HW85B6746</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>stripSwiftSymbols</key><true/>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

xcodebuild -project BPM.xcodeproj -scheme BPM -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive_path" \
  archive -allowProvisioningUpdates 2>&1 | tee "$release_dir/archive.log"

test -d "$archive_path/dSYMs/BPM.app.dSYM"
test -d "$archive_path/dSYMs/BPMActivityExtension.appex.dSYM"
xcodebuild -exportArchive -archivePath "$archive_path" \
  -exportPath "$release_dir/export" -exportOptionsPlist "$release_dir/UploadOptions.plist" \
  -allowProvisioningUpdates 2>&1 | tee "$release_dir/upload.log"
