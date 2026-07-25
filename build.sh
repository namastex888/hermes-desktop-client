#!/usr/bin/env bash
# Build a CLIENT-ONLY Hermes Desktop .deb from upstream source.
#
# Upstream configures a deb target but omits `homepage`, so their Linux build
# dies at the fpm stage — which is why they ship .exe and .dmg but no .deb.
# We inject the missing metadata at build time. No fork, no patch, no diff to
# rebase: upstream is consumed verbatim at a release tag.
#
# The result contains the Electron client only — no Python, no venv, no
# gateway, no server. Updates come from apt, not from an in-app updater.
#
# Usage: ./build.sh [tag]      (default: latest upstream release)
set -euo pipefail

UPSTREAM_GIT=https://github.com/NousResearch/hermes-agent.git
UPSTREAM_WEB=https://github.com/NousResearch/hermes-agent
PKG=hermes-desktop

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HERE/.work}"
OUT="${OUT:-$HERE/dist}"
SRC="$WORK/src"

TAG="${1:-}"
if [ -z "$TAG" ]; then
  TAG=$(gh api repos/NousResearch/hermes-agent/releases/latest --jq .tag_name)
fi
VER="${TAG#v}"          # deb version mirrors the upstream release tag

echo "==> upstream $TAG  ->  ${PKG}_${VER}_amd64.deb"

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

# MIT requires the licence + copyright notice to ship with binaries.
# Upstream's deb bundles only the Electron/Chromium licences, so add theirs.
cp "$SRC/LICENSE" "$SRC/apps/desktop/LICENSE"

# ----------------------------------------------------------------- build ----
cd "$SRC/apps/desktop"
npm run build
npm run builder -- --linux deb \
  -c.extraMetadata.name="$PKG" \
  -c.extraMetadata.version="$VER" \
  -c.extraMetadata.homepage="$UPSTREAM_WEB" \
  -c.extraFiles=LICENSE

# ---------------------------------------------------------------- collect ----
DEB=$(find "$SRC/apps/desktop/release" -maxdepth 1 -name '*.deb' | head -1)
[ -n "$DEB" ] || { echo "ERROR: no .deb produced" >&2; exit 1; }
mv -f "$DEB" "$OUT/${PKG}_${VER}_amd64.deb"
echo "==> $OUT/${PKG}_${VER}_amd64.deb"

# ------------------------------------------------------------------ gate ----
# Fail loudly if server bloat ever leaks in — that is the whole point.
FILES=$(dpkg-deb -c "$OUT/${PKG}_${VER}_amd64.deb" | awk '{print $6}')
if grep -qiE 'python|site-packages|hermes_cli|hermes_agent|uvicorn' <<<"$FILES"; then
  echo "ERROR: server components found in a client-only package" >&2
  exit 1
fi
grep -q 'LICENSE' <<<"$FILES" || { echo "ERROR: upstream LICENSE missing" >&2; exit 1; }
echo "==> clean: no server components, licence present"
