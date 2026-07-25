#!/bin/sh
# One-command install of the client-only Hermes Desktop app.
#
#   curl -fsSL https://raw.githubusercontent.com/namastex888/hermes-desktop-client/main/install.sh | sh
#
# Linux (dpkg) -> .deb into /opt/Hermes
# Linux (other) -> AppImage into ~/.local/bin
# macOS        -> .dmg into /Applications
# Windows      -> use install.ps1 instead (see README)
set -eu

REPO=namastex888/hermes-desktop-client
API="https://api.github.com/repos/$REPO/releases/latest"

say()  { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"

# --------------------------------------------------------------- release ----
say "resolving latest release"
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
  say "mounting"
  MNT=$(hdiutil attach -nobrowse -readonly "$TMP/hermes.dmg" | awk '/\/Volumes\//{print substr($0, index($0,"/Volumes/"))}' | head -1)
  [ -n "$MNT" ] || fail "could not mount the dmg"
  APP=$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)
  [ -n "$APP" ] || { hdiutil detach "$MNT" >/dev/null; fail "no .app inside the dmg"; }
  say "copying to /Applications"
  rm -rf "/Applications/$(basename "$APP")"
  cp -R "$APP" /Applications/
  hdiutil detach "$MNT" >/dev/null
  # Unsigned build: strip the quarantine bit or Gatekeeper refuses to open it.
  xattr -dr com.apple.quarantine "/Applications/$(basename "$APP")" 2>/dev/null || true
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
