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

## 2026-05-20T00:14Z — CX
Doc-staleness REQ is complete in the remaining Codex lane: business-use and
local-ops docs now frame ad-hoc as OS1's intentional production mode, document
the Telegram routing split (`mo2darkbot` OpenClaw/notify and `mo2drkbot`
Hermes/OS1 allowlist), and keep Developer ID as unused future escalation.
Local readiness treats skipped live business smoke and absent current-HEAD
GitHub CI as informational in local mode while public mode remains strict.

## 2026-05-20T17:55Z — CX
Business-ops runner no longer allows its own health stage to trigger the
business-ops LaunchAgent catch-up path: `scripts/os1-business-ops-run.sh`
invokes `scripts/os1-local-ops-health.sh` with
`OS1_LOCAL_OPS_KICK_BUSINESS_OPS=0`. This prevents self-kick overlap from
leaving stale locks and `com.os1.local.business-ops` exit code 1. After
clearing the orphan lock, launchd kickstart completed with last exit code 0
and `scripts/os1-production-readiness.sh --local` passed with the expected
local warnings.

## 2026-05-20T18:01Z — CX
Live business smoke is no longer skipped in the local proof path:
`OS1_READINESS_LIVE_BUSINESS_SMOKE=1 scripts/os1-production-readiness.sh
--local` exited 0 using `qwen2.5-coder:1.5b`. Business output validation stayed
strict-clean and the ad-hoc release archive verifier remained release-ready.
OpenClaw direct gateway status was healthy after a transient watchdog timeout;
Composio/Twitter remains degraded upstream.

## 2026-05-20T18:06Z — CX
No-apply business dry-run chain completed: real-business brief dry-run planned
successfully, one incomplete generated business-ops runtime artifact from the
earlier orphan-lock failure was quarantined, a fresh quick business-ops run
made the newest three runs green, strict validation passed 18/0/0, and
post-approved-content dry-run passed for LinkedIn plus Gmail draft without
sending or posting.

## 2026-05-20T18:10Z — CX
Autopilot watchdog stale REQ recovered on recheck without source changes:
heartbeat ledger resumed at 18:05Z with readiness OK, OpenClaw up, Composio
degraded rc 0, Twitter FAILED; launchd reports
`com.os1.autopilot.watchdog` last exit code 0. Strict business output
validation remains clean at 18/0/0.

## 2026-05-20T21:31Z — CX
Recovered a transient watchdog status regression without source changes:
the 21:25Z ledger line showed OpenClaw gateway-timeout and Composio down while
readiness remained OK, but direct OpenClaw validation/probe passed and direct
Composio status returned degraded rc 0. After one watchdog kick, launchd last
exit code returned to 0 and the 21:30Z ledger line is back to Hermes up,
OpenClaw up, Composio degraded rc 0, Twitter FAILED, readiness OK.

## 2026-05-21T12:10Z — CC [BAR-1 UNLOCKED]
First live `os1-post-approved-content.sh --apply` to LinkedIn fired.
- Channel: linkedin (Composio ca_9IfVCfV7xpXI ACTIVE).
- Visibility: CONNECTIONS.
- Title: "OS1 — first real local-first ops cycle".
- body_chars: 1008.
- Artifact: ~/Library/Application Support/OS1/posts/runs/20260521T121040Z/.
- result: ok, FAILED=none. Response body empty (LinkedIn returns URN in
  x-restli-id header, not body) so response_id captured as "unknown" — post
  itself went live. `w_member_social` scope is write-only so we cannot
  read it back via the same token; operator visual-confirms on LinkedIn.
- Pre-flight bug fixed: `composio_proxy_call` merged stderr into stdout,
  letting the CLI's "Update available" banner corrupt the JSON jq parsed
  for the userinfo /v2/userinfo person URN. First --apply failed with
  "could not resolve person URN"; second --apply (after the stderr-sidecar
  fix) succeeded.
- Operator explicitly authorized the post.

## 2026-05-21T12:25Z — CC
Exa wired as the primary AI search backend across the stack.

