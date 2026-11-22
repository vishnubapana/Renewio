# Renewio

Native macOS menu bar app that downloads unsigned IPAs from GitHub, resigns them with your Xcode Personal Team, and installs them on paired Apple TV / iPhone / iPad devices via Apple’s CLI tools (`xcodebuild`, `codesign`, `devicectl`).

Tracks each app per device with a 7-day signing countdown and local expiry notifications.

## Requirements

- macOS 14+
- Xcode with tvOS and/or iOS platforms installed
- Apple ID signed into Xcode → Settings → Accounts
- Device paired in Xcode → Window → Devices and Simulators

## Install

Download the latest `.dmg` from [Releases](https://github.com/vishnubapana/Renewio/releases), open it, and drag **Renewio** into Applications.

Or build from source:

```bash
./scripts/install-renewio.sh
open -a Renewio
```

## Usage

1. Click the menu bar icon → gear (Settings)
2. Confirm Team ID (auto-detected when possible)
3. Add a paired device
4. Add an app by pasting a GitHub HTTPS clone URL (e.g. `https://github.com/bobsupra/NuvioTVOS.git`)
5. Save, then renew from the app card

## Project layout

- `Renewio/` — SwiftUI MenuBarExtra app
- `scripts/renewio.sh` — download / sign / install pipeline
- `scripts/build-renewio.sh` — Release build into `dist/`
- `scripts/install-renewio.sh` — build, install to `/Applications`, create DMG

Config lives at `~/Library/Application Support/Renewio/config.json`.  
Logs: `~/Library/Logs/Renewio/`.

## License

Personal / private use unless otherwise noted.
