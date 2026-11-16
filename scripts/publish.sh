#!/bin/bash
# Builds, signs, notarizes and publishes the version checked out at HEAD to GitHub Releases. Installed copies
# update themselves (Sparkle).
#
#   scripts/publish.sh [--dry-run]
#
# GitHub Actions runs this for every pushed v<x.y.z> tag (.github/workflows/release.yml); scripts/release.sh
# makes the tag. HEAD must be the tag v<MARKETING_VERSION>, on main, not yet released, with a CHANGELOG.md
# section for the version and a CURRENT_PROJECT_VERSION above the build the feed serves now.
# --dry-run skips those tag checks, builds, notarizes, signs and writes the appcast, then stops before uploading.
#
# Two signing modes:
#  - Local (the Mac with the credentials): the "Developer ID Application" certificate, an Xcode account for
#    team 88U7V98QAC (export and notarization go through it), the Sparkle EdDSA key in the login keychain
#    (account "quotapulse") and `gh` logged in.
#  - CI (QP_APP_PROFILE set): manual signing with the installed Developer ID profile of that name, the
#    certificate in a keychain on the search list (QP_KEYCHAIN), notarytool with an App Store Connect API key
#    (NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER) and the Sparkle key from SPARKLE_KEY_FILE.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=StevenLi-phoenix/QuotaPulse
TEAM=88U7V98QAC
APP_ID=app.lishuyu.quotapulse
KEY_ACCOUNT=quotapulse
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "usage: scripts/publish.sh [--dry-run]" >&2; exit 2 ;;
esac

log() { printf '[publish %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[publish] ERROR: %s\n' "$*" >&2; exit 1; }

CI_MODE=0
if [ -n "${QP_APP_PROFILE:-}" ]; then
  CI_MODE=1
  for v in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER SPARKLE_KEY_FILE; do [ -n "${!v:-}" ] || die "CI mode needs $v"; done
  [ -s "$NOTARY_KEY_PATH" ] || die "no API key at NOTARY_KEY_PATH"
  [ -s "$SPARKLE_KEY_FILE" ] || die "no Sparkle key at SPARKLE_KEY_FILE"
fi

# ── Preflight ────────────────────────────────────────────────────────────────
REMOTE=$(git remote -v | awk '/github\.com[:\/]StevenLi-phoenix\/QuotaPulse(\.git)? \(push\)/ {print $1; exit}')
[ -n "$REMOTE" ] || die "no git remote points at github.com/$REPO"
GIT_REMOTE=(git -c credential.helper= -c "credential.helper=!gh auth git-credential")
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"
gh api "repos/$REPO" --jq .full_name >/dev/null 2>&1 || die "gh can't reach $REPO (log in, or set GH_TOKEN)"
security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM)" || die "no Developer ID Application certificate for $TEAM"

