# OS1 production push — decisions log

Append-only ledger of material decisions made by Claude Code (CC) or Codex CLI (CX)
while jointly pushing OS1 to live business readiness. Newest at bottom.

## 2026-05-19T03:20Z — CC
Coord lane opened. Lane split:
- CX: local-ops scripts, CUA daemon, business runner, Swift Runtime, readiness
  gate, CI workflow, production-readiness + local-ops + business-use-cases docs.
- CC: Apple signing/notarization scripts, release artifact verifier, business
  output validator, Apple credentials runbook, entitlements plist.
Shared boundary: CC posts new script paths + exit-code contracts in
`coord/CODEX_INBOX.md`; CX owns wiring them into `os1-production-readiness.sh`,
`ci.yml`, and `production-readiness.md` if/when it wants to.

## 2026-05-19T04:15Z — CC
Ad-hoc distribution is the permanent, intentional OS1 release mode. User
declined paid Apple Developer membership (recurring cost); Developer-ID +
notarization path stays documented but indefinitely deferred. `adhoc` is the
default for `release-archive-verify.sh` / `OS1_RELEASE_MODE` and should be
treated as steady state, not a stopgap.

## 2026-05-19T04:15Z — CC
`RELEASE.md` gained an end-user "ad-hoc build" install section (right-click→Open
+ `xattr -dr com.apple.quarantine`). RELEASE.md is unowned by either lane and
was already dirty; CX may reclaim it by posting in CLAUDE_INBOX.

## 2026-05-19T04:15Z — CC
Adhoc-collapse finish for `scripts/os1-production-readiness.sh` (3
`require_for_public`→`apple_cred_miss` swaps + optional mode-aware verifier
call) delegated to CX via `REQ:` rather than CC editing CX's owned file. CC
made the edits locally, then reverted them to keep the lane clean; exact diff
is in CODEX_INBOX.

## 2026-05-19T16:12Z — CX
`scripts/os1-local-ops-health.sh` no longer infers `OLLAMA_MODEL` from Hermes
config when the variable is unset. Hermes may be pointed at an OpenRouter model,
but local ops readiness must validate the local Ollama fallback through
`scripts/ollama-health.sh`'s local default. Live readiness with business smoke
now exits 0; remaining local warnings are dirty worktree and stale scheduled
business-ops summary.

## 2026-05-19T16:15Z — CC
Twitter/X integration declared **upstream-blocked, not user-actionable**.
`ca_45KWg-Typfl1` FAILED because composio's own OAuth callback host
`hermes.composio.dev` returns Cloudflare 1016 (origin DNS error). Decision:
do NOT delete/re-link until the host returns non-5xx — re-linking only mints
new FAILED accounts and log churn while upstream is down. Recovery is gated on
a host-health curl check, documented in `docs/composio-integration-state.md`.
gmail+linkedin remain ACTIVE; SMB use case degrades gracefully without X.

## 2026-05-19T16:15Z — CC
E2E real-business dry-run chain verified green end-to-end (brief --dry-run →
validate-business-output --strict → post-approved-content --dry-run, NO
--apply). Canonical pre-`--apply` gate for the SMB content/ops use case; all
three stages exit 0 against the current published `business-ops/latest/`.

## 2026-05-19T16:15Z — CC
Surfaced (cross-lane, not actioned by CC): autopilot watchdog retired itself
at 16:05Z (>3h tick window) and openclaw gateway `gateway-unreachable` since
~13:00Z per `/tmp/os1-heartbeat.log`. Hermes up, readiness ok. Needs a
watchdog re-arm + openclaw gateway restart by the gateway-lane owner / next
operator pass.

## 2026-05-19T16:31Z — CX
`scripts/os1-local-ops-health.sh` gained a macOS-only business-ops catch-up:
when `com.os1.local.business-ops` is loaded and the latest run is older than
2x the LaunchAgent interval, the health check kicks the LaunchAgent once via
`launchctl kickstart -k`. This prevents sleep gaps from leaving readiness stale
until a manual operator kick. Disable with `OS1_LOCAL_OPS_KICK_BUSINESS_OPS=0`;
override threshold with `OS1_BUSINESS_OPS_CATCHUP_SECONDS`.

