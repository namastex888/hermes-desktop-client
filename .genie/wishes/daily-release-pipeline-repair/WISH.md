# Wish: Repair the daily release pipeline

| Field | Value |
|-------|-------|
| **Status** | APPROVED |
| **Slug** | `daily-release-pipeline-repair` |
| **Date** | 2026-08-05 |
| **Author** | felipe@namastex.io |
| **Appetite** | small |
| **Branch** | `wish/daily-release-pipeline-repair` |
| **Repos touched** | `namastex888/hermes-desktop-client` |
| **Design** | _No brainstorm — direct wish_ |

## Summary

**Problem:** the daily release cron has failed on every scheduled run since 2026-07-31 because the client-only
gate in `build.sh` matches the bare substring `python` against a JavaScript syntax-highlighting chunk, stranding
upstream `v2026.7.30` and `v2026.8.3`.

**Approach:** replace the substring gate with a rule-based classifier evaluable from a path listing alone, prove it
with a committed two-way fixture corpus, make the independent client-only inspection a structural pre-publish step
rather than a manual one, ship the stranded release, and close the notification gap only where one actually exists.

## Confirmed Evidence (2026-08-05)

The gate match is a **false positive**, verified directly against the upstream tree already checked out at
`.work/src` (detached at `v2026.8.3`):

```
.work/src/apps/desktop/dist/assets/python-B5eWn6H5.js   6.1K
```

Contents are a CodeMirror keyword table — `and/or/not/is`, `def/class/lambda/yield`, builtins
`abs/all/any/bin/bool/...`. It is a syntax mode, not a runtime. `find dist -type f \( -name '*.py' -o -name
'*cpython*' -o -name 'pyvenv.cfg' \)` returns **nothing**: there is no Python payload in the package.

Environment and artifact facts established during review, which constrain every validation command below:

| Fact | Consequence |
|---|---|
| `build.asarUnpack` is **byte-identical** at `v2026.7.20` and `v2026.8.3` | The exposure path is old; only the chunk is new. The failure class recurs with every language mode upstream lazily loads (`ruby-*.js`, `perl-*.js`). This is why the fix is a classifier change, not a pattern tweak. |
| Upstream sets `artifactName: Hermes-${version}-${os}-${arch}.${ext}`; `build.sh` never overrides it | Artifacts are `Hermes-2026.8.3-linux-amd64.deb`, **not** `hermes-desktop_*`. Confirmed against published `v2026.7.20` assets. |
| `dpkg-deb`, `PIL`, and `convert` are all absent on the darwin working machine | `build.sh:95` aborts before the build. No local Linux build is possible. |
| **No container runtime exists** — `docker`, `podman`, `colima`, `nerdctl`, `lima`, `orb` all absent; host is `arm64` | Containerised builds are not an available mitigation. Linux builds run in CI, which is `ubuntu-latest`/amd64. |
| `dpkg-deb -c` emits `./`-prefixed paths, and 40 of 234 entries are directories with a trailing `/` | The classifier must normalise a leading `./` and match per path segment, or it will pass every fixture and catch nothing in production. |
| `publish` needs `[resolve, build]` with no branch condition; a successful dispatch **publishes** | An independent inspection cannot precede publish as a manual step — it must be a job in the pipeline. |
| `resources/` legitimately contains **exactly one ELF**: `app.asar.unpacked/dist/node_modules/node-pty/build/Release/pty.node` | `node-pty` is a production dependency (terminal emulation) and `asarUnpack` includes `**/*.node`, so its native addon is unavoidably an unpacked real binary. A naive "any ELF under `resources/`" check flags it and blocks every release forever. The `verify` job must allowlist `*.node`. |
| The rule table was prototyped against all **234 real paths** from the published `v2026.7.20` `.deb` | Zero false positives in production. Verified independently during review. |

## Scope

### IN

- Replace the substring client-only gate with a rule-based classifier evaluable from a path string alone.
- Expose the classifier as `build.sh --check-paths` so it is testable without a build, on any platform.
- Commit a two-way fixture corpus (must-reject / must-accept) and assert both directions.
- Add a `verify` job to `release.yml` that inspects the built `.deb` by a method independent of the gate, gating `publish`.
- Publish the stranded `v2026.8.3` release.
- Determine whether the six silent failures already generated notifications, then add visibility only for the gap that actually exists.

### OUT

- No nightly / pre-release channel built from upstream `main` — cadence stays "check daily, release when upstream tags". (Explicitly chosen over the nightly option.)
- No code signing or notarisation for macOS/Windows; unsigned builds remain as documented in the README.
- No fork or patch of upstream; the no-diff design in `build.sh` stays intact.
- No change to the cron time, the version scheme, or `install.sh` / `install.ps1`.
- No upgrade of the deprecated Node 20 actions — warnings only, not the failure.
- No extension of the gate to the macOS/Windows targets (see Risks) — the linux-only reach is documented, not fixed here.
- No local Linux build workflow — the working machine cannot run one, and CI already can.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Repair the existing daily cron rather than build a new release mechanism | The 24h automation is already correct by design; only the gate is wrong. Replacing it would discard a working keepalive, resolve-if-needed, and matrix build. |
| 2 | Classify by **structure**, not by substring — with one conceded exception | A grammar and a runtime collide only in their filename. Rules 1–5 below key on structure (extension, path segment). Rule 6/7 must detect a bare interpreter (`resources/python3.12/bin/python3`), which carries no structural marker at all — from a path listing that is unavoidably name-shaped. The concession is explicit and anchored so it cannot drift into substring matching. |
| 3 | Make the gate precise, never loosen or delete it | The client-only guarantee is the entire premise of this repo (README "Build gate"). A gate removed to make CI green protects nothing. |
| 4 | Expose the classifier as `build.sh --check-paths` | The gate is currently unreachable except via a full Linux build, which is why it has never been tested in either direction. A callable mode makes the guarantee verifiable by a reviewer on any machine, including this arm64 darwin one. |
| 5 | Make the independent inspection a `verify` **job**, not a manual step | `publish` fires automatically once `build` succeeds, so nothing manual can run "before publish". A job between them is the only placement where the ordering is structural rather than aspirational — and it makes the check run on every future release, not once. |
| 6 | Diagnose the notification gap before designing a notifier | GitHub already emails the workflow's last committer on scheduled-run failure. If those six emails fired and were ignored, the defect is routing, not absence — and an auto-filed issue would be a second channel to ignore. |
| 7 | The gate must name the offending path and the rule that matched | This incident cost six days partly because the gate prints only "server components found in a client-only package", with no path. Diagnosis required cloning upstream and hand-inspecting the tree. |

