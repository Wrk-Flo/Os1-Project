# Local 24/7 Operations

This runbook keeps OS1 operating from the Mac with Azure disabled. It does not
read Azure, mutate Azure, sync Key Vault, start cloud VMs, or require `sudo`.

Use it for local business operations where the Mac, Ollama, Hermes Agent, and
optional CUA computer-use stack are the runtime.

## Safety Posture

- Keep `OS1_AZURE_ALLOW_MUTATIONS` and `OS1_AZURE_ALLOW_SECRET_SYNC` unset.
- Do not run the launchd installer with `sudo`; it installs per-user
  LaunchAgents under `~/Library/LaunchAgents`.
- The health script prints paths, readiness, and `set`/`missing` style status
  only. It does not print API keys, tokens, or config file contents.
- Use `scripts/azure/*` only after Azure is intentionally restored and
  preflighted. That is outside this local runbook.

## Operating Model

The local business-operations runner is intentionally small:

- `com.os1.local.ollama` is optional. It keeps `ollama serve` running on
  `127.0.0.1:11434` when OS1 owns the model server.
- `com.os1.local.health` is the recurring OS1 monitor. It runs
  `scripts/os1-local-ops-health.sh` every 300 seconds by default.
- `com.os1.local.business-ops` is optional. It runs
  `scripts/os1-business-ops-run.sh` every 3600 seconds by default when the
  launchd installer is called with `--business-ops`.
- `scripts/os1-production-readiness.sh --local` is the manual gate for deciding
  whether this Mac is ready for live local work. It is not a daemon and it does
  not install or start services.

Use `--health-only` when `Ollama.app`, Homebrew services, or another supervisor
already owns Ollama. In that mode OS1 monitors the stack without competing for
the Ollama port.

## Prerequisites

Install and test the local model server:

```sh
ollama serve
ollama pull qwen2.5-coder:1.5b
```

For a fuller Hermes Agent profile on an 8 GB Mac, prefer an installed model
with a declared 64K context, such as:

```sh
ollama pull llama3.1:8b
scripts/configure-local-oss-models.sh ollama
```

Install Hermes Agent separately and confirm the CLI is visible:

```sh
hermes version
```

For local CUA computer-use sessions, install the CUA driver from the Hermes
environment:

```sh
hermes computer-use install
```

Store the optional CUA API key in the OS1 Keychain slot without printing it:

```sh
scripts/configure-cua-api-key.sh --status
scripts/configure-cua-api-key.sh --prompt
```

Start the local CUA daemon only when a guarded computer-use workflow needs it:

```sh
scripts/manage-cua-driver.sh status
scripts/manage-cua-driver.sh start
scripts/manage-cua-driver.sh stop
```

The helper starts `cua-driver serve --no-relaunch` directly because the
app-wrapper relaunch path can fail to create the socket in terminal-run
contexts. Treat `scripts/manage-cua-driver.sh status` as the readiness signal;
an app process alone is not enough. Stop the daemon after the approved
computer-use session ends.

CUA is optional for local model operations. Missing CUA is a health warning,
not a hard failure.

## Health

Run the local health check manually:

```sh
scripts/os1-local-ops-health.sh
scripts/os1-production-readiness.sh --local
```

Hard failures include an invalid OS1 repo, missing Hermes CLI, failed Hermes
version check, unavailable Ollama endpoint, missing selected local model, and
critically low disk. Warnings include optional CUA gaps, unreadable optional
config, and low but non-critical disk.

Useful overrides:

```sh
OLLAMA_HOST=http://127.0.0.1:11434 \
OLLAMA_MODEL=qwen2.5-coder:1.5b \
OS1_LOCAL_OPS_DISK_WARN_GIB=50 \
OS1_LOCAL_OPS_DISK_FAIL_GIB=20 \
OS1_LOCAL_OPS_EXTRA_DISK_PATHS=/Volumes/OS1Data \
scripts/os1-local-ops-health.sh
```

If `OLLAMA_MODEL` is unset, the health script delegates to
`scripts/ollama-health.sh` and lets that checker use its local default. It does
not infer the active model from `~/.hermes/config.yaml`, because Hermes may be
pointed at a remote provider while local ops still validates the Ollama fallback.

## Output And State Map

The runner keeps operational output local to this Mac:

