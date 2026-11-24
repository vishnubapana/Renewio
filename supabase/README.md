# Renewio Supabase security backend

## Setup

1. Create a **dedicated** Supabase project (do not reuse unrelated apps).
2. Apply `migrations/20261124000000_security_scanning.sql`.
3. Deploy Edge Functions under `functions/`.
4. Set secrets:
   - `SUBMIT_REPORT_HMAC_SECRET` — shared with GHA
   - `GITHUB_DISPATCH_TOKEN` — PAT/GitHub App token that can `workflow_dispatch` the scanner repo
   - `SCANNER_GITHUB_REPO` — `owner/renewio-security-scanners`
   - `RENEWIO_CRON_SECRET` — for `recheck-vulns`
5. Prefer **Pro** plan for friend-group use (Free pauses after 1 week inactivity), or add a keepalive cron.

## Functions

| Function | Auth | Purpose |
|----------|------|---------|
| `request-scan` | user JWT | Dedupe + enqueue + dispatch GHA |
| `submit-report` | HMAC | GHA publishes report |
| `check-eligibility` | user JWT | Install policy |
| `record-approval` / `revoke-approval` | user JWT | Per-user risk acceptance |
| `scan-status` | user JWT | Poll job |
| `recheck-vulns` | cron secret | Expire reports / list recheck candidates |
