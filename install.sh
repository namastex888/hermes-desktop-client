#!/bin/sh
# One-command install of the client-only Hermes Desktop app.
#
#   curl -fsSL https://raw.githubusercontent.com/namastex888/hermes-desktop-client/main/install.sh | sh
#
# Nightly channel (rolling build of upstream main, macOS + Linux):
#
#   curl -fsSL https://raw.githubusercontent.com/namastex888/hermes-desktop-client/main/install.sh | sh -s -- --nightly
#
# Linux (dpkg) -> .deb into /opt/Hermes
# Linux (other) -> AppImage into ~/.local/bin
# macOS        -> .dmg into /Applications
# Windows      -> use install.ps1 instead (see README)
set -eu

REPO=namastex888/hermes-desktop-client
# Pre-releases never appear at /releases/latest, so the nightly channel is
# addressed by its rolling tag.
CHANNEL=latest
[ "${1:-}" = "--nightly" ] && CHANNEL=nightly
if [ "$CHANNEL" = nightly ]; then
  API="https://api.github.com/repos/$REPO/releases/tags/nightly"
else
  API="https://api.github.com/repos/$REPO/releases/latest"
fi

say()  { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"

# --------------------------------------------------------------- release ----
say "resolving $CHANNEL release"
JSON=$(curl -fsSL "$API") || fail "could not reach GitHub"
# Pull asset download URLs without requiring jq.
asset_url() {
  printf '%s' "$JSON" \
    | tr ',' '\n' \
    | grep '"browser_download_url"' \
    | cut -d'"' -f4 \
    | grep -i -- "$1" \
    | head -1
}

# ------------------------------------------------------------- integrity ----
# Every release carries a SHA256SUMS manifest covering all of its assets.
# Verify each download against it. Releases cut before the manifest existed
# simply do not have the asset — warn and continue rather than refusing to
# install from an older release.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else return 1
  fi
}

verify_sha() {
  # $1 = downloaded file, $2 = the asset name as published
  _sums_url=$(asset_url 'SHA256SUMS$') || true
  if [ -z "${_sums_url:-}" ]; then
    say "note: this release predates SHA256SUMS — skipping checksum verification"
    return 0
  fi
  _want=$(curl -fsSL "$_sums_url" | grep -- " \*\{0,1\}$2\$" | cut -d' ' -f1 | head -1)
  if [ -z "${_want:-}" ]; then
    say "note: $2 is absent from SHA256SUMS — skipping checksum verification"
    return 0
  fi
  _got=$(sha256_of "$1") || { say "note: no sha256 tool available — skipping verification"; return 0; }
  [ "$_got" = "$_want" ] || fail "checksum mismatch for $2
  expected $_want
  got      $_got
This download does not match the published manifest. Do not install it."
  say "checksum verified"
}

OS=$(uname -s)
ARCH=$(uname -m)
# electron-builder names assets per-arch; pick the matching one rather than
# grabbing the first of a file type, or an Intel Mac gets an arm64 dmg.
case "$ARCH" in
  x86_64|amd64)  DEB_A=amd64; APP_A=x86_64; MAC_A=x64;   WIN_A=x64 ;;
  arm64|aarch64) DEB_A=arm64; APP_A=arm64;  MAC_A=arm64; WIN_A=arm64 ;;
  *) fail "unsupported architecture: $ARCH" ;;
esac

case "$OS" in
# ------------------------------------------------------------------ linux ----
Linux)
  if command -v dpkg >/dev/null 2>&1; then
    URL=$(asset_url "linux-$DEB_A\.deb$") || true
    [ -n "${URL:-}" ] || fail "no linux-$DEB_A .deb in the latest release (arch $ARCH)"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    say "downloading $(basename "$URL")"
    curl -fsSL -o "$TMP/pkg.deb" "$URL"
    verify_sha "$TMP/pkg.deb" "$(basename "$URL")"
    say "installing (sudo)"
    if command -v apt >/dev/null 2>&1; then
      sudo apt install -y "$TMP/pkg.deb"
    else
      sudo dpkg -i "$TMP/pkg.deb" || sudo apt-get -f install -y
    fi
    say "installed. Launch 'Hermes' from your app menu."
  else
    URL=$(asset_url "linux-$APP_A\.AppImage$") || true
    [ -n "${URL:-}" ] || fail "no linux-$APP_A AppImage in the latest release (arch $ARCH)"
    mkdir -p "$HOME/.local/bin"
    DEST="$HOME/.local/bin/hermes-desktop"
    say "downloading AppImage"
    curl -fsSL -o "$DEST" "$URL"
    verify_sha "$DEST" "$(basename "$URL")"
    chmod +x "$DEST"
    say "installed at $DEST"
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) ;;
      *) say "note: add ~/.local/bin to your PATH" ;;
    esac
  fi
  ;;
# ------------------------------------------------------------------ macos ----
Darwin)
  URL=$(asset_url "mac-$MAC_A\.dmg$") || true
  [ -n "${URL:-}" ] || fail "no mac-$MAC_A .dmg in the latest release (arch $ARCH)"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  say "downloading $(basename "$URL")"
  curl -fsSL -o "$TMP/hermes.dmg" "$URL"
  verify_sha "$TMP/hermes.dmg" "$(basename "$URL")"
  say "mounting"
  MNT=$(hdiutil attach -nobrowse -readonly "$TMP/hermes.dmg" | awk '/\/Volumes\//{print substr($0, index($0,"/Volumes/"))}' | head -1)
  [ -n "$MNT" ] || fail "could not mount the dmg"
  APP=$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)
  [ -n "$APP" ] || { hdiutil detach "$MNT" >/dev/null; fail "no .app inside the dmg"; }
  say "copying to /Applications"
  rm -rf "/Applications/$(basename "$APP")"
  cp -R "$APP" /Applications/
  hdiutil detach "$MNT" >/dev/null
  # The dmg and the app inside are both notarized and stapled, so Gatekeeper
  # clears them on its own — offline, from the stapled ticket. Do NOT strip
  # the quarantine bit here: on a notarized build it buys nothing, and it
  # would throw away the one signal that tells a user this really is our
  # build. Verify instead, and only fall back to stripping when the app is
  # genuinely not notarized (an old release, or a local unsigned build).
  INSTALLED="/Applications/$(basename "$APP")"
  if spctl -a -t exec -vv "$INSTALLED" 2>&1 | grep -q 'source=Notarized Developer ID'; then
    say "verified: notarized by Apple, signed by the Developer ID on record"
  else
    say "WARNING: this build is not notarized — clearing the quarantine flag so it will open"
    xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
  fi
  say "installed. Launch Hermes from /Applications."
  ;;
# ---------------------------------------------------------------- windows ----
MINGW* | MSYS* | CYGWIN*)
  URL=$(asset_url "win-$WIN_A\.exe$") || true
  [ -n "${URL:-}" ] || fail "no win-$WIN_A .exe in the latest release (arch $ARCH)"
  TMP=$(mktemp -d)
  say "downloading installer"
  curl -fsSL -o "$TMP/hermes-setup.exe" "$URL"
  say "launching installer"
  "$TMP/hermes-setup.exe"
  ;;
*)
  fail "unsupported OS: $OS"
  ;;
esac
