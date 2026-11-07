#!/usr/bin/env bash
# Commits all changes, pushes, builds the macOS .app (zipped) and an unsigned iOS .ipa, and
# publishes both as a GitHub release on Qerope/Spotube-SwiftUI, then adds the .ipa to the AltStore
# source on the server (https://qerope.me/spotube/altstore/source.json; skip with NO_ALTSTORE=1).
#
# With a "Developer ID Application" certificate + notary profile the Mac app is also notarized
# (opens on any Mac); otherwise it is ad-hoc signed (install-latest.sh strips quarantine).
# The .ipa is unsigned: sideload it with AltStore / Sideloadly / Xcode, which sign it for you.
#
# Usage:
#   ./release.sh                     # next patch version (v1.0.0 -> v1.0.1)
#   ./release.sh -m "Fix login"      # with a commit message
#   ./release.sh 1.2.0 [-m "..."]    # a specific version
set -euo pipefail

REPO="Qerope/Spotube-SwiftUI"
SCHEME="SpotubeLite"
APP_NAME="SpotubeLite"
NOTARY_PROFILE="${NOTARY_PROFILE:-SpotubeLite-notary}"
SERVER="${SERVER:-ubuntu@204.216.106.35}"      # hosts the AltStore source (see Server/altstore.py)

cd "$(dirname "$0")"

VERSION=""; MESSAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message) MESSAGE="${2:?missing message after $1}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) VERSION="${1#v}"; shift ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }
warn() { printf '\033[33mWarning: %s\033[0m\n' "$1" >&2; }

command -v gh >/dev/null || fail "GitHub CLI (gh) is not installed: brew install gh"
command -v xcodegen >/dev/null || fail "xcodegen is not installed: brew install xcodegen"
gh auth status >/dev/null 2>&1 || fail "Not logged in to GitHub. Run: gh auth login"

# --- Version -----------------------------------------------------------------------------
git fetch --tags --quiet origin 2>/dev/null || true
if [[ -z "$VERSION" ]]; then
  LATEST=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)
  if [[ -z "$LATEST" ]]; then VERSION="1.0.0"
  else IFS=. read -r MAJOR MINOR PATCH <<< "${LATEST#v}"; VERSION="$MAJOR.$MINOR.$((PATCH + 1))"; fi
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must look like 1.2.3 (got '$VERSION')"
TAG="v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "Tag $TAG already exists"
echo "Releasing $TAG"

PREV_TAG=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)

# --- Commit ------------------------------------------------------------------------------
step "Committing changes"
git add -A
if git diff --cached --quiet; then echo "Nothing to commit."
else git commit -q -m "${MESSAGE:-Release $TAG}"; git log --oneline -1; fi

# --- Build -------------------------------------------------------------------------------
BUILD_DIR="build"; DERIVED="$BUILD_DIR/DerivedData"; mkdir -p "$BUILD_DIR"
BUILD_NUMBER=$(git rev-list --count HEAD)
# Never ship the server token in public release assets: pair devices with the QR code in Settings instead.
# The project references the file, so an empty placeholder takes its place during the build.
if [[ -f Config/server.json ]]; then mv Config/server.json Config/server.json.local; trap 'mv Config/server.json.local Config/server.json' EXIT; fi
echo '{}' > Config/server.json
xcodegen -q
build() { # $1 = destination, $2 = log name, rest = extra settings
  local dest="$1" log="$BUILD_DIR/$2.log"; shift 2
  if ! xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release \
      -destination "$dest" -derivedDataPath "$DERIVED" \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "$@" build > "$log" 2>&1; then
    grep -E 'error:' "$log" | sort -u | head -20 || tail -30 "$log"
    fail "Build failed; full log in $log"
  fi
}

step "Building macOS app"
build 'generic/platform=macOS' macos
APP_PATH="$DERIVED/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || fail "Built app not found at $APP_PATH"

