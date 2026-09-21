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

UPSTREAM_GIT="https://${GH_TOKEN:+x-access-token:${GH_TOKEN}@}github.com/NousResearch/hermes-agent.git"
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
# Version mirrors the upstream release tag. Nightly builds check out a bare
# commit whose sha is no version — the workflow supplies a date-based one.
VER="${VER_OVERRIDE:-${TAG#v}}"

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

# ------------------------------------------------------------------ sign ----
# electron-builder signs the mac build by itself when CSC_LINK/CSC_KEY_PASSWORD
# are in the environment, and notarizes when told to (APPLE_ID,
# APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID). All five are CI secrets — on
# forks and local builds they are absent and the dmg stays unsigned as before.
MAC_SIGN=()
SIGNED=0
if [ "$PLATFORM" = mac ] && [ -n "${APPLE_ID:-}" ]; then
  MAC_SIGN=(-c.mac.notarize=true -c.mac.hardenedRuntime=true)
  SIGNED=1
  echo "==> mac signing + notarization enabled"
fi

# setup_keychain — import the signing cert ourselves, before electron-builder.
#
# electron-builder's own p12 import dies on its last step:
#
#   /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k ***
#     <tmp>/a31cc02c...keychain
#   security: SecKeychainUnlock: The user name or passphrase you entered is
#   not correct.
#
# The password is fine. That keychain path is a hash of the certificate, so it
# is the SAME file on every run; electron-builder creates it with a fresh
# random password each time but does not delete a pre-existing one, so once a
# stale keychain is present the new password no longer opens it and every
# subsequent signed build fails. The cert had already been imported by then —
# which is why the unsigned fallback still produced a signed app, having
# auto-discovered the identity that the "failed" import left behind.
#
# So do the import in a keychain we name, create and unlock ourselves. With
# CSC_LINK then unset, electron-builder skips its own import and finds the
# identity by auto-discovery over the search list, and -c.mac.notarize survives
# — which the unsigned fallback drops, shipping a signed but un-notarized dmg.
KEYCHAIN=hermes-build.keychain
setup_keychain() {
  local kcpw p12="$WORK/cert.p12"
  kcpw="$(openssl rand -hex 16)"

  # CSC_LINK is base64-encoded p12 in CI; electron-builder also accepts a path.
  if [ -f "$CSC_LINK" ]; then
    cp "$CSC_LINK" "$p12"
  else
    printf '%s' "$CSC_LINK" | base64 --decode > "$p12"
  fi

  # Left over from an earlier run on a warm runner — the whole bug above.
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true

  security create-keychain -p "$kcpw" "$KEYCHAIN"
  # -lut: no auto-lock mid-notarization (the wait can run long).
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$kcpw" "$KEYCHAIN"
  security import "$p12" -k "$KEYCHAIN" -P "$CSC_KEY_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
  # Keep the login keychain in the search list; codesign needs the Apple
  # intermediate certificates that live there.
  security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
  # Authorise codesign to use the key without an interactive prompt. This is
  # the call that fails inside electron-builder; here the password is one we
  # just set on a keychain we just created, so it opens.
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$kcpw" "$KEYCHAIN" >/dev/null
  rm -f "$p12"

  # Same pipefail/SIGPIPE trap as in verify_dmg — capture, then match.
  local found
  found="$(security find-identity -v -p codesigning "$KEYCHAIN" 2>&1 || true)"
  case "$found" in (*"Developer ID Application"*) return 0 ;; esac
  return 1
}

if [ "$SIGNED" = 1 ] && [ -n "${CSC_LINK:-}" ]; then
  mkdir -p "$WORK"
  if setup_keychain; then
    echo "==> signing identity imported into $KEYCHAIN"
    export CSC_KEYCHAIN="$KEYCHAIN"
    unset CSC_LINK CSC_KEY_PASSWORD
  else
    # Not fatal: leave CSC_LINK in place and let electron-builder try its own
    # import, with the retry/unsigned fallback below as the last line of defence.
    echo "==> WARNING: could not import the signing cert; leaving it to electron-builder" >&2
  fi
fi

echo "==> upstream $TAG -> $PKG $VER ($PLATFORM)"

# ---------------------------------------------------------------- source ----
mkdir -p "$WORK" "$OUT"