## Simplicity Case

- **Simplest complete design:** one classifier function in `build.sh` with a `--check-paths` entry point, one committed fixture pair, one `verify` job, and — only if Group 4's diagnosis shows no signal reaches a human — one notify job.
- **Added machinery, each with present evidence:**
  - `--check-paths` — the gate has never been executable in isolation, which is exactly why a false positive survived to break six consecutive releases.
  - The fixture corpus — the gate has never been tested in either direction.
  - The `verify` job — required by the confirmed fact that `publish` auto-fires after `build`, so no manual inspection can precede it. Without the job, "inspect before publish" is unachievable, not merely inconvenient.
  - The notifier is **conditional** on Group 4's diagnosis and is not built if notifications already fire.
- **Deferred until measured:** a size-budget gate, an artifact-diff against the previous release, and extending the gate to the `.dmg`/`.exe` targets — deferred until a gate escape occurs that this classifier does not catch.
- **Complexity removed:** no nightly channel, no release-channel concept in the installers, no version-scheme change, no upstream fork, no local Linux build path, and no per-language name-exception list.

## Dependencies

**depends-on:** none
**blocks:** none

## Success Criteria

- [ ] The confirmed offending path is recorded in `gate-matches.txt` in **both** its build-tree and installed-tree forms, with the classification and reason.
- [ ] `build.sh --check-paths` exits **non-zero** for every line of `fixtures/must-reject.txt` and **zero** for every line of `fixtures/must-accept.txt`, each line tested individually, running natively on darwin with no build and no container.
- [ ] Every path in `must-reject.txt` is caught by at least one rule stated in Group 2 Deliverable 1, and no path in `must-accept.txt` is caught by any of them — verifiable by reading the rules against the fixtures.
- [ ] `must-reject.txt` contains a bare interpreter path with no `venv`, no `site-packages`, and no `hermes_*` segment, so a classifier that merely drops the `python` term fails it.
- [ ] `must-accept.txt` contains a second language chunk (`ruby-*.js`), proving the recurrence class is handled and not just the one observed file.
- [ ] Fixtures include a `./`-prefixed path and a directory entry, matching the real form of `dpkg-deb -c` output.
- [ ] On rejection the gate prints each matching path and the rule that matched.
- [ ] A `verify` job runs between `build` and `publish`, inspects the extracted `.deb` without using `build.sh`'s classifier, and `publish` does not run if it fails.
- [ ] A `build-and-publish` run completes green across all three platforms and publishes `v2026.8.3`; the run URL is recorded.
- [ ] `gh release view v2026.8.3` lists `.deb`, `.AppImage`, `.dmg` (x64 + arm64), and `.exe` assets.
- [ ] Group 4's diagnosis is recorded in `notification-diagnosis.md`: whether the six failed runs notified, to whom, and therefore whether a notifier is built at all.
- [ ] If a notifier is built, a forced-failure run produces a durable signal whose URL is recorded.

## Execution Strategy

### Wave 1 (parallel — independent)

| Group | Agent | Complexity | Model | Description |
|-------|-------|------------|-------|-------------|
| 1 | engineer | 1 — evidence already captured; commit and classify only | `engineer-trivial` / low | Commit the confirmed evidence and build the two-way fixture corpus |
| 4 | engineer | 3 — CI/release work (+1), no deterministic local test (+1), diagnosis precedes design (+1) | `engineer-standard` / high | Diagnose the notification gap, then close it only if it is real |

Group 4 runs in Wave 1 deliberately: the pipeline is **currently red**, a free already-occurring failure to
diagnose against. Deferring it would require manufacturing a failure and would collide with Group 3's publish.

### Wave 2 (sequential — depends on Group 1's fixtures)

| Group | Agent | Complexity | Model | Description |
|-------|-------|------------|-------|-------------|
| 2 | engineer | 4 — CI/release work (+1), prior rework on this gate (+1), subjective client-only acceptance (+1), shared build-contract change (+1) | `engineer-complex` / high | Replace the substring gate with the classifier and prove it both ways |

### Wave 3 (sequential — depends on Group 2)

| Group | Agent | Complexity | Model | Description |
|-------|-------|------------|-------|-------------|
| 3 | engineer | 4 — CI/release work (+1), stateful: publishes a real release (+1), irreversible once published (+1), workflow-topology change (+1) | `engineer-complex` / high | Add the `verify` job, then ship the stranded release |

## Execution Groups

### Group 1: Commit the evidence and build the fixture corpus

**Goal:** Turn the confirmed diagnosis into committed artifacts that Group 2 is tested against.

**Deliverables:**
1. `.genie/wishes/daily-release-pipeline-repair/gate-matches.txt` — the offending path in both its build-tree form (`.work/src/apps/desktop/dist/assets/python-B5eWn6H5.js`) and its installed-tree form (`./opt/Hermes/resources/app.asar.unpacked/dist/assets/python-B5eWn6H5.js`), its classification, and the reason.
2. `fixtures/must-reject.txt` — paths the gate must reject.
3. `fixtures/must-accept.txt` — paths the gate must accept.

