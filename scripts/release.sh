#!/usr/bin/env bash
#
# scripts/release.sh - Cut a new ZhiYin release end-to-end.
#
# Usage:
#   ./scripts/release.sh <VERSION> [--dry-run] [--yes]
#
#   <VERSION>    Semver like 0.9.1
#   --dry-run    Print plan, do nothing
#   --yes        Skip confirmation prompt
#
# Preflight (fails fast):
#   - Valid semver version
#   - On 'dev' branch, working tree clean
#   - local 'main' in sync with origin/main
#   - gh CLI installed + authenticated
#   - CHANGELOG.md has a [X.Y.Z] section (release notes must exist)
#   - Tag vX.Y.Z doesn't exist locally or on origin
#   - Notarization profile 'zhiyin' in Keychain, OR .env has
#     appleid / team_id / app_specific_password to auto-create it
#
# Flow:
#   1. Bump Info.plist (CFBundleShortVersionString + CFBundleVersion)
#   2. Commit bump on dev
#   3. Switch to main, squash-merge dev
#   4. Commit on main with CHANGELOG [X.Y.Z] section as body
#   5. Push main to origin
#   6. Create + push annotated tag vX.Y.Z
#   7. Build DMG (./scripts/make-dmg.sh; auto-notarized if profile set)
#   8. Verify notarization (stapler + spctl)
#   9. Create GitHub Release with DMG as asset + CHANGELOG notes
#   10. Return to dev branch
#
# Safety:
#   - Shows full plan and asks to confirm (unless --yes)
#   - Fails fast before pushing if anything off
#   - Never modifies .env, never logs credentials

set -euo pipefail
cd "$(dirname "$0")/.."  # project root

# ── log helpers ──────────────────────────────────────────────
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
log()  { echo; echo "${BOLD}${CYAN}━━ $* ━━${RESET}"; }
info() { echo "${BLUE}•${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}⚠${RESET} $*"; }
die()  { echo "${RED}✗${RESET} $*" >&2; exit 1; }

# ── parse args ───────────────────────────────────────────────
VERSION=""; DRY_RUN=false; AUTO_YES=false
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=true ;;
        --yes|-y)  AUTO_YES=true ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's|^#\s\{0,1\}||;$d'; exit 0 ;;
        -*)        die "unknown flag: $a" ;;
        *)         [[ -z "$VERSION" ]] && VERSION="$a" || die "unexpected arg: $a" ;;
    esac
done
[[ -n "$VERSION" ]] || die "usage: $0 <VERSION> [--dry-run] [--yes]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version: $VERSION (want X.Y.Z)"
TAG="v$VERSION"
REPO="Jason-Kou/zhiyin"
PLIST="ZhiYin/Sources/Info.plist"

# ── preflight ────────────────────────────────────────────────
log "Preflight"

[[ $(git branch --show-current) == "dev" ]] || die "must be on 'dev' (currently $(git branch --show-current))"
git diff --quiet && git diff --cached --quiet \
    || die "working tree has uncommitted changes"
ok "on dev, working tree clean"

command -v gh >/dev/null || die "gh CLI not installed"
gh auth status &>/dev/null || die "gh CLI not authenticated — run 'gh auth login'"
ok "gh CLI authenticated"

grep -q "^## \[$VERSION\]" CHANGELOG.md \
    || die "CHANGELOG.md has no [$VERSION] section — write release notes first"
ok "CHANGELOG.md has [$VERSION] section"

! git rev-parse "$TAG" &>/dev/null || die "tag $TAG already exists locally"
! git ls-remote --tags origin 2>/dev/null | grep -qE "refs/tags/$TAG$" \
    || die "tag $TAG already exists on origin"
ok "tag $TAG is new"

info "fetching origin/main..."
git fetch origin main --quiet
[[ $(git rev-parse main) == $(git rev-parse origin/main) ]] \
    || die "local main diverges from origin/main — pull/reconcile first"