# The macOS runners share a small pool of egress IPs and GitHub throttles them
# hard: `error: RPC failed; HTTP 429` mid-clone, killing the build at exit 128
# before a single file is packaged. Authenticating the clone (see git history)
# raised the ceiling but did not remove it — the token is scoped to THIS repo,
# so cloning upstream still counts against the shared anonymous budget.
#
# 429 is a wait-and-retry signal, not an error, so treat it as one — but the
# throttling was self-inflicted. This used to clone with --filter=blob:none,
# which downloads no file contents up front and then fetches them lazily from
# the promisor remote as `git checkout` touches them: thousands of small
# requests for one checkout, which is exactly the traffic shape a rate limiter
# exists to stop. The tell was the last error of a failing run —
#
#   fatal: could not fetch 354ff6b... from promisor remote
#   warning: Clone succeeded, but checkout failed.
#
# — a checkout dying on a fetch, long after the clone reported success.
#
# A --depth 1 fetch of the one ref we build takes a single request and carries
# its blobs with it. Nothing lazy is left to fetch, so the checkout is local,
# and it is faster besides. Retries remain, with exponential backoff, for the
# throttling we cannot avoid. GitHub periodically applies anti-scraping limits
# to the upstream repo itself: while one is in force, `git clone` AND the
# source tarball both return 429 ("This request was rate-limited due to too
# many requests") for everyone, authenticated or not — reproducible from a
# laptop with a personal token, so it is not a runner-IP or token-scope
# problem and no credential change fixes it. It clears within minutes, which
# is what the backoff is for.
fetch_source() {
  local attempt=1 max=8 delay=20
  # Test for $SRC/.git directly, NOT `git -C "$SRC" rev-parse --git-dir`:
  # $SRC lives at .work/src, inside this repo's own checkout, so rev-parse
  # walks up and happily reports the OUTER repository. Trusting it skips the
  # init and points every command below — remote, fetch, checkout — at
  # hermes-desktop-client itself, which checks upstream's tree out over the
  # workspace and then fails in `git clean` with "failed to remove ./".
  mkdir -p "$SRC"
  [ -d "$SRC/.git" ] || git init -q "$SRC"
  git -C "$SRC" remote remove origin 2>/dev/null || true
  git -C "$SRC" remote add origin "$UPSTREAM_GIT"
  while true; do
    # One request, blobs included. $TAG is a tag for the release channel and a
    # bare sha for nightly; github.com serves both (allowReachableSHA1InWant).
    if git -C "$SRC" fetch --depth 1 --force origin "$TAG" \
       && git -C "$SRC" checkout --detach FETCH_HEAD; then
      return 0
    fi
    if [ "$attempt" -ge "$max" ]; then
      echo "ERROR: could not fetch upstream $TAG after $max attempts" >&2
      return 1
    fi
    echo "==> upstream fetch failed (attempt $attempt/$max) — retrying in ${delay}s" >&2
    sleep "$delay"
    # Cap the backoff: the throttle lifts on its own within minutes, so a
    # doubling delay would end up waiting far longer than the block lasts.
    [ "$delay" -ge 300 ] || delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}
fetch_source
git -C "$SRC" clean -xdf -e node_modules -e apps/desktop/node_modules

# ------------------------------------------------------------------ deps ----
# Retry: `npm ci` here is not just a registry fetch. Electron's postinstall
# (`node install.js`) downloads the ~100MB Electron binary from a separate
# host, and that host returns 5xx often enough to break a build on its own:
#
#   npm error command sh -c node install.js
#   npm error HTTPError: Response code 504 (Gateway Time-out)
#
# Nothing about that is our tree, and the next attempt normally succeeds — the
# same shape as the upstream-clone 429s and the keychain race, both of which
# already retry. An unretried transient here fails a 30-minute three-platform
# release build at its second minute.
install_deps() {
  local attempt=1 max=4 delay=15
  while true; do
    if ( cd "$SRC" && npm ci --no-audit --no-fund ); then
      return 0
    fi
    if [ "$attempt" -ge "$max" ]; then
      echo "ERROR: npm ci failed after $max attempts" >&2
      return 1
    fi
    echo "==> npm ci failed (attempt $attempt/$max) — retrying in ${delay}s" >&2
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}
install_deps

# MIT requires the licence + copyright notice to ship with binaries. Upstream's
# packaging bundles only the Electron/Chromium licences, so add theirs. Shipped
# via extraResources (Contents/Resources on mac), NOT extraFiles: extraFiles
# lands at the Contents/ root, where codesign rejects it as an unsigned
# subcomponent and the signed nightly build fails.
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
run_builder() {
  npm run builder -- "${TARGETS[@]}" ${ICON_FLAGS[@]+"${ICON_FLAGS[@]}"} \
    ${MAC_SIGN[@]+"${MAC_SIGN[@]}"} --publish never \
    -c.extraMetadata.name="$PKG" \
    -c.extraMetadata.version="$VER" \
    -c.extraMetadata.homepage="$UPSTREAM_WEB" \
    -c.extraMetadata.repository="$SELF_WEB" \
    -c.extraResources=LICENSE
}