Composio side (for OS1 scripts / MCP):
- Created auth_config `ac_leOyjgYk3u27` (toolkit=exa, scheme=API_KEY).
- Created connected_account `ca_gY5js-efve_X` (ACTIVE) with the operator's
  Exa API key stored in Composio's secret slot. Verified via
  `composio execute EXA_ANSWER` — returned synthesized answer + citations.
- 18 Exa tools now available through Composio (EXA_SEARCH,
  EXA_GET_CONTENTS_ACTION, EXA_ANSWER, EXA_FIND_SIMILAR, EXA_CREATE_RESEARCH,
  EXA_GET_RESEARCH, EXA_LIST_RESEARCH, etc.).

Hermes side (interactive web tool, direct API):
- `EXA_API_KEY` added to `~/.hermes/.env` (mode 600) and the
  `ai.hermes.gateway` launchd plist EnvironmentVariables.
- `~/.hermes/config.yaml` flipped: `web.backend`, `web.search_backend`,
  `web.extract_backend` all set to `exa` (replacing previous `composio`
  /`ddgs`). Hermes auto-detects via EXA_API_KEY env per
  `tools/web_tools.py:155`.
- Gateway reloaded; subprocess env confirms EXA_API_KEY present.
- Direct probe to `api.exa.ai/answer` returned a real synthesized answer
  with 5 citations in 2.4 s.

Why two paths: Hermes interactive uses the direct Exa API (lowest
latency, no Composio hop). OS1 scripts and any future MCP tool routing
can use Composio's `EXA_*` tools through the connected account
(consistent auth, audit, rate-limit handling).

API key never written to any tracked file; lives in `~/.hermes/.env`,
the launchd plist EnvironmentVariables, and Composio's secret store.

## 2026-05-21T12:35Z — CC [PERF FIX]
"Hardware is too slow for local Ollama" diagnosis was **wrong**. Naked
Ollama.app defaults were the actual cause of every "extreme slowness"
report; 8 GB M1 + Metal can run llama3.2:1b at ~0.5 s warm response
once tuned.

Root cause: Ollama.app's launchd-supervised serve subprocess inherits
launchctl env, NOT the user's shell. So shell-level OLLAMA_* exports
never reached it. Defaults left in place:
- KEEP_ALIVE=5m  → any pause > 5 min triggers a 3-7 s cold load.
- KV cache F16   → doubles RAM cost vs Q8_0 (and ~halves what fits).
- flash_attn off → larger memory pressure, slower throughput.

Fix shipped: `scripts/configure-ollama-tunings.sh` sets and persists:
- OLLAMA_KEEP_ALIVE=-1 (stay loaded)
- OLLAMA_FLASH_ATTENTION=1 (Metal flash attention)
- OLLAMA_KV_CACHE_TYPE=q8_0 (halves KV cache RAM)
- OLLAMA_MAX_LOADED_MODELS=1 (no concurrent thrash on 8 GB)
- OLLAMA_NUM_PARALLEL=1 (one request at a time)
Modes: --apply (current session), --persist (installs
~/Library/LaunchAgents/com.os1.ollama-env.plist for reboot survival),
--preload MODEL (warms the named model with keep_alive=-1), --status.

Verified live on M1/8 GB after --persist:
- llama3.2:1b warm: 0.4-0.7 s (was timing out >60 s under default
  KEEP_ALIVE after idle).
- qwen2.5-coder:1.5b warm: similar profile.
- llama3.2:3b warm: ~4 tok/s eval; usable for batch, slow for chat.
- Ollama log confirms: `flash_attn = enabled`, `K (q8_0)`, `V (q8_0)`,
  Metal KV buffer 238 MiB (was ~476 MiB under F16).

LaunchAgent `com.os1.ollama-env` runs at user login, sets the five
env vars before Ollama.app autostarts so the supervisor inherits them.
Source via `bash scripts/configure-ollama-tunings.sh --status` to see
what's currently in the serve subprocess.

Sources: Exa-synthesized current best practice for 8 GB Apple Silicon
+ direct llama.cpp log verification. The "switch to cloud" advice was
defeatist; rejecting it.