step "Building iOS app"
build 'generic/platform=iOS' ios CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
IOS_APP="$DERIVED/Build/Products/Release-iphoneos/$APP_NAME.app"
[[ -d "$IOS_APP" ]] || fail "Built iOS app not found at $IOS_APP"
IPA="$BUILD_DIR/$APP_NAME-$TAG.ipa"
rm -rf "$BUILD_DIR/Payload" "$IPA"; mkdir -p "$BUILD_DIR/Payload"
cp -R "$IOS_APP" "$BUILD_DIR/Payload/"
# Ad-hoc sign with entitlements so AltStore/SideStore register the App Group the widget shares with the app.
P="$BUILD_DIR/Payload/$APP_NAME.app"
for X in "$P"/PlugIns/*.appex; do [[ -d "$X" ]] && codesign -f -s - --entitlements Widgets/Widgets.entitlements "$X"; done
codesign -f -s - --entitlements Sources/App-iOS.entitlements "$P"
(cd "$BUILD_DIR" && zip -qry "$(basename "$IPA")" Payload) && rm -rf "$BUILD_DIR/Payload"
echo "Built $IPA ($(du -h "$IPA" | cut -f1))"

# --- Signing (macOS) ---------------------------------------------------------------------
# One-time setup to make it open on any Mac (paid Apple Developer Program):
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials SpotubeLite-notary --apple-id YOU --team-id TEAM
ZIP="$BUILD_DIR/$APP_NAME-$TAG.zip"
DEV_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p' | head -1)
if [[ -n "$DEV_ID" ]]; then
  step "Signing with $DEV_ID"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "No notarization credentials in keychain profile '$NOTARY_PROFILE'. See 'Signing' in $0."
  codesign --force --options runtime --timestamp --entitlements Sources/App.entitlements --sign "$DEV_ID" "$APP_PATH"
  step "Notarizing (usually takes a few minutes)"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP_PATH" "$ZIP"
  OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  echo "$OUT" | grep -q 'status: Accepted' || { echo "$OUT"; fail "Notarization failed (nothing was pushed or released)"; }
  xcrun stapler staple -q "$APP_PATH"
else
  warn "No 'Developer ID Application' certificate: ad-hoc signed. Other Macs need install-latest.sh (strips quarantine)."
  codesign --force --deep --sign - --entitlements Sources/App.entitlements "$APP_PATH"
fi
rm -f "$ZIP"; ditto -c -k --keepParent "$APP_PATH" "$ZIP"
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1))"

# --- Push + release ----------------------------------------------------------------------
step "Pushing to GitHub"
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
git tag -a "$TAG" -m "$TAG"
git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
git push origin "$TAG"

step "Creating GitHub release $TAG"
gh release create "$TAG" "$ZIP" "$IPA" --repo "$REPO" --title "Spotube Lite $TAG" --generate-notes

# --- AltStore -----------------------------------------------------------------------------
if [[ -z "${NO_ALTSTORE:-}" ]]; then
  step "Publishing to the AltStore source"
  NOTES="$BUILD_DIR/notes.txt"
  git log --no-merges --format='• %s' ${PREV_TAG:+"$PREV_TAG..HEAD"} | grep -v '^• Release v' | head -15 > "$NOTES" || true
  if scp -q "$IPA" "$NOTES" "$SERVER:/tmp/" \
     && scp -q Sources/Assets.xcassets/AppIcon.appiconset/ios1024.png "$SERVER:/opt/spotube/data/altstore/icon.png" \
     && ssh "$SERVER" bash -c "'mv /tmp/$(basename "$IPA") /opt/spotube/data/altstore/ && chmod 644 /opt/spotube/data/altstore/* \
          && python3 /opt/spotube/altstore.py $(basename "$IPA") $VERSION $BUILD_NUMBER /tmp/notes.txt'"; then
    echo "AltStore source: https://qerope.me/spotube/altstore/source.json"
  else
    warn "Could not update the AltStore source (GitHub release is done). Retry later or check $SERVER."
  fi
fi

printf '\n\033[32mDone:\033[0m %s\n' "$(gh release view "$TAG" --repo "$REPO" --json url --jq .url)"