`must-reject.txt`, verbatim:
```
./opt/Hermes/resources/venv/lib/python3.12/site-packages/uvicorn/__init__.py
./opt/Hermes/resources/venv/pyvenv.cfg
./opt/Hermes/resources/venv/bin/python3.12
./opt/Hermes/resources/venv/
./opt/Hermes/resources/hermes_agent/server.py
./opt/Hermes/resources/hermes_cli/__main__.py
./opt/Hermes/resources/app.asar.unpacked/.venv/lib/python3.11/site-packages/fastapi/__init__.py
./opt/Hermes/resources/python3.12/bin/python3
./opt/Hermes/resources/python3.12/lib/libpython3.12.so.1.0
./opt/Hermes/resources/lib-dynload/_socket.cpython-312-x86_64-linux-gnu.so
./opt/Hermes/resources/app.asar.unpacked/dist/scripts/helper.py
```
Line 8 is the crux: it carries **no** `venv`, `site-packages`, or `hermes_*` segment, so a classifier that drops
the `python` term to make the build pass fails it. Line 9 is the only fixture caught by **rule 7 alone** —
verified against a prototype classifier, every other rule returns false for it — so without it rule 7 could be
omitted entirely and the suite would still pass. Line 4 is a directory entry and every line is `./`-prefixed,
matching the real form of `dpkg-deb -c | awk '{print $6}'` output.

The rule table in Group 2 was run against this corpus with a throwaway prototype before this wish was finalised:
all eleven reject lines matched a rule (1,3,3,3,1,1,1,6,7,2,1) and all five accept lines matched none.

`must-accept.txt`, verbatim:
```
./opt/Hermes/resources/app.asar.unpacked/dist/assets/python-B5eWn6H5.js
./opt/Hermes/resources/app.asar.unpacked/dist/assets/ruby-K2mPq7Xz.js
./opt/Hermes/resources/app.asar.unpacked/dist/node_modules/node-pty/build/Release/pty.node
./opt/Hermes/resources/app.asar
./usr/share/icons/hicolor/48x48/apps/Hermes.png
./opt/Hermes/LICENSE
```
Line 2 is not decoration: `asarUnpack` is unchanged upstream, so the next language mode upstream lazily loads
produces exactly this shape. Accepting it is the difference between a fix and a deferral. Line 3 is the real
node-pty native addon taken from the shipped package — the one legitimate binary in `resources/`, and the path
most at risk from any future "tighten the gate" edit.

**Acceptance Criteria:**
- [ ] All three files exist and are committed.
- [ ] `must-reject.txt` contains all eleven lines above; `must-accept.txt` all six.
- [ ] `must-reject.txt` contains the rule-7-only fixture (`python3.12/lib/libpython3.12.so.1.0`), without which rule 7 is untested.
- [ ] `gate-matches.txt` records both path forms, states "false positive", and states the reason (syntax mode, not runtime).
- [ ] No path appears in both lists.

**Validation:**
```bash
set -e
D=.genie/wishes/daily-release-pipeline-repair
test "$(grep -c . "$D/fixtures/must-reject.txt")" -eq 11
test "$(grep -c . "$D/fixtures/must-accept.txt")" -eq 6
# The load-bearing entries, by exact shape.
grep -q '^\./opt/Hermes/resources/python3\.12/bin/python3$'   "$D/fixtures/must-reject.txt"  # crux: no venv/site-packages
grep -q 'libpython3\.12\.so\.1\.0$'                            "$D/fixtures/must-reject.txt"  # rule-7-only
grep -q 'cpython-312'                                          "$D/fixtures/must-reject.txt"
grep -q 'dist/scripts/helper\.py$'                             "$D/fixtures/must-reject.txt"
grep -q '/$'                                                   "$D/fixtures/must-reject.txt"  # directory entry
grep -q 'python-B5eWn6H5\.js$'                                 "$D/fixtures/must-accept.txt"
grep -q 'ruby-.*\.js$'                                         "$D/fixtures/must-accept.txt"  # recurrence class
grep -q 'node-pty/build/Release/pty\.node$'                    "$D/fixtures/must-accept.txt"  # the one legit ELF
# Every line carries the production ./ prefix.
# `test -z "$(...)"`, not `! grep ... | grep -q .` — bash exempts `!`-inverted commands from
# errexit, so the negated form cannot fail the block unless it is the last command in it.
test -z "$(grep -hv '^\./' "$D/fixtures/must-reject.txt" "$D/fixtures/must-accept.txt")"
# Evidence content, not just presence.
grep -q 'python-B5eWn6H5\.js'   "$D/gate-matches.txt"
grep -qi 'false positive'        "$D/gate-matches.txt"
grep -q 'app\.asar\.unpacked'    "$D/gate-matches.txt"   # installed-tree form recorded too
# The two lists must be disjoint.
test -z "$(comm -12 <(sort "$D/fixtures/must-reject.txt") <(sort "$D/fixtures/must-accept.txt"))"
```
Scope rationale: this group produces only text fixtures, so validation is a content contract — exact counts, the
specific load-bearing entries, production path form, evidence content, and disjointness. It reaches no runtime, so
no build or lint check applies. Disjointness is the check that would catch a corpus quietly rewritten to make
Group 2 pass.

**depends-on:** none
**blocks:** 2

---

### Group 2: Replace the substring gate with a rule-based classifier

**Goal:** Make the client-only gate reject any Python runtime, venv, or server module while accepting a JavaScript chunk regardless of which language it is named after.

**Deliverables:**

