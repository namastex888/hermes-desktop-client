# hermes-desktop-client

Unofficial **client-only** Linux packaging of the [Hermes Agent](https://github.com/NousResearch/hermes-agent) desktop app.

Nous Research ships `.exe` and `.dmg`, but no Linux package. The official Linux
route installs the full agent — Python venv, gateway, server — even if all you
want is the desktop client talking to a backend somewhere else.

This builds a `.deb` containing **the Electron client and nothing else**, and
lets `apt` handle updates.

| | official install | this |
|---|---|---|
| Python / venv | yes | **no** |
| gateway / server | yes | **no** |
| installed size | GBs | ~334 MB |
| updates | in-app updater | `apt upgrade` |

## Install

**Linux / macOS**

```sh
curl -fsSL https://raw.githubusercontent.com/namastex888/hermes-desktop-client/main/install.sh | sh
```

**Windows** (PowerShell)

```powershell
irm https://raw.githubusercontent.com/namastex888/hermes-desktop-client/main/install.ps1 | iex
```

| Platform | Gets | Lands in |
|---|---|---|
| Debian/Ubuntu | `.deb` | `/opt/Hermes` + app menu |
| other Linux | `AppImage` | `~/.local/bin/hermes-desktop` |
| macOS | `.dmg` | `/Applications` |
| Windows | `.exe` | Start menu |

Then point it at a backend: **Settings → Gateway → Remote connection**.

### Nightly

A rolling [`nightly` pre-release](https://github.com/namastex888/hermes-desktop-client/releases/tag/nightly)
tracks upstream `main` and is rebuilt every day upstream moves: macOS `.dmg`
(both architectures) plus the Linux `.deb` and `.AppImage`. Upstream `main`
runs thousands of commits ahead of the newest tag, so the nightly is the only
channel carrying current backend work. The install commands above always
resolve the latest *tagged* release; for the nightly:

```sh
curl -fsSL https://raw.githubusercontent.com/namastex888/hermes-desktop-client/main/install.sh | sh -s -- --nightly
```

Downloading the dmg by hand works too: it is notarized and stapled, so
Gatekeeper opens it without complaint and without any `xattr` workaround.

Architectures: Linux and Windows are **x86_64**; macOS ships both **Apple
Silicon and Intel**. The installers match your machine's architecture and stop
with a clear message rather than fetching the wrong one.

### Release channels

| channel | tag | built from | contents |
| --- | --- | --- | --- |
| stable (mirror) | `vYYYY.M.D` | the matching upstream **tag** | Linux, macOS, Windows |
| stable (from main) | `main-YYYY.M.D` | upstream **`main`** at dispatch time | Linux, macOS, Windows |
| nightly | `nightly` | upstream **`main`**, daily | Linux, macOS |

Upstream `main` runs thousands of commits ahead of the newest tag, so a
tag-mirror release can be months of work behind. To cut a full stable release
from current upstream `main`:

```sh
gh workflow run release.yml -f upstream_ref=main
```

That builds all three platforms, publishes as `main-<date>` and marks it
**Latest**, so `install.sh` resolves it by default. The `main-` prefix cannot
collide with upstream's `vYYYY.M.D` tags, so the tag mirror keeps working
untouched.

### Signing and notarization

**macOS** — the app *and the disk image around it* are signed with a Developer
ID, built with the hardened runtime, notarized by Apple, and stapled. Stapling
is the part that matters at install time: the ticket travels inside the file,
so Gatekeeper clears it offline, on a plane or behind a firewall, without
calling home.

Verify a download yourself:

```sh
xcrun stapler validate Hermes-*-mac-arm64.dmg     # -> "The validate action worked!"
spctl -a -t open --context context:primary-signature -v Hermes-*-mac-arm64.dmg
```

Notarizing only the `.app` is the trap here, and it is what this repo did until
recently: the app inside verified clean while the dmg — the thing a user
actually downloads, and the thing that carries the quarantine bit — was
unsigned and unstapled. Gatekeeper evaluates the disk image first, so every
release still produced the "damaged" dialog. `build.sh` now signs, notarizes
and staples the container too, then re-verifies both layers and **fails the
build** rather than publishing an artifact that does not pass. There is no
unsigned fallback in CI: signing credentials present means signing is
mandatory.

**Linux** has no OS-level notary — there is nothing to notarize *against*. The
equivalent guarantee is provenance: every artifact is signed keylessly through
Sigstore by [GitHub Artifact Attestations][att], binding the file's digest to
this repository, this workflow and the exact commit, recorded in a public
transparency log. No long-lived signing key exists to leak or rotate.

```sh
gh attestation verify Hermes-*-linux-amd64.deb --repo namastex888/hermes-desktop-client
```

Every release also carries a `SHA256SUMS` manifest covering all of its assets;
`install.sh` checks each download against it before installing anything.

**Windows** is unsigned (no Authenticode certificate); SmartScreen may warn
("More info" → "Run anyway").

[att]: https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds

## Why upstream has no .deb

`apps/desktop/package.json` already configures a `deb` target, but omits the
`homepage` field that electron-builder's fpm target requires — so the Linux
build fails while macOS and Windows succeed. This repo injects that field at
build time.

## Design

- **No fork, no patch.** Upstream is cloned at a release tag and consumed
  verbatim. All packaging metadata is injected via `electron-builder` CLI
  flags, so there is no diff to rebase and nothing to maintain when upstream
  moves.
- **Version mirrors the upstream release tag** (`v2026.7.20` → `2026.7.20`).
- **`productName` stays `Hermes`**, so config lives in `~/.config/Hermes` —
  identical to any other install.
- **Build gate.** The build fails if any Python, venv, or server file lands in
  the package, or if the upstream licence is missing. Client-only is enforced,
  not assumed.

## Build locally

```sh
./build.sh              # latest upstream release
./build.sh v2026.7.20   # a specific tag
```

Needs `node`, `npm`, `git`, `dpkg-deb`, and `gh` (only to resolve "latest").

## Licence

Hermes Agent is MIT, © 2025 Nous Research; its licence ships inside the package
at `/opt/Hermes/LICENSE`. The build tooling here is MIT, © 2026 Namastex Labs.

Not affiliated with or endorsed by Nous Research.
