# Hermes Desktop - OS1 Edition

> **OS1 by Element Software** · SSH-first Hermes workspace · optional Orgo support · forked from Hermes Desktop

A native macOS interface for a Hermes Agent running on a host you control.
Inspired by *Her* (2013): warm coral on cream, thin type, calm motion.

Connect over SSH, point OS1 at the agent, and stay in one focused
workspace: sessions, kanban, files, skills, cron jobs, and a real
terminal. Azure VMs work through the same SSH path. Orgo remains an
optional managed cloud-computer provider if you already have it.

## What you get

- **SSH-first workspace access** for hosts you already control:
  another Mac, a Raspberry Pi, a VPS, or an Azure VM when Azure is available.
- **Local open-source model path** with Ollama or llama.cpp exposed as
  OpenAI-compatible Hermes providers. This is the default fallback when
  Azure/Key Vault services are unavailable.
- **Real interactive shell** for the active host. SSH uses the native
  local terminal path; Orgo uses its optional websocket terminal path.
- **Optional Orgo managed computers**: if you have an Orgo account, OS1
  can still list workspaces/computers, create VMs, install Hermes, and
  open Desktop/noVNC surfaces.
- **Provider-neutral Computer Session planning** for future Cua and
  sandbox providers without requiring Orgo.
- **Everything else** from the foundation: native Sessions browser
  with full-text search, Kanban board, file editor with conflict
  checks, skills viewer, cron job manager, profile-aware paths,
  English / Simplified Chinese / Russian localization scaffolding.

## Requirements

- macOS 14 or newer (Apple Silicon or Intel — universal build)
- One of:
  - A host you already reach with `ssh` from this Mac without
    interactive prompts, including this Mac, another local machine, a VPS,
    or an Azure VM when Azure is available, OR
  - An optional **Orgo account** with an API key if you want Orgo's
    managed cloud-computer flow.
- For the no-cloud model path: Ollama on `127.0.0.1:11434`,
  llama.cpp on `127.0.0.1:8080`, or LM Studio on `127.0.0.1:1234`
  with an OpenAI-compatible `/v1` endpoint.

For SSH connections, the host needs `python3` on the non-interactive SSH
PATH and Hermes already installed. For Orgo connections, the app handles
VM provisioning, agent installation, and the websocket terminal.

You do not need an Orgo account to use OS1 with Azure or another
SSH-reachable host. The Azure runbook in
[`docs/azure-operations.md`](docs/azure-operations.md) is the current
no-Orgo operating path. Cua planning is separate: it is for optional,
approval-gated computer sessions, not a requirement for SSH usage.

Orgo-specific capabilities stay inactive unless the active connection is
an Orgo VM with a computer selected. SSH profiles do not show Desktop/noVNC
or Realtime computer-control tools, even if an Orgo API key is saved for
another profile.

Planning for the provider-neutral Computer Session lane lives in
[`docs/computer-session-provider-plan.md`](docs/computer-session-provider-plan.md).
It now includes disabled experimental Cua plumbing for approval-gated one-shot
computer sessions. Cua is not a host transport, live desktop provider, or
Realtime adapter yet, and it does not change the current Orgo and SSH setup
flow.

## Install

Public distribution is blocked until Developer ID signing and notarization
are configured. For now, build locally with `./scripts/build-macos-app.sh`;
the local artifact at `dist/OS1.app` is universal and ad-hoc signed.
On first launch macOS may say it can't verify the developer — right-click
the app, choose Open, and confirm.

## Setup

### Local OSS Models

Use this path while Azure services and Key Vault are unavailable.

1. Start a local provider:

   ```sh
   ollama serve
   ollama pull qwen2.5-coder:3b
   ```

   Or run llama.cpp server on `127.0.0.1:8080` or LM Studio on
   `127.0.0.1:1234`, each with an OpenAI-compatible `/v1` endpoint.

2. Configure the local Hermes profile on this Mac:

   ```sh
   scripts/configure-local-oss-models.sh ollama
   # or:
   scripts/configure-local-oss-models.sh llama-cpp
   # or:
   scripts/configure-local-oss-models.sh lm-studio
   ```