## 2026-05-19T16:38Z — CX
Current Hermes direct-message routing uses `TELEGRAM_ALLOWED_USERS`; the old
OS1 Messaging DM-pairing panel is vestigial for this runtime and no longer
surfaces in the configured view. The Messaging install UI now guides operators
to manage allowed Telegram user IDs directly, matching the live Hermes setup
Claude restored at 16:33Z.

## 2026-05-19T16:46Z — CX
CI now runs the CC-lane smoke contract directly with
`scripts/ci-cc-lane-smoke.sh` after Swift tests and before release packaging.
Local verification returned PASS=24 / FAIL=0. This keeps Claude-owned release,
Composio, watchdog, real-brief, and posting scripts covered without duplicating
their contracts inside `.github/workflows/ci.yml`.

## 2026-05-19T19:18Z — CC (Desktop)
`scripts/os1-real-business-brief.sh` made resilient: added `osa_guarded()`
(hard `OS1_OSA_TIMEOUT_SECONDS`=25s timeout on Calendar/Reminders osascript;
prior unguarded call hung ~14min and wedged the brief lock for every run),
and Ollama failure now degrades to a data-only brief instead of `die`.
Validated in prod (runs 190509Z, 190729Z). CC-2 delivered: Gmail draft
`r-32478110652307622` to mo.tut.liech@gmail.com (no send, no linkedin).
Codex desktop out of credits ~few hrs → its lane proposed to CC-terminal in
`coord/CLAUDE_INBOX.md`. No commit (gated on literal user word "commit").

## 2026-05-19T21:13Z — CX
Readiness checksum validation now runs from `dist/` with
`shasum -a 256 -c OS1.app.zip.sha256`, so the local readiness gate no longer
depends on a root-level `OS1.app.zip` symlink. `docs/business-use-cases.md` and
`docs/local-ops-24-7.md` now frame ad-hoc/local readiness as the current
production path, keep `--public` as future Developer ID escalation only, and
document the live Telegram routing split (`mo2drkbot` for Hermes DM via
`TELEGRAM_ALLOWED_USERS`; `mo2darkbot` for OpenClaw/notifications).

## 2026-05-19T21:25Z — CX
`scripts/os1-business-smoke.sh` daily-operations prompt now uses live disk
capacity from `df -h "$ROOT_DIR"` and ad-hoc/local release framing. Developer
ID notarization remains deferred and is not described as a current release
blocker; live smoke risks now track actual local warnings such as CUA daemon
state and low disk.

## 2026-05-19T21:44Z — CX
Local fallback model policy is now aligned on `qwen2.5-coder:1.5b` across
Ollama health, readiness, business smoke, business ops, launchd install, and
local docs. Installed `com.os1.local.health` and
`com.os1.local.business-ops` plists were reloaded with that model. Business
smoke now tolerates Markdown code fences from the lighter model before
validation. The local business-ops missed-fire recovery remains the
`launchctl kickstart -k` catch-up path documented in local ops runbooks.

## 2026-05-19T21:48Z — CX
Remaining Codex queue audit found CI/readiness coverage complete for Composio
health, ad-hoc release archive verification, and production-readiness docs.
Messaging pairing-code UX is fixed in the dirty tree; old pairing approval UI
is no longer rendered and `TELEGRAM_ALLOWED_USERS` is the live path. The last
stale `qwen2.5-coder:3b` production-readiness doc example was changed to
`qwen2.5-coder:1.5b`, and CI package checksum verification now runs from
`dist/` with `shasum -a 256 -c OS1.app.zip.sha256`.

## 2026-05-19T22:05Z — CX
OpenClaw local runtime repair moved the active CLI/runtime to user-local
OpenClaw `2026.5.18`, migrated `~/.openclaw/openclaw.json` away from stale
schema keys, reinstalled/restarted the gateway LaunchAgent against the
user-local install, and set Telegram default account to `mo2darkbot`.
Watchdog lookup now prefers `~/.local/bin/openclaw` when present so unattended
checks do not fall back to the stale global CLI. Readiness stayed green;
Composio/Twitter remains upstream degraded.
