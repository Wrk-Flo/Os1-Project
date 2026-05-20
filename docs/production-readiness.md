# Production Readiness

OS1 has three readiness targets while Azure is disabled:

- **Local production readiness**: one controlled Mac can run OS1, Hermes Agent,
  Ollama, and the health monitor for real daily work.
- **Ad-hoc release readiness**: the app can be packaged reproducibly for the
  intentionally unsigned/free distribution path.
- **Public release readiness**: the app can be distributed to users as a
  Developer ID-signed, notarized macOS release.

The local and ad-hoc targets are reachable without Azure, Key Vault, Azure
OpenAI, paid cloud inference, or Apple Developer Program membership.
`OS1_RELEASE_MODE=adhoc` is the default release posture for local builds, so
Developer ID and notarization checks collapse to non-blocking local-readiness
signals. The public target is an explicit escalation and still requires Apple
Developer ID signing and notarization.

## Local Readiness Gate

Run the local gate before a long work session:

```sh
scripts/os1-production-readiness.sh --local
```

This checks:

- git worktree and upstream state
- Azure mutation flags are not enabled
- local OS1/Hermes/Ollama health
- the OS1 health LaunchAgent
- an optional bounded local business smoke through the selected Ollama model
- the local business-ops runner script, latest summary, and optional
  LaunchAgent status
- downstream validation that the latest business-ops artifacts are complete,
  fresh, and consumable
- optional Composio integration health for Gmail/LinkedIn business workflows
- disk and model-cache state
- latest GitHub CI status when `gh` is available
- app bundle and release archive verifier state in `OS1_RELEASE_MODE=adhoc`
  unless the public profile is requested
- public signing credentials as ad-hoc informational misses only

The local profile can pass without Developer ID signing, notarization
credentials, or a release archive. When a release archive exists, local mode
verifies it with `scripts/release-archive-verify.sh --mode adhoc` by default.
Set `OS1_RELEASE_MODE=developer-id` only when intentionally validating a signed
public distribution path.

## Fit With The 24/7 Runner

The recurring runner and the readiness gate have different jobs:

- `scripts/install-local-ops-launchd.sh --apply` installs the per-user
  LaunchAgents that keep the local stack monitored.
- `com.os1.local.health` runs `scripts/os1-local-ops-health.sh` on an interval
  and writes the latest recurring status under `~/Library/Logs/OS1`.
- `com.os1.local.business-ops` is optional. When installed with
  `scripts/install-local-ops-launchd.sh --business-ops --apply`, it writes
  timestamped run artifacts under
  `~/Library/Application Support/OS1/business-ops`.
- `scripts/os1-local-ops-health.sh` detects when the business-ops latest
  summary is older than two configured LaunchAgent intervals and kickstarts
  `com.os1.local.business-ops` after sleep gaps.
- `scripts/os1-production-readiness.sh --local` is a read-only acceptance gate.
  Run it before relying on the Mac for unattended local business work, after
  changing LaunchAgents, after changing the selected local model, and after
  moving model or log storage. The gate requires
  `scripts/os1-business-ops-run.sh` to be executable; a missing latest summary
  or unloaded optional business-ops LaunchAgent is reported as a warning.

Output locations and retention are part of the operator runbook, not the
readiness script. The local readiness profile validates the latest published
business artifacts by default. It only runs a live Ollama business smoke when
`OS1_READINESS_LIVE_BUSINESS_SMOKE=1` is set, because scheduled or manual
business runs already publish the durable output the operator actually consumes.
It does not require the optional business-ops schedule to be installed. See
[`docs/local-ops-24-7.md`](local-ops-24-7.md) for the local output map,
business artifact retention, manual log pruning, LaunchAgent restart commands,
and health-only mode when another supervisor already owns Ollama.

Composio health is checked as an integration signal. A degraded or missing
Composio setup is reported as a warning in the local profile unless
`OS1_REQUIRE_COMPOSIO=1` is set.

## Ad-Hoc Release Gate

Ad-hoc is the default release mode:

```sh
OS1_RELEASE_MODE=adhoc scripts/release-archive-verify.sh --mode adhoc
```

In ad-hoc mode, Developer ID signature, hardened runtime, notarization,
stapling, and Gatekeeper acceptance misses are expected warnings. The archive
still must exist and match its checksum.

## Public Release Gate

Run the stricter public gate only when intentionally escalating to Developer ID
distribution:

```sh
scripts/os1-production-readiness.sh --public
```

`--public` escalates release verification to Developer ID mode even when the
operator environment otherwise defaults to `OS1_RELEASE_MODE=adhoc`.

The `--public` profile switches the release verifier to
`--mode developer-id` and fails when any of these are missing:

- clean git worktree
- successful GitHub CI for the current HEAD
- built `dist/OS1.app`
- release zip plus a verifying `dist/OS1.app.zip.sha256`
- Developer ID Application signature
- hardened runtime
- notarization credentials
- Gatekeeper acceptance
- stapled notarization ticket
- `scripts/release-archive-verify.sh` passing against the final app bundle and
  release zip

Build a public-ready archive only after Developer ID and notary credentials are
available:

```sh
OS1_CODESIGN_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
OS1_NOTARIZE=1 \
OS1_NOTARY_KEYCHAIN_PROFILE=os1-notary \
scripts/package-github-release.sh
```

## Interpreting Results

- `OK` means the specific gate passed.
- `WARN` means the item should be addressed, but does not block that profile.
- `FAIL` means the current profile is not ready.

For the current Azure-disabled setup, expected local warnings may include:

- CUA driver installed but not running
- missing Developer ID/notarization credentials
- missing `dist/OS1.app` when no release archive has been built

Those are not blockers for local 24/7 use or ad-hoc release verification. They
remain blockers only for the explicit `--public` Developer ID path.

## Current Local Operating Path

Use these commands in order:

```sh
scripts/os1-local-ops-health.sh
scripts/validate-business-output.sh
scripts/os1-production-readiness.sh --local
```

For the recurring monitor:

```sh
OLLAMA_MODEL=qwen2.5-coder:1.5b scripts/install-local-ops-launchd.sh --health-only --apply
launchctl print gui/$(id -u)/com.os1.local.health
```

Use `--health-only` when `Ollama.app` is already supervising the model server.
Use the full installer only when OS1 should also own `ollama serve`.

For scheduled local business artifacts, add the optional business-ops runner
after the local gate is passing:

```sh
scripts/install-local-ops-launchd.sh --apply --health-only \
  --business-ops \
  --business-ops-mode quick \
  --business-ops-retention-days 14
launchctl print gui/$(id -u)/com.os1.local.business-ops
```

For optional CUA computer-use, keep the API key in the OS1 Keychain slot and
check only status words:

```sh
scripts/configure-cua-api-key.sh --status
scripts/configure-cua-api-key.sh --prompt
```

## Remaining Public Blockers

- Developer ID Application certificate
- Apple notarization credentials
- signed, notarized, stapled archive
- release tag and GitHub release asset from the final green commit
- packaged installer and managed update channel for non-developer users
- privacy, permissions, and data-retention review for always-on automation

The interim manual zip procedure is documented in
[`docs/public-install-update-rollback.md`](public-install-update-rollback.md).

Azure restoration is separate. If Azure comes back, start with read-only
preflight commands from `docs/azure-operations.md`; do not re-enable mutations
unless the operator explicitly chooses to.
