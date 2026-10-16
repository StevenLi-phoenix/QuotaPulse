#!/bin/bash
# Builds the Release macOS app and installs it to ~/Applications (never /Applications).
set -euo pipefail
cd "$(dirname "$0")/.."
XCODEGEN="../tools/xcodegen/bin/xcodegen"
[ -x "$XCODEGEN" ] && "$XCODEGEN" generate >/dev/null
xcodebuild -project QuotaPulse.xcodeproj -scheme QuotaPulse-macOS -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData build | grep -E 'error:|BUILD' || true
SRC="build/DerivedData/Build/Products/Release/QuotaPulse.app"
DST="$HOME/Applications/QuotaPulse.app"
mkdir -p "$HOME/Applications"
if pgrep -f "$DST/Contents/MacOS/QuotaPulse" >/dev/null; then pkill -f "$DST/Contents/MacOS/QuotaPulse"; sleep 1; fi
rm -rf "$DST"
cp -R "$SRC" "$DST"
echo "Installed $DST"
open -n "$DST"