1. A `client_only_check` function in `build.sh` reading newline-delimited package paths on **stdin**. It first
   normalises each line by stripping a leading `./` and a trailing `/`, then matches **per path segment**. It
   rejects a path when any rule below fires:

   | # | Rule | Catches |
   |---|------|---------|
   | 1 | basename ends `.py` | `helper.py`, `server.py`, `__init__.py` |
   | 2 | basename matches `*cpython-*.so` | `_socket.cpython-312-x86_64-linux-gnu.so` |
   | 3 | any segment is exactly `site-packages`, `venv`, or `.venv` | venv layouts, incl. the directory entry |
   | 4 | basename is exactly `pyvenv.cfg` | venv marker |
   | 5 | any segment is exactly `hermes_agent` or `hermes_cli` | upstream server modules |
   | 6 | basename matches `^python[0-9]*(\.[0-9]+)*$` | `python`, `python3`, `python3.12` — a bare interpreter |
   | 7 | any segment matches `^python[0-9]+\.[0-9]+$` | `resources/python3.12/` — an interpreter home |

   Rules 6 and 7 are anchored whole-token matches, which is precisely why `python-B5eWn6H5.js` survives them: its
   basename contains a hyphen and a `.js` extension, so it is neither `python[0-9.]*` nor a `pythonN.N` segment.
   The old gate's failure was an **unanchored substring**; anchoring is the entire fix. `ruby-K2mPq7Xz.js` is
   matched by no rule at all, which is the point.

   The previously stated rule *"any ELF interpreter under `resources/`"* is **removed**: the classifier receives
   path strings from `dpkg-deb -c`, never files, so ELF-ness is not evaluable at this layer. Content-based
   interpreter detection moves to Group 3's `verify` job, which has an extracted tree.

2. A `build.sh --check-paths` entry point dispatching to the classifier and exiting with its status. It must be
   handled **before** `TAG="${1:-}"` at `build.sh:28`, or `--check-paths` flows into `git checkout --detach`. It
   must not clone upstream, build, or require `dpkg-deb`, so it runs natively on darwin.
3. The existing gate call site rewritten to `client_only_check <<<"$FILES"`. The `LICENSE` and hicolor icon-size
   assertions stay **at the call site**, not inside the function — moving them in would make every single-path
   `must-accept` fixture fail them.
4. On rejection, print one line per match in exactly the form `REJECT <path> (rule <N>)`, then the existing summary error (Decision 7). The format is fixed so the validation below can assert it.
5. A comment at the classifier explaining what it catches and why anchoring is load-bearing.

**Acceptance Criteria:**
- [ ] Every line of `fixtures/must-reject.txt`, fed individually, makes `build.sh --check-paths` exit non-zero.
- [ ] Every line of `fixtures/must-accept.txt`, fed individually, makes `build.sh --check-paths` exit zero.
- [ ] Rejection output names the offending path and the rule number.
- [ ] `--check-paths` runs on darwin with no build, no clone, no container, and no `dpkg-deb`.
- [ ] The `LICENSE` and hicolor icon-size assertions are unchanged and still at the call site.
- [ ] The gate still exists and still fails the build — narrowed, not removed.
- [ ] Passing `--check-paths` does not set `TAG`.

**Validation:**
```bash
set -e
D=.genie/wishes/daily-release-pipeline-repair
fail=0

# `|| [ -n "$p" ]` — the last fixture line may lack a trailing newline.
while read -r p || [ -n "$p" ]; do [ -n "$p" ] || continue
  if printf '%s\n' "$p" | ./build.sh --check-paths >/dev/null 2>&1; then
    echo "FAIL must-reject accepted: $p" >&2; fail=1
  fi
done < "$D/fixtures/must-reject.txt"

while read -r p || [ -n "$p" ]; do [ -n "$p" ] || continue
  if ! printf '%s\n' "$p" | ./build.sh --check-paths >/dev/null 2>&1; then
    echo "FAIL must-accept rejected: $p" >&2; fail=1
  fi
done < "$D/fixtures/must-accept.txt"
[ "$fail" = 0 ]

# Rejection must name the path and the rule.
printf './opt/Hermes/resources/python3.12/bin/python3\n' | ./build.sh --check-paths 2>&1 \
  | tee /tmp/reject.out | grep -qE '^REJECT \./opt/Hermes/resources/python3\.12/bin/python3 \(rule [67]\)$'

# The whole corpus at once must also fail (production feeds a full listing, not one line).
cat "$D/fixtures/must-reject.txt" | ./build.sh --check-paths && exit 1 || true
cat "$D/fixtures/must-accept.txt" | ./build.sh --check-paths
```
Scope rationale: this group changes the single guarantee the repository exists to provide, so validation is
escalated past "the build is green" to a two-way fixture assertion plus a whole-corpus pass — a green build alone
cannot distinguish a narrowed gate from a disabled one. It deliberately does **not** run a Linux build: the
working machine has no `dpkg-deb`, no `PIL`, no `convert`, and no container runtime, so any local build step would
fail for reasons unrelated to this change. The real build runs in CI under Group 3, where the tooling exists.

**depends-on:** 1
**blocks:** 3

---

### Group 3: Gate publish on an independent check, then ship the stranded release

**Goal:** Make client-only verification a structural precondition of publishing, then publish `v2026.8.3`.

