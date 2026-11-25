# Renewio

Status: **implemented** (updated 2026-11-24). **v1.5.0** ships the shared pre-install security gate (Supabase + GHA), email/password security sign-in, per-app Auto-update, and pinned-tag age overrides. Native macOS menu bar app that downloads unsigned IPAs from configurable GitHub repos (or local `.ipa` files), refreshes free/paid Xcode Personal Team profiles with Apple CLI tools, resigns apps, and installs them on paired Apple TV / iPhone / iPad devices via `devicectl`. Tracks each app per device with real provisioning profile expiry countdowns and local expiry notifications.

## Shared security verification (Supabase + GHA)

Pre-install gate (when **Require security review** is on):

1. Download the **original** GitHub IPA into the local cache (or use local path).
2. Compute **SHA-256** of that exact file.
3. Authenticated `request-scan` → Supabase dedupes by artifact identity and dispatches public GHA scanners.
4. Poll `check-eligibility` until a report exists (or fail closed).
5. UI: Checks Passed / Review Required / Blocked / Scanning / Scan Failed.
6. On allow (or Proceed after recording per-user approval), **re-verify hash**, then resign/install via existing `renewio.sh` using `--ipa` to the assessed file.

Signing credentials never leave the Mac. Shared reports are keyed by unsigned IPA hash + policy/scanner versions.

### Layout

- [`security-scanners/`](security-scanners/) — GHA workflow + adapters (identity, age, Semgrep, Gitleaks, OSV, IPA light) + Phase 5 stubs (MobSF, VT, release diff, AI)
- [`supabase/`](supabase/) — Postgres migration, Edge Functions (`request-scan`, `submit-report`, `check-eligibility`, `record-approval`, `revoke-approval`, `scan-status`, `recheck-vulns`)
- [`Renewio/Sources/Security/`](Renewio/Sources/Security/) — client, hasher, eligibility, approvals, IPA download

Configure `RenewioSupabaseURL` + `RenewioSupabaseAnonKey` in Info.plist (or env). Sign in under Settings with **email + password** (turn Confirm email off on the Security-Scanner project so signup needs no SMTP). Create a **dedicated** Supabase project; do not apply migrations to unrelated apps. Prefer Pro (or keepalive) to avoid Free-tier pause.

Offline same-artifact renew: 72h grace if last local assessment was Checks Passed (or Review Required with a stored approval). Upgrades fail closed when the backend is unreachable.

## Install it

```bash
./scripts/install-renewio.sh
open -a Renewio
```

## Multi-device / multi-source model

Config v2 at `~/Library/Application Support/Renewio/config.json`:

- `devices[]`, `installs[]` (optional `lastIpaSha256`, `lastReportId`, `lastAssessmentStatus`, …)
- `autoRenewEnabled` — global master switch
- `installs[].autoUpdateEnabled` — per-app opt-in (default true)
- `securityReviewEnabled` — default on; gates on shared reports when configured

## What Renew does after security allow

`Contents/Resources/renewio.sh`: device check → use `--ipa` or fetch → provision → resign → `devicectl install`.

## License

Personal / private use unless otherwise noted.
