# Renewio

Status: **implemented** (updated 2026-11-23). Native macOS menu bar app that downloads unsigned IPAs from configurable GitHub repos (or local `.ipa` files), refreshes free/paid Xcode Personal Team profiles with Apple CLI tools, resigns apps, and installs them on paired Apple TV / iPhone / iPad devices via `devicectl`. Tracks each app per device with real provisioning profile expiry countdowns and local expiry notifications.

Formerly named **ReNuvio** — renamed to Renewio because the tool is multi-source, not Nuvio-only. Support/Logs folders migrate automatically from `ReNuvio` → `Renewio`.

## Install it

```bash
./scripts/install-renewio.sh
```

That builds a Release app, ad-hoc signs it, copies it to `/Applications/Renewio.app`, and writes a shareable DMG at `dist/Renewio-1.4.0.dmg` (drag into Applications).

Then open from Applications, Spotlight, or:

```bash
open -a Renewio
```

Rebuild only (no install):

```bash
./scripts/build-renewio.sh
open dist/Renewio.app
```

Run unit tests:

```bash
xcodebuild test -project Renewio/Renewio.xcodeproj -scheme Renewio -destination 'platform=macOS' -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES
```

1. Click the menu bar icon → gear (**Settings**).
2. Confirm **Team ID** (auto-detected from Xcode when possible).
3. Add paired devices (Apple TV / iPhone / iPad) from Xcode Devices and Simulators (or remove old devices).
4. **Add app** on a device: paste a GitHub repo URL (optional pinned version via **Scan**) or pick/drop a **Local `.ipa`**, confirm Bundle ID.
5. Configure **Launch at login**, **Auto-renew when nearby**, **Require security review**, or an optional **GitHub token** (Keychain) for private repos and higher API limits.
6. **Save**, then **Renew** on each app card (or **Renew all** when a device has multiple apps).

## Multi-device / multi-source model

Config v2 at `~/Library/Application Support/Renewio/config.json`:

- `devices[]` — tracked UDID + platform (`tvos` / `ios` / `ipados`)
- `installs[]` — per-device app with `githubRepo` or `localIPAPath`, `bundleID`, install history, real `lastExpiresAt` from the provisioning profile, optional `selectedTag`
- `autoRenewEnabled` — optional background auto-renew when devices are nearby and apps are within 24h of expiry
- `securityReviewEnabled` — default **on**; when on, manual renews show age/OSV review (Proceed/Reject); auto-renew skips on medium+ findings
- Legacy v1 flat configs auto-migrate on launch (Living Room → one tvOS device + Nuvio TV install)
- Legacy ReNuvio Application Support / Logs directories move into Renewio on first launch

IPA cache: `~/Library/Application Support/Renewio/downloads/<owner>__<repo>/` (keeps latest 3 per repo; clearable from Settings).

## Pre-install security gate (2026-11-23)

Before resign/install of a GitHub-sourced IPA (manual renew, update badge, Renew all, auto-renew):

1. **Age floor (fixed 14 days)** — only install GitHub releases with `published_at` ≥ 14 days. “Latest” / update badges resolve to the newest IPA release that meets the floor. Pinned tags that are too new are a **hard block** (no silent downgrade, no Proceed anyway).
2. **OSV OSS scan** — `SecurityScan.swift` fetches lockfiles at the release tag via GitHub Contents (`Package.resolved`, `Podfile.lock`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `Cargo.lock`, `go.sum`, `Gemfile.lock`) and POSTs to `https://api.osv.dev/v1/querybatch` (no third-party deps).
3. **Manual UI** — compact review card in the menu popover: age verdict, elevated findings, **Reject** / **Proceed anyway**.
4. **Auto-renew** — never interactive; proceeds only if age OK **and** no medium/high/critical findings; otherwise skip + local notification.
5. **Local `.ipa`** — no age rule; OSS scan skipped with a “no GitHub source” note unless a repo is configured.
6. **Scripts** — `scripts/renewio.sh` and `Renewio/Resources/renewio.sh` mirror the age filter (`[ERROR]` before download for too-new `--tag` / no eligible latest).

## What Renew does

`Contents/Resources/renewio.sh` (also at `scripts/renewio.sh`):

1. Rotates `renew.log` if >2 MB and checks the selected device with `xcrun devicectl`
2. Fetches the chosen GitHub release (using optional `GITHUB_TOKEN` from Keychain) or uses `--tag` / `--ipa`, emitting `[PROGRESS]` during downloads — skips releases younger than 14 days
3. Builds `ProvisioningStub` (tvOS) or `ProvisioningStubIOS` (iOS/iPadOS) with `xcodebuild -allowProvisioningUpdates` and reads the real `ExpirationDate` from `embedded.mobileprovision`
4. Patches `CFBundleIdentifier`, removes PlugIns for Personal Team profiles, resigns with `codesign`
5. Installs with `xcrun devicectl device install app`
6. Emits `[STAGE]` / `[PROGRESS]` / `[ERROR]` / `[RESULT]` (with real `expiresAtISO`); app writes install history when `--no-config-write` is set

## UI & Feature Notes

- **Dynamic menu bar icon**: switches between normal, active spinner, warning (`≤48h`), and expired states
- **Main popover**: device switcher pills, per-app countdown cards (exact 7-day or 365-day progress), update-available badge (`↑ vX.Y.Z`), hover quick-edit button, in-flight **Cancel** button, live download progress bar, dismissible status banners with **"Copied"** log feedback, resilient **Renew all** with batch summary, drag-and-drop `.ipa` support, and **pre-install security review** cards
- **Settings**: stays inside the same `360px` MenuBarExtra; supports device add/remove, GitHub or Local `.ipa` app sources, Launch at Login (`SMAppService`), Auto-Renew toggle, Require security review toggle, optional Keychain GitHub token, **Open Logs**, and **Clear Cache** with disk size display
- **Shared interaction layer**: `Components.swift` + `Theme.swift` (`RenewioMotion`); `SystemServices.swift` (Keychain + Launch at Login); `SecurityScan.swift` (age + OSV)

## Verified locally

- `bash -n scripts/renewio.sh`
- Python age-floor helpers smoke-checked (14-day eligibility)
- Unit tests extended in `RenewioTests` (age eligibility, latest-eligible skip, lockfile parse fixtures, auto-renew decision matrix) — run via `xcodebuild test` on macOS

## Layout

- `Renewio/` — SwiftUI MenuBarExtra app + Resources + `Tests/`
- `Renewio/Sources/Theme.swift` — color + motion tokens
- `Renewio/Sources/Components.swift` — shared surfaces, controls, interaction modifiers
- `Renewio/Sources/SystemServices.swift` — Keychain GitHub token + `SMAppService` Launch at Login
- `Renewio/Sources/SecurityScan.swift` — release age policy, lockfile parsers, OSV querybatch
- `Renewio/Tests/RenewioTests.swift` — XCTest unit suite
- `scripts/renewio.sh` — install pipeline
- `scripts/build-renewio.sh` — builds into `dist/Renewio.app`
- `scripts/install-renewio.sh` — install to `/Applications` + DMG
