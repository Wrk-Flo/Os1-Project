# OS1 Real Business Brief

## Purpose

`scripts/os1-real-business-brief.sh` is a read-only sidecar that turns live local
business signals into an operator brief. It complements the existing
`scripts/os1-business-ops-run.sh` runner; it does not replace the canonical
business-ops readiness summary.

The script gathers Gmail, Apple Calendar, Apple Reminders, and LinkedIn identity
signals, then asks the configured local Ollama model to write a concise markdown
brief. It never sends mail, creates calendar items, posts content, or mutates
remote state.

Default output root:

```bash
~/Library/Application Support/OS1/business-brief
```

Each run writes:

```text
runs/<UTC>/
  summary.md
  brief.md
  provenance.json
  data/
    gmail-recent.json
    gmail-summarized.md
    linkedin-feed.json
    linkedin-summarized.md
    calendar-today.txt
    reminders-open.txt
latest -> runs/<UTC>
```

## Quick Start

Preview the planned work without collecting data or writing artifacts:

```bash
scripts/os1-real-business-brief.sh --quick --dry-run
```

Generate a daily brief:

```bash
scripts/os1-real-business-brief.sh --quick
```

Generate a wider weekly-context brief:

```bash
scripts/os1-real-business-brief.sh --full
```

Use a temporary output root for verification:

```bash
tmp_root="$(mktemp -d)"
OS1_BUSINESS_BRIEF_ROOT="$tmp_root/business-brief" \
  scripts/os1-real-business-brief.sh --quick
find "$tmp_root/business-brief" -maxdepth 3 -type f -print | sort
```

## Options

`--quick`: Gmail last 24 hours and one daily-brief pass. This is the default.

`--full`: Gmail last 7 days plus a second local-model pass for a short weekly
outlook.

`--model MODEL`: override `OLLAMA_MODEL`. The local default is
`qwen2.5-coder:3b`.

`--output-root DIR`: write artifacts under an alternate absolute path.

`--dry-run`: print the planned steps and exit without calling Ollama, collecting
data, or writing run artifacts.

`--no-symlink`: write the run directory but leave `latest` unchanged.

## Environment

`OLLAMA_MODEL`: local model used for summarization.

`OLLAMA_TASK_MAX_TIME_SECONDS`: max time for each Ollama generation. Keep this
bounded for scheduled runs so local inference cannot hang an ops cycle.

`OS1_BUSINESS_BRIEF_ROOT`: default artifact root override.

`OS1_BUSINESS_BRIEF_LOCK_STALE_SECONDS`: stale lock threshold. Default: `1800`.

`COMPOSIO_BIN`: Composio CLI path. Default: `~/.composio/composio`.

`OS1_BUSINESS_BRIEF_PROMPT_CAP`: max prompt characters before truncation.
Default: `6000`.

## Readiness Probe

The brief script runs `scripts/os1-integration-probe.sh --quiet --json` before
collecting data. Probe result handling is:

| Probe result | Brief behavior |
| --- | --- |
| `ready` | Continue. |
| `degraded` | Continue and include whatever data can be collected. |
| `down` | Fail before writing a new brief. |

Run the probe directly:

```bash
scripts/os1-integration-probe.sh
scripts/os1-integration-probe.sh --json
scripts/os1-integration-probe.sh --strict
```

The probe is read-only. It checks Ollama, the requested model, Composio CLI,
Gmail proxy access, LinkedIn proxy access, Twitter connected-account status,
Calendar automation access, and Reminders automation access.

## Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Brief generated, skipped because another run is active, or dry-run ok. |
| `1` | Hard failure such as probe down, missing dependency, lock failure, or Ollama failure. |
| `2` | Usage error. |

## Operator Workflow

1. Run the canonical business ops cycle first:

```bash
scripts/os1-business-ops-run.sh --quick
```

2. Generate the real-data sidecar brief:

```bash
OLLAMA_TASK_MAX_TIME_SECONDS=120 scripts/os1-real-business-brief.sh --quick
```

3. Review:

```bash
open "$HOME/Library/Application Support/OS1/business-brief/latest/brief.md"
```

4. If the brief is approved for external posting, copy or edit the approved text
into a clean markdown post and use `scripts/os1-post-approved-content.sh` in
dry-run first. Do not post directly from raw generated output.

## Failure Playbook

`FAIL: integration probe - RESULT=down`: run
`scripts/os1-integration-probe.sh` and fix the first `FAIL` line. Common causes
are Ollama not running or Composio credentials unavailable.

`ollama failure`: verify Ollama is running and the model is installed:

```bash
ollama list
curl -sS http://127.0.0.1:11434/api/tags | jq .
```

For slow local inference, lower `OLLAMA_NUM_PREDICT`, use
`qwen2.5-coder:1.5b`, or set a shorter `OLLAMA_TASK_MAX_TIME_SECONDS`.

`AppleScript error`: grant Automation or privacy access for the terminal parent
application in System Settings. Calendar and Reminders failures degrade the
brief but should not mutate data.

`composio proxy call failed`: run `docs/composio-integration-state.md` checks.
Gmail and LinkedIn are the useful v1 channels. Twitter can remain initiated or
expired until OAuth is completed.

## Wire-In Boundary

The sidecar remains opt-in from `scripts/os1-business-ops-run.sh` with
`--real-brief` or `OS1_BUSINESS_OPS_REAL_BRIEF=1`. The default runner path keeps
the real-data collection skipped so scheduled local operations can remain cheap
and predictable.

The canonical readiness contract still includes the existing `summary.md`
fields: `Health`, `Storage`, and `Business smoke`. When the sidecar is enabled,
the runner adds `Real business brief` and `Real business brief run directory`
without changing those existing fields.

## Security

The script never prints API keys. It may write personal identifiers and message
metadata into the local artifact directory, including email addresses, message
snippets, calendar titles, reminder names, and LinkedIn identity fields. Treat
the output root as local private operator data.

Do not commit generated artifacts.
