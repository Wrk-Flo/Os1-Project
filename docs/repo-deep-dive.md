# Hermes Desktop OS1 Repo Deep Dive

Snapshot audited: `nickvasilescu/hermes-desktop-os1` at `bea7d24aa03c1834b80390345c8875eaf9ae6502`.

This local project was populated from that snapshot. The imported source tree matched the upstream checkout byte-for-byte before these `docs/` notes were added.

## Executive Summary

OS1 is a native SwiftUI macOS 14+ app packaged with Swift Package Manager. It presents one workspace for a Hermes Agent running either behind SSH or on an Orgo cloud computer. The app is not Electron and does not have a backend service of its own; it reaches the selected host directly from the Mac app.

The core architecture is:

- SwiftUI app shell and state graph in `Sources/OS1/App`.
- Domain models in `Sources/OS1/Models`.
- Host operations in `Sources/OS1/Services`.
- UI screens in `Sources/OS1/Views`.
- A vendored terminal emulator in `Vendor/SwiftTerm`.
- macOS packaging scripts and Info.plist under `scripts/` and `packaging/`.

The cloud-computer implementation is currently Orgo-specific. The transport boundary is clean enough to add Azure, but Azure cannot exactly duplicate Orgo's "direct per-VM terminal websocket and HTTP `/bash`/`/exec` API with no VM helper" unless we install our own helper on the VM or use SSH. Azure's native VM APIs provide provisioning, run-command, identity, logging, disks, and networking, but not a raw interactive terminal websocket equivalent.

## Root Files

- `Package.swift`: SwiftPM package named `OS1`, one executable target `OS1`, one test target, macOS 14 minimum, and a local dependency on `Vendor/SwiftTerm`.
- `README.md`: product overview, Orgo setup, SSH fallback, build/test commands, Realtime voice instructions, routing behavior, and live Orgo test flags.
- `LICENSE`: MIT license.
- `SECURITY.md`: private disclosure expectations.
- `CONTRIBUTING.md`: contribution guidance.
- `RELEASE.md`: release checklist: tests, secret scan, docs check, package build, checksum, signing/notarization, tag, release assets.
- `THIRD_PARTY_NOTICES.md`: upstream and dependency notices.
- `.gitignore`: excludes SwiftPM build products, app bundles, local state, and generated artifacts.

## `.github`

- `.github/workflows/ci.yml`: macOS 15 CI; checks Swift version, installs Python/PyYAML for script-generated Python tests, runs `swift test`, then builds an arm64 app bundle.
- `.github/workflows/deploy-pages.yml`: manual GitHub Pages deployment for the static `site/index.html`.
- `.github/ISSUE_TEMPLATE`: bug and feature templates with connection/security prompts and disabled blank issues.

## `Sources/OS1/App`

- `OS1App.swift`: app entry point, registers DM Sans fonts, mounts `BootGate -> RootView`, sets hidden title bar, dark color scheme, minimum window size, and routes `os1://oauth/...` callbacks.
- `AppState.swift`: central main-actor state container. It owns connection state, every screen's loading/error state, services, VM installers, provider stores, Composio, AgentMail, Telegram, terminal workspace, and realtime voice status.
- `HermesApplicationDelegate.swift`: macOS app delegate integration.
- `OS1Commands.swift`: app command/menu wiring.

`AppState` is the composition root. If we add Azure as a first-class transport, this is where `AzureCredentialStore`, `AzureCatalogService`, `AzureTransport`, and any Azure installer/terminal service would be initialized and passed into downstream stores.

## `Sources/OS1/Models`

The models folder is mostly Codable/Equatable data structures used by services and views:

- `ConnectionProfile.swift`: transport model. Currently supports `.ssh(SSHConfig)` and `.orgo(OrgoConfig)`, with backward-compatible decoding from legacy SSH-only profiles.
- `AppSection.swift`: navigation sections and symbols.
- `RemoteDiscovery.swift`: shape returned by remote Hermes discovery: profiles, paths, session store, kanban state.
- `SessionModels.swift`, `HermesChatModels.swift`: sessions, transcript metadata, chat invocation state.
- `KanbanModels.swift`, `CronJobModels.swift`, `SkillModels.swift`, `WorkspaceFileModels.swift`, `RemoteTrackedFile.swift`: feature-specific remote data.
- `ProviderCatalog.swift`: built-in LLM provider catalog and model list normalization. Current providers include Anthropic, OpenRouter, OpenAI, Fireworks, Kimi, and Z.AI.
- `ComposioModels.swift`, `TelegramModels.swift`, `OrgoCatalogModels.swift`, `AgentMail`-adjacent models: connector/provider support surfaces.
- `TerminalTheme.swift`, `TerminalTabModel.swift`, `TerminalWorkspaceContext.swift`: terminal presentation and workspace state.

