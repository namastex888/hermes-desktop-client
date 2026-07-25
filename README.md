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

Architectures: Linux and Windows are **x86_64**; macOS ships both **Apple
Silicon and Intel**. The installers match your machine's architecture and stop
with a clear message rather than fetching the wrong one.

### Signing

Linux packages need no signing. The **macOS and Windows builds are unsigned** —
notarisation needs a paid Apple Developer account and an Authenticode
certificate. On macOS the installer strips the quarantine bit for you; on
Windows, SmartScreen may warn ("More info" → "Run anyway"). If that is not
acceptable, build locally with `./build.sh`.

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