VERSION=$(awk '/^ *MARKETING_VERSION:/ {print $2; exit}' project.yml)
BUILD=$(awk '/^ *CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MARKETING_VERSION in project.yml must be x.y.z (got $VERSION)"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION in project.yml must be a number (got $BUILD)"
TAG="v$VERSION"

# What installed copies run now: Sparkle only offers a higher build number.
FEED_XML=$(curl -fsSL "$FEED" 2>/dev/null || true)
FEED_VERSION=$(printf '%s' "$FEED_XML" | sed -nE 's/.*<sparkle:shortVersionString>([^<]+)<.*/\1/p' | head -n 1)
FEED_BUILD=$(printf '%s' "$FEED_XML" | sed -nE 's/.*<sparkle:version>([0-9]+)<.*/\1/p' | head -n 1)

if [ "$DRY_RUN" = 1 ]; then
  log "dry run: $VERSION ($BUILD) at $(git rev-parse --short HEAD); the feed serves ${FEED_VERSION:-nothing} (${FEED_BUILD:-?})"
else
  [ "$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)" = "$(git rev-parse HEAD)" ] \
    || die "HEAD is not tag $TAG (project.yml says $VERSION); make releases with scripts/release.sh"
  "${GIT_REMOTE[@]}" fetch -q "$REMOTE" main || die "git fetch $REMOTE main failed"
  git merge-base --is-ancestor HEAD "$REMOTE/main" || die "$TAG is not on $REMOTE/main"
  gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && die "$TAG is already published"
  [ -n "$FEED_BUILD" ] || die "can't read the build number the feed serves ($FEED)"
  [ "$BUILD" -gt "$FEED_BUILD" ] || die "build $BUILD is not above $FEED_BUILD, which the feed serves ($FEED_VERSION); Sparkle would skip it"
fi
grep -q "^## \[$VERSION\]" CHANGELOG.md || die "CHANGELOG.md has no [$VERSION] section"

XCODEGEN=${XCODEGEN:-../tools/xcodegen/bin/xcodegen}
[ -x "$XCODEGEN" ] || XCODEGEN="$(command -v xcodegen || true)"
[ -n "$XCODEGEN" ] || XCODEGEN=/opt/homebrew/bin/xcodegen
[ -x "$XCODEGEN" ] || die "xcodegen not found: brew install xcodegen"

WORK="build/release/$VERSION"
rm -rf "$WORK"
mkdir -p "$WORK"
LOG="$WORK/release.log"
MODE=local; [ "$CI_MODE" = 1 ] && MODE="CI (profile \"$QP_APP_PROFILE\")"
log "QuotaPulse $VERSION ($BUILD) from $(git rev-parse --short HEAD), $MODE signing; log $LOG"

# xcodegen may rewrite tracked plists and entitlements; the tree was clean, so put them back on exit.
restore() { local f; f=$(git diff --name-only -- '*.plist' '*.entitlements'); [ -z "$f" ] || git checkout -q -- $f; }
trap restore EXIT

# ── Release notes ────────────────────────────────────────────────────────────
# This version's CHANGELOG.md section, plus any tagged-but-unpublished versions between it and the feed's.
python3 - "$VERSION" "${FEED_VERSION:-}" "$WORK" <<'PY'
import html, pathlib, re, sys
version, feed_version, work = sys.argv[1:4]
text = pathlib.Path("CHANGELOG.md").read_text()
sections = [s for s in re.split(r"(?m)^(?=## \[)", text) if s.startswith("## [")]
versions = [re.match(r"## \[([^\]]+)\]", s).group(1) for s in sections]
i = versions.index(version)
picked = [sections[i]]
if feed_version != version and feed_version in versions[i + 1:]:
    picked += sections[i + 1 : versions.index(feed_version, i + 1)]
if len(picked) == 1:
    md = picked[0].split("\n", 1)[1].strip()
else:
    md = "\n\n".join(s.strip() for s in picked)
pathlib.Path(work, "notes.md").write_text(md + "\n")
print("[publish] release notes from " + ", ".join(versions[i : i + len(picked)]))
# Release notes for Sparkle's update window: the same text as simple HTML.
out, in_list = [], False
for line in md.splitlines():
    if line.startswith("## ") or line.startswith("### "):
        if in_list: out.append("</ul>"); in_list = False
        level = 2 if line.startswith("## ") else 3
        title = line[level + 1:].replace("[", "").replace("]", "")
        out.append(f"<h{level}>{html.escape(title)}</h{level}>")
    elif line.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        item = html.escape(line[2:])
        item = re.sub(r"`([^`]+)`", r"<code>\1</code>", item)
        item = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", item)
        out.append(f"<li>{item}</li>")
if in_list: out.append("</ul>")
pathlib.Path(work, "notes.html").write_text("\n".join(out) + "\n")
PY

# ── Archive ──────────────────────────────────────────────────────────────────
"$XCODEGEN" generate >/dev/null
ARCHIVE="$WORK/QuotaPulse.xcarchive"
if [ "$CI_MODE" = 1 ]; then
  # Command-line settings reach every target, Swift package resource bundles too, so they need the team as well.
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application" "DEVELOPMENT_TEAM=$TEAM" "QP_APP_PROFILE=$QP_APP_PROFILE")
  [ -n "${QP_KEYCHAIN:-}" ] && SIGN_ARGS+=("OTHER_CODE_SIGN_FLAGS=--keychain $QP_KEYCHAIN")
else
  SIGN_ARGS=(-allowProvisioningUpdates)
fi
log "archiving"
xcodebuild archive -project QuotaPulse.xcodeproj -scheme QuotaPulse-macOS -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData-release \
  -archivePath "$ARCHIVE" "${SIGN_ARGS[@]}" >>"$LOG" 2>&1 || { grep -E 'error:' "$LOG" >&2 || true; die "archive failed"; }

# The Sparkle key must sign what SUPublicEDKey in the app verifies; check before spending time on notarization.
SPARKLE_BIN=build/DerivedData-release/SourcePackages/artifacts/sparkle/Sparkle/bin
[ -x "$SPARKLE_BIN/sign_update" ] || die "Sparkle tools not found in $SPARKLE_BIN"
sparkle_sign() {
  if [ "$CI_MODE" = 1 ]; then "$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$@"
  else "$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" "$@"; fi
}
PLIST_KEY=$(plutil -extract SUPublicEDKey raw "$ARCHIVE/Products/Applications/QuotaPulse.app/Contents/Info.plist")
xcrun swiftc -O scripts/verify-ed-signature.swift -o "$WORK/verify-ed" >>"$LOG" 2>&1 || die "could not build scripts/verify-ed-signature.swift"
head -c 4096 /dev/urandom >"$WORK/probe.bin"
PROBE_SIG=$(sparkle_sign -p "$WORK/probe.bin") || die "sign_update can't use the Sparkle key"
"$WORK/verify-ed" "$PLIST_KEY" "$PROBE_SIG" "$WORK/probe.bin" >>"$LOG" || die "the Sparkle key does not match SUPublicEDKey in the app"

# ── Developer ID export + notarization ───────────────────────────────────────
# Developer ID builds may only use the Production CloudKit environment.
EXPORT_PLIST="$WORK/export.plist"
if [ "$CI_MODE" = 1 ]; then
  cat >"$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$TEAM</string>
  <key>provisioningProfiles</key><dict><key>$APP_ID</key><string>$QP_APP_PROFILE</string></dict>
  <key>iCloudContainerEnvironment</key><string>Production</string>
</dict></plist>
EOF
  log "signing with Developer ID (manual)"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$WORK/export" >>"$LOG" 2>&1 || { grep -E 'error:' "$LOG" >&2 || true; die "export failed"; }
  APP="$WORK/export/QuotaPulse.app"
  [ -d "$APP" ] || die "no QuotaPulse.app in $WORK/export"
  log "notarizing with the App Store Connect API key (usually 1–10 minutes)"
  ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
  NOTARY=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  xcrun notarytool submit "$WORK/notarize.zip" "${NOTARY[@]}" --wait --timeout 60m --output-format json \
    >"$WORK/notary.json" 2>>"$LOG" || true
  NOTARY_ID=$(plutil -extract id raw "$WORK/notary.json" 2>/dev/null || true)
  NOTARY_STATUS=$(plutil -extract status raw "$WORK/notary.json" 2>/dev/null || echo "no answer")
  echo "notarytool: id $NOTARY_ID, status $NOTARY_STATUS" >>"$LOG"
  if [ "$NOTARY_STATUS" != Accepted ]; then
    [ -n "$NOTARY_ID" ] && xcrun notarytool log "$NOTARY_ID" "${NOTARY[@]}" "$WORK/notary-log.json" >>"$LOG" 2>&1 && cat "$WORK/notary-log.json" >>"$LOG"
    die "notarization $NOTARY_STATUS (id $NOTARY_ID; see $LOG)"
  fi
  xcrun stapler staple "$APP" >>"$LOG" 2>&1 || die "stapling failed"
else
  cat >"$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
  <key>iCloudContainerEnvironment</key><string>Production</string>
</dict></plist>
EOF
  log "signing with Developer ID and uploading to Apple's notary service"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$WORK/upload" -allowProvisioningUpdates >>"$LOG" 2>&1 || { grep -E 'error:' "$LOG" >&2 || true; die "export/upload failed"; }
  log "waiting for notarization (usually 1–10 minutes)"
  NOTARIZED="$WORK/notarized"
  deadline=$((SECONDS + 3600))
  until xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$NOTARIZED" >"$WORK/notarized.log" 2>&1; do
    last=$(grep -E 'error:' "$WORK/notarized.log" | tail -1 || true)
    echo "$last" >>"$LOG"
    if echo "$last" | grep -qiE 'invalid|rejected'; then die "notarization rejected: $last"; fi
    [ $SECONDS -lt $deadline ] || die "notarization still pending after 60 minutes: $last"
    sleep 30
  done
  APP="$NOTARIZED/QuotaPulse.app"
  [ -d "$APP" ] || die "no QuotaPulse.app in $NOTARIZED"
  xcrun stapler validate "$APP" >>"$LOG" 2>&1 || xcrun stapler staple "$APP" >>"$LOG" 2>&1 || die "stapling failed"
fi

# ── Checks on the app that ships ─────────────────────────────────────────────
spctl --assess --type execute -vv "$APP" >>"$LOG" 2>&1 || die "Gatekeeper rejects the notarized app (see $LOG)"
[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VERSION" ] || die "built app has the wrong version"
codesign -d --entitlements - --xml "$APP" 2>/dev/null >"$WORK/entitlements.plist" || die "can't read the app's entitlements"
[ "$(plutil -extract com\\.apple\\.developer\\.icloud-container-environment raw "$WORK/entitlements.plist" 2>/dev/null)" = Production ] \
  || die "the app is not signed for CloudKit Production"
[ "$(plutil -extract com\\.apple\\.application-identifier raw "$WORK/entitlements.plist" 2>/dev/null)" = "$TEAM.$APP_ID" ] \
  || die "the app's application-identifier is not $TEAM.$APP_ID"
security cms -D -i "$APP/Contents/embedded.provisionprofile" >"$WORK/embedded-profile.plist" 2>/dev/null \
  || die "the app has no embedded provisioning profile (iCloud needs one)"
log "embedded profile: $(plutil -extract Name raw "$WORK/embedded-profile.plist")"
if [ "$CI_MODE" = 1 ]; then
  # A profile that doesn't cover the entitlements passes Gatekeeper but is killed at launch; launch it once.
  "$APP/Contents/MacOS/QuotaPulse" >>"$WORK/smoke.log" 2>&1 &
  SMOKE_PID=$!
  sleep 8
  kill -0 "$SMOKE_PID" 2>/dev/null || die "the signed app exits at launch (see $WORK/smoke.log)"
  kill "$SMOKE_PID"
  wait "$SMOKE_PID" 2>/dev/null || true
  log "launch check passed"
fi
log "notarized, stapled and accepted by Gatekeeper"

# ── Zip, EdDSA signature, appcast ────────────────────────────────────────────
ZIP_NAME="QuotaPulse-$VERSION.zip"
ZIP="$WORK/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIG_ATTRS=$(sparkle_sign "$ZIP")  # sparkle:edSignature="…" length="…"
[[ "$SIG_ATTRS" == *edSignature=* ]] || die "sign_update failed"
ZIP_SIG=$(printf '%s' "$SIG_ATTRS" | sed -E 's/.*edSignature="([^"]+)".*/\1/')
"$WORK/verify-ed" "$PLIST_KEY" "$ZIP_SIG" "$ZIP" >>"$LOG" || die "the zip's EdDSA signature does not verify"
MIN_OS=$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")
URL="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME"
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  echo '  <channel>'
  echo '    <title>QuotaPulse</title>'
  echo '    <item>'
  echo "      <title>$VERSION</title>"
  echo "      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
  echo "      <sparkle:version>$BUILD</sparkle:version>"
  echo "      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
  echo "      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>"
  echo "      <description><![CDATA["
  cat "$WORK/notes.html"
  echo "      ]]></description>"
  echo "      <enclosure url=\"$URL\" $SIG_ATTRS type=\"application/octet-stream\"/>"
  echo '    </item>'
  echo '  </channel>'
  echo '</rss>'
} >"$WORK/appcast.xml"
xmllint --noout "$WORK/appcast.xml" || die "appcast.xml is not valid XML"
log "zip $(du -h "$ZIP" | cut -f1 | tr -d ' '), signature verified, appcast written"

if [ "$DRY_RUN" = 1 ]; then
  log "dry run: stopping before upload; artifacts in $WORK"
  exit 0
fi

# ── Publish ──────────────────────────────────────────────────────────────────
gh release create "$TAG" --repo "$REPO" --verify-tag --latest --title "QuotaPulse $VERSION" \
  --notes-file "$WORK/notes.md" "$ZIP" "$WORK/appcast.xml"
log "published $TAG: https://github.com/$REPO/releases/tag/$TAG"

# The feed URL must now serve this version (installed copies check it hourly).
for _ in 1 2 3 4 5 6; do
  if curl -fsSL "$FEED" | grep -q "<sparkle:shortVersionString>$VERSION<"; then
    log "feed serves $VERSION: $FEED"
    exit 0
  fi
  sleep 10
done
die "feed does not serve $VERSION yet: $FEED"