Azure parity requires extending `TransportKind`, `TransportConfig`, `ConnectionProfile` accessors, validation, display text, tests, and Codable migration behavior.

## `Sources/OS1/Resources`

- `Boot/`: boot animation HTML/CSS/JS, Three.js bundle, infinity loader, startup audio.
- `Fonts/`: bundled DM Sans TTFs registered by `OS1FontRegistry`.
- `en.lproj`, `zh-Hans.lproj`, `ru.lproj`: localization scaffolding.
- `vnc.html`: browser-side VNC surface for the desktop screen feature.

The app packages resources through SwiftPM and then copies localization bundles into the `.app` in `scripts/build-macos-app.sh`.

## `Sources/OS1/Services`

Services are the real system boundary.

- `RemoteTransport.swift`: protocol for executing remote shell commands and JSON-returning Python scripts.
- `MultiplexedRemoteTransport.swift`: routes each call to SSH or Orgo based on `ConnectionProfile.transport`.
- `RemoteHermesService.swift`: runs remote Python discovery against `~/.hermes`, profiles, files, sessions, cron, and kanban.
- `SessionBrowserService.swift`: reads sessions from SQLite or JSONL artifacts, supports search, transcript load, and deletion.
- `HermesChatService.swift`: sends messages into Hermes sessions.
- `FileEditorService.swift`: reads, lists, and writes remote files with UTF-8 checks, size limits, and conflict hashes.
- `KanbanBrowserService.swift`: reads and mutates Hermes kanban tasks.
- `CronBrowserService.swift`, `SkillBrowserService.swift`, `UsageBrowserService.swift`, `KnowledgeBaseService.swift`: feature-specific Hermes workspace operations.
- `HermesUpdater.swift`: update/install-adjacent host operations.

### `Services/Orgo`

- `OrgoCredentialStore.swift`: Keychain storage for the global Orgo API key.
- `OrgoHTTPClient.swift`: authenticated HTTP wrapper over `https://www.orgo.ai/api`.
- `OrgoCatalogService.swift`: lists Orgo projects/workspaces and creates computers with defaults: Linux, 8 GB RAM, 4 CPU, 50 GB disk, `1280x720x24`.
- `OrgoTransport.swift`: implements `RemoteTransport`.
  - `/bash` commands are wrapped with a nonce sentinel because Orgo's response success/exit-code behavior is not enough.
  - `/exec` runs Python and decodes JSON.
  - platform proxy is tried first for normal calls.
  - direct VM fallback uses `https://<fly_instance_id>.orgo.dev/...` and VNC password bearer auth.
  - terminal endpoint is `wss://<fly_instance_id>.orgo.dev/terminal?token=...`.
  - VNC endpoint is `wss://<fly_instance_id>.orgo.dev/websockify?token=...`.
- `OrgoHermesInstaller.swift`: long-running official Hermes installer path, with clock drift, apt lock, and missing git handling.

### `Services/SSH`

- `SSHTransport.swift`: runs `/usr/bin/ssh` in batch mode, with ControlMaster for service calls and isolated sessions for interactive terminal shells. Remote JSON calls are Python scripts piped to `python3 -`.

SSH is the fastest Azure route because it already works with any Azure VM reachable from the Mac.

### `Services/Terminal`

- `TerminalSession.swift`: chooses `TerminalViewHost` for SSH or `OrgoTerminalDriver` for Orgo.
- `OrgoTerminalDriver.swift`: resolves Orgo websocket endpoint, mounts SwiftTerm, streams input/resize/ping messages, parses output frames, and feeds bytes to the terminal view.
- `TerminalViewHost.swift`, `TerminalDriver.swift`, `TerminalWorkspaceStore.swift`: terminal driver abstraction, tab/session management, and AppKit host view.

Azure needs either an SSH terminal path using the existing driver or a new websocket driver backed by a VM helper/gateway.

### `Services/Realtime`

- `RealtimeVoiceSessionServer.swift`: local loopback HTTP server. The hidden web view posts SDP to `/session`; Swift forwards multipart SDP/session config to OpenAI Realtime calls. It also exposes `/tools` and `/tool` for Orgo MCP-backed realtime function tools.
- `RealtimeOrgoMCPBridge.swift`: starts `npx -y @orgo-ai/mcp` or a configured JS path, lists MCP tools, and forwards tool calls. Defaults expose `core,screen,files`, disable upload, and keep shell/admin opt-in.
- `RealtimeCallsMultipartRequest.swift`: multipart body builder.

Azure parity can keep OpenAI Realtime unchanged, but Orgo MCP tools need an Azure-specific MCP bridge or a generic provider abstraction.

### Other Service Subfolders