# electron-builder imports the p12 into a throwaway keychain, and that import
# fails intermittently on the macOS runners:
#
#   security: SecKeychainUnlock: The user name or passphrase you entered is
#   not correct.  (/usr/bin/security set-key-partition-list ... failed 1)
#
# The credentials are fine — the same secrets sign and notarize successfully
# on the very next run. It is a race in the keychain setup, not a bad password,
# so the cure is to try again rather than to go digging in the secrets.
#
# Retry the whole packaging step — the keychain race is transient and the next
# attempt normally wins.
#
# There is deliberately NO unsigned fallback. This used to downgrade to an
# unsigned build when every signed attempt failed, on the reasoning that a
# stalled release channel is worse than an unsigned dmg. That trade is wrong
# for a signed channel: the fallback turns a loud, fixable signing failure into
# a green build that publishes an artifact Gatekeeper rejects, and it does so
# at exactly the moment nobody is watching (a 06:30 cron). Shipping an
# unsigned binary under a release that claims to be notarized is worse than
# shipping nothing, so when the credentials are present, signing is mandatory
# and a failure is fatal. Set ALLOW_UNSIGNED=1 to opt back in — for local
# experiments, never in CI.
BUILD_ATTEMPTS="${BUILD_ATTEMPTS:-3}"
attempt=1
while true; do
  if run_builder; then
    break
  fi
  if [ "$attempt" -lt "$BUILD_ATTEMPTS" ]; then
    echo "==> build attempt $attempt/$BUILD_ATTEMPTS failed — retrying in 15s" >&2
    sleep 15
    attempt=$((attempt + 1))
    continue
  fi
  if [ "$SIGNED" = 1 ] && [ "${ALLOW_UNSIGNED:-0}" = 1 ]; then
    echo "==> WARNING: $BUILD_ATTEMPTS signed builds failed; ALLOW_UNSIGNED=1 — retrying UNSIGNED" >&2
    echo "==> WARNING: the resulting dmg will not be signed or notarized" >&2
    MAC_SIGN=()
    SIGNED=0
    unset CSC_LINK CSC_KEY_PASSWORD APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID
    run_builder
    break
  fi
  echo "ERROR: build failed after $BUILD_ATTEMPTS attempts" >&2
  [ "$SIGNED" = 1 ] && echo "ERROR: signing credentials were present — refusing to publish unsigned" >&2
  exit 1
done

