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
#
# Usage: ./build.sh --check-paths
#   Run the client-only classifier over newline-delimited package paths on
#   stdin (the form emitted by `dpkg-deb -c | awk '{print $6}'`) and exit
#   non-zero if any path is rejected. No clone, no build, no dpkg-deb —
#   runs natively on any machine with bash.
set -euo pipefail

UPSTREAM_GIT=https://github.com/NousResearch/hermes-agent.git
UPSTREAM_WEB=https://github.com/NousResearch/hermes-agent
SELF_WEB=https://github.com/namastex888/hermes-desktop-client
PKG=hermes-desktop

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HERE/.work}"
OUT="${OUT:-$HERE/dist}"
SRC="$WORK/src"

# ----------------------------------------------------------------- gate ----
# client_only_check — rule-based classifier for the client-only guarantee.
#
# Reads newline-delimited package paths on stdin, normalises each line
# (strip a leading "./" and a trailing "/" — the real form of dpkg-deb -c
# output), then matches PER PATH SEGMENT. A path is rejected when the first
# of these rules fires:
#
#   1  basename ends in .py                     python source
#   2  basename matches *cpython-*.so           CPython extension module
#   3  a segment is exactly site-packages/venv/.venv   venv layout
#   4  basename is exactly pyvenv.cfg           venv marker
#   5  a segment is exactly hermes_agent/hermes_cli    upstream server module
#   6  basename matches ^python[0-9]*(\.[0-9]+)*$      bare interpreter
#   7  a segment matches ^python[0-9]+\.[0-9]+$        interpreter home
#
# Rules 6 and 7 are ANCHORED whole-token matches. That anchoring is the
# entire fix: the old gate grep'd the bare substring `python` and falsely
# fired on dist/assets/python-B5eWn6H5.js — a CodeMirror keyword table for
# the Python syntax mode (a JS object literal, not a runtime). The anchored
# rules leave python-B5eWn6H5.js (hyphen + .js extension) and ruby-*.js
# (the next language mode upstream lazily loads) untouched, while still
# catching a bare interpreter at resources/python3.12/bin/python3 and an
# interpreter home at resources/python3.12/ — neither of which carries any
# structural marker other than its name. If these name-shaped rules ever
# drift back toward substring matching, the must-accept fixtures fail
# immediately.
client_only_check() {
  local line orig base segs seg rule bad=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    orig="$line"
    line="${line#./}"
    line="${line%/}"
    base="${line##*/}"
    rule=0

    # 1 — python source file
    case "$base" in *.py) rule=1 ;; esac

    # 2 — CPython extension module (always *cpython-*.so, never .py)
    if [ "$rule" = 0 ]; then
      case "$base" in *cpython-*.so) rule=2 ;; esac
    fi

    # 3 — venv layout: any segment is a venv marker dir (incl. dir entries)
    if [ "$rule" = 0 ]; then
      IFS=/ read -ra segs <<< "$line"
      for seg in ${segs[@]+"${segs[@]}"}; do
        case "$seg" in
          site-packages|venv|.venv) rule=3; break ;;
        esac
      done
    fi

    # 4 — venv marker file
    if [ "$rule" = 0 ]; then
      case "$base" in pyvenv.cfg) rule=4 ;; esac
    fi

    # 5 — upstream server module directory
    if [ "$rule" = 0 ]; then
      for seg in ${segs[@]+"${segs[@]}"}; do
        case "$seg" in
          hermes_agent|hermes_cli) rule=5; break ;;
        esac
      done
    fi

    # 6 — bare interpreter: whole basename is python[0-9.]* (anchored)
    if [ "$rule" = 0 ] && [[ "$base" =~ ^python[0-9]*(\.[0-9]+)*$ ]]; then
      rule=6
    fi

    # 7 — interpreter home: a whole segment is pythonN.N (anchored)
    if [ "$rule" = 0 ]; then
      for seg in ${segs[@]+"${segs[@]}"}; do
        if [[ "$seg" =~ ^python[0-9]+\.[0-9]+$ ]]; then
          rule=7
          break
        fi
      done
    fi

    if [ "$rule" != 0 ]; then
      printf 'REJECT %s (rule %d)\n' "$orig" "$rule" >&2
      bad=1
    fi
  done
  return "$bad"
}

