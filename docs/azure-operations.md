# Azure Operations

This runbook covers the standalone OS1 Azure VM used through the existing SSH transport. It does not create app source changes or install a new VM helper service.

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

Show VM state and the SSH allowlist source:

```sh
scripts/azure/os1-vm.sh status
```

Refresh the SSH NSG rule to this Mac's current public IP:

```sh
scripts/azure/os1-vm.sh refresh-ssh-allowlist
```

Use an explicit CIDR instead of public IP discovery:

```sh
OS1_AZURE_OPERATOR_CIDR=203.0.113.10/32 scripts/azure/os1-vm.sh refresh-ssh-allowlist
```

Preview an allowlist mutation without changing Azure:

```sh
OS1_AZURE_DRY_RUN=1 scripts/azure/os1-vm.sh refresh-ssh-allowlist
```

Start, restart, stop, or deallocate the standalone VM:

```sh
scripts/azure/os1-vm.sh start
scripts/azure/os1-vm.sh restart
scripts/azure/os1-vm.sh stop
scripts/azure/os1-vm.sh deallocate
```

Use `deallocate` when the machine should stop incurring VM compute charges. Use `stop` only when the VM must remain allocated.

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

## Tool And MCP Integration

You can start testing OS1 against the Azure VM now. Use this order:

1. Open OS1 and select `OS1 Hermes Dev`.
2. Verify Overview, Sessions, Files, and Terminal against the SSH host.
3. Add a provider key in the Providers tab, then install it onto the VM.
4. Use Connectors to configure Composio if you want Gmail, Slack, Notion, GitHub, HubSpot, and similar app tools.
5. Use Mail if you want AgentMail MCP support.
6. Use Messaging if you want Telegram gateway support.

Do not paste or log provider, Composio, AgentMail, Telegram, Orgo, or OpenAI keys in shell transcripts. OS1 should write them through Keychain/local UI flows and remote `~/.hermes` config/env files.

Current limitation: Azure uses OS1's SSH transport. The voice-mode Orgo MCP bridge remains Orgo-specific in this codebase, so Azure VM tools are available to Hermes through the VM's Hermes config and connector setup, not through the Orgo Realtime voice bridge.

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