- `Services/Providers`: provider API key validation, OpenRouter OAuth, provider credential Keychain storage, and remote VM config injection into Hermes `.env` and `config.yaml`.
- `Services/Composio`: Composio API key storage, MCP client, VM installer, toolkit service, identity support.
- `Services/AgentMail`: AgentMail credentials/account store, VM scanning, realtime service.
- `Services/Telegram`: bot token storage and VM installer.
- `Services/Doctor`: health snapshot support.
- `Services/Storage`: application paths and JSON persistence for connections, preferences, bookmarks, and pinned sessions.

## `Sources/OS1/Theme`

- `OS1Tokens.swift`, `OS1Theme.swift`, `OS1Controls.swift`, `OS1FontRegistry.swift`.

This defines the coral/cream theme, typography, custom buttons/panels, and font loading. Most views rely on these primitives instead of raw SwiftUI styling.

## `Sources/OS1/Utilities`

- `DateFormatters.swift`: shared date display.
- `Localization.swift`: string lookup convenience.
- `RemotePythonScript.swift`: wraps payloads and common Python helpers for remote execution.

`RemotePythonScript` is important because most service calls serialize Swift input to Python payloads, run them remotely, and decode JSON back into Swift models.

## `Sources/OS1/Views`

Top-level UI is `RootView.swift`. Each feature is split by folder:

- `Boot`: boot animation gate.
- `Connections`: host list and connection editor. This is where Azure transport UI would be added.
- `Overview`: remote Hermes discovery dashboard and install/update banners.
- `Sessions`: session browser and detail chat/transcript view.
- `Kanban`: Hermes kanban board and task workflows.
- `Files`: remote file browser/editor.
- `Skills`: skills viewer/detail.
- `CronJobs`: cron job manager.
- `Terminal`: tabbed terminal workspace using SwiftTerm.
- `Desktop`: VNC/desktop view.
- `Providers`: provider connection, validation, and install UI.
- `Connectors`: Composio connector UI.
- `Mail`: AgentMail setup/inbox/compose.
- `Messaging`: Telegram setup and messaging UI.
- `Doctor`: health/diagnostic view.
- `Usage`: usage dashboard.
- `Shared`: reusable Hermes/OS1 UI pieces.
- `Realtime`: hidden runtime voice view.

## `Tests/OS1Tests`

There are 22 test files. Coverage focuses on models, transport routing, generated Python scripts, provider handling, credential store behavior, localization coverage, and Realtime request building. `OrgoTransportLiveTests.swift` is skipped unless `ORGO_LIVE_TESTS=1`, `ORGO_API_KEY`, and `ORGO_DEFAULT_COMPUTER_ID` are present.

Important test surfaces for an Azure implementation:

- `ConnectionProfileTransportTests.swift`
- `MultiplexedRemoteTransportTests.swift`
- `OrgoTransportLiveTests.swift` equivalent for Azure live tests
- `ProviderVMInstallerTests.swift`
- `RemotePythonScriptTests.swift`
- `TerminalThemeTests.swift`
- localization coverage tests after adding Azure UI strings

## `Vendor/SwiftTerm`

Vendored SwiftTerm source provides the macOS terminal widget, parser, rendering, search, selection, GPU support, and local process/PTY abstractions. OS1 imports it as a local SwiftPM package from `Vendor/SwiftTerm`.

## `scripts`

- `run-tests.sh`: custom SwiftPM test runner with local cache/config/security paths and SDK/framework selection.
- `build-macos-app.sh`: universal build script. Builds arm64 and x86_64 unless `HERMES_MAC_ARCHS` is set, creates `.app`, generates icon, copies SwiftPM resources/localizations, strips binary, and ad-hoc signs with stable designated requirement unless a signing identity is configured.
- `package-github-release.sh`: builds, zips `dist/OS1.app`, and writes SHA256.
- `generate-app-icon.swift`, `build-icns.swift`, `build-app-icon.py`: icon generation/build helpers.

## `packaging`

- `Info.plist`: bundle metadata, `com.elementsoftware.os1`, macOS 14 minimum, microphone usage description, local networking allowance, and `os1://oauth` URL scheme.
- `OS1.icns`: app icon.

## `assets`

Static screenshots used by the README/site: sessions, kanban, files, terminal, usage.

## `site`

Single static marketing/docs page for GitHub Pages. It is manually deployed by `.github/workflows/deploy-pages.yml`.

## Build Verification Notes

Local verification hit a toolchain issue before app code compiled:

```text
error: Invalid manifest
Undefined symbols for architecture arm64:
  PackageDescription.Package.__allocating_init(...)
```

The same failure occurred in the clean upstream clone with `swift package dump-package`, so the imported project is not the cause. The machine currently has only Command Line Tools selected at `/Library/Developer/CommandLineTools`; no full `/Applications/Xcode*.app` installation was found. CI expects macOS 15 with a full toolchain. Installing/selecting a matching Xcode should be the next verification step before treating test/build status as meaningful.
