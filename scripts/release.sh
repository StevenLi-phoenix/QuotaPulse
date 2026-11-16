#!/bin/bash
# Cuts a macOS release: bumps the version, turns CHANGELOG.md's [Unreleased] into the version's section,
# commits "chore(release): <version>", tags v<version> and pushes main and the tag in one atomic push.
# The tag starts .github/workflows/release.yml, which tests, signs, notarizes and publishes it
# (scripts/publish.sh); installed Macs update themselves within an hour. Needs only git and gh.
#
#   scripts/release.sh <auto | patch | minor | major | x.y.z>
#
# auto = minor when [Unreleased] has an "### Added" section, otherwise patch.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=StevenLi-phoenix/QuotaPulse
BUMP=${1:?usage: scripts/release.sh <auto|patch|minor|major|x.y.z>}

log() { printf '[release %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[release] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────
REMOTE=$(git remote -v | awk '/github\.com[:\/]StevenLi-phoenix\/QuotaPulse(\.git)? \(push\)/ {print $1; exit}')
[ -n "$REMOTE" ] || die "no git remote points at github.com/$REPO"
GIT_REMOTE=(git -c credential.helper= -c "credential.helper=!gh auth git-credential")
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "release from main (now on $(git rev-parse --abbrev-ref HEAD))"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"
"${GIT_REMOTE[@]}" fetch -q "$REMOTE" main || die "git fetch $REMOTE main failed"
git merge-base --is-ancestor "$REMOTE/main" HEAD || die "$REMOTE/main has commits this main lacks; pull first"

UNRELEASED=$(awk '/^## \[Unreleased\]/ {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md)
printf '%s\n' "$UNRELEASED" | grep -q '^- ' || die "CHANGELOG.md [Unreleased] is empty; nothing to release"
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

# ── Bump, changelog, commit, tag ─────────────────────────────────────────────
# Until the commit exists, a failure puts project.yml and CHANGELOG.md back.
COMMITTED=0
trap '[ "$COMMITTED" = 1 ] || git checkout -q -- project.yml CHANGELOG.md' EXIT
sed -i '' -E "s/^( *MARKETING_VERSION:) .*/\1 $VERSION/; s/^( *CURRENT_PROJECT_VERSION:) .*/\1 $BUILD/" project.yml
ROLLED=$(awk -v v="$VERSION" -v d="$(date +%Y-%m-%d)" \
  '!done && $0 == "## [Unreleased]" { print; print ""; print "## [" v "] - " d; done = 1; next } { print }' CHANGELOG.md)
printf '%s\n' "$ROLLED" >CHANGELOG.md
[ "$(git diff --name-only | sort | tr '\n' ' ')" = "CHANGELOG.md project.yml " ] || die "the bump changed unexpected files"
git add project.yml CHANGELOG.md
git commit -q -m "chore(release): $VERSION"
COMMITTED=1
git tag -a "$TAG" -m "QuotaPulse $VERSION"
log "QuotaPulse $OLD_VERSION ($OLD_BUILD) → $VERSION ($BUILD), tagged $TAG at $(git rev-parse --short HEAD)"

# ── Push ─────────────────────────────────────────────────────────────────────
"${GIT_REMOTE[@]}" push -q --atomic "$REMOTE" main "$TAG" \
  || die "push failed; main and $TAG are committed here: retry with git push --atomic $REMOTE main $TAG"
log "pushed main and $TAG; GitHub Actions builds, notarizes and publishes it"

# The tag's workflow run, for watching it.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  RUN=$(gh run list --repo "$REPO" --workflow release.yml --branch "$TAG" -L 1 --json databaseId,url \
    --jq '.[0] | "\(.databaseId) \(.url)"' 2>/dev/null || true)
  if [ -n "$RUN" ] && [ "$RUN" != "null null" ]; then
    log "run ${RUN#* }"
    log "watch: gh run watch ${RUN%% *} --repo $REPO --exit-status"
    exit 0
  fi
  sleep 3
done
log "the run hasn't appeared yet: gh run list --repo $REPO --workflow release.yml --branch $TAG"