**Deliverables:**
1. `.github/scripts/verify-client-only.sh <extracted-dir>` — a standalone content-based checker, **independent of `build.sh`**: a `find` over the extracted tree plus a `file`-based ELF check (the content check rules 6/7 cannot do from a path listing). Factored into a script rather than inlined in YAML so it runs on darwin against a synthetic tree, making it testable before it ever gates a release.
2. A `verify` job in `release.yml` between `build` and `publish` that downloads artifact `installers-linux` (`release.yml:91`, `installers-${{ matrix.platform }}`), extracts the `.deb`, and runs the script. `download-artifact@v4` on a same-run artifact needs no permission beyond the existing `contents: write`.
3. `publish` changed to `needs: [resolve, build, verify]`, so a failed verification blocks the release.
4. A green end-to-end run dispatched against the wish branch, with its URL recorded.
5. A published `v2026.8.3` release with all platform assets.
6. A recorded decision on whether `v2026.7.30` is backfilled or deliberately skipped.

**Acceptance Criteria:**
- [ ] `verify` runs after `build` and before `publish`; `publish` lists `verify` in `needs`.
- [ ] `verify` does not call `build.sh` or reuse its classifier — it is genuinely independent.
- [ ] The script flags `*.py`, `*cpython*`, `pyvenv.cfg`, `site-packages`/`venv`/`.venv` directories, `bin/python*`, and any ELF under `resources/` **that is not a Node native addon (`*.node`)**.
- [ ] The script passes against a synthetic tree containing `resources/app.asar.unpacked/dist/node_modules/node-pty/build/Release/pty.node` — the one legitimate ELF, which must **not** be flagged.
- [ ] The script fails against a synthetic tree with a planted `resources/venv/bin/python3.12` and again with a planted `resources/hermes_agent/server.py`.
- [ ] All three matrix jobs succeed, `verify` passes, `publish` runs; the run URL is recorded.
- [ ] `gh release view v2026.8.3` lists `.deb`, `.AppImage`, `.dmg` (x64 and arm64), and `.exe`.
- [ ] The backfill-or-skip decision for `v2026.7.30` is written down with its reason.

**Validation:**
```bash
set -e
BR=wish/daily-release-pipeline-repair

# --- Script-level, runs natively on darwin. No CI, no scratch branch, no release at risk. ---
T=$(mktemp -d)
mkdir -p "$T/opt/Hermes/resources/app.asar.unpacked/dist/node_modules/node-pty/build/Release"
# A real ELF, so the check is exercised rather than trivially passing.
printf '\177ELF\2\1\1\0%.0s' 1 > "$T/opt/Hermes/resources/app.asar.unpacked/dist/node_modules/node-pty/build/Release/pty.node"
.github/scripts/verify-client-only.sh "$T"                      # must PASS: node-pty is legitimate

cp "$T/opt/Hermes/resources/app.asar.unpacked/dist/node_modules/node-pty/build/Release/pty.node" \
   "$T/opt/Hermes/resources/rogue-interpreter"                  # same ELF bytes, not a .node
! .github/scripts/verify-client-only.sh "$T"                    # must FAIL: unexplained ELF
rm "$T/opt/Hermes/resources/rogue-interpreter"

mkdir -p "$T/opt/Hermes/resources/venv/bin"
touch "$T/opt/Hermes/resources/venv/bin/python3.12"
! .github/scripts/verify-client-only.sh "$T"                    # must FAIL: venv
rm -rf "$T/opt/Hermes/resources/venv"

mkdir -p "$T/opt/Hermes/resources/hermes_agent"
touch "$T/opt/Hermes/resources/hermes_agent/server.py"
! .github/scripts/verify-client-only.sh "$T"                    # must FAIL: server module
rm -rf "$T" 

git push -u origin "$BR"          # --ref resolves server-side; the branch must exist remotely

# Workflow topology, asserted on the LOCAL file — `gh workflow view` reads the default branch.
python3 - <<'PY'
import yaml
wf = yaml.safe_load(open('.github/workflows/release.yml'))
assert 'verify' in wf['jobs'], 'verify job missing'
assert 'build'  in wf['jobs']['verify']['needs']
assert 'verify' in wf['jobs']['publish']['needs'], 'publish not gated on verify'
PY

# Dispatch against the wish branch — a default-branch dispatch would run the UNFIXED gate.
# Baseline the run id first: dispatch is async and `--limit 1` otherwise races the 06:00 cron.
BEFORE=$(gh run list --workflow=build-and-publish --branch "$BR" --event workflow_dispatch \
           --limit 1 --json databaseId --jq '.[0].databaseId // "none"')
gh workflow run build-and-publish --ref "$BR" -f tag=v2026.8.3
for _ in $(seq 30); do
  RUN=$(gh run list --workflow=build-and-publish --branch "$BR" --event workflow_dispatch \
          --limit 1 --json databaseId --jq '.[0].databaseId // "none"')
  [ "$RUN" != "$BEFORE" ] && break
  sleep 5
done
[ "$RUN" != "$BEFORE" ] || { echo "dispatch never registered" >&2; exit 1; }
gh run watch "$RUN" --exit-status
gh run view "$RUN" --json url --jq .url        # record this

# The published asset set. Names follow upstream artifactName: Hermes-${version}-${os}-${arch}.${ext}
gh release view v2026.8.3 --json assets --jq '.assets[].name' | tee /tmp/assets.txt
grep -q '^Hermes-2026\.8\.3-linux-amd64\.deb$'       /tmp/assets.txt
grep -q '^Hermes-2026\.8\.3-linux-x86_64\.AppImage$' /tmp/assets.txt
grep -q '^Hermes-2026\.8\.3-win-x64\.exe$'           /tmp/assets.txt
test "$(grep -c '^Hermes-2026\.8\.3-mac-.*\.dmg$' /tmp/assets.txt)" -eq 2   # x64 + arm64
```
Scope rationale: this is a release group that changes workflow topology and publishes an irreversible,
user-facing artifact, so validation is the full end-to-end gate — a structural assertion on the job graph plus the
real workflow run plus exact assertions on the published asset set. Asset names are asserted exactly, against
upstream's `artifactName` template confirmed on the `v2026.7.20` release, because a substring match would accept a
partially-published set. The `verify` job exists because `publish` auto-fires after `build`: no manual inspection
can precede it.

