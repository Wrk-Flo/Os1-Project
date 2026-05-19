# Azure Operations

This runbook covers the standalone OS1 Azure VM used through the existing SSH transport. It is the current no-Orgo path for running OS1 against a cloud host, and it does not create app source changes or install a new VM helper service.

## Azure Disabled Fallback

Default posture as of 2026-05-18: treat Azure subscription and Key Vault access
as unavailable until `scripts/azure/os1-vm.sh preflight` proves otherwise.

If Azure returns disabled-subscription, billing, or Key Vault data-plane
errors, do not use this runbook as the active setup path. Use local OSS
models and local/SSH infrastructure instead:

```sh
ollama serve
ollama pull qwen2.5-coder:3b
scripts/configure-local-oss-models.sh ollama
```

For llama.cpp, run its OpenAI-compatible server on `127.0.0.1:8080`, then:

```sh
scripts/configure-local-oss-models.sh llama-cpp
```

This writes a local Hermes provider under `~/.hermes/config.yaml`, sets the
active model, and avoids Azure CLI, Azure Key Vault, Azure OpenAI, and VM
mutations entirely. The Azure VM helper can print the same fallback without
contacting Azure:

```sh
scripts/azure/os1-vm.sh local-fallback
scripts/azure/sync-os1-secrets.py --local-fallback
```

See `docs/local-oss-runtime.md` for the local-only runbook. Resume this Azure
runbook only after the subscription and Key Vault data plane are healthy again.

For the separate provider-neutral Computer Session lane covering disposable
visual desktops and sandboxes, see `docs/computer-session-provider-plan.md`.
This runbook remains scoped to Azure VM operations over SSH.

## Scope

- Resource group: `os1-project-rg`
- VM: `os1-hermes-dev`
- Network security group: `os1-hermes-devNSG`
- Default SSH user: `hermes`
- SSH allowlist rule: `AllowSSHFromMosesMac`

Override these defaults with environment variables when operating another OS1 Azure VM:

```sh
OS1_AZURE_RESOURCE_GROUP=my-rg \
OS1_AZURE_VM_NAME=my-vm \
OS1_AZURE_NSG_NAME=my-vmNSG \
OS1_AZURE_SSH_USER=hermes \
scripts/azure/os1-vm.sh status
```

## Prerequisites

1. Azure CLI is installed.
2. `az login` has an active session for the OS1 subscription.
3. The local SSH private key can reach the VM without an interactive password prompt.
4. The VM has `python3` available on the non-interactive SSH path.

The helper never prints Azure tokens, private keys, or application secrets. It does print VM metadata, the VM public IP, and the SSH source CIDR because those are the values being operated.

## Common Operations

Run a read-only Azure readiness check before mutations:

```sh
scripts/azure/os1-vm.sh preflight
```

`preflight` reports the Azure CLI login state, subscription name/ID/state,
whether writes are blocked because the subscription is not `Enabled`, and
whether the configured VM can be found. It does not start, stop, update, or
create Azure resources.

Azure write commands fail closed by default. After `preflight` reports a
healthy subscription, explicitly opt in to Azure mutations with
`OS1_AZURE_ALLOW_MUTATIONS=1`. Leave that variable unset while Azure is
disabled or uncertain.

Show VM state and the SSH allowlist source:

```sh
scripts/azure/os1-vm.sh status
```

Refresh the SSH NSG rule to this Mac's current public IP:

```sh
OS1_AZURE_ALLOW_MUTATIONS=1 scripts/azure/os1-vm.sh refresh-ssh-allowlist
```

Use an explicit CIDR instead of public IP discovery:

```sh
OS1_AZURE_ALLOW_MUTATIONS=1 \
OS1_AZURE_OPERATOR_CIDR=203.0.113.10/32 \
scripts/azure/os1-vm.sh refresh-ssh-allowlist
```

Preview an allowlist mutation without changing Azure:

```sh
OS1_AZURE_DRY_RUN=1 scripts/azure/os1-vm.sh refresh-ssh-allowlist
```

Start, restart, stop, or deallocate the standalone VM:

```sh
OS1_AZURE_ALLOW_MUTATIONS=1 scripts/azure/os1-vm.sh start
OS1_AZURE_ALLOW_MUTATIONS=1 scripts/azure/os1-vm.sh restart
OS1_AZURE_ALLOW_MUTATIONS=1 scripts/azure/os1-vm.sh stop
OS1_AZURE_ALLOW_MUTATIONS=1 scripts/azure/os1-vm.sh deallocate
```

Use `deallocate` when the machine should stop incurring VM compute charges. Use `stop` only when the VM must remain allocated.

If Azure returns `ReadOnlyDisabledSubscription`, re-enable the subscription
before retrying `start`, `restart`, `stop`, `deallocate`, or
`refresh-ssh-allowlist`. Read-only commands such as `preflight` and `status`
are safe to run while the subscription is disabled.

Smoke test the OS1 SSH path:

```sh
scripts/azure/os1-vm.sh ssh-smoke
```

The smoke test checks SSH batch-mode access, `python3`, and whether the `hermes` CLI is visible. If the public IP changed, refresh the SSH allowlist first.

Check tool and MCP readiness:

```sh
scripts/azure/os1-vm.sh tools-status
```

This checks the VM runtime without printing secrets:

- Python and Hermes CLI visibility.
- Node, npm, and npx availability for MCP servers that run through Node.
- Whether `~/.hermes/config.yaml` exists.
- Which MCP server names are configured under `mcp_servers`.
- Hermes gateway status.

Expected fresh-VM output is roughly:

```text
node=v22...
npm=10...
npx=10...
mcp_servers=none
gateway_status:
✗ Gateway is not running
```

That is still ready for initial app testing. MCP servers appear after you install connector integrations from OS1, such as Composio or AgentMail.

Check known Azure Key Vault credentials without writing to the OS1 VM:

```sh
scripts/azure/sync-os1-secrets.py --dry-run
```

The sync helper is check-only by default. It prints subscription readiness and
redacted `set`/`missing` status. It exits before any SSH write when the
subscription is not `Enabled`, Key Vault is unavailable, or required secrets
are missing.

After Azure and Key Vault are restored, apply the sync explicitly:

```sh
scripts/azure/sync-os1-secrets.py --apply
```

`OS1_AZURE_ALLOW_SECRET_SYNC=1` is also accepted for automation, but `--dry-run`
always skips VM writes.

Defaults:

- OpenAI key: `wrkflo-kv/openai-api-key`
- Composio key: `wrkflo-kv/composio-api-key`
- Telegram bot token: Azure Container App secret `wrkflo/wrkflo-orchestrator/telegram-bot-token`
- Target host: `os1-hermes-dev`
- Active model after sync: `gpt-5.4-mini`

Use a different Composio vault/secret when testing candidates:

```sh
scripts/azure/sync-os1-secrets.py \
  --dry-run \
  --composio-vault gs-quantum-kv \
  --composio-secret COMPOSIO-API-KEY
```

The sync helper does not print secret values. With `--apply`, it reports only
redacted status, writes `OPENAI_API_KEY` and `TELEGRAM_BOT_TOKEN` to
`~/.hermes/.env`, registers the `openai` provider in
`~/.hermes/config.yaml`, sets `auth.json.active_provider=openai`, and writes
`mcp_servers.composio`.

Historical credential state observed from Azure before the disabled posture:

- `wrkflo-kv/openai-api-key`: available and installed on the VM.
- `wrkflo-kv/composio-api-key`: available, but Composio MCP rejected it with `401 Unauthorized`.
- `gs-quantum-kv/COMPOSIO-API-KEY`: available, but Composio MCP also rejected it with `401 Unauthorized`.
- `wrkflo/wrkflo-orchestrator/telegram-bot-token`: available as a Container App secret and validated with Telegram `getMe`.
- OpenClaw VM `/opt/global-sentinel/.env`: also has Telegram token/chat fields set; the default token validated as the same bot. OpenClaw has Telegram polling disabled, and the bot had no webhook during validation.
- AgentMail and Orgo keys were not found in the accessible Key Vault inventory during this pass.
- Azure OpenAI keys and deployments exist, but OS1's provider catalog does not currently model Azure OpenAI deployment/API-version semantics, so those were not installed as an OS1 provider.

