# Azure Parity Plan For OS1

## Goal

Duplicate the OS1 experience as closely as possible on Azure:

- provision/select a cloud computer,
- install Hermes Agent,
- browse sessions/kanban/files/skills/cron,
- edit files safely,
- use an interactive terminal,
- keep credentials local or in managed secret stores,
- keep Realtime voice working.

## Current Azure Inventory Observed

Azure CLI is authenticated to:

- Tenant: `Wrk.Flo` / `wrkflo.biz`
- Subscription: `Azure subscription 1`
- Subscription ID: `7091c86a-9dec-49e9-9e11-f26f96c9db66`

Running VMs found:

- `openclaw-gateway-vm`
  - Resource group: `OPENCLAW-RG`
  - Region: `eastus`
  - Size: `Standard_DC4as_v5`
  - Private IP: `10.0.0.4`
  - Public IP: `20.124.180.8`
- `dev-workspace-vm`
  - Resource group: `DEV-WS-WESTUS2`
  - Region: `westus2`
  - Size: `Standard_D2s_v5`
  - Private IP: `10.0.0.4`
  - Public IP: `20.230.203.79`

I did not create, modify, or delete Azure resources.

## Closest Immediate Match: Azure VM Over SSH

This requires no source changes if an Azure VM is reachable through normal non-interactive SSH from the Mac.

1. Install Hermes Agent on the Azure VM.
2. Make sure `python3` is on the non-interactive SSH PATH.
3. Add an OS1 host using the existing `SSH` transport.
4. Use the existing Sessions, Kanban, Files, Skills, Cron, Usage, and Terminal views.

This gives the main product workflow immediately. It does not duplicate Orgo's inline VM picker/create-computer flow or websocket terminal transport, but it is the lowest-risk path with the current code.

## Exact Orgo Feature Map

| OS1 Orgo behavior | Azure equivalent | Gap |
| --- | --- | --- |
| Save one Orgo API key in macOS Keychain | Save Azure credential/profile metadata in Keychain, preferably use `az login`/DefaultAzureCredential where possible | Need Azure auth implementation in Swift |
| List workspaces/projects and computers | List resource groups and VMs via Azure Resource Manager | Different hierarchy and permissions model |
| Create Linux VM from app | ARM/Bicep/CLI-backed VM creation | Need design for resource group, network, image, size, cloud-init |
| `/bash` command execution | SSH command execution, Azure Run Command, or custom helper API | Azure Run Command is not a low-latency shell and has limits |
| `/exec` Python JSON execution | SSH `python3 -`, Azure Run Command, or custom helper API | Existing SSH path already covers this cleanly |
| Direct terminal websocket | SSH-backed SwiftTerm or custom websocket agent | Azure does not expose native raw terminal websocket per VM |
| Direct VNC websocket | Azure Bastion, VM helper/websockify, or existing VNC service | Native Bastion is not the same as embeddable SwiftTerm/noVNC bytes |
| VNC password bearer to direct VM API | SSH key, managed identity, or helper-issued token | Requires new security model |
| Orgo MCP tools for voice | Azure MCP/CLI bridge or custom MCP server | Needs new tool bridge |

## Recommended Azure Architecture

### Phase 1: Use Existing SSH Transport

Use existing Azure VMs as OS1 hosts:

- `dev-workspace-vm` is a good candidate for a development workspace because its name matches the OS1 use case.
- `openclaw-gateway-vm` looks more production/gateway-like and should be treated carefully unless the user explicitly wants OS1/Hermes on it.

Requirements:

- SSH key-based access from this Mac.
- `python3`, `git`, `curl`, and `bash` installed.
- Hermes Agent installed.
- Optional: a dedicated Linux user such as `hermes` or `os1`.

This should be the first live test because it exercises the app without changing cloud code.

### Phase 2: Add Azure As A First-Class Transport

Files to change:

- `Sources/OS1/Models/ConnectionProfile.swift`
  - Add `AzureConfig`.
  - Add `TransportKind.azure`.
  - Add `.azure(AzureConfig)` to `TransportConfig`.
  - Add Codable migration and validation tests.
- `Sources/OS1/App/AppState.swift`
  - Initialize Azure credential/catalog/transport services.
  - Pass Azure transport into the multiplexer and terminal workspace.
- `Sources/OS1/Services/MultiplexedRemoteTransport.swift`
  - Route `.azure` profiles.
- `Sources/OS1/Services/Terminal/TerminalSession.swift`
  - Select Azure terminal driver or SSH fallback.
- `Sources/OS1/Views/Connections/ConnectionEditorSheet.swift`
  - Add Azure transport picker form: subscription, resource group, VM, username, SSH mode or helper mode.