**depends-on:** 2

---

### Group 4: Diagnose the notification gap, then close it

**Goal:** Establish why six consecutive failures produced no human reaction, and add a signal only if none exists.

**Deliverables:**
1. `.genie/wishes/daily-release-pipeline-repair/notification-diagnosis.md` — did the six failed scheduled runs notify, to whom, and was delivery plausible? GitHub emails the workflow file's last committer on scheduled-run failure; identify that recipient and state the finding either way. The file must contain exactly one line matching `^DECISION: (no-notifier|notifier-required)$` — a machine-readable sentinel, so the branch below keys on a declared decision rather than on prose wording.
2. **Only if the diagnosis shows no signal reaches a human:** a `notify` job in `release.yml` filing or updating a durable signal, with dedupe so daily failures do not accumulate.
3. If a notifier is added: a note in `release.yml` and README stating where release failures surface.

**Acceptance Criteria:**
- [ ] `notification-diagnosis.md` exists, names the notification recipient, and states whether delivery occurred.
- [ ] If notifications already fire: **no notifier is built**; the file records the real remedy (routing/recipient) instead, and `release.yml` gains no `notify` job.
- [ ] If a notifier is built: it runs only on `failure()` and does not fire on the `needed=false` no-op path, which is a success.
- [ ] If a notifier is built: it lives in its own job with its own `permissions:` block granting `issues: write`. The workflow-level grant is **not** widened — `build` executes arbitrary upstream code with the token in scope.
- [ ] If a notifier is built: a forced-failure run produces the signal and its URL is recorded.
- [ ] The working tree is left clean and on its original branch, with no scratch branch remaining locally or remotely.

**Validation:**
```bash
set -e
D=.genie/wishes/daily-release-pipeline-repair

# --- Diagnosis. Runs in both branches. ---
gh api "repos/{owner}/{repo}/actions/runs?status=failure&event=schedule" \
  --jq '.workflow_runs[] | "\(.created_at)\t\(.conclusion)\t\(.html_url)"' | head
git log -1 --format='%an <%ae>' -- .github/workflows/release.yml    # the notification recipient
test -s "$D/notification-diagnosis.md"
grep -qiE 'recipient|notified|email' "$D/notification-diagnosis.md"
test "$(grep -cE '^DECISION: (no-notifier|notifier-required)$' "$D/notification-diagnosis.md")" -eq 1

# --- Branch A: notifications already fire -> assert NO notifier was built. ---
if grep -qx 'DECISION: no-notifier' "$D/notification-diagnosis.md"; then
  python3 -c "
import yaml; wf=yaml.safe_load(open('.github/workflows/release.yml'))
assert 'notify' not in wf['jobs'], 'notifier built despite diagnosis saying it is unnecessary'"
  exit 0
fi

# --- Branch B: a notifier is justified. ---
python3 - <<'PY'
import yaml
wf = yaml.safe_load(open('.github/workflows/release.yml'))
j = wf['jobs']['notify']
assert j['if'].strip() == 'failure()', j['if']
assert 'build' in j['needs']
assert j['permissions'].get('issues') == 'write'          # scoped to this job
assert 'issues' not in (wf.get('permissions') or {})      # NOT widened workflow-wide
PY

# Forced failure in a DEDICATED WORKTREE so in-flight Group 1/2 work is never swept into
# the scratch commit and build.sh is never left with `exit 1` in the shared tree.
# `exit 1` guarantees `build` cannot succeed, so `publish` (needs: build) can never fire
# and no release is cut. Dispatching an already-released tag is NOT a valid forced failure:
# needed=false skips `build` entirely (release.yml:60) and the notify path is never exercised.
git worktree add -b ci/notify-smoke /tmp/notify-smoke HEAD
( cd /tmp/notify-smoke
  # Insert immediately after the shebang, not at EOF: appending would make all three
  # matrix jobs run a full ~25min build before failing. This fails in seconds.
  sed -i '' '1a\
exit 1
' build.sh
  git commit -m 'temp: force build failure for notify smoke test' -- build.sh
  git push -u origin ci/notify-smoke )
gh workflow run build-and-publish --ref ci/notify-smoke -f tag=v2026.8.3
# baseline-and-poll for the run id exactly as in Group 3, then:
gh issue list --label release-failure --json url --jq '.[0].url'   # record this
# Cleanup — local worktree, local branch, and remote branch.
git worktree remove --force /tmp/notify-smoke
git branch -D ci/notify-smoke
git push origin --delete ci/notify-smoke
```
Scope rationale: this is CI configuration whose failure mode is silence, so a YAML parse check alone is
insufficient — validation asserts the diagnosis artifact in **both** branches (including the likely one where no
notifier is built, which would otherwise close with zero verification), and adds a forced-failure exercise plus a
structural assertion that `issues: write` is job-scoped rather than workflow-wide. The forced failure runs in a
dedicated worktree with a planted `exit 1` so `publish` is structurally unreachable and the shared tree is never
contaminated.

**depends-on:** none

---

## QA Criteria

_What must be verified on dev after merge. The QA agent tests each criterion._

