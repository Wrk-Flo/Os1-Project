# OS1 Business Use Case — Operator Runbook

Operator-facing runbook for the recurring local business-ops workload that
ships with the local-only OS1 profile. This document covers the daily and
weekly operator loop, where artifacts live, and the failure playbook when
the downstream validator (`scripts/validate-business-output.sh`) flags a
problem.

> Scope. This runbook is for an operator who already has OS1 installed in
> the local 24/7 profile (see `docs/local-ops-24-7.md`). It complements the
> upstream architecture/setup doc `docs/business-use-cases.md` rather than
> replacing it.

## Non-goals

- **Does not cover public distribution.** Apple Developer ID signing,
  notarization, entitlements, and the `dist/OS1.app.zip` release pipeline
  belong in the separate Apple credentials runbook
  (`docs/apple-credentials-setup.md`, owned by the signing agent — created
  alongside the signing scripts). When that document lands, reference it
  from there for any "ship to other Macs" question.
- **Does not replace the readiness gate.** Use
  `scripts/os1-production-readiness.sh --local` for the canonical go/no-go
  status check (worktree, LaunchAgents, Ollama, CI, app bundle, public
  credentials). This runbook focuses on the narrower question
  "is the business output usable right now?".
- **Does not modify the runner.** The validator is read-only against the
  runner's published `latest/` artifacts.

## What "real business operations" means in the local-only profile

In this profile, OS1 is not calling Azure, Key Vault, or any hosted
inference endpoint. The recurring business-ops workload is driven entirely
by:

1. **`com.os1.local.health`** — LaunchAgent that runs
   `scripts/os1-local-ops-health.sh` on an interval, exercising the local
   Ollama runtime and the offline planning paths. Logs go to
   `~/Library/Logs/OS1/local-health.log`.
2. **`com.os1.local.business-ops`** — LaunchAgent that runs
   `scripts/os1-business-ops-run.sh` on a slower cadence and produces the
   business artifact tree. This is the workload the operator actually
   consumes.

Each business-ops invocation does three jobs and publishes their results
into a timestamped run directory:

| Stage          | What it does                                       | Artifact             |
| -------------- | -------------------------------------------------- | -------------------- |
| Health         | Re-runs local-ops health for an isolated baseline  | `health.log`         |
| Storage        | Snapshots local storage usage and growth           | `storage.txt`        |
| Business smoke | Generates daily ops brief (quick) or 3 briefs (full) via the local model | `business-smoke.log` + `business-smoke/*.md` |
| Summary        | One markdown digest with status fields             | `summary.md`         |

In `--quick` mode (the LaunchAgent default), `business-smoke/` contains
`daily-operations-brief.md`. In `--full` mode it additionally contains
`customer-support-triage.md` and `project-task-extraction.md`. These
markdown briefs are the actual *business output*: bullet-point operating
status the operator can paste into their daily log, customer queue, or
project tracker.

The operator's job is to read these briefs each morning, decide what to
act on, and confirm the workload is healthy enough that tomorrow's briefs
will still be there. The validator script is what mechanizes that confirm
step.

## Where artifacts live

Default root (override with `OS1_BUSINESS_OPS_OUTPUT_ROOT` for the runner,
`OS1_BUSINESS_OPS_ROOT` for the validator/archiver):

```
~/Library/Application Support/OS1/business-ops/
  runs/YYYYMMDDTHHMMSSZ/        # one dir per run
    summary.md
    health.log
    storage.txt
    business-smoke.log
    business-smoke/*.md
  latest -> runs/<newest>       # symlink updated by runner
  archive/<run>.tar.gz          # created by business-output-archive.sh
  .lock/                        # owned by an in-flight runner
```

Retention is covered in `docs/local-ops-24-7.md` under "Retention" — read
that section, not this one, as the canonical source. The short version:
the runner prunes run directories older than 14 days by default; this
runbook adds a soft archive tier via
`scripts/business-output-archive.sh` (gzip to `archive/` before delete)
for any operator who wants to keep month-plus history offline.

## Daily operator loop

Each morning, before standup:

1. **Validate.** Run:
   ```sh
   bash scripts/validate-business-output.sh
   ```
   Exit code 0 means the latest run is fresh, complete, all three status
   fields are `passed`, and every expected artifact is present and
   non-empty. Exit code 1 means at least one critical check failed — jump
   to the failure playbook below.
2. **Open the brief.** Read
   `~/Library/Application Support/OS1/business-ops/latest/business-smoke/daily-operations-brief.md`.
   This is the actual business output for the day.
3. **Act on the brief.** Move bullets into your real-world tracker
   (project board, customer queue, finance log) — OS1 does not yet write
   into those systems for you in the local-only profile.
4. **Archive if needed.** If you finished an operational milestone that
   you want preserved beyond the 14-day prune window, run:
   ```sh
   bash scripts/business-output-archive.sh        # dry-run first
   bash scripts/business-output-archive.sh --apply
   ```
   This is safe to re-run; it skips already-archived runs and never
   touches the run currently pointed to by `latest`.