ok "local main in sync with origin"

SQUASH_COUNT=$(git rev-list --count main..dev)
[[ $SQUASH_COUNT -gt 0 ]] || die "nothing to squash (main == dev)"
ok "will squash $SQUASH_COUNT commit(s) from dev into main"

# notarization profile status
NOTARIZE_READY=false
if xcrun notarytool history --keychain-profile zhiyin &>/dev/null; then
    NOTARIZE_READY=true
    ok "notarization profile 'zhiyin' present in Keychain"
elif [[ -f .env ]]; then
    set -a; source .env; set +a
    if [[ -n "${appleid:-}" && -n "${team_id:-}" && -n "${app_specific_password:-}" ]]; then
        info "notarization profile missing — will create from .env"
    else
        warn "notarization profile missing and .env incomplete (appleid/team_id/app_specific_password)"
        warn "DMG will ship UN-notarized (users will see Gatekeeper warning)"
    fi
else
    warn "notarization profile missing and no .env — DMG will ship UN-notarized"
fi

# version bump preview
CUR_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
CUR_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEW_BUILD=$((CUR_BUILD + 1))

# ── plan ─────────────────────────────────────────────────────
log "Release plan"
cat <<EOF
  Version:     $CUR_VERSION (build $CUR_BUILD) → $VERSION (build $NEW_BUILD)
  Tag:         $TAG
  Source:      dev ($(git rev-parse --short dev)) — squashing $SQUASH_COUNT commits
  Target:      main ($(git rev-parse --short main))
  CHANGELOG:   [$VERSION] section detected
  DMG:         ZhiYin-$TAG-mac-arm64.dmg (via scripts/make-dmg.sh)
  Notarize:    $(if $NOTARIZE_READY; then echo "ready (Keychain)"; elif [[ -n "${appleid:-}" ]]; then echo "will set up from .env"; else echo "SKIPPED"; fi)
  Release:     github.com/$REPO/releases/tag/$TAG

  Actions:
    1. Bump Info.plist
    2. Commit on dev
    3. Checkout main, squash-merge dev
    4. Commit on main (title="feat: $TAG", body=CHANGELOG section)
    5. Push main
    6. Create + push tag $TAG
    7. Build DMG (auto-notarize if profile set)
    8. Verify notarization
    9. Create GitHub Release with DMG + notes
    10. Return to dev
EOF

if $DRY_RUN; then
    info "[DRY-RUN] no actions taken"
    exit 0
fi

if ! $AUTO_YES; then
    echo
    read -r -p "Continue? [y/N] " REPLY
    [[ "$REPLY" =~ ^[yY]$ ]] || { info "aborted"; exit 0; }
fi

# ── store notarization credentials if needed ─────────────────
if ! $NOTARIZE_READY && [[ -n "${appleid:-}" && -n "${team_id:-}" && -n "${app_specific_password:-}" ]]; then
    log "Storing notarization credentials"
    if xcrun notarytool store-credentials zhiyin \
         --apple-id "$appleid" \
         --team-id "$team_id" \
         --password "$app_specific_password" \
         >/dev/null 2>&1; then
        ok "credentials stored in Keychain as profile 'zhiyin'"
    else
        warn "failed to store credentials — DMG will ship unnotarized"
    fi
fi

# ── Step 1: bump ─────────────────────────────────────────────
log "[1/10] Bumping Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
ok "$CUR_VERSION (build $CUR_BUILD) → $VERSION (build $NEW_BUILD)"

# ── Step 2: commit bump on dev ──────────────────────────────
log "[2/10] Committing bump on dev"
git add "$PLIST"
git commit -m "chore: bump to $TAG" >/dev/null
ok "committed on dev: $(git rev-parse --short dev)"