- [ ] Functional: installing the published `.deb` yields a working Hermes client that launches with a correct icon and no dock/menu regression.
- [ ] Functional: `/opt/Hermes` contains no Python interpreter, venv, or gateway — inspected by hand, independently of both the gate and the `verify` job.
- [ ] Functional: Python **and** Ruby syntax highlighting still work in the app, confirming the accepted chunks are genuinely needed and were not excluded from the bundle.
- [ ] Integration: `curl -fsSL .../install.sh | sh` on a clean Debian/Ubuntu machine installs the new version and resolves the architecture-matched asset.
- [ ] Integration: after merge, one dispatch of `build-and-publish` on `main` completes green, exercising the merged state of `release.yml` including the `verify` job. _(This is post-merge by necessity — no pre-merge run exercises merged `main`.)_
- [ ] Integration: the next unattended scheduled cron run at `0 6 * * *` completes green with `needed=false`, exercising the scheduled path that `workflow_dispatch` never takes.
- [ ] Regression: `./build.sh` with no arguments still builds the latest upstream release on a Linux machine.
- [ ] Regression: the macOS and Windows artifacts still install and launch, with the documented unsigned-binary warnings and no new ones.

---

## Assumptions / Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| The classifier is narrowed just far enough to pass the build, silently weakening the guarantee | High | `must-reject.txt` line 8 is a bare interpreter with no `venv`, `site-packages`, or `hermes_*` segment; a drop-the-`python`-term fix fails it. Rules 6/7 are anchored whole-token matches, and the `verify` job checks the extracted tree independently. |
| Rules 6/7 are name-shaped and could drift back toward substring matching | Medium | Decision 2 concedes this explicitly and anchors both rules. `must-accept.txt` contains `python-B5eWn6H5.js` and `ruby-K2mPq7Xz.js`, so any drift toward substring matching fails the fixture suite immediately. |
| The same failure class recurs when upstream adds another language mode | Medium | `ruby-*.js` is a committed must-accept fixture, so the recurrence class is tested, not just the observed file. |
| A genuine server payload is misread as another false positive | High | The classification is already made and committed as evidence rather than decided by an agent whose remaining work unblocks on "false positive". Any *new* match at a future tag is a BLOCKED condition requiring a human decision, not a pattern edit. |
| The gate runs on linux only (`build.sh:131`), so `.dmg`/`.exe` carry no client-only enforcement | Medium | Pre-existing and explicitly OUT of scope. Documented because it is the load-bearing assumption under the repo's headline guarantee: the payload is *asserted* identical across targets, not checked. Revisit if a target diverges. |
| No local Linux build is possible — no `dpkg-deb`, no `PIL`, no `convert`, no container runtime, arm64 host | Medium | `--check-paths` needs none of them and runs natively; every build-touching validation runs in CI on `ubuntu-latest`. No validation command assumes a container. |
| Group 4's forced failure publishes a release or contaminates the shared tree | Medium | The planted `exit 1` makes `build` unable to succeed, so `publish` cannot fire. It runs in a dedicated worktree, commits only `build.sh`, and cleans up worktree, local branch, and remote branch. Group 4 also runs in Wave 1, before Group 3 exists. |
| Widening workflow permissions for the notifier expands blast radius | Medium | `build` runs arbitrary upstream code with the token in scope, so `issues: write` is granted in the notify job's own `permissions:` block, never workflow-wide. Asserted in validation. |
| Publishing `v2026.8.3` while skipping `v2026.7.30` leaves a gap in release history | Low | Group 3 requires the backfill-or-skip decision to be recorded rather than made implicitly. |
| Upstream tags again mid-wish, moving the target | Low | Every validation is pinned to `v2026.8.3`; the cron picks up anything newer afterwards. |

---

## Review Results

### 2026-08-05T21:31:12Z — Plan Review #1 (target `WISH.md` @ `cbf1e5a`)

**Verdict: FIX-FIRST** — 9 HIGH, 6 MEDIUM, 5 LOW. Reviewer executed the wish's own validation commands.

- **H1** Group 2's negative test (`source <(sed -n …)` fed from stdin) exited 0 unconditionally — `PLATFORM`/`OUT` unbound, and the gate reads `$FILES` via herestring, never stdin. The one check separating a narrowed gate from a disabled one was a guaranteed false result.
- **H2** Pattern narrowing was fittable to the single path in the AC. **H3/H4** Group 3 dispatched the default branch (unfixed gate) and raced `gh run list --limit 1`. **H5** Every `./build.sh` step was unrunnable on darwin. **H6** `ls dist/*.deb | head -1` returns the 7.20 deb. **H7/H8** Group 4's forced-failure exercise had no commands; parse check read the default branch. **H9** Group 4's failure run could publish a release out from under Group 3.

**Questioner lens** independently confirmed the root cause from `.work/src`: the match is
`dist/assets/python-B5eWn6H5.js`, a CodeMirror keyword table. Established that `asarUnpack` is unchanged between
`v2026.7.20` and `v2026.8.3`, so the failure class recurs with every new language mode — arguing against a
name-based gate. Raised that the "no signal existed" diagnosis was never tested.

### 2026-08-05T21:52:00Z — Plan Review #2 (fix-loop 1)

**Verdict: FIX-FIRST** — 6 HIGH, 6 MEDIUM, 7 LOW. Reviewer downloaded the published `v2026.7.20` `.deb` and
probed the working machine rather than assuming.

- **H1** "Any ELF interpreter under `resources/`" is **unevaluable** — the classifier receives path strings, never files.
- **H2** The crux fixture `resources/python3.12/bin/python3` was caught by **no** evaluable rule, making Group 2 unsatisfiable; and the naive fix would also reject `python-B5eWn6H5.js`, making the two lists contradictory.
- **H3** `hermes-desktop_2026.8.3_amd64.deb` **never exists** — upstream's `artifactName` yields `Hermes-2026.8.3-linux-amd64.deb`. Confirmed against published assets.
- **H4** No container runtime on the machine — `docker`/`podman`/`colima`/`nerdctl`/`lima`/`orb` all absent. **H5** Host is arm64, so a container build would emit arm64 artifacts. **H6** Group 3 had no artifact to inspect (`dist/` gitignored, Group 2 opens with `rm -rf dist`).
- Confirmed fixed from #1: loop shell semantics, `comm` negation, errexit-safety, keeping `LICENSE`/icon asserts at the call site, Group 4's no-publish argument, wave coherence.

