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

## Prerequisites

Install and test the local model server:

```sh
ollama serve
ollama pull qwen2.5-coder:3b
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
OLLAMA_MODEL=qwen2.5-coder:3b \
OS1_LOCAL_OPS_DISK_WARN_GIB=50 \
OS1_LOCAL_OPS_DISK_FAIL_GIB=20 \
OS1_LOCAL_OPS_EXTRA_DISK_PATHS=/Volumes/OS1Data \
scripts/os1-local-ops-health.sh
```

If `OLLAMA_MODEL` is unset, the health script tries to infer the active model
from `~/.hermes/config.yaml`, then falls back to `scripts/ollama-health.sh`
defaults.

## Launchd Install

Preview the LaunchAgents without writing files:

```sh
scripts/install-local-ops-launchd.sh
```

Install and load per-user services:

```sh
OLLAMA_MODEL=qwen2.5-coder:3b scripts/install-local-ops-launchd.sh --apply
```

This creates:

- `~/Library/LaunchAgents/com.os1.local.ollama.plist`
- `~/Library/LaunchAgents/com.os1.local.health.plist`

The Ollama agent runs `ollama serve` on `127.0.0.1:11434`. The health agent
runs every 300 seconds by default. Change the interval during install:

```sh
scripts/install-local-ops-launchd.sh --apply --health-interval 600
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

## Logs

Default logs are under `~/Library/Logs/OS1`:

```sh
tail -f ~/Library/Logs/OS1/ollama.out.log
tail -f ~/Library/Logs/OS1/ollama.err.log
tail -f ~/Library/Logs/OS1/local-health.log
tail -f ~/Library/Logs/OS1/local-health.err.log
```

Check launchd state:

```sh
launchctl print gui/$(id -u)/com.os1.local.ollama
launchctl print gui/$(id -u)/com.os1.local.health
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

Unload services:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.ollama.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.health.plist
```

After changing plists, reload them:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.ollama.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.health.plist
```

## Model Fallback

Keep at least two local models available:

```sh
ollama pull qwen2.5-coder:3b
ollama pull qwen2.5-coder:1.5b
ollama list
```

Use `qwen2.5-coder:3b` as the default local model on the current 8 GB Mac. Pull
a larger model such as `llama3.1:8b` only when a specific heavier task needs it
and you can tolerate the extra disk, RAM, and latency. If the active model is
missing or too slow, reconfigure Hermes locally:

```sh
OLLAMA_MODEL=qwen2.5-coder:3b scripts/configure-local-oss-models.sh ollama
scripts/os1-local-ops-health.sh
```

For a temporary one-off fallback without changing Hermes config:

```sh
OLLAMA_MODEL=qwen2.5-coder:3b scripts/ollama-task.sh "Summarize docs/local-oss-runtime.md"
```

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

## Public Production Release Blockers

This setup is suitable for local operations on a controlled Mac, not public
production release. Remaining blockers:

- No packaged, signed, notarized installer for these LaunchAgents.
- No managed auto-update and rollback flow for OS1, Hermes Agent, Ollama, or
  CUA driver.
- Single-Mac runtime with no high availability, queue durability guarantee, or
  remote failover.
- Local model quality, latency, and context limits still vary by hardware and
  selected model.
- CUA local computer-use has prerequisite checks, but persistent status and
  stop controls are not wired as a production service surface.
- No enterprise observability, alert routing, or secret-rotation workflow.
- Public release still needs a security, privacy, permission, and data-retention
  review for always-on local automation.
