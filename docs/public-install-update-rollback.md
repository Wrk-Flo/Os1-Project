# Public Install, Update, And Rollback

This is the interim public-distribution runbook for OS1 before a packaged
installer, auto-update channel, or managed rollback service exists. It assumes a
signed and notarized `OS1.app.zip` plus `OS1.app.zip.sha256` have been published
from a final green commit.

## Install

Verify the downloaded archive before opening it:

```sh
shasum -a 256 -c OS1.app.zip.sha256
ditto -x -k OS1.app.zip .
codesign --verify --deep --strict OS1.app
spctl --assess --type execute -vvv OS1.app
```

Then move the app into `/Applications`:

```sh
mkdir -p "$HOME/Applications/OS1 Backups"
if [ -d /Applications/OS1.app ]; then
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  mv /Applications/OS1.app "$HOME/Applications/OS1 Backups/OS1.$stamp.app"
fi
mv OS1.app /Applications/OS1.app
```

## Local Services

Local production services are per-user LaunchAgents and must be installed
separately from the app bundle:

```sh
cd "/path/to/Os1 Project"
scripts/install-local-ops-launchd.sh --health-only --business-ops --apply
scripts/os1-production-readiness.sh --local
```

Use `--health-only` when another supervisor already owns Ollama. Use the full
installer only when OS1 should own `ollama serve`.

## Update

Before replacing the app, capture the current operating state:

```sh
scripts/os1-production-readiness.sh --local
sed -n '1,120p' "$HOME/Library/Application Support/OS1/business-ops/latest/summary.md"
```

Stop OS1, verify the new archive, back up `/Applications/OS1.app`, then replace
it using the install steps above. Re-run readiness before relying on the updated
app for live local work.

## Rollback

If the new app fails launch, Gatekeeper, or local readiness, restore the previous
backup:

```sh
latest_backup="$(ls -dt "$HOME"/Applications/OS1\ Backups/OS1.*.app 2>/dev/null | head -n 1)"
[ -n "$latest_backup" ] || { echo "No OS1 backup found" >&2; exit 1; }
rm -rf /Applications/OS1.app
cp -R "$latest_backup" /Applications/OS1.app
codesign --verify --deep --strict /Applications/OS1.app
spctl --assess --type execute -vvv /Applications/OS1.app
```

If a local LaunchAgent update was part of the failed change, unload and restore
the previous service configuration manually:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.health.plist 2>/dev/null || true
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.os1.local.business-ops.plist 2>/dev/null || true
scripts/install-local-ops-launchd.sh --health-only --business-ops --apply
```

Hermes Agent has its own backup-aware update path. If Hermes was changed during
the same incident, use its documented backup restore flow before re-running OS1
readiness.

## Future Installer Decision

This manual zip flow is acceptable for controlled pilots only. A public release
still needs a signed installer or DMG, an update channel, rollback metadata, and
a supportable permissions/privacy review before non-developer distribution.