# --------------------------------------------------------------- collect ----
shopt -s nullglob
found=0
for f in release/*.deb release/*.AppImage release/*.dmg release/*.exe; do
  mv -f "$f" "$OUT/"
  echo "==> $OUT/$(basename "$f")"
  found=1
done
[ "$found" = 1 ] || { echo "ERROR: no installer produced" >&2; exit 1; }

# -------------------------------------------------------- notarize (mac) ----
# electron-builder's `notarize` option notarizes and staples the .app during
# its afterSign phase — which runs BEFORE the dmg is packaged. The dmg built
# around that app is itself left unsigned and unstapled. That is what this
# repo published for every signed release so far:
#
#   $ codesign -dv Hermes-2026.9.14-mac-arm64.dmg
#   code object is not signed at all
#   $ xcrun stapler validate Hermes-2026.9.14-mac-arm64.dmg
#   ...does not have a ticket stapled to it
#   $ spctl -a -t open --context context:primary-signature -v <dmg>
#   rejected (source=no usable signature)
#
# The app INSIDE verified clean the entire time — "accepted, source=Notarized
# Developer ID" — so the build logs said "notarization successful" and nothing
# ever looked wrong. But the dmg is what the user downloads, and the dmg is
# what carries the quarantine bit. Gatekeeper evaluates the disk image first,
# finds no signature and no ticket, and blocks it. That is the "damaged"
# dialog the README has been telling people to defeat with
# `xattr -dr com.apple.quarantine` — not a quirk of unsigned builds, a real
# gap in this pipeline.
#
# So: sign the container, notarize the container, staple the ticket to it.
# The stapling is what buys OFFLINE verification. Without a stapled ticket
# Gatekeeper must reach Apple to confirm the notarization, and a first launch
# on a plane or behind a strict firewall fails.
signing_identity() {
  # Capture, then parse. `security | awk '{...; exit}'` is the same
  # pipefail/SIGPIPE trap as the checks in verify_dmg: awk's `exit` can close
  # the pipe while security is still writing, security reports 141, and under
  # `set -o pipefail` the command substitution fails — taking `set -e` and the
  # whole build with it, on the one line that decides whether we can sign.
  local ids
  ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  printf '%s\n' "$ids" | awk '/Developer ID Application/ { print $2; exit }'
}

notarize_dmg() {
  local dmg="$1" id="$2" base
  base="$(basename "$dmg")"

  # --timestamp is not optional: notarytool rejects a signature that carries
  # no secure timestamp. --force replaces any signature already there.
  echo "==> signing $base"
  codesign --sign "$id" --timestamp --force "$dmg"

  echo "==> notarizing $base (waiting on Apple)"
  # --wait blocks until Apple returns a verdict; a non-Accepted status exits
  # non-zero, which fails the build rather than shipping an unstapled dmg.
  xcrun notarytool submit "$dmg" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait --timeout 30m

  echo "==> stapling $base"
  xcrun stapler staple "$dmg"
}

# verify_dmg — the gate. Checks the artifact the way a user's Mac will, not
# the way the build wishes it were. Every check is on the FILE AS SHIPPED.
verify_dmg() {
  local dmg="$1" base mp app
  base="$(basename "$dmg")"
  echo "==> verifying $base"

  # 1. Container carries a stapled ticket -> Gatekeeper clears it offline.
  xcrun stapler validate "$dmg" \
    || { echo "ERROR: $base has no stapled notarization ticket" >&2; return 1; }

  # 2. Gatekeeper's verdict on the disk image itself.
  spctl -a -t open --context context:primary-signature -v "$dmg" \
    || { echo "ERROR: $base is rejected by Gatekeeper" >&2; return 1; }

  # 3. The app inside: mount read-only and assess it as Finder would.
  mp="$(mktemp -d)"
  hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mp" -quiet \
    || { echo "ERROR: cannot mount $base" >&2; rmdir "$mp"; return 1; }
  app="$(find "$mp" -maxdepth 1 -name '*.app' -print -quit)"

  local rc=0
  if [ -z "$app" ]; then
    echo "ERROR: no .app inside $base" >&2; rc=1
  else
    codesign --verify --deep --strict "$app" 2>/dev/null \
      || { echo "ERROR: $base: app signature is not valid" >&2; rc=1; }
    xcrun stapler validate "$app" >/dev/null 2>&1 \
      || { echo "ERROR: $base: app has no stapled ticket" >&2; rc=1; }
    # Hardened runtime is a prerequisite of notarization; assert it anyway so
    # a config regression cannot quietly drop it.
    # Capture first, match second. `cmd | grep -q` is a trap under
    # `set -o pipefail`: grep -q exits the instant it matches, the writer
    # takes SIGPIPE and reports 141, and the pipeline fails *because the
    # match succeeded*. Both of these would then reject a good artifact.
    local desc assess
    desc="$(codesign -d --verbose=4 "$app" 2>&1 || true)"
    case "$desc" in
      *flags=*runtime*) ;;
      *) echo "ERROR: $base: app is not built with the hardened runtime" >&2; rc=1 ;;
    esac
    # The verdict that matters: not merely signed, but NOTARIZED.
    assess="$(spctl -a -t exec -vv "$app" 2>&1 || true)"
    case "$assess" in
      *"source=Notarized Developer ID"*) ;;
      *) echo "ERROR: $base: app is not accepted as Notarized Developer ID" >&2
         echo "$assess" >&2; rc=1 ;;
    esac
  fi

  hdiutil detach "$mp" -quiet 2>/dev/null || hdiutil detach "$mp" -force -quiet 2>/dev/null
  rmdir "$mp" 2>/dev/null || true
  [ "$rc" = 0 ] && echo "==> $base: signed, notarized, stapled, Gatekeeper-accepted"
  return "$rc"
}

if [ "$PLATFORM" = mac ] && [ "$SIGNED" = 1 ]; then
  IDENTITY="$(signing_identity)"
  [ -n "$IDENTITY" ] || { echo "ERROR: no Developer ID Application identity found" >&2; exit 1; }
  for dmg in "$OUT"/*.dmg; do
    notarize_dmg "$dmg" "$IDENTITY"
  done
  for dmg in "$OUT"/*.dmg; do
    verify_dmg "$dmg" || { echo "ERROR: notarization gate failed" >&2; exit 1; }
  done
  echo "==> all mac artifacts are notarized end to end"
elif [ "$PLATFORM" = mac ]; then
  echo "==> WARNING: no signing credentials — the dmg is unsigned and NOT notarized" >&2
fi

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

# ------------------------------------------------------------ checksums ----
# Printed, not written: the authoritative SHA256SUMS manifest is generated
# once in the publish job over the MERGED set of artifacts from all three
# platform builds. Writing a per-platform manifest here would produce three
# files with the same name, and `merge-multiple: true` would silently keep
# whichever landed last. These lines exist so a build log can be matched
# against a published artifact after the fact.
echo "==> sha256:"
for f in "$OUT"/*; do
  [ -f "$f" ] || continue
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | sed "s|$OUT/||"
  else
    shasum -a 256 "$f" | sed "s|$OUT/||"
  fi
done
