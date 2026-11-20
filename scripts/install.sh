#!/bin/bash
# Builds the Release macOS app and installs it to $QUOTAPULSE_INSTALL_DIR (default ~/Applications).
set -euo pipefail
cd "$(dirname "$0")/.."
# The .xcodeproj is generated from project.yml and not in git, so regenerate it before every build.
# xcodegen: next to the repo, on PATH, or Homebrew's (a non-login shell may not have Homebrew on PATH).
XCODEGEN="../tools/xcodegen/bin/xcodegen"
[ -x "$XCODEGEN" ] || XCODEGEN="$(command -v xcodegen || true)"
[ -n "$XCODEGEN" ] || [ ! -x /opt/homebrew/bin/xcodegen ] || XCODEGEN=/opt/homebrew/bin/xcodegen
if [ -n "$XCODEGEN" ]; then
  "$XCODEGEN" generate >/dev/null
elif [ -d QuotaPulse.xcodeproj ]; then
  echo "WARNING: xcodegen not found; building the existing QuotaPulse.xcodeproj, which may miss new files" >&2
else
  echo "xcodegen not found and there is no QuotaPulse.xcodeproj: brew install xcodegen" >&2
  exit 1
fi
echo "Building $(git rev-parse --short HEAD 2>/dev/null || echo '?'): $(git log -1 --format=%s 2>/dev/null || true)"
LOG="build/xcodebuild-release.log"
mkdir -p build
# A failed build must stop here: the steps below delete the installed app before copying the new one.
if ! xcodebuild -project QuotaPulse.xcodeproj -scheme QuotaPulse-macOS -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build >"$LOG" 2>&1; then
  grep -E 'error:|errSec' "$LOG" >&2 || true
  grep -q errSecInternalComponent "$LOG" && echo "codesign can't reach the login keychain (SSH session?): run 'security unlock-keychain ~/Library/Keychains/login.keychain-db' first, or build from a GUI terminal." >&2
  echo "BUILD FAILED — installed app left untouched (log: $LOG)" >&2
  exit 1
fi
echo "** BUILD SUCCEEDED **"
SRC="build/DerivedData/Build/Products/Release/QuotaPulse.app"
DST_DIR="${QUOTAPULSE_INSTALL_DIR:-$HOME/Applications}"
DST="$DST_DIR/QuotaPulse.app"
mkdir -p "$DST_DIR"
# Stop the installed copy by PID (exact executable path), so a stale instance never keeps running the old build.
PIDS=$(pgrep -f "^$DST/Contents/MacOS/QuotaPulse" || true)
if [ -n "$PIDS" ]; then
  echo "stopping running QuotaPulse: $(echo $PIDS)"
  kill $PIDS; sleep 1
fi
rm -rf "$DST"
cp -R "$SRC" "$DST"
echo "Installed $DST"
# Make LaunchServices / PlugInKit see the (sandboxed) widget extension right away.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f -R "$DST" >/dev/null 2>&1 || true
pluginkit -a "$DST/Contents/PlugIns/QuotaPulseWidget.appex" >/dev/null 2>&1 || true
open -n "$DST"
sleep 3
# chronod (the widget daemon) sometimes purges a freshly replaced extension ("shouldn't cache it");
# a restart makes it re-scan and keep it. It relaunches on its own.
killall chronod 2>/dev/null || true
if pluginkit -m -i app.lishuyu.quotapulse.widget >/dev/null 2>&1; then
  echo "Widget extension registered: $(pluginkit -m -i app.lishuyu.quotapulse.widget)"
else
  echo "WARNING: widget extension not registered yet — open Notification Center → Edit Widgets after a few seconds, or log out/in." >&2
fi
