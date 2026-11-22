# ReNuvio (Renew Nuvio)

Status: **implemented** (2026-11-21). Native macOS menu bar app that downloads unsigned IPAs from configurable GitHub repos, refreshes free/paid Xcode Personal Team profiles with Apple CLI tools, resigns apps, and installs them on paired Apple TV / iPhone / iPad devices via `devicectl`. Tracks each app per device with an individual 7-day refresh countdown.

## Install it

```bash
./scripts/install-renuvio.sh
```

That builds a Release app, ad-hoc signs it, copies it to `/Applications/ReNuvio.app`, and writes a shareable DMG at `dist/ReNuvio-1.0.0.dmg` (drag into Applications).

Then open from Applications, Spotlight, or:

```bash
open -a ReNuvio
```

Rebuild only (no install):

```bash
./scripts/build-renuvio.sh
open dist/ReNuvio.app
```

1. Click the menu bar icon → gear (**Settings**).
2. Confirm **Team ID** (auto-detected from Xcode when possible).
3. Add paired devices (Apple TV / iPhone / iPad) from Xcode Devices and Simulators.
4. **Add app** on a device: name, GitHub `owner/repo` source (default `bobsupra/NuvioTVOS`), optional pinned version via **Scan**, Bundle ID.
5. **Save**, then **Renew** on each app card (or **Renew all** when a device has multiple apps).

## Multi-device / multi-source model

Config v2 at `~/Library/Application Support/ReNuvio/config.json`:

- `devices[]` — tracked UDID + platform (`tvos` / `ios` / `ipados`)
- `installs[]` — per-device app with `githubRepo`, `bundleID`, install history, optional `selectedTag`
- Legacy v1 flat configs auto-migrate on launch (Living Room → one tvOS device + Nuvio TV install)

IPA cache: `~/Library/Application Support/ReNuvio/downloads/<owner>__<repo>/` (keeps latest 3 per repo).

## What Renew does

`Contents/Resources/renew-nuvio.sh` (also at `scripts/renew-nuvio.sh`):

1. Checks the selected device with `xcrun devicectl`
2. Fetches the chosen GitHub release (or uses `--tag` / `--ipa`)
3. Builds `ProvisioningStub` (tvOS) or `ProvisioningStubIOS` (iOS/iPadOS) with `xcodebuild -allowProvisioningUpdates`
4. Patches `CFBundleIdentifier`, removes PlugIns for Personal Team profiles, resigns with `codesign`
5. Installs with `xcrun devicectl device install app`
6. Emits `[STAGE]` / `[ERROR]` / `[RESULT]`; app writes install history when `--no-config-write` is set

## UI notes

- Main popover: device switcher pills + per-app countdown cards + Renew / Renew all
- Settings stays inside the same `360px` MenuBarExtra (shared `SectionCard` / `SelectableOptionRow` / `CardSurface` in `Theme.swift`)
- Failure logs stay in-app (Copy); full files still at `~/Library/Logs/ReNuvio/`

## Verified locally

- `xcodebuild` **Release** ReNuvio.app → `dist/ReNuvio.app`
- `ProvisioningStub` (tvOS) and `ProvisioningStubIOS` (iOS) schemes build
- v1 → v2 config migration preserves Living Room + Nuvio TV `3.5.2` countdown
- Script flags: `--repo`, `--platform`, `--tag`, `--ipa`, `--no-config-write`

## Layout

- `ReNuvio/` — SwiftUI MenuBarExtra app + Resources
- `scripts/renew-nuvio.sh` — install pipeline
- `scripts/build-renuvio.sh` — builds into `dist/ReNuvio.app`