3. In OS1, open **Providers** and enable **Ollama Local**,
   **llama.cpp Local**, or **LM Studio Local**. These providers do not
   require API keys. Hermes Agent itself is installed separately; OS1 and
   the helper only configure the selected provider. For CUA/Computer Use
   on that agent, run `hermes computer-use install` in the Hermes
   environment.

The script writes only local Hermes config files under `~/.hermes`, backs up
existing files under `~/.hermes/backups`, and reports status without printing
secrets. See [`docs/local-oss-runtime.md`](docs/local-oss-runtime.md) for the
full Azure-disabled local runtime runbook.

For longer local business-operation sessions, use
[`docs/local-ops-24-7.md`](docs/local-ops-24-7.md). It covers per-user
LaunchAgents for Ollama and OS1 health checks, local logs, restart commands,
health-only monitoring when Ollama is already managed by `Ollama.app`, and the
remaining blockers before public production distribution. For limited disk
environments, use [`docs/local-storage.md`](docs/local-storage.md) and the
storage helpers:

```sh
scripts/os1-storage-report.sh
scripts/os1-clean-storage.sh --all
```

### SSH or Azure VM

1. Open the **Connections** tab → click **Add Host**
2. Keep the transport picker on **SSH**
3. Enter an SSH alias or host, plus optional user/port and Hermes profile.
4. Save → the connection is selectable from the host list.

For the no-Orgo Azure path, use the SSH profile from
[`docs/azure-operations.md`](docs/azure-operations.md) once the VM is
running and reachable from this Mac. If Azure is disabled, keep this path
parked and use the local OSS model path above.

### Orgo VM (optional)

Use this only if you already have or want an Orgo account.
New Orgo profiles are hidden by default in public builds. To create one
during development or for an Orgo-enabled run, launch OS1 with
`OS1_ENABLE_ORGO=1`. Existing saved Orgo profiles remain visible and
editable without the flag.
The Orgo setup path enables managed VM provisioning, Desktop/noVNC, the
managed Hermes installer, and Orgo-backed Realtime computer tools for that
connection. It is not required for SSH or Azure VM usage.

1. Open the **Connections** tab → click **Add Host**
2. Switch the transport picker to **Orgo VM**
3. Paste your API key → click **Verify & Save**. The key persists in
   the macOS Keychain; subsequent connections reuse it.
4. Pick a workspace from the dropdown.
5. Pick a computer, or click **Create new computer…** to spin one up
   inline (defaults: Linux, 8 GB RAM, 4 CPU, 50 GB disk).
6. Save → the connection is selectable from the host list.
7. If the agent isn't installed on the VM, the **Overview** screen
   shows an install banner. One click runs the official Hermes
   Agent installer. You can use the rest of the app while it runs.

## Build from source

```sh
./scripts/build-macos-app.sh
```

The bundle lands at `dist/OS1.app`.

```sh
swift test
```

## Realtime voice mode

OS1 includes a minimal WebRTC voice mode using OpenAI Realtime calls
with `gpt-realtime-2`. The app starts a loopback session endpoint when
the boot animation finishes. The bottom-left **Voice** row toggles the
live voice connection on or off; there is no separate voice control
panel.

The browser surface in the app sends raw SDP to `POST /session`. The
Swift endpoint keeps `OPENAI_API_KEY` server-side, forwards the SDP to
`https://api.openai.com/v1/realtime/calls`, and uses multipart
`FormData` fields named `sdp` and `session`.

Use the **Providers** tab to save an OpenAI key in the macOS Keychain.
For local development, `OPENAI_API_KEY` is also supported as a fallback.

Run from source with an environment fallback:

```sh
OPENAI_API_KEY="sk-..." swift run OS1
```

Enable new Orgo profile creation only for Orgo-enabled runs:

```sh
OS1_ENABLE_ORGO=1 swift run OS1
```

Run the packaged app from a shell with an environment fallback:

```sh
./scripts/build-macos-app.sh
OPENAI_API_KEY="sk-..." ./dist/OS1.app/Contents/MacOS/OS1
```

The packaging script signs ad-hoc with an explicit designated
requirement for `com.elementsoftware.os1`, which gives macOS a stable
local app identity so privacy grants such as microphone access can
survive rebuilds. For a stronger certificate-backed identity, set
`OS1_CODESIGN_IDENTITY` / `HERMES_CODESIGN_IDENTITY`, or set
`OS1_AUTO_CODESIGN=1` to prefer the first available `Developer ID
Application` identity and fall back to `Apple Development`.