**Amendments applied (this revision):** ELF rule removed and replaced with anchored rules 6/7 evaluable from a
path string, with the concession stated in Decision 2; crux fixture now covered twice; `ruby-*.js` added to
must-accept to test the recurrence class; fixtures given production `./` prefix and a directory entry; all asset
names corrected to upstream's `artifactName` template; every container invocation removed — `--check-paths` runs
natively and Linux builds run in CI; independent inspection promoted to a `verify` job gating `publish`
(Decision 5), which also resolves "no artifact to inspect"; gate now names path and rule (Decision 7); Group 4
given a diagnosis artifact, an else-branch assertion, and worktree isolation; `SC` for merged-workflow moved to
QA as post-merge; read loops handle a missing trailing newline; run-id poll filtered by branch and event.

### 2026-08-05T22:15:00Z — Plan Review #3 (fix-loop 2)

**Verdict: FIX-FIRST** — 1 HIGH, 6 MEDIUM, 6 LOW. Reviewer downloaded the published `v2026.7.20` `.deb`,
extracted it with `ar`+`tar`, and re-derived the rule table independently.

**Confirmed good:** rule table reproduced from scratch — all 11 reject lines caught (1,3,3,3,1,1,1,6,7,2,1), all
accept lines clean, every rule exercised by ≥1 fixture, rule 2 does catch the `cpython-312` shared object, and the
normalisation is unambiguous. Run over all **234 real paths** from the shipped package: **0 false positives**. All
four asset-name assertions correct against the live release, including the `amd64` deb vs `x86_64` AppImage arch-
token difference. Group 4's branch-A early exit correct. `verify` in `publish`'s `needs` does not break the
`needed=false` no-op. No regressions from loop 1.

- **H1 (blocking)** `resources/` legitimately contains exactly one ELF — `node-pty/build/Release/pty.node`, a
  production dependency unavoidably unpacked by `asarUnpack`. The specified "any ELF under `resources/`" check
  flags it, `verify` fails, and `publish` is blocked **forever** — contradicting Group 3's own ACs. This is the
  wish's own failure class (a shape gate false-positiving on a legitimate client asset) reintroduced one layer up,
  in a hard release gate.

**Amendments applied (this revision):** the node-pty ELF fact recorded in Confirmed Evidence and the check
respecified to allowlist `*.node` (H1); `verify` factored into `.github/scripts/verify-client-only.sh` so it is
testable on darwin against a synthetic tree before it can gate a live release, with four positive/negative cases
(M3); `pty.node` added to `must-accept` and verified against the prototype to match no rule (M1); both
`! grep … | grep -q .` assertions replaced with `test -z "$(…)"` because bash exempts `!`-inverted commands from
errexit — verified on bash 3.2.57 (M2); Group 4's branch selector changed from prose `grep -qi 'no notifier'` to a
required `^DECISION: (no-notifier|notifier-required)$` sentinel (M5); rejection output format fixed as
`REJECT <path> (rule <N>)` and asserted (L2); `installers-linux` artifact name and permission note stated (L3);
smoke-test `exit 1` moved to line 2 so it fails in seconds rather than after a ~25min build (L6).

**Not applied, with reason:** M4 (post-merge QA vehicle) and M6 (rules 4/5/6 shadowed by other rules on every
fixture) are recorded as known, accepted gaps — see below. L1, L4, L5 are cosmetic.

**Fix-loop budget:** this was loop 2 of 2. H1 was a single missing fact with a bounded correction, applied above
and independently verified (`pty.node` matches no rule; a synthetic-tree test now proves both directions before
any release is at stake). Per the review contract the plan does not auto-escalate model or effort; the remaining
MEDIUM/LOW items are explicitly in-flight work for the implementer, not blockers.

**Status → APPROVED** on the H1 correction. Known accepted gaps carried into execution:
- **M4** — no pre-merge run exercises merged `main`; once `v2026.8.3` is released, a `main` dispatch resolves
  `needed=false` and skips everything. If Group 3's decision is *backfill*, dispatch `-f tag=v2026.7.30`
  post-merge as the vehicle that actually exercises `verify`; if *skip*, the first exercise is the next real
  upstream tag. Group 3 must record which.
- **M6** — rules 4, 5, and 6 are each shadowed by another rule on every current fixture, so all three could be
  deleted with the suite still green. Rule 6 is the one that matters (Decision 2 calls it load-bearing).
  Adding `./opt/Hermes/resources/bin/python3.12` would exercise rule 6 alone; left to the implementer since it
  moves the fixture counts and the crux path is already covered twice.
- **L1** — a `.pyc` outside a venv (`__pycache__/foo.cpython-312.pyc`) escapes all seven path rules; the `verify`
  job's content check covers it.

---

## Files to Create/Modify

```
build.sh                                                              # client_only_check + --check-paths (Group 2)
.github/scripts/verify-client-only.sh                                 # independent content check (Group 3)
.github/workflows/release.yml                                         # verify job (Group 3); notify job iff Group 4 diagnosis warrants
README.md                                                             # only if a notifier is added (Group 4)
.genie/wishes/daily-release-pipeline-repair/gate-matches.txt          # evidence (Group 1)
.genie/wishes/daily-release-pipeline-repair/fixtures/must-reject.txt  # fixtures (Group 1)
.genie/wishes/daily-release-pipeline-repair/fixtures/must-accept.txt  # fixtures (Group 1)
.genie/wishes/daily-release-pipeline-repair/notification-diagnosis.md # diagnosis (Group 4)
```