# --check-paths must be handled BEFORE the TAG/PLATFORM parse below, or the
# flag would flow into `git checkout --detach`. It never touches the network,
# the work dir, or dpkg-deb, so it runs natively on darwin.
if [ "${1:-}" = "--check-paths" ]; then
  client_only_check || exit $?
  exit 0
fi

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
  # Both arches: the macOS runner is Apple Silicon, so an arm64-only build
  # would leave Intel Macs with no installer.
  mac)   TARGETS=(--mac dmg --x64 --arm64) ;;
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

# ------------------------------------------------------------------ icons ----
# Upstream's build.icon is a single 1024x1024 png, so electron-builder installs
# it to hicolor/1024x1024 — a size the hicolor index.theme does not declare.
# GTK then reports has_icon=true but resolves no file, and the launcher shows a
# blank tile with no dock entry. Generate the standard sizes instead.
ICON_FLAGS=()
if [ "$PLATFORM" = linux ]; then
  ICONS="$SRC/apps/desktop/build-icons"
  rm -rf "$ICONS"; mkdir -p "$ICONS"
  if python3 -c "import PIL" 2>/dev/null; then
    python3 - "$SRC/apps/desktop/assets/icon.png" "$ICONS" <<'PY'
import sys
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
for s in (16, 24, 32, 48, 64, 128, 256, 512):
    im.resize((s, s), Image.LANCZOS).save(f"{out}/{s}x{s}.png")
PY
  elif command -v convert >/dev/null 2>&1; then
    for s in 16 24 32 48 64 128 256 512; do
      convert "$SRC/apps/desktop/assets/icon.png" -resize "${s}x${s}" "$ICONS/${s}x${s}.png"
    done
  else
    echo "ERROR: need python3-pil or imagemagick to generate the icon set" >&2
    exit 1
  fi
  ICON_FLAGS=(-c.linux.icon=build-icons)
fi

# ----------------------------------------------------------------- build ----
# Everything upstream omits is supplied here as electron-builder flags, so the
# upstream tree stays byte-identical to the tag we checked out.
cd "$SRC/apps/desktop"
npm run build
# --publish never + a repository field: the AppImage/nsis/dmg targets resolve an
# auto-update publish config (deb does not), and upstream sets no `repository`.
# We ship no updater — apt / re-running install.sh is the update path — so the
# config exists only to satisfy the packager.
# ${a[@]+"${a[@]}"} — bash 3.2 (macOS) errors on an empty array under set -u.
npm run builder -- "${TARGETS[@]}" ${ICON_FLAGS[@]+"${ICON_FLAGS[@]}"} --publish never \
  -c.extraMetadata.name="$PKG" \
  -c.extraMetadata.version="$VER" \
  -c.extraMetadata.homepage="$UPSTREAM_WEB" \
  -c.extraMetadata.repository="$SELF_WEB" \
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
  # The classifier prints one REJECT <path> (rule <N>) line per match;
  # the summary below follows if any path failed.
  if ! client_only_check <<<"$FILES"; then
    echo "ERROR: server components found in a client-only package" >&2
    exit 1
  fi
  grep -q 'LICENSE' <<<"$FILES" || { echo "ERROR: upstream LICENSE missing" >&2; exit 1; }
  # A single 1024x1024 icon is the bug this build works around — catch a regression.
  SIZES=$(grep -cE 'icons/hicolor/(48x48|128x128|256x256)/apps/' <<<"$FILES")
  [ "$SIZES" -ge 3 ] || { echo "ERROR: standard icon sizes missing (got $SIZES)" >&2; exit 1; }
  echo "==> clean: no server components, licence + icon set present"
fi