| Item | Default location | Notes |
| --- | --- | --- |
| LaunchAgent plists | `~/Library/LaunchAgents/com.os1.local.ollama.plist`, `~/Library/LaunchAgents/com.os1.local.health.plist`, and optionally `~/Library/LaunchAgents/com.os1.local.business-ops.plist` | Written only by `scripts/install-local-ops-launchd.sh --apply`. |
| Runner logs | `~/Library/Logs/OS1` | Override during install with `--log-dir` or at runtime with `OS1_LOCAL_OPS_LOG_DIR`. |
| Health stdout | `~/Library/Logs/OS1/local-health.log` | Contains timestamped `INFO`, `OK`, `WARN`, and `FAIL` lines. |
| Health stderr | `~/Library/Logs/OS1/local-health.err.log` | Usually empty unless shell, launchd, or tool errors occur. |
| CUA daemon log | `~/Library/Logs/OS1/cua-driver.log` | Written only when `scripts/manage-cua-driver.sh start` starts the optional local daemon. Override with `OS1_CUA_DRIVER_LOG`. |
| Ollama stdout/stderr | `~/Library/Logs/OS1/ollama.out.log` and `~/Library/Logs/OS1/ollama.err.log` | Present only when OS1 installs the Ollama LaunchAgent. |
| Business ops stdout/stderr | `~/Library/Logs/OS1/business-ops.log` and `~/Library/Logs/OS1/business-ops.err.log` | Present only when the optional business-ops LaunchAgent is installed. |
| Business ops artifacts | `~/Library/Application Support/OS1/business-ops/runs/<UTC timestamp>` and `~/Library/Application Support/OS1/business-ops/latest` | Each run writes `summary.md`, `health.log`, `storage.txt`, `business-smoke.log`, and `business-smoke/*.md`. |
| Ollama models | `~/.ollama/models` unless `OLLAMA_MODELS` is set | Move large models to an external APFS SSD when internal disk is tight. |
| Hermes state | `~/.hermes` | Local Hermes config and backups live here; do not commit it. |
| One-off business smoke artifacts | None by default | `scripts/os1-business-smoke.sh --output-dir DIR` writes Markdown responses under the directory you choose. |
| Build and release artifacts | `.build`, `.build-tests`, `.swiftpm-home`, `dist` | Disposable repo-local outputs; see `docs/local-storage.md`. |

Keep customer, finance, and project outputs outside the repo unless they are
intentionally sanitized documentation fixtures. A practical local folder is
`~/Library/Application Support/OS1/business-ops`, `~/Documents/OS1 Operations`,
or an encrypted external volume.

## Retention

There is no automatic log rotation in these LaunchAgents. Set an explicit local
retention habit before using OS1 for live business work:

- Keep active runner logs for 14 to 30 days unless a customer, legal, or audit
  policy requires a different window.
- The recurring business-ops runner prunes run directories older than 14 days
  by default. Set `--business-ops-retention-days N` during launchd install to
  choose a different positive retention window.
- The business-ops runner writes a lock owner file and removes stale locks only
  after the owner process is gone and the lock is older than two hours. Override
  that threshold with `OS1_BUSINESS_OPS_LOCK_STALE_SECONDS`.
- Each business-ops stage is bounded by `OS1_BUSINESS_OPS_STAGE_TIMEOUT_SECONDS`
  and each Ollama generation is bounded by `OLLAMA_TASK_MAX_TIME_SECONDS`.
  Lower `OLLAMA_NUM_PREDICT` or switch to a smaller local model if scheduled
  runs approach those limits.
- The readiness gate treats a latest business-ops summary older than two hours
  as stale by default. Override with `OS1_BUSINESS_OPS_MAX_AGE_SECONDS`.
- For a direct one-off business run, `scripts/os1-business-ops-run.sh --no-prune`
  keeps prior run directories. Use that only for short investigations.
- Keep business smoke Markdown artifacts only as long as they are useful for
  the operating review. Do not commit them.
- Treat model caches as replaceable but expensive to redownload. Remove models
  manually with `ollama rm MODEL` after confirming they are not the selected
  fallback.
- Treat `.build`, `.build-tests`, `.swiftpm-home`, and `dist` as disposable.
  Use `scripts/os1-storage-report.sh` before cleanup and
  `scripts/os1-clean-storage.sh --all --apply` only after the dry run looks
  correct.
- Before sharing logs, review them for local paths, hostnames, project names,
  and generated task content. The health scripts avoid printing secrets, but
  business prompts and model responses may still contain sensitive information.

Archive and prune logs manually when needed:

```sh
mkdir -p ~/Library/Logs/OS1/archive
stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
for name in local-health.log local-health.err.log ollama.out.log ollama.err.log business-ops.log business-ops.err.log; do
  [ -f "$HOME/Library/Logs/OS1/$name" ] || continue
  cp "$HOME/Library/Logs/OS1/$name" "$HOME/Library/Logs/OS1/archive/$name.$stamp"
done
find ~/Library/Logs/OS1/archive -type f -mtime +30 -delete
```

To start a fresh log after archiving:

```sh
: > ~/Library/Logs/OS1/local-health.log
: > ~/Library/Logs/OS1/local-health.err.log
: > ~/Library/Logs/OS1/ollama.out.log
: > ~/Library/Logs/OS1/ollama.err.log
: > ~/Library/Logs/OS1/business-ops.log
: > ~/Library/Logs/OS1/business-ops.err.log
```

## Launchd Install

Preview the LaunchAgents without writing files:

```sh
scripts/install-local-ops-launchd.sh
```

Install and load per-user services:

```sh
OLLAMA_MODEL=qwen2.5-coder:1.5b scripts/install-local-ops-launchd.sh --apply
```

This creates:

- `~/Library/LaunchAgents/com.os1.local.ollama.plist`
- `~/Library/LaunchAgents/com.os1.local.health.plist`

When `--business-ops` is included, it also creates:

- `~/Library/LaunchAgents/com.os1.local.business-ops.plist`

The Ollama agent runs `ollama serve` on `127.0.0.1:11434`. The health agent
runs every 300 seconds by default and writes to `~/Library/Logs/OS1`. Change
the interval or log directory during install:

```sh
scripts/install-local-ops-launchd.sh --apply --health-interval 600
scripts/install-local-ops-launchd.sh --apply --log-dir ~/Library/Logs/OS1
```

Write plists without loading them:

```sh
scripts/install-local-ops-launchd.sh --apply --no-load
```

If Ollama is already supervised by `Ollama.app`, Homebrew services, or another
LaunchAgent, install only the OS1 health monitor to avoid two supervisors
competing for `127.0.0.1:11434`:

```sh
scripts/install-local-ops-launchd.sh --health-only
scripts/install-local-ops-launchd.sh --health-only --apply
```

Install with explicit runtime values when the selected model or Ollama endpoint
differs from the defaults:

```sh
scripts/install-local-ops-launchd.sh --apply \
  --ollama-http-host http://127.0.0.1:11434 \
  --ollama-model qwen2.5-coder:1.5b \
  --health-interval 300
```

Preview and install the scheduled business-ops runner:

```sh
scripts/install-local-ops-launchd.sh --business-ops
scripts/install-local-ops-launchd.sh --apply \
  --business-ops \
  --business-ops-mode quick \
  --business-ops-interval 3600 \
  --business-ops-retention-days 14 \
  --business-ops-output-root "$HOME/Library/Application Support/OS1/business-ops"
```

Use `--business-ops-mode full` only when the Mac can afford the extra local
model work. The quick mode writes the daily operations brief; full mode runs
all local business smoke workflows.

## Logs

Default logs are under `~/Library/Logs/OS1`:

```sh
tail -f ~/Library/Logs/OS1/ollama.out.log
tail -f ~/Library/Logs/OS1/ollama.err.log
tail -f ~/Library/Logs/OS1/local-health.log
tail -f ~/Library/Logs/OS1/local-health.err.log
tail -f ~/Library/Logs/OS1/business-ops.log
tail -f ~/Library/Logs/OS1/business-ops.err.log
```

Check launchd state:

```sh
launchctl print gui/$(id -u)/com.os1.local.ollama
launchctl print gui/$(id -u)/com.os1.local.health
launchctl print gui/$(id -u)/com.os1.local.business-ops
```

Use the last health lines as the quickest recurring status check:

```sh
tail -n 80 ~/Library/Logs/OS1/local-health.log
tail -n 80 ~/Library/Logs/OS1/local-health.err.log
tail -n 80 ~/Library/Logs/OS1/business-ops.log
sed -n '1,120p' "$HOME/Library/Application Support/OS1/business-ops/latest/summary.md"
```

## Restart And Stop

Restart Ollama:

```sh
launchctl kickstart -k gui/$(id -u)/com.os1.local.ollama
```

Run health immediately:

```sh
launchctl kickstart -k gui/$(id -u)/com.os1.local.health
```

Run the business-ops cycle immediately:

```sh
launchctl kickstart -k gui/$(id -u)/com.os1.local.business-ops
```

Unload services:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.ollama.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.health.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.business-ops.plist
```

Remove the installed plists after unloading if this Mac should no longer run
the local monitor:

```sh
rm -f ~/Library/LaunchAgents/com.os1.local.ollama.plist
rm -f ~/Library/LaunchAgents/com.os1.local.health.plist
rm -f ~/Library/LaunchAgents/com.os1.local.business-ops.plist
```

After changing plists, reload them:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.ollama.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.health.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.business-ops.plist
```

## Model Fallback

Keep at least two local models available:

```sh
ollama pull qwen2.5-coder:1.5b
ollama pull qwen2.5-coder:3b
ollama list
```