Public distribution remains blocked until Developer ID signing and
notarization are configured. To produce a public-ready archive, opt into
notarization after configuring Apple notary credentials in Keychain or an
App Store Connect API key:

```sh
OS1_CODESIGN_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
OS1_NOTARIZE=1 \
OS1_NOTARY_KEYCHAIN_PROFILE=os1-notary \
./scripts/package-github-release.sh
```

The notarization path requires a Developer ID Application signature,
submits `dist/OS1.app.zip`, staples the ticket to `dist/OS1.app`, then
recreates the final zip and checksum.

After the boot animation completes, the hidden WebRTC view requests
microphone access, opens the `oai-events` data channel, registers a sample
`check_calendar(date, time)` function with `session.update`, and asks
the model to greet with `hello, can you hear me?`.

The same voice session exposes computer-control tools through a
provider-neutral Realtime tool bridge. Orgo MCP is the first registered
adapter: OS1 starts the MCP server locally, reads tools with
`tools/list`, registers them with `session.update`, and forwards model
tool calls back to `tools/call`; Orgo credentials stay in the Swift app
and are never sent to the browser or model. By default the Orgo adapter
exposes `core,screen,files`, disables file upload, uses the saved Orgo
API key in OS1 or `ORGO_API_KEY` if no key is saved, and passes the
active Orgo connection's computer ID as `ORGO_DEFAULT_COMPUTER_ID`.
Cua realtime tools are not exposed yet.

Voice mode runs `npx -y @orgo-ai/mcp` by default. You can override the
bridge with:

```sh
OS1_ORGO_MCP_JS_PATH="/absolute/path/to/dist/index.js"
OS1_ORGO_MCP_PACKAGE="@orgo-ai/mcp"
OS1_REALTIME_ORGO_TOOLSETS="core,screen,files"
OS1_REALTIME_ORGO_DISABLED_TOOLS="orgo_upload_file"
OS1_REALTIME_ORGO_READ_ONLY="true"
```

`shell` and `admin` are opt-in through `OS1_REALTIME_ORGO_TOOLSETS`.
Only enable them for agents and computers you are comfortable letting a
voice model operate.

Live integration tests (skipped by default) hit a real cloud computer:

```sh
ORGO_LIVE_TESTS=1 \
ORGO_API_KEY="sk_live_..." \
ORGO_DEFAULT_COMPUTER_ID="<uuid>" \
swift test --filter OrgoTransportLiveTests
```

## How it routes

For cloud connections:

1. **HTTP ops** (`/bash`, `/exec`) try the platform proxy at
   `https://www.orgo.ai/api/computers/{id}/...` first. On a 5xx
   that looks like a routing failure (ECONNREFUSED, gateway timeout,
   stale port), the transport falls back to the direct VM URL
   `https://<fly_instance_id>.orgo.dev/...` with the VNC password as
   bearer. Long-running ops (e.g. the agent installer) skip the
   proxy entirely since its 30s request timeout would always trip
   first.
2. **Terminal** opens a websocket directly to
   `wss://<fly_instance_id>.orgo.dev/terminal?token=<vncPassword>`,
   feeding bytes into SwiftTerm.

VM clock drift, missing system git, stale apt locks from earlier
attempts — all handled in the install path so you don't have to wrestle
with the VM by hand.

## Acknowledgements

OS1 builds on two layers of generous prior work:

- The original native macOS application code is forked from
  [dodo-reach/hermes-desktop](https://github.com/dodo-reach/hermes-desktop),
  the SSH-first companion for the Hermes Agent. The conventions, panels,
  discovery model, and most of the SSH-side code are that author's
  design.
- The cloud-computer transport, websocket terminal, agent auto-install,
  and connection picker were added on top to make OS1 work directly
  with Orgo VMs.

The visual design language (coral on cream, DM Sans, OS¹ wordmark) is
the **Element Software** product theme — see [`OS-1`](https://github.com/nickvasilescu/OS-1)
for the canonical palette and motion vocabulary that this app borrows.

License: [MIT](LICENSE). All upstream copyrights are preserved.

## Status

This is an early build. Translation polish, GitHub Pages site, and
Developer ID credential setup are still in progress. Open issues in this
repo for bugs and feature requests.
