#!/usr/bin/env bash
# verify-client-only.sh <extracted-dir>
#
# Independent, CONTENT-based verification that an extracted .deb payload is
# client-only. Deliberately does NOT call build.sh and does NOT reuse its
# classifier: it inspects real files in an extracted tree (ELF-ness is not
# evaluable from a path listing), so it is a genuine second opinion on the
# gate, not a re-run of it. Runs on any machine with find(1), file(1), bash.
#
# Flags:
#   *.py                                   python source
#   *cpython*                              CPython artifact (.so/.pyc)
#   pyvenv.cfg                             venv marker
#   venv / .venv / site-packages dirs      venv layout
#   */bin/python*                          bare interpreter
#   ELF under resources/ not ending .node  unexplained binary payload
#
# *.node is exempt: node-pty (a production dependency for terminal
# emulation) is unpacked by asarUnpack's **/*.node rule, so its native
# addon is legitimately an ELF in resources/.
set -euo pipefail

ROOT="${1:-}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "ERROR: usage: $0 <extracted-deb-dir>" >&2
  exit 2
fi

RES="$ROOT/opt/Hermes/resources"
if [ ! -d "$RES" ]; then
  echo "ERROR: $RES missing — not a Hermes payload" >&2
  exit 1
fi

fail=0

# 1 — Python source, CPython artifacts, venv markers (whole tree).
while IFS= read -r -d '' f; do
  case "$f" in
    *.py)        echo "REJECT $f (python source)" >&2; fail=1 ;;
    *cpython*)   echo "REJECT $f (CPython artifact)" >&2; fail=1 ;;
    */pyvenv.cfg) echo "REJECT $f (venv marker)" >&2; fail=1 ;;
  esac
done < <(find "$ROOT" -type f -print0)

# 2 — venv layout directories.
while IFS= read -r -d '' d; do
  echo "REJECT $d (venv directory)" >&2
  fail=1
done < <(find "$ROOT" -type d \( -name venv -o -name .venv -o -name site-packages \) -print0)

# 3 — bare interpreters under any bin/ (python, python3, python3.12, ...).
while IFS= read -r -d '' f; do
  echo "REJECT $f (bare interpreter)" >&2
  fail=1
done < <(find "$RES" -type f -path '*/bin/python*' -print0)

# 4 — ELF binaries under resources/ that are not Node native addons.
if command -v file >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    case "$f" in
      *.node) continue ;;
    esac
    if file -b "$f" | grep -q 'ELF'; then
      echo "REJECT $f (ELF binary)" >&2
      fail=1
    fi
  done < <(find "$RES" -type f -print0)
else
  echo "WARNING: file(1) not available; skipping ELF check" >&2
fi

if [ "$fail" = 1 ]; then
  echo "ERROR: server components found in a client-only package" >&2
  exit 1
fi
echo "==> clean: no server components in $ROOT"
