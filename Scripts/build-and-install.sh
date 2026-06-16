#!/usr/bin/env bash
# build-and-install.sh
# Build CodexBar, sign with the user's Apple Development cert, and install to /Applications.
# This stops macOS from re-prompting for keychain access on every rebuild.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_IDENTITY="Apple Development: jxu49220@gmail.com (5XX5TWL4QD)"
APP_PATH="/Applications/CodexBar.app"

echo "==> 1. Kill any running CodexBar"
pkill -f "CodexBar.app/Contents/MacOS/CodexBar" 2>/dev/null || true
sleep 1

echo "==> 2. Build (adhoc stage)"
rm -rf .build/package/CodexBar.app
CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh debug >/dev/null 2>&1 || true

if [[ ! -d .build/package/CodexBar.app ]]; then
    echo "  ! adhoc build did not produce .build/package/CodexBar.app, aborting"
    exit 1
fi

echo "==> 3. Strip detritus (FinderInfo / ResourceFork / AppleDouble)"
find .build/package/CodexBar.app -type f -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
find .build/package/CodexBar.app -type f -exec xattr -d com.apple.ResourceFork {} \; 2>/dev/null || true
xattr -cr .build/package/CodexBar.app
find .build/package/CodexBar.app -name "._*" -delete

echo "==> 4. Re-sign with Apple Development cert"
codesign --force --deep --no-strict \
    --sign "$APP_IDENTITY" \
    --options runtime \
    .build/package/CodexBar.app

echo "==> 5. Verify"
codesign --verify --verbose=2 .build/package/CodexBar.app | tail -2

echo "==> 6. Install to $APP_PATH"
rm -rf "$APP_PATH"
mv .build/package/CodexBar.app "$APP_PATH"

echo "==> 7. Launch"
open "$APP_PATH"
sleep 2

echo ""
echo "==> Done. App should be running as $APP_IDENTITY"
codesign -dv "$APP_PATH" 2>&1 | grep -E "Identifier|TeamIdentifier|Signed Time"
pgrep -lf "CodexBar.app/Contents/MacOS/CodexBar" || echo "  ! App not running, check Console.app"
