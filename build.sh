#!/usr/bin/env bash
# Build CLIENT-ONLY Hermes Desktop installers from upstream source.
#
# Upstream configures a deb target but omits `homepage`, so their Linux build
# dies at the fpm stage — which is why they ship .exe and .dmg but no .deb.
# We inject the missing metadata at build time. No fork, no patch, no diff to
# rebase: upstream is consumed verbatim at a release tag.
#
# The result contains the Electron client only — no Python, no venv, no
# gateway, no server. Updates come from the package manager, not an in-app
# updater.
#
# Usage: ./build.sh [tag] [platform]
#   tag       upstream tag (default: latest release)
#   platform  linux | mac | win   (default: detected from uname)
set -euo pipefail

UPSTREAM_GIT=https://github.com/NousResearch/hermes-agent.git
UPSTREAM_WEB=https://github.com/NousResearch/hermes-agent
PKG=hermes-desktop

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HERE/.work}"
OUT="${OUT:-$HERE/dist}"
SRC="$WORK/src"

TAG="${1:-}"
PLATFORM="${2:-}"

if [ -z "$TAG" ]; then
  TAG=$(gh api repos/NousResearch/hermes-agent/releases/latest --jq .tag_name)
fi
VER="${TAG#v}"          # version mirrors the upstream release tag

if [ -z "$PLATFORM" ]; then
  case "$(uname -s)" in
    Linux)  PLATFORM=linux ;;
    Darwin) PLATFORM=mac ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM=win ;;
    *) echo "ERROR: cannot detect platform" >&2; exit 1 ;;
  esac
fi

case "$PLATFORM" in
  linux) TARGETS=(--linux deb AppImage) ;;
  mac)   TARGETS=(--mac dmg) ;;
  win)   TARGETS=(--win nsis) ;;
  *) echo "ERROR: unknown platform '$PLATFORM'" >&2; exit 1 ;;
esac

echo "==> upstream $TAG -> $PKG $VER ($PLATFORM)"

# ---------------------------------------------------------------- source ----
mkdir -p "$WORK" "$OUT"
if [ ! -d "$SRC/.git" ]; then
  git clone --filter=blob:none "$UPSTREAM_GIT" "$SRC"
fi
git -C "$SRC" fetch --tags --force origin
git -C "$SRC" checkout --detach "$TAG"
git -C "$SRC" clean -xdf -e node_modules -e apps/desktop/node_modules

# ------------------------------------------------------------------ deps ----
( cd "$SRC" && npm ci --no-audit --no-fund )

# MIT requires the licence + copyright notice to ship with binaries. Upstream's
# packaging bundles only the Electron/Chromium licences, so add theirs.
cp "$SRC/LICENSE" "$SRC/apps/desktop/LICENSE"

# ----------------------------------------------------------------- build ----
# Everything upstream omits is supplied here as electron-builder flags, so the
# upstream tree stays byte-identical to the tag we checked out.
cd "$SRC/apps/desktop"
npm run build
npm run builder -- "${TARGETS[@]}" \
  -c.extraMetadata.name="$PKG" \
  -c.extraMetadata.version="$VER" \
  -c.extraMetadata.homepage="$UPSTREAM_WEB" \
  -c.extraFiles=LICENSE

# --------------------------------------------------------------- collect ----
shopt -s nullglob
found=0
for f in release/*.deb release/*.AppImage release/*.dmg release/*.exe; do
  mv -f "$f" "$OUT/"
  echo "==> $OUT/$(basename "$f")"
  found=1
done
[ "$found" = 1 ] || { echo "ERROR: no installer produced" >&2; exit 1; }

# ------------------------------------------------------------------ gate ----
# Fail loudly if server bloat ever leaks in — that is the whole point.
# Verifiable directly only on the deb; the payload is identical across targets.
if [ "$PLATFORM" = linux ]; then
  DEB=$(ls "$OUT"/*.deb | head -1)
  FILES=$(dpkg-deb -c "$DEB" | awk '{print $6}')
  if grep -qiE 'python|site-packages|hermes_cli|hermes_agent|uvicorn' <<<"$FILES"; then
    echo "ERROR: server components found in a client-only package" >&2
    exit 1
  fi
  grep -q 'LICENSE' <<<"$FILES" || { echo "ERROR: upstream LICENSE missing" >&2; exit 1; }
  echo "==> clean: no server components, licence present"
fi