Use `qwen2.5-coder:1.5b` as the default local fallback model on the current
8 GB Mac. Keep `qwen2.5-coder:3b` available only for tasks where the extra disk,
RAM, and latency are acceptable. Pull a larger model such as `llama3.1:8b` only
when a specific heavier task needs it. If the active model is missing or too
slow, reconfigure Hermes locally:

```sh
OLLAMA_MODEL=qwen2.5-coder:1.5b scripts/configure-local-oss-models.sh ollama
scripts/os1-local-ops-health.sh
```

For a temporary one-off fallback without changing Hermes config:

```sh
OLLAMA_MODEL=qwen2.5-coder:1.5b scripts/ollama-task.sh "Summarize docs/local-oss-runtime.md"
```

## Readiness Gate

Run the full local gate after installing or changing LaunchAgents, changing the
selected model, moving model storage, or before starting a long unattended
business session:

```sh
scripts/os1-production-readiness.sh --local
```

That script is read-only. For the local profile it combines the checks from
this runbook with git state, Azure-disabled flags, LaunchAgent state, Ollama
health, a quick local business smoke, business-ops runner status, storage
reporting, GitHub CI status when `gh` is available, app bundle warnings, and
public signing warnings. Local warnings such as missing Developer ID signing can
still be acceptable for a controlled Mac; hard failures mean the runner is not
ready for live work.

The readiness gate runs its own quick business smoke. It does not require the
optional `com.os1.local.business-ops` schedule to be installed, but it does
require `scripts/os1-business-ops-run.sh` to exist and be executable. If the
latest summary exists, readiness checks that health, storage, and business smoke
passed and warns when the summary is stale. If the schedule or latest summary is
missing, readiness reports a warning. If the scheduled runner is part of the
local operating plan, kick it once after the readiness gate and inspect the
generated summary:

```sh
launchctl kickstart -k gui/$(id -u)/com.os1.local.business-ops
sed -n '1,120p' "$HOME/Library/Application Support/OS1/business-ops/latest/summary.md"
```

The recurring health monitor also handles missed business-ops fires after Mac
sleep. When `com.os1.local.business-ops` is loaded and the latest summary is
older than two configured LaunchAgent intervals, `scripts/os1-local-ops-health.sh`
runs `launchctl kickstart -k gui/$(id -u)/com.os1.local.business-ops`. Set
`OS1_LOCAL_OPS_KICK_BUSINESS_OPS=0` to disable catch-up, or set
`OS1_BUSINESS_OPS_CATCHUP_SECONDS` to choose an explicit age threshold. If no
latest summary exists yet, kick the agent manually once to create the first
baseline.

## External Storage

For 24/7 work, keep the Mac on power and use a fast APFS SSD for large local
model and artifact storage. Avoid removable storage that sleeps aggressively.

Ollama can store models on an external volume by adding `OLLAMA_MODELS` to the
Ollama LaunchAgent environment:

```xml
<key>OLLAMA_MODELS</key>
<string>/Volumes/OS1Data/ollama-models</string>
```

Then reload Ollama:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.ollama.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.ollama.plist
```

Monitor external storage with:

```sh
OS1_LOCAL_OPS_EXTRA_DISK_PATHS=/Volumes/OS1Data scripts/os1-local-ops-health.sh
```

If the health LaunchAgent should monitor that path every run, add
`OS1_LOCAL_OPS_EXTRA_DISK_PATHS` to the health plist environment.

## Local Production Boundaries

This setup is suitable for local operations on a controlled Mac and ad-hoc OS1
distribution. Ad-hoc is the intentional production mode, with
`OS1_RELEASE_MODE=adhoc` as the default in
`scripts/os1-production-readiness.sh` and
`scripts/release-archive-verify.sh --mode adhoc` as the matching archive gate.

## Public Distribution Path (unused)

Developer ID signing and notarization are not blockers for the current OS1
production path. The `--public` readiness gate and Developer ID archive checks
exist only for a later paid Apple Developer Program escalation. See
`RELEASE.md` "Distribution modes" for the active ad-hoc/default mode and
`docs/apple-credentials-setup.md` for the unused Developer ID operator path.

Remaining operational boundaries:

- No packaged Developer ID-signed installer for these LaunchAgents.
- No managed auto-update and rollback flow for OS1, Hermes Agent, Ollama, or
  CUA driver.
- Single-Mac runtime with no high availability, queue durability guarantee, or
  remote failover.
- Local model quality, latency, and context limits still vary by hardware and
  selected model.
- CUA local computer-use has prerequisite checks, but persistent status and
  stop controls are not wired as a production service surface.
- No enterprise observability, alert routing, or secret-rotation workflow.
- Wider distribution still needs a security, privacy, permission, and data-retention
  review for always-on local automation.
