# Changelog

All notable OS1 production-push changes. Newest entries at top.

## [Unreleased] - 2026-05-19 (production push)

Parallel-agent session across Claude Code (terminal + Claude Desktop) and Codex
(CLI + Desktop). Lane split documented in `coord/decisions.log.md` (CC =
signing/notarization, business output validator, watchdog, real-brief; CX =
local-ops, readiness gate, runner, Swift Runtime UI, CI workflow, docs).
Commit explicitly held all session per dispatch protocol (gated on literal user
word "commit").

### Added
- `scripts/sign-os1-app.sh` — Developer ID + hardened-runtime codesign pipeline
  (inside-out, `--options runtime --timestamp --entitlements`).
- `scripts/notarize-os1-app.sh` — `notarytool submit --wait` → `stapler` flow;
  honors `OS1_NOTARY_PROFILE` (legacy `OS1_NOTARY_KEYCHAIN_PROFILE` still wins).
- `scripts/release-archive-verify.sh` — adhoc/developer-id mode-aware release
  gate; in adhoc mode the 5 Apple-cert checks downgrade FAIL→WARN, exit 0.
- `scripts/validate-business-output.sh` — downstream consumer validator with
  `--strict --history N` (default 3). 18 pass / 0 fail in prod.
- `scripts/business-output-archive.sh` — tar.gz of `runs/` older than
  `OS1_ARCHIVE_DAYS` (default 30); dry-run default, `--apply` to execute.
- `scripts/os1-real-business-brief.sh` — live brief generator (Gmail, Calendar,
  Reminders, OS1 health, Ollama summary). Read-only Alpaca by default.
- `scripts/os1-post-approved-content.sh` — multi-channel poster (linkedin,
  gmail-draft); dry-run default, explicit `--apply` per run.
- `scripts/os1-autopilot-watchdog.sh` — credit-free LLM-free local fallback;
  5-min launchd ledger, self-heals hermes + openclaw, surfaces composio/twitter
  + pairing-pending state to `/tmp/os1-heartbeat.log`.
- `scripts/install-real-brief-launchd.sh` — installs
  `com.os1.local.real-business-brief` daily at 06:07 CDT.
- `scripts/ci-cc-lane-smoke.sh` — credentials-free CI gate; PASS=30/30 local.
- `scripts/composio-health-check.sh` + `scripts/llm-task-openrouter.sh` +
  `scripts/os1-integration-probe.sh` + `scripts/os1-daily-brief-and-notify.sh`
  + `scripts/os1-notify-brief-ready.sh`.
- `packaging/OS1.entitlements` — minimal hardened-runtime entitlements (only
  `apple-events=true`).
- New docs: `apple-credentials-setup.md`, `business-use-case-runbook.md`,
  `composio-health-check.md`, `composio-integration-state.md`,
  `os1-post-approved-content.md`, `os1-real-business-brief.md`,
  `public-install-update-rollback.md`.
- `coord/CODEX_INBOX.md`, `coord/CLAUDE_INBOX.md`, `coord/decisions.log.md` —
  cross-agent coordination mailbox.
- `Tests/OS1Tests/LaunchStabilityDefaultsTests.swift` and HermesRuntime service
  test for OpenRouter model selection from `~/.hermes/config.yaml`.

### Changed
- Local fallback model aligned to `qwen2.5-coder:1.5b` (was `:3b`) across
  `scripts/ollama-health.sh`, `os1-production-readiness.sh`,
  `os1-business-smoke.sh`, `os1-business-ops-run.sh`,
  `install-local-ops-launchd.sh`, `os1-real-business-brief.sh`, and docs.
  Installed launchd plists reloaded with `OLLAMA_MODEL=qwen2.5-coder:1.5b`.
- `scripts/os1-real-business-brief.sh` now auto-detects OpenRouter creds (env
  or `~/.openrouter-key`), defaults to `z-ai/glm-4.5-air:free` via
  `llm-task-openrouter.sh`. `--model` / `OLLAMA_MODEL` overrides preserved.
- `scripts/os1-business-smoke.sh` daily prompt now derives live disk free from
  `df -h "$ROOT_DIR"`, frames release state as intentional ad-hoc (not a
  blocker). Tolerates Markdown code fences from the lighter model.
- `Sources/OS1/Views/Messaging/MessagingView.swift` — old "Approve pairing
  code" panel removed; install copy routes users to `TELEGRAM_ALLOWED_USERS`.
- `Sources/OS1/Views/Messaging/MessagingViewModel.swift` — `useDMPairing`
  default flipped to `false`; install always passes `allowedUsersDraft`.
- `docs/business-use-cases.md` + `docs/local-ops-24-7.md` — ad-hoc/local
  readiness reframed as current production path; `--public` is future
  Developer ID escalation only. Added Telegram routing split note
  (`mo2drkbot` for Hermes DM, `mo2darkbot` for OpenClaw/notifications).
- `docs/production-readiness.md` — `OS1_RELEASE_MODE=adhoc` documented as
  default; last `qwen2.5-coder:3b` reference scrubbed.
- `RELEASE.md` — new Distribution Modes section, end-user `xattr -dr
  com.apple.quarantine` workaround, notary step references canonical
  `OS1_NOTARY_PROFILE`.

### Fixed
- `scripts/os1-real-business-brief.sh` root-cause repair: `osa_guarded()`
  helper added (hard `OS1_OSA_TIMEOUT_SECONDS`=25s on Calendar/Reminders
  osascript; prior unguarded Reminders call hung ~14min and wedged
  `business-brief/.brief.lock` for every subsequent run). Ollama failure
  degrades to data-only brief instead of `die`. Validated in prod runs
  `190509Z` (degrade) and `190729Z` (full, 9 live Gmail msgs).