# ── Step 3: switch to main + squash merge ────────────────────
log "[3/10] Squash-merging dev into main"
git checkout main --quiet
git merge --squash dev >/dev/null
ok "$((SQUASH_COUNT + 1)) commits squashed and staged"

# ── Step 4: commit on main with CHANGELOG body ───────────────
log "[4/10] Committing on main"
NOTES=$(mktemp -t zhiyin-release-notes.XXXXXX)
trap 'rm -f "$NOTES"' EXIT
# Extract body of [VERSION] section: everything between the header and the next ## [
sed -n "/^## \[$VERSION\]/,/^## \[/{ /^## \[/!p; }" CHANGELOG.md \
    | awk 'NR==1 && /^$/ { next } { print }' \
    > "$NOTES"
[[ -s "$NOTES" ]] || die "CHANGELOG [$VERSION] section is empty"
{
    echo "feat: $TAG"
    echo
    cat "$NOTES"
} | git commit -F - >/dev/null
ok "committed on main: $(git rev-parse --short main)"

# ── Step 5: push main ────────────────────────────────────────
log "[5/10] Pushing main to origin"
git push origin main \
    || die "push main failed — recover with: git push origin main"
ok "main pushed"

# ── Step 6: tag ──────────────────────────────────────────────
log "[6/10] Creating + pushing tag $TAG"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG" \
    || die "tag push failed — recover with: git push origin $TAG"
ok "tag $TAG pushed"

# ── Step 7: build DMG ────────────────────────────────────────
log "[7/10] Building DMG (this takes a few minutes)"
./scripts/make-dmg.sh
DMG="ZhiYin-$TAG-mac-arm64.dmg"
[[ -f "$DMG" ]] || die "DMG not produced at $DMG"
ok "DMG ready: $DMG ($(du -h "$DMG" | cut -f1))"

# ── Step 8: verify notarization ──────────────────────────────
log "[8/10] Verifying notarization"
NOTARIZED=false
if xcrun stapler validate "$DMG" 2>&1 | grep -q "worked"; then
    ok "ticket stapled to DMG"
    NOTARIZED=true
else
    warn "no ticket stapled — DMG is NOT notarized (users will see Gatekeeper warning)"
fi
MOUNT=$(hdiutil attach -nobrowse "$DMG" 2>&1 | grep Volumes | awk '{print $3}' || true)
if [[ -n "${MOUNT:-}" && -d "$MOUNT/ZhiYin.app" ]]; then
    if spctl -a -t exec -v "$MOUNT/ZhiYin.app" 2>&1 | grep -q "Notarized"; then
        ok "Gatekeeper: accepted — Notarized Developer ID"
    else
        warn "Gatekeeper: app not accepted as notarized (may be signed-only)"
    fi
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
fi

# ── Step 9: GitHub Release ───────────────────────────────────
log "[9/10] Creating GitHub Release $TAG"
if ! gh release create "$TAG" \
       --repo "$REPO" \
       --title "$TAG" \
       --notes-file "$NOTES" \
       "$DMG"; then
    die "gh release create failed — recover with:\n  gh release create $TAG --repo $REPO --title $TAG --notes-file $NOTES $DMG"
fi
RELEASE_URL=$(gh release view "$TAG" --repo "$REPO" --json url --jq '.url')
ok "release: $RELEASE_URL"

# ── Step 10: return to dev ───────────────────────────────────
log "[10/10] Returning to dev"
git checkout dev --quiet
ok "back on dev"

# ── summary ──────────────────────────────────────────────────
log "Release $TAG complete"
cat <<EOF
  main:     $(git rev-parse --short main) pushed
  tag:      $TAG pushed
  DMG:      $DMG ($(du -h "$DMG" | cut -f1))$(if $NOTARIZED; then echo " — notarized"; else echo " — NOT notarized"; fi)
  release:  $RELEASE_URL

  Next version: add a [X.Y.Z] section to CHANGELOG.md, then:
    ./scripts/release.sh X.Y.Z
EOF
