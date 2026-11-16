#!/bin/bash
# Publishes a notarized macOS build to GitHub Releases. Installed copies update themselves (Sparkle).
#
#   scripts/release.sh <auto | x.y.z | patch | minor | major> [--dry-run]
#
# auto = minor when CHANGELOG.md's [Unreleased] has an "### Added" section, otherwise patch.
# --dry-run builds, notarizes, signs and writes the appcast, then stops before any commit, tag or upload.
#
# Normally GitHub Actions runs this on every push to main (.github/workflows/release.yml). Two signing modes:
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
BUMP=${1:?usage: scripts/release.sh <auto|x.y.z|patch|minor|major> [--dry-run]}
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1

log() { printf '[release %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[release] ERROR: %s\n' "$*" >&2; exit 1; }

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
GIT_PUSH=(git -c credential.helper= -c "credential.helper=!gh auth git-credential")
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "release from main (now on $(git rev-parse --abbrev-ref HEAD))"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"
"${GIT_PUSH[@]}" fetch -q "$REMOTE" main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse "$REMOTE/main")" ]; then
  [ "$DRY_RUN" = 1 ] || die "main is not $REMOTE/main; pull or push first"
  log "dry run: main differs from $REMOTE/main"
fi
gh api "repos/$REPO" --jq .full_name >/dev/null 2>&1 || die "gh can't reach $REPO (log in, or set GH_TOKEN)"
security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM)" || die "no Developer ID Application certificate for $TEAM"

UNRELEASED=$(awk '/^## \[Unreleased\]/ {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md)
printf '%s\n' "$UNRELEASED" | grep -q '^- ' || die "CHANGELOG.md [Unreleased] is empty"
if [ "$BUMP" = auto ]; then
  if printf '%s\n' "$UNRELEASED" | grep -q '^### Added'; then BUMP=minor; else BUMP=patch; fi
fi
OLD_VERSION=$(awk '/^ *MARKETING_VERSION:/ {print $2; exit}' project.yml)
OLD_BUILD=$(awk '/^ *CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
IFS=. read -r MA MI PA <<<"$OLD_VERSION"
case "$BUMP" in
  patch) VERSION="$MA.$MI.$((PA + 1))" ;;
  minor) VERSION="$MA.$((MI + 1)).0" ;;
  major) VERSION="$((MA + 1)).0.0" ;;
  *) VERSION=$BUMP ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be x.y.z (got $VERSION)"
BUILD=$((OLD_BUILD + 1))
TAG="v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
git ls-remote --exit-code --tags "$REMOTE" "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on $REMOTE"

XCODEGEN=${XCODEGEN:-../tools/xcodegen/bin/xcodegen}
[ -x "$XCODEGEN" ] || XCODEGEN="$(command -v xcodegen || true)"
[ -n "$XCODEGEN" ] || XCODEGEN=/opt/homebrew/bin/xcodegen
[ -x "$XCODEGEN" ] || die "xcodegen not found: brew install xcodegen"

WORK="build/release/$VERSION"
rm -rf "$WORK"
mkdir -p "$WORK"
LOG="$WORK/release.log"
MODE=local; [ "$CI_MODE" = 1 ] && MODE="CI (profile \"$QP_APP_PROFILE\")"
log "QuotaPulse $OLD_VERSION ($OLD_BUILD) → $VERSION ($BUILD) from $(git rev-parse --short HEAD), $MODE signing; log $LOG"

# Until the bump is committed, a failure (or a dry run) puts back what this script changed: the tree was
# clean, so that is project.yml, CHANGELOG.md and any plist/entitlements xcodegen rewrote.
COMMITTED=0
release_files() { echo project.yml CHANGELOG.md; git diff --name-only -- '*.plist' '*.entitlements'; }
restore() { [ "$COMMITTED" = 1 ] || git checkout -q -- $(release_files); }
trap restore EXIT

# ── Version bump + changelog ─────────────────────────────────────────────────
sed -i '' -E "s/^( *MARKETING_VERSION:) .*/\1 $VERSION/; s/^( *CURRENT_PROJECT_VERSION:) .*/\1 $BUILD/" project.yml
TODAY=$(date +%Y-%m-%d)
python3 - "$VERSION" "$TODAY" "$WORK" <<'PY'
import html, pathlib, re, sys
version, today, work = sys.argv[1:4]
p = pathlib.Path("CHANGELOG.md")
text = p.read_text()
text = text.replace("## [Unreleased]\n", f"## [Unreleased]\n\n## [{version}] - {today}\n", 1)
p.write_text(text)
section = text.split(f"## [{version}] - {today}\n", 1)[1].split("\n## [", 1)[0].strip()
pathlib.Path(work, "notes.md").write_text(section + "\n")
# Release notes for Sparkle's update window: the same section as simple HTML.
out, in_list = [], False
for line in section.splitlines():
    if line.startswith("### "):
        if in_list: out.append("</ul>"); in_list = False
        out.append(f"<h3>{html.escape(line[4:])}</h3>")
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
  log "dry run: stopping before commit/tag/upload; artifacts in $WORK"
  exit 0
fi

# ── Commit, tag, push, publish ───────────────────────────────────────────────
# A push that landed during the build has its own run (CI) or needs a rerun (local) that releases both.
"${GIT_PUSH[@]}" fetch -q "$REMOTE" main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse "$REMOTE/main")" ]; then
  [ "$CI_MODE" = 1 ] && { log "main moved during the build; the run for the newer push releases it"; exit 0; }
  die "main moved during the build; pull and rerun"
fi
git add $(release_files)
git commit -q -m "chore(release): $VERSION"
COMMITTED=1
git tag -a "$TAG" -m "QuotaPulse $VERSION"
"${GIT_PUSH[@]}" push -q "$REMOTE" main "$TAG"
gh release create "$TAG" --repo "$REPO" --verify-tag --title "QuotaPulse $VERSION" \
  --notes-file "$WORK/notes.md" "$ZIP" "$WORK/appcast.xml"
log "published $TAG: https://github.com/$REPO/releases/tag/$TAG"

# The feed URL must now serve this version (installed copies check it hourly).
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
for _ in 1 2 3 4 5 6; do
  if curl -fsSL "$FEED" | grep -q "<sparkle:shortVersionString>$VERSION<"; then
    log "feed serves $VERSION: $FEED"
    exit 0
  fi
  sleep 10
done
die "feed does not serve $VERSION yet: $FEED"
