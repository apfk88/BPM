#!/bin/bash

# Script to set API URL based on git branch name
# If branch starts with "staging", use staging URL, otherwise use production URL

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Determine the Info.plist path
if [ -n "$SRCROOT" ]; then
    INFO_PLIST="${SRCROOT}/BPM/Info.plist"
else
    # Fallback for manual execution - assume we're in the repo root
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    INFO_PLIST="${REPO_ROOT}/BPM/Info.plist"
fi

# Determine API URL based on branch
if [[ "$BRANCH" == staging* ]]; then
    API_URL="https://staging.bpmtracker.app"
    echo "🔵 Using staging API URL: $API_URL (branch: $BRANCH)"
else
    API_URL="https://bpmtracker.app"
    echo "🟢 Using production API URL: $API_URL (branch: $BRANCH)"
fi

# Set the API URL in Info.plist
/usr/libexec/PlistBuddy -c "Set :BPM_API_BASE_URL $API_URL" "$INFO_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :BPM_API_BASE_URL string $API_URL" "$INFO_PLIST" 2>/dev/null

if [ $? -eq 0 ]; then
    echo "✅ Set BPM_API_BASE_URL to $API_URL in Info.plist"
else
    echo "⚠️ Failed to set API URL in Info.plist"
fi

