#!/usr/bin/env bash
# Pulls the repo, downloads the latest (or given) GitHub release of Spotube Lite — both the macOS
# .zip and the iOS .ipa — installs the Mac app into /Applications with quarantine removed, and
# leaves the .ipa in IPA_DIR (default ~/Downloads) for sideloading.
#
# Usage:
#   ./install-latest.sh              # install if a newer version is available
#   ./install-latest.sh --force      # reinstall even if up to date
#   ./install-latest.sh --no-launch  # don't open the app afterwards
#   ./install-latest.sh v1.0.3       # a specific release
#
# Env: APP_DIR (default /Applications), IPA_DIR (default ~/Downloads).
set -euo pipefail

REPO="Qerope/Spotube-SwiftUI"
APP_NAME="SpotubeLite"
APP_DIR="${APP_DIR:-/Applications}"
IPA_DIR="${IPA_DIR:-$HOME/Downloads}"

FORCE=false; LAUNCH=true; TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force) FORCE=true; shift ;;
    --no-launch) LAUNCH=false; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) TAG="v${1#v}"; shift ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }
warn() { printf '\033[33mWarning: %s\033[0m\n' "$1" >&2; }

command -v gh >/dev/null || fail "GitHub CLI (gh) is not installed: brew install gh"

# Full YouTube audio on macOS is decoded by yt-dlp (needs a JS runtime: deno).
for tool in yt-dlp deno; do
  if ! command -v "$tool" >/dev/null; then
    command -v brew >/dev/null || fail "$tool is missing and Homebrew isn't installed"
    step "Installing $tool"; brew install -q "$tool"
  fi
done
brew upgrade -q yt-dlp >/dev/null 2>&1 || true   # YouTube changes often; keep yt-dlp current

# --- Pull --------------------------------------------------------------------------------
cd "$(dirname "$0")"
if git rev-parse --git-dir >/dev/null 2>&1; then
  step "Pulling latest source"
  git pull --ff-only --quiet && git log --oneline -1 || warn "git pull failed (local changes?); continuing"
fi

# --- Find the release --------------------------------------------------------------------
step "Looking up the ${TAG:-latest} release of $REPO"
TAG=$(gh release view ${TAG:+"$TAG"} --repo "$REPO" --json tagName --jq .tagName) || fail "No release found"
VERSION="${TAG#v}"
ZIP="$APP_NAME-$TAG.zip"; IPA="$APP_NAME-$TAG.ipa"
echo "Release: $TAG"

TARGET="$APP_DIR/$APP_NAME.app"; INSTALLED=""
if [[ -d "$TARGET" ]]; then
  INSTALLED=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$TARGET/Contents/Info.plist" 2>/dev/null || true)
  echo "Installed: ${INSTALLED:-unknown version}"
else echo "Installed: none"; fi
UP_TO_DATE=false
[[ "$INSTALLED" == "$VERSION" && "$FORCE" == false ]] && UP_TO_DATE=true

# --- Download both -----------------------------------------------------------------------
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
step "Downloading $ZIP and $IPA"
gh release download "$TAG" --repo "$REPO" --pattern "$ZIP" --pattern "$IPA" --dir "$WORK" \
  || fail "Release $TAG is missing $ZIP or $IPA"
mkdir -p "$IPA_DIR"; cp -f "$WORK/$IPA" "$IPA_DIR/"
xattr -d com.apple.quarantine "$IPA_DIR/$IPA" 2>/dev/null || true
echo "iOS app: $IPA_DIR/$IPA (sideload with AltStore / Sideloadly / Xcode)"

if [[ "$UP_TO_DATE" == true ]]; then echo "Mac app already up to date. Use --force to reinstall."; exit 0; fi

ditto -x -k "$WORK/$ZIP" "$WORK/unzipped"
NEW_APP="$WORK/unzipped/$APP_NAME.app"
[[ -d "$NEW_APP" ]] || fail "$ZIP does not contain $APP_NAME.app"
codesign --verify --deep --strict "$NEW_APP" 2>/dev/null || fail "The downloaded app's signature is broken; not installing it"
echo "Signed by: $(codesign -dvv "$NEW_APP" 2>&1 | sed -n 's/^Authority=//p' | head -1 | grep . || echo ad-hoc)"

# --- Replace the installed app -----------------------------------------------------------
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$NEW_APP/Contents/Info.plist")
if pgrep -xq "$APP_NAME"; then
  step "Quitting the running $APP_NAME"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq "$APP_NAME" || break; sleep 0.25; done
  pgrep -xq "$APP_NAME" && { pkill -x "$APP_NAME" || true; sleep 1; }
fi

step "Installing into $APP_DIR"
mkdir -p "$APP_DIR"; SUDO=""
[[ -w "$APP_DIR" && ( ! -e "$TARGET" || -w "$TARGET" ) ]] || { SUDO="sudo"; echo "Needs administrator rights to write to $APP_DIR."; }
$SUDO rm -rf "$TARGET"
$SUDO ditto "$NEW_APP" "$TARGET"
$SUDO xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
spctl --assess --type execute "$TARGET" 2>/dev/null && echo "Gatekeeper: accepted (notarized)." \
  || warn "Not notarized; removed the quarantine flag so it opens on this Mac anyway."
echo "Installed Spotube Lite $VERSION${INSTALLED:+ (was $INSTALLED)}."

[[ "$LAUNCH" == true ]] && open "$TARGET"
exit 0
