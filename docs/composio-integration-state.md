# Composio Integration State

**Last audited:** 2026-05-19 (Central)
**Operator:** Claude Code on `mosestut@` Mac
**Composio CLI:** `/Users/mosestut/.composio/composio` (v0.2.27)
**API key:** `~/.composio/api_key` (header: `x-api-key`)
**Login:** moses@wrkflo.biz / org `moses_workspace` / user_id `default`
**API base:** `https://backend.composio.dev/api/v3`

## Current Connected Accounts (after cleanup)

| ca_id | toolkit | status | auth_config | notes |
|-------|---------|--------|-------------|-------|
| `ca_9IfVCfV7xpXI` | linkedin | ACTIVE | `ac_x3w4YQNRuuOL` (composio-managed) | Verified — Moses Tut, LinkedIn id `7rSk6RLTL-`. Refresh expires ~60d. |
| `ca_wn5lq8W8tCMf` | gmail | ACTIVE | `ac_Ocx2kcAvL0pU` (composio-managed) | Verified — labels readable. Scopes include full Gmail + profile. |
| `ca_45KWg-Typfl1` | twitter | **FAILED** | `ac_HwJToG2Q4jq1` (WrkFlo Twitter v2) | **UPSTREAM-BLOCKED — "OAuth callback failed during token exchange". Root cause is composio's own callback host (Cloudflare 1016). Not user-actionable. Re-verified 2026-05-19. See below.** |

### Deleted during this audit (2026-05-18)
- `ca_alg-wkCtUtdf` (twitter, EXPIRED) — refresh token permanently failed
- `ca_VLr0XfPwmzi1` (twitter, FAILED) — OAuth callback token exchange failed
- `ca_TeZ3DRIjkYcb` (twitter, EXPIRED) — initiation never completed (10-min timeout)
- `ca_BdVuJZrba4YV` (linkedin, EXPIRED) — initiation never completed (10-min timeout)

### Deleted during follow-up audit (2026-05-19)
- `ca_C1Vr3KdsEmYi` (twitter, EXPIRED) — previous INITIATED handshake expired before user completed OAuth flow; replaced with `ca_45KWg-Typfl1`.

Delete recipe:
```bash
curl -s -X DELETE -H "x-api-key: $(cat ~/.composio/api_key)" \
  "https://backend.composio.dev/api/v3/connected_accounts/<ca_id>"
```

## Twitter/X — UPSTREAM-BLOCKED (not user-actionable)

**Status as of 2026-05-19 re-verification:** `ca_45KWg-Typfl1` = **FAILED**, reason
`OAuth callback failed during token exchange`.

### Root cause (verified, not ours to fix)

Composio's OAuth callback host is down on Composio's own infrastructure:

```
$ curl -sS -o /dev/null -w "%{http_code}\n" https://hermes.composio.dev/
530
$ curl -sS https://hermes.composio.dev/
error code: 1016
```

Cloudflare **error 1016 = "Origin DNS error"** — Cloudflare cannot resolve the
origin server behind `hermes.composio.dev`. This is the host the OAuth provider
redirects back to during the authorization-code → token exchange step, so the
exchange fails regardless of who initiates it or which browser/account is used.

`backend.composio.dev/api/v3` (the data-plane API) is healthy — gmail and
linkedin round-trips pass. Only the OAuth **callback** path is broken.

### Why we are NOT re-linking right now

Deleting and re-initiating `ca_45KWg-Typfl1` would mint a new redirect URL whose
callback still lands on the 1016 host, producing another FAILED account and
log churn. No local action (CLI, API, browser, different X account, either auth
config `ac_HwJToG2Q4jq1` / `ac_LWKPeyoTiCbJ`) can succeed while the host is down.
gmail + linkedin remain ACTIVE and unaffected, so the SMB content/ops use case
degrades gracefully without Twitter/X.

### Recovery runbook — execute only once the host recovers

1. **Gate on host health** (must return `200`/`302`, not `530`/`1016`):
   ```bash
   curl -sS -o /dev/null -w "%{http_code}\n" --max-time 15 https://hermes.composio.dev/
   ```
   Until this is non-5xx, do nothing — the block is upstream.
2. Delete the stale FAILED account:
   ```bash
   curl -s -X DELETE -H "x-api-key: $(cat ~/.composio/api_key)" \
     https://backend.composio.dev/api/v3/connected_accounts/ca_45KWg-Typfl1
   ```
3. Re-initiate against the v2 custom client (see *Reauth Recipes* below), open
   the returned `redirect_url` in a browser logged into **@wrkflo_ai**.
