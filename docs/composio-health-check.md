# Composio Health Check

`scripts/composio-health-check.sh` is a read-only operator validator for OS1
Composio readiness. It checks local prerequisites, the Composio connected
accounts API, expected active toolkits, Gmail and LinkedIn read-only roundtrips,
and whether stale or unexpected connected accounts are present.

The validator never prints the API key and does not issue `POST`, `PUT`, or
`DELETE` requests.

## Usage

```bash
scripts/composio-health-check.sh
scripts/composio-health-check.sh --strict
scripts/composio-health-check.sh --json --quiet
scripts/composio-health-check.sh --expected gmail,linkedin --timeout-seconds 8
```

Options:

- `--expected CSV`: expected active toolkit slugs. Default: `gmail,linkedin`.
- `--strict`: exits `1` when any check reports `FAIL`.
- `--json`: emits a single JSON document with check results and final result.
- `--quiet`: suppresses per-check human output and prints only `RESULT`.
- `--timeout-seconds N`: per-request timeout. Default: `8`.
- `-h`, `--help`: prints usage.

Environment:

- `COMPOSIO_BIN`: Composio CLI path. Default: `$HOME/.composio/composio`.
- `COMPOSIO_API_KEY_FILE`: API key file. Default: `$HOME/.composio/api_key`.
- `COMPOSIO_API_BASE`: API base. Default:
  `https://backend.composio.dev/api/v3`.

## Preconditions

The API key file must be readable, non-empty, and mode `0600` or stricter. If
the key is missing, empty, unreadable, or too permissive, the validator stops
before making network requests and exits `3`.

Fix file mode with:

```bash
chmod 600 ~/.composio/api_key
```

## Results

The final line is always:

```text
RESULT: ready
RESULT: degraded
RESULT: down
```

Exit codes:

- `0`: `ready`, or `degraded` without `--strict`.
- `1`: `down`, or `--strict` with any `FAIL`.
- `2`: usage error.
- `3`: missing or unsafe precondition.

`INITIATED` connected accounts are reported as `WARN` because they usually mean
an OAuth flow was started but not completed. Failed, expired, disabled, deleted,
or unexpected accounts fail the `no-orphan-accounts` check.

## Wire-In Contract

Local ops, release, or production-readiness runners may call this script as a
read-only gate and consume either the final `RESULT` line or the JSON `result`
field. Callers should preserve the exit-code contract above and must not pass or
log raw Composio API keys.