- `scripts/package-github-release.sh::write_checksum` — now `cd` into `dist/`
  before `shasum` so checksum holds the bare `OS1.app.zip` filename; readiness
  gate symlink hack removed by CX cleanup in
  `os1-production-readiness.sh` (verifies from `dist/` directly).
- `scripts/os1-production-readiness.sh` checksum branch updated to run from
  `dist/` with `shasum -a 256 -c OS1.app.zip.sha256`. CI same fix.
- `scripts/os1-local-ops-health.sh` no longer infers `OLLAMA_MODEL` from
  Hermes config when unset (Hermes may point at OpenRouter; local Ollama
  health must use its local default).
- `scripts/os1-autopilot-watchdog.sh` — OpenClaw `channels status` and
  `gateway restart` bounded by `OPENCLAW_STATUS_TIMEOUT` /
  `OPENCLAW_RESTART_TIMEOUT`; ledger now distinguishes `gateway-timeout`,
  `gateway-unreachable`, `mo2darkbot-down`, `config-invalid`. Component
  failures propagate to script exit code. Hermes recovery falls back to
  `hermes gateway start` if `restart` cannot reload unloaded launchd service.
  Prefers `~/.local/bin/openclaw` over stale global CLI.
- OpenClaw local runtime repaired: migrated to user-local
  `~/.local/bin/openclaw 2026.5.18` (was stale global `2026.2.1`); cleaned
  `~/.openclaw/openclaw.json` (`models.providers.ollama.api`, legacy
  `streamMode` → `streaming.mode`); gateway LaunchAgent reinstalled against
  user-local install; Telegram default = `mo2darkbot`.

### Infrastructure
- New launchd jobs installed: `com.os1.autopilot.watchdog` (5-min),
  `com.os1.local.real-business-brief` (daily 06:07 CDT). Existing
  `com.os1.local.business-ops` and `com.os1.local.health` reloaded with new
  model env.
- `scripts/os1-local-ops-health.sh` missed-fire recovery (macOS-only): when
  `com.os1.local.business-ops` latest run is >2x interval old, issues
  `launchctl kickstart -k`. Disable via
  `OS1_LOCAL_OPS_KICK_BUSINESS_OPS=0`; threshold
  `OS1_BUSINESS_OPS_CATCHUP_SECONDS`.
- `.github/workflows/ci.yml` — wired in CC-lane smoke
  (`scripts/ci-cc-lane-smoke.sh`); syntax gates for composio-health-check +
  release-archive-verify; adhoc archive packaging + verification step.

### Coord / Process
- Lane split formalized at 03:20Z (CC vs CX); see `coord/decisions.log.md`.
- 19:18Z: Claude Desktop took over the CC lane from terminal-Claude after the
  user re-assigned ("Codex desktop out of credits, take over"). Lane handed
  back to terminal-Claude with Desktop owning real-brief/posting/composio.
- 22:05Z: Codex Desktop closed OpenClaw config-invalid loop, restoring
  `openclaw=mo2darkbot-up` baseline in heartbeat ledger.
- Dispatch gates groups A–F on literal word "commit" — held all session.

### Known / Deferred
- Twitter OAuth (`ca_45KWg-Typfl1`) **upstream-blocked**: `hermes.composio.dev`
  callback host returns HTTP 530 / Cloudflare 1016 Origin DNS error. Re-link
  would mint another FAILED account. Recovery gated on host-health curl
  documented in `docs/composio-integration-state.md`. Gmail + LinkedIn
  unaffected; SMB use case degrades gracefully without X.
- Apple Developer ID path indefinitely deferred — user declined paid Apple
  Developer membership. Ad-hoc distribution is the permanent locked release
  mode; sign + notarize scripts remain dormant but tested.
- Brief content quality: `glm-4.5-air:free` returns empty summary; pipeline
  solid but summarization quality is a separate follow-up.
- CUA daemon optional/not running; disk free 21.5–22.5 GiB (below 25 GiB warn
  threshold). Both surfaced as warnings, not readiness failures.
- 2 stale duplicate "OS1 Real Business Brief" Gmail drafts from earlier peer
  attempts — harmless, user can purge.

### Verification
- Readiness gate (`scripts/os1-production-readiness.sh --local`): exit 0 with
  2 baseline WARNs (dirty worktree + Composio degraded).
- Live business smoke (`OS1_READINESS_LIVE_BUSINESS_SMOKE=1`): exit 0.
- CI smoke (`scripts/ci-cc-lane-smoke.sh`): PASS=30/30, FAIL=0,
  `RESULT: cc-lane-ci-ready`.
- `validate-business-output.sh --strict --history 3`: 18 pass / 0 fail / 0
  warn against `business-ops/latest/`.
- E2E dry-run chain (brief → validate → post-approved-content): all exit 0.
- `release-archive-verify.sh --mode adhoc --app dist/OS1.app`: exit 0 (5
  expected ad-hoc WARNs).
- `scripts/os1-dev.sh build-tests`: pass.
- `git diff --check`: clean.
- Watchdog ledger steady-state at session end (`/tmp/os1-heartbeat.log`):
  `hermes=up(pid=37163) openclaw=mo2darkbot-up composio=degraded(rc=0)
  twitter=FAILED readiness=ok` (rolling since 22:02Z).
- CC-2 Gmail draft delivered: `r-32478110652307622` to
  mo.tut.liech@gmail.com (no send, no linkedin per protocol).