4. Confirm ACTIVE, then run the Twitter smoke test.

The `scripts/composio-health-check.sh` `no-orphan-accounts` FAIL and
`scripts/os1-autopilot-watchdog.sh` twitter poll will both clear automatically
once the connection flips ACTIVE — no separate verification needed.

## Reauth Recipes (one per toolkit)

For toolkits where you have your **own** auth config (custom client), use the API form so the auth config can be pinned. For composio-managed defaults, `composio link` is fine.

### Twitter/X (custom client `ac_HwJToG2Q4jq1`)
```bash
API_KEY=$(cat ~/.composio/api_key)
curl -s -X POST -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"auth_config":{"id":"ac_HwJToG2Q4jq1"},"connection":{"user_id":"default","callback_url":"https://backend.composio.dev/api/v1/auth-apps/add"}}' \
  https://backend.composio.dev/api/v3/connected_accounts
```
Returns `redirect_url`. Open it in a browser logged into the correct X account.

### LinkedIn (composio-managed `ac_x3w4YQNRuuOL`)
```bash
/Users/mosestut/.composio/composio link linkedin
```
Browser opens automatically; CLI waits for completion.

### Gmail (composio-managed `ac_Ocx2kcAvL0pU`)
```bash
/Users/mosestut/.composio/composio link gmail
```

## End-to-End Smoke Tests

Run after any reauth to confirm health. Each is read-only.

### Gmail — PASS as of 2026-05-18
```bash
/Users/mosestut/.composio/composio run \
  'const r = await execute("GMAIL_LIST_LABELS", {}); console.log(JSON.stringify(r).slice(0,400))'
```
Expected: `successful:true`, list of system labels (INBOX, SENT, DRAFT, etc.).

### LinkedIn — PASS as of 2026-05-18
```bash
/Users/mosestut/.composio/composio run \
  'const r = await execute("LINKEDIN_GET_MY_INFO", {}); console.log(JSON.stringify(r).slice(0,400))'
```
Expected: `successful:true`, returns localized first/last name + profile picture URL. Last verified: id `7rSk6RLTL-` (Moses Tut).

### Twitter/X — pending until OAuth completes
```bash
# Read profile (after ca_C1Vr3KdsEmYi is ACTIVE)
/Users/mosestut/.composio/composio run \
  'const r = await execute("TWITTER_USER_LOOKUP_ME", {}); console.log(JSON.stringify(r).slice(0,400))'
```

## Toolkit Candidates to Connect Next

User has NO connection for these. Ranked by business value for the Wrk.Flo SMB social-media + ops use case.

| Rank | Toolkit | slug | Why | Link command |
|------|---------|------|-----|--------------|
| 1 | Google Calendar | `googlecalendar` | Eden already drives calendar. Composio side unblocks scheduled-post timing + meeting-aware ops. | `composio link googlecalendar` |
| 2 | Google Drive | `googledrive` | Source of truth for content assets (images, brand kit, post drafts). Needed for the SMB content workflow. | `composio link googledrive` |
| 3 | Notion | `notion` | Content calendar + idea backlog + agent task tracking. Common SMB workspace. | `composio link notion` |
| 4 | Slack | `slack` | Approval / notification fan-out alongside Telegram. Adds the "post-approval" channel for non-Telegram users. | `composio link slack` |
| 5 | Google Sheets | `googlesheets` | Lightweight content schedule + post-performance log for non-Notion users. | `composio link googlesheets` |

Skipped (already covered elsewhere or low-priority):
- GitHub — already wired in repo workflows
- Stripe / HubSpot / Calendly / Airtable — available but no current pull from active use cases

## Troubleshooting Notes

- `composio dev connected-accounts list` requires `composio dev init` in the cwd. The plain `composio link <toolkit> --list` is the project-less alternative.
- `composio link <toolkit> --no-wait` swallows stdout on this CLI version (0.2.27). Use the API POST recipe above to reliably capture the redirect URL.
- INITIATED connections auto-expire to EXPIRED after 10 minutes. Re-run the POST to mint a new URL — old ca_id stays as a deletable EXPIRED record.
- Never delete an ACTIVE connection. Always confirm `status` field via `GET /api/v3/connected_accounts/<id>` first.
- Auth config `ac_LWKPeyoTiCbJ` (legacy "WrkFlo Twitter") still exists but has 0 connections; safe to leave or delete via `DELETE /api/v3/auth_configs/ac_LWKPeyoTiCbJ`. The newer v2 (`ac_HwJToG2Q4jq1`) is the one to keep.
