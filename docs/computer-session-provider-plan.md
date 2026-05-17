# Computer Session Provider Plan

## Decision

OS1 should keep Azure as the cloud backbone and add Cua as an optional
computer-session provider. Cua is not a replacement for Azure, Orgo, or SSH.
It is the disposable visual-computer layer for tasks where an agent must see,
click, type, and visually verify work inside a real desktop or browser.

Orgo is optional in this architecture. The no-Orgo route is the existing SSH
transport against an Azure VM for normal OS1 host workflows, with Cua planned as
an optional governed computer-session provider when visual desktop control is
needed.

Orgo-specific UI and tool surfaces should be capability-gated. A saved Orgo API
key alone must not enable Desktop/noVNC, managed install prompts, or Realtime
computer tools for an SSH-backed Azure/direct-host profile. Those surfaces turn
on only when the active connection advertises the matching capability, which is
currently true for Orgo VM profiles.

```text
Azure = cloud backbone, VM boundary, secrets, model routing, logs, operations
SSH = current Azure VM and direct-host execution path
Orgo = current first-class cloud-computer provider
Cua = proposed open-source disposable computer-session provider
E2B = proposed secure Linux/code/data sandbox provider
Playwright = deterministic browser automation provider
Composio + MCP = SaaS connector layer
```

The governing rule is:

```text
Use APIs first.
Use deterministic browser automation second.
Use full computer-use desktops last.
```

## How This Fits OS1

OS1 currently has two host transports:

- `SSH`: reaches existing hosts, including the dedicated Azure VM
  `os1-hermes-dev`.
- `Orgo VM`: reaches Orgo computers through the Orgo API, per-VM HTTP
  endpoints, terminal websocket, and VNC websocket.

Cua should enter as a third provider family, but not by copying Orgo
conditionals across the app. The first implementation step is a provider-neutral
Computer Session contract that describes:

- requested task,
- risk level,
- session type,
- provider preference,
- approval requirement,
- time budget,
- recording/audit requirement,
- allowed and blocked domains,
- credential policy,
- expected output artifacts.

Once that contract is stable, the Desktop and Realtime surfaces can ask for
provider capabilities instead of checking only `case .orgo`.

## Execution Router Policy

Computer sessions are a high-risk execution lane because they can expose
private data, authenticated browser state, credentials, or destructive UI
controls. OS1 should classify them as approval-gated by default.

Recommended routing:

```text
1. Direct API or Composio/MCP
2. Deterministic browser automation with Playwright
3. Code/data sandbox with Azure Container Apps Jobs or E2B
4. Visual computer session with Cua, E2B Desktop, Orgo, or Azure helper
```

## Provider Responsibilities

### Cua

Use Cua for full desktop/browser workflows:

- agent-controlled desktop sessions,
- visual browsing,
- UI workflows without stable APIs,
- screenshots and replay,
- multi-app GUI workflows,
- Claude/OpenAI computer-use loops.

Reference repo: `trycua/cua`.

Cua should not be modeled as an Orgo-style host transport. The repo splits
capabilities across multiple surfaces: sandbox SDK, background macOS driver,
CuaBot/agent examples, MCP/server integration, and benchmarks. OS1 should pick
the specific Cua surface per capability instead of assuming a single
websocket/VNC/API shape.

### E2B

Use E2B-style sandboxes when the task is mostly:

- code execution,
- data processing,
- file conversion,
- document generation,
- safe untrusted scripts,
- Linux browser automation.

### Azure

Use Azure for the control plane and normal infrastructure:

- existing OS1 Azure VM via SSH,
- Azure Container Apps Jobs for finite batch work,
- Azure Key Vault for secrets,
- Azure Blob Storage for artifacts,
- Application Insights / Log Analytics for observability,
- Azure OpenAI / Foundry for model routing.

Azure should become a first-class OS1 provider only after the product decision
is made between SSH-only, Azure Run Command plus SSH, or a hardened OS1 VM
helper exposing `/bash`, `/exec`, `/terminal`, and optional VNC/websockify.

### Orgo

Keep Orgo working as the existing cloud-computer provider. The Orgo path is
already deeper than a generic transport: it owns catalog, create-computer,
Hermes install, direct VM fallback, terminal websocket, VNC endpoint, and the
Realtime MCP bridge.

## Guardrails

Hard defaults:

- `requiresApproval = true`
- `recordSession = true`
- `maxMinutes = 10`
- deny by default for destructive, financial, legal, permission-changing, or
  bulk actions
- no credential injection without an explicit credential policy
- no raw credentials, cookies, authorization headers, or tokens in logs
- cleanup must run after success, failure, cancellation, or budget exhaustion

Lower-risk exceptions are allowed only for synthetic no-credential demos, local
offline prototypes, or screenshot-only observation of a sandbox that has no
authenticated state.

## Minimal OS1 Slice

1. Add typed Computer Session models.
2. Add tests for approval defaults, provider selection, and JSON compatibility.
3. Add a dormant Cua provider service shell.
4. Refactor Desktop availability from `is Orgo` to `has visual desktop
   capability`.
5. Wire Cua only after auth, session lifecycle, streaming, recording, and
   cleanup behavior are explicit.

Current implementation status:

- Computer Session request/response/status models exist under
  `Sources/OS1/Models/ComputerSessionModels.swift`.
- `ComputerSessionService` resolves configured providers, fails fast when a
  selected provider is unavailable, and returns approval records before any
  provider start for governed sessions.
- `ComputerSessionService` keeps in-memory approval records and exposes
  `approve` / `deny` methods so a stored normalized request can be resumed or
  rejected without starting a provider before approval.
- Cua is registered in `AppState` only as a disabled provider shell with a
  dedicated Keychain store. It is not a host transport and is not shown in the
  Host editor.
- Desktop availability now reads `ConnectionProfile.capabilities` instead of
  directly checking for Orgo. Orgo is still the only current profile with visual
  desktop capability.
- Desktop endpoint resolution now goes through `DesktopEndpointResolving`.
  The first adapter is Orgo-backed and still returns a noVNC/websockify shape;
  this is prerequisite plumbing, not live Cua desktop support.
- Terminal driver selection now goes through `TerminalDriverFactory`, with the
  existing SSH and Orgo drivers unchanged. This does not make Cua a host
  terminal provider and does not add `.cua` to `TransportKind`.
- Realtime computer tools now go through `RealtimeComputerToolBridge`. Orgo MCP
  is the only registered adapter, preserving `orgo_` tool names and existing
  Orgo environment variables. Cua realtime tools remain unregistered until Cua
  auth, session lifecycle, streaming, recording, and cleanup are explicit.
  Orgo realtime tools are disabled unless the active connection supports
  realtime computer tools and has an Orgo computer ID.
- A no-Orgo SSH/Azure profile keeps Orgo-only visual and Realtime surfaces
  hidden even when Orgo credentials exist in Keychain or `ORGO_API_KEY`.

The first usable prototype should be non-destructive:

```text
User requests public-site research.
OS1 creates a Computer Session request.
Policy classifies it as approval-gated.
After approval, Cua starts a browser/desktop session.
Artifacts and screenshots are saved under Azure-backed storage.
Session is stopped and the audit summary returns to OS1.
```