- `Sources/OS1/Views/Connections/ConnectionsView.swift`
  - Update copy from "SSH profiles" to "hosts/cloud computers".
- `Sources/OS1/Views/Overview/OverviewView.swift`
  - Make host labels transport-aware; current copy still says SSH in some panels.

New folders/classes:

- `Sources/OS1/Services/Azure/AzureCredentialStore.swift`
- `Sources/OS1/Services/Azure/AzureARMClient.swift`
- `Sources/OS1/Services/Azure/AzureCatalogService.swift`
- `Sources/OS1/Services/Azure/AzureTransport.swift`
- `Sources/OS1/Services/Azure/AzureHermesInstaller.swift`
- `Sources/OS1/Services/Azure/AzureTerminalDriver.swift` only if we do more than SSH.

Tests to add:

- `AzureConnectionProfileTests`
- `AzureCatalogServiceTests`
- `AzureTransportTests`
- `AzureHermesInstallerTests`
- `AzureTerminalDriverTests` if helper/websocket mode exists
- Azure live tests gated by `AZURE_LIVE_TESTS=1`

### Phase 3: Decide Terminal Strategy

There are three viable options:

1. SSH terminal only.
   - Lowest risk.
   - Already implemented by `TerminalViewHost`.
   - Requires users to have SSH access.

2. Azure Run Command for background operations, SSH for terminal.
   - Lets app perform some setup through ARM.
   - Still uses SSH for interactive terminal.
   - Good transitional design.

3. Install a small OS1 VM helper.
   - Closest to Orgo.
   - Helper exposes `/bash`, `/exec`, `/terminal`, and optionally `/websockify`.
   - Needs TLS/auth/token rotation, systemd unit, firewall rules, logs, updates, and security review.

For "duplicate exactly", option 3 is the closest, but it contradicts the README claim "no helper service on the VM." That claim is possible on Orgo because Orgo provides the per-VM service. Azure does not provide that same service natively.

## Provisioning Blueprint

Recommended VM defaults to mirror Orgo:

- Image: Ubuntu 22.04 LTS or 24.04 LTS.
- Size: 4 vCPU / 8 GB RAM class, for example `Standard_D4s_v5`, unless cost requires `Standard_D2s_v5`.
- OS disk: 50 GB managed disk minimum.
- Network: dedicated subnet, NSG restricted to trusted IPs, no broad inbound helper ports unless behind TLS/auth.
- Identity: system-assigned managed identity.
- Secrets: Azure Key Vault for cloud-side secrets; macOS Keychain for local user-entered keys.
- Observability: Log Analytics workspace plus Azure Monitor VM Insights.
- Bootstrap: cloud-init installs `python3`, `git`, `curl`, `build-essential`, `nodejs` if MCP/voice tools need it, and Hermes Agent.

Possible starter command, after target values are confirmed:

```sh
az vm create \
  --resource-group DEV-WS-WESTUS2 \
  --name os1-hermes-dev \
  --image Ubuntu2204 \
  --size Standard_D4s_v5 \
  --admin-username hermes \
  --ssh-key-values ~/.ssh/id_ed25519.pub \
  --os-disk-size-gb 50 \
  --public-ip-sku Standard
```

Do not run this until the resource group, region, VM name, size, networking, and cost expectations are confirmed.

## Swift Implementation Sketch

Immediate SSH-backed Azure profile:

- Store Azure metadata in `AzureConfig`, but execute through the existing SSH transport.
- Use Azure catalog only to list/select VMs and prefill public/private IP.
- Keep terminal behavior identical to SSH.

Later helper-backed Azure profile:

- `AzureCatalogService` lists resource groups/VMs and creates VMs.
- `AzureHermesInstaller` runs through SSH or Run Command.
- `AzureTransport` implements `RemoteTransport`.
- `AzureTerminalDriver` streams websocket frames if a helper is installed.

## Open Questions Before Provisioning

- Which Azure resource group should own the OS1 VM: `dev-ws-westus2`, `wrkflo`, `wrkflo-rg`, or a new resource group?
- Should we reuse `dev-workspace-vm` or create a fresh `os1-hermes-*` VM?
- Is inbound SSH from this Mac already allowed?
- What SSH username/key should OS1 use?
- Should this be dev-only or production-style with Key Vault, managed identity, Log Analytics, and tighter NSG rules?
- Should the app remain branded `OS1`, or should bundle ID/name be changed for the new repo?

## Practical Next Step

Use `dev-workspace-vm` as the first smoke target if SSH access is available. Install Hermes Agent, add it as an SSH host in OS1, and verify:

- Overview discovery,
- Sessions list,
- file browser read/write conflict check,
- terminal interactivity,
- provider key install,
- voice mode without Orgo MCP tools.

Only after that should we add first-class Azure transport code.
