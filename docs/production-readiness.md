# Production Readiness

OS1 has two different readiness targets while Azure is disabled:

- **Local production readiness**: one controlled Mac can run OS1, Hermes Agent,
  Ollama, and the health monitor for real daily work.
- **Public release readiness**: the app can be distributed to users as a signed,
  notarized, reproducible macOS release.

The local target is reachable without Azure, Key Vault, Azure OpenAI, or paid
cloud inference. The public target still requires Apple Developer ID signing and
notarization.

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
- a quick local business smoke through the selected Ollama model
- disk and model-cache state
- latest GitHub CI status when `gh` is available
- app bundle state if `dist/OS1.app` exists
- public signing credentials as warnings only

The local profile can pass without Developer ID signing, notarization
credentials, or a release archive.

## Public Release Gate

Run the stricter public gate before publishing a downloadable release:

```sh
scripts/os1-production-readiness.sh --public
```

The public profile fails when any of these are missing:

- clean git worktree
- successful GitHub CI for the current HEAD
- built `dist/OS1.app`
- release zip plus a verifying `dist/OS1.app.zip.sha256`
- Developer ID Application signature
- hardened runtime
- notarization credentials
- Gatekeeper acceptance
- stapled notarization ticket

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

Those are not blockers for local 24/7 use. They remain blockers for public
distribution.

## Current Local Operating Path

Use these commands in order:

```sh
scripts/os1-local-ops-health.sh
scripts/os1-business-smoke.sh --quick
scripts/os1-production-readiness.sh --local
```

For the recurring monitor:

```sh
OLLAMA_MODEL=qwen2.5-coder:3b scripts/install-local-ops-launchd.sh --health-only --apply
launchctl print gui/$(id -u)/com.os1.local.health
```

Use `--health-only` when `Ollama.app` is already supervising the model server.
Use the full installer only when OS1 should also own `ollama serve`.

## Remaining Public Blockers

- Developer ID Application certificate
- Apple notarization credentials
- signed, notarized, stapled archive
- release tag and GitHub release asset from the final green commit
- installer/update/rollback story for non-developer users
- privacy, permissions, and data-retention review for always-on automation

Azure restoration is separate. If Azure comes back, start with read-only
preflight commands from `docs/azure-operations.md`; do not re-enable mutations
unless the operator explicitly chooses to.