After any Composio key update, validate it on the VM:

```sh
ssh os1-hermes-dev 'hermes mcp test composio'
```

The command masks the key fragment in output. Treat `401 Unauthorized` as a stale or wrong Composio Connect API key.

After any Telegram token update, validate it without printing the token:

```sh
ssh os1-hermes-dev 'python3 - <<'"'"'PY'"'"'
import json
import pathlib
import urllib.request

env = {}
path = pathlib.Path.home() / ".hermes" / ".env"
for line in path.read_text(errors="ignore").splitlines() if path.exists() else []:
    if line.strip() and not line.strip().startswith("#") and "=" in line:
        key, _, value = line.partition("=")
        env[key.strip()] = value.strip().strip("\"'")

token = env.get("TELEGRAM_BOT_TOKEN")
print("telegram_bot_token=" + ("set" if token else "missing"))
if token:
    result = json.loads(urllib.request.urlopen(f"https://api.telegram.org/bot{token}/getMe", timeout=15).read().decode())
    print("telegram_getMe=" + ("ok" if result.get("ok") else "failed"))
PY'
```

Start or restart the Hermes gateway after syncing Telegram:

```sh
ssh os1-hermes-dev 'hermes gateway install && hermes gateway start'
scripts/azure/os1-vm.sh tools-status
```

Current OS1 VM Telegram state:

- `TELEGRAM_BOT_TOKEN`: installed on `os1-hermes-dev`.
- Telegram `getMe`: validated as the `mo2darkbot` bot.
- `hermes-gateway.service`: installed as a user systemd service, active, and linger-enabled so it survives SSH logout.
- Gateway state: Telegram platform connected.
- `TELEGRAM_ALLOWED_USERS`: not set. Users should pair by DM from OS1/Hermes, or add a numeric allowlist if a locked-down direct allowlist is required.

## Tool And MCP Integration

While Azure is disabled, use `docs/local-oss-runtime.md` instead of the Azure
VM. After `preflight` reports healthy Azure access and the VM is reachable, use
this order:

1. Open OS1 and select `OS1 Hermes Dev`.
2. Verify Overview, Sessions, Files, and Terminal against the SSH host.
3. Add a provider key in the Providers tab, then install it onto the VM.
4. Use Connectors to configure Composio if you want Gmail, Slack, Notion, GitHub, HubSpot, and similar app tools.
5. Use Mail if you want AgentMail MCP support.
6. Use Messaging if you want Telegram gateway support.

Do not paste or log provider, Composio, AgentMail, Telegram, Orgo, or OpenAI keys in shell transcripts. OS1 should write them through Keychain/local UI flows and remote `~/.hermes` config/env files.

Current limitation: Azure uses OS1's SSH transport. Voice-mode computer tools now route through `RealtimeComputerToolBridge`, but Orgo MCP remains the only registered adapter. Azure VM tools are available to Hermes through the VM's Hermes config and connector setup, not through Realtime voice tools.

## OS1 App Verification

After the VM is running and SSH is reachable, add or verify an OS1 SSH connection with:

- SSH alias: `os1-hermes-dev`
- Name: `OS1 Hermes Dev`
- Host/user/port: leave blank if the SSH alias owns them
- Hermes home/profile: default `~/.hermes`

The local SSH config should contain:

```sshconfig
Host os1-hermes-dev
  HostName 20.115.128.223
  User hermes
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

OS1 stores connection profiles in `~/Library/Application Support/OS1/connections.json`. This Mac has been pre-seeded with the `OS1 Hermes Dev` profile pointing at the `os1-hermes-dev` SSH alias.

Then verify these app paths:

1. Overview discovery succeeds.
2. Sessions list loads.
3. Files can read a small file and preserve conflict checks.
4. Terminal opens an interactive SSH shell.
5. Provider key install works without printing keys in logs or screenshots.