## Weekly operator loop

Once a week (Monday is a good slot):

1. Run validation in strict mode to confirm the recurring runner has been
   reliably green:
   ```sh
   bash scripts/validate-business-output.sh --strict --history 7
   ```
2. Skim `~/Library/Logs/OS1/business-ops.log` for unexpected warnings
   that the per-run `summary.md` collapsed into "passed" status.
3. Skim a `storage.txt` from earlier in the week and compare it to today's.
   Sustained growth in `.build`, `.build-tests`, or the Ollama model
   cache is a signal to run `scripts/os1-clean-storage.sh --all` (dry-run
   first).
4. Run the archiver in apply mode if you want a clean live `runs/` tree
   going into the week.

## Failure playbook

When `scripts/validate-business-output.sh` exits non-zero, read the
output top-to-bottom — every `FAIL:` line is a distinct check. Then
follow the first matching branch below.

### `FAIL: latest/ is missing`

- The recurring business-ops LaunchAgent has not produced any run yet, or
  the entire output root has been deleted/relocated.
- Check whether `com.os1.local.business-ops` is loaded:
  `launchctl print "gui/$(id -u)/com.os1.local.business-ops"`.
- If not loaded, reinstall:
  `scripts/install-local-ops-launchd.sh --health-only --business-ops --apply`.
- If loaded, force a manual run to seed the directory:
  `scripts/os1-business-ops-run.sh --quick`.

### `FAIL: latest/ is stale`

- The agent stopped firing or its runs are failing before they can
  publish. Read:
  1. `~/Library/Logs/OS1/business-ops.log` and `business-ops.err.log`.
  2. The most recent `runs/<id>/business-smoke.log` and `health.log`.
- Most common root cause is Ollama not responding. Re-run
  `scripts/ollama-health.sh` and `scripts/os1-local-ops-health.sh`
  directly.
- If logs look healthy but the agent is silent, restart the LaunchAgent:
  ```sh
  launchctl bootout "gui/$(id -u)/com.os1.local.business-ops" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" \
    ~/Library/LaunchAgents/com.os1.local.business-ops.plist
  ```
- If restart does not produce a fresh run within the interval, escalate
  to a manual `scripts/os1-business-ops-run.sh --quick` and capture its
  exit code; that exit code is the canonical signal to share when asking
  for help.

### `FAIL: summary.md Health = failed` (or `Storage = failed` or `Business smoke = failed`)

- The run completed and published, but a stage inside it failed. Read
  the corresponding artifact in the same run directory:
  - Health → `health.log`
  - Storage → `storage.txt` (also re-run `scripts/os1-storage-report.sh`
    directly for cleaner output).
  - Business smoke → `business-smoke.log` first, then the contents of
    `business-smoke/` to see whether briefs were even generated.
- If the upstream readiness gate (`scripts/os1-production-readiness.sh
  --local`) also flags the same stage, treat that as the primary signal
  and use this runbook's playbook only for the downstream-consumer view.

### `FAIL: <artifact> is 0 bytes` or `<artifact> missing`

- The runner crashed mid-publish, or a stage exited before writing its
  output. Confirm via `business-smoke.log` whether the model call timed
  out. Re-run manually with `--quick` to see live output:
  ```sh
  scripts/os1-business-ops-run.sh --quick
  ```
  and re-validate.

### Strict-mode `FAIL: run <id> ...` lines

- One or more recent runs were not all-green even though the latest run
  is fine. This is informational unless the same run id also fails the
  non-strict checks. Use it as a trend signal:
  - Repeated smoke failures → suspect the local model or its prompt
    template (`scripts/os1-business-smoke.sh`).
  - Repeated storage failures → suspect disk pressure; run the storage
    report and clean.
  - Repeated health failures → suspect Ollama or the local runtime;
    re-run `scripts/ollama-health.sh` and `scripts/os1-local-ops-health.sh`.

### Validator itself errors out

- `OS1_BUSINESS_OPS_ROOT` is misset, or freshness window is bad. Re-run
  with no env overrides and the defaults to isolate.
- If the script reports parser drift (status fields read as empty when
  `summary.md` clearly has them), the runner's summary format may have
  changed. Check `scripts/os1-business-ops-run.sh::write_summary` —
  status lines must remain in the form
  `- Label: \`value\`` for both this validator and the readiness gate
  to parse them.

## When to escalate

Escalate (open a coord note in `coord/CODEX_INBOX.md`, or ping the
build owner) when:

- Three consecutive validator runs across a day still fail after a
  manual `scripts/os1-business-ops-run.sh --quick` finishes green
  (suggests the LaunchAgent itself, not the workload, is broken).
- `summary.md` parser drift is suspected (the validator and the
  readiness gate both depend on the backticked-value format).
- The archiver fails on `--apply` for any reason other than a missing
  source directory — investigate disk space, permissions, and read-only
  flags on `archive/` before retrying.
