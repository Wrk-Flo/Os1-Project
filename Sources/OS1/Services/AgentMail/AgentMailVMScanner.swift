import Foundation

struct AgentMailVMScanResult: Decodable, Equatable, Sendable {
    let success: Bool
    let errors: [String]
    let discovered_key: String?
    let primary_inbox_id: String?

    var hasDiscoveredKey: Bool {
        (discovered_key?.isEmpty == false)
    }
}

/// Read-only scan that hunts for an existing AgentMail API key in the
/// active host's `~/.hermes/config.yaml`. Mirrors
/// `ComposioVMInstaller.discoverKey`, but looks at
/// `mcp_servers.agentmail.env.AGENTMAIL_API_KEY` instead of the
/// Composio header path.
///
/// We intentionally don't have a corresponding installer/push for
/// AgentMail — the OS1 → AgentMail integration is OS1-side only (the
/// agent's email tooling comes through Composio's MCP), so we only
/// need to read keys, never write them onto a VM.
final class AgentMailVMScanner: @unchecked Sendable {
    private let orgoTransport: OrgoTransport
    private let multiplexed: any RemoteTransport

    init(orgoTransport: OrgoTransport, multiplexed: any RemoteTransport) {
        self.orgoTransport = orgoTransport
        self.multiplexed = multiplexed
    }

    func discoverKey(on connection: ConnectionProfile) async throws -> AgentMailVMScanResult {
        let script = Self.makeScript()
        switch connection.transport {
        case .orgo:
            return try await orgoTransport.executeJSON(
                on: connection,
                pythonScript: script,
                responseType: AgentMailVMScanResult.self
            )
        case .ssh:
            return try await multiplexed.executeJSON(
                on: connection,
                pythonScript: script,
                responseType: AgentMailVMScanResult.self
            )
        }
    }
}

extension AgentMailVMScanner {
    static func makeScript() -> String {
        return #"""
        import json
        import os
        import subprocess
        import sys

        errors = []
        discovered_key = None
        primary_inbox_id = None

        def emit():
            print(json.dumps({
                "success": len(errors) == 0,
                "errors": errors,
                "discovered_key": discovered_key,
                "primary_inbox_id": primary_inbox_id,
            }))
            sys.exit(0)

        try:
            import yaml
        except ImportError:
            try:
                subprocess.run(
                    [sys.executable, "-m", "pip", "install", "--quiet", "--user", "pyyaml"],
                    check=True,
                    timeout=45,
                    capture_output=True,
                )
                import yaml  # noqa: F401
            except Exception as exc:
                errors.append(f"Couldn't load PyYAML: {exc}")
                emit()

        config_path = os.path.join(os.path.expanduser("~"), ".hermes", "config.yaml")
        if not os.path.exists(config_path):
            emit()

        try:
            with open(config_path, "r") as fh:
                loaded = yaml.safe_load(fh) or {}
        except Exception as exc:
            errors.append(f"Couldn't read config.yaml: {exc}")
            emit()

        if not isinstance(loaded, dict):
            emit()

        servers = loaded.get("mcp_servers")
        if not isinstance(servers, dict):
            emit()

        # Try a couple of names — Composio publishes the AgentMail skill
        # under "agentmail", but a self-installed npx-based config may
        # use the same casing as the npm package, so be liberal.
        agentmail_entry = None
        for candidate in ("agentmail", "AgentMail", "agent_mail"):
            if isinstance(servers.get(candidate), dict):
                agentmail_entry = servers[candidate]
                break
        if agentmail_entry is None:
            emit()

        env = agentmail_entry.get("env")
        if isinstance(env, dict):
            value = env.get("AGENTMAIL_API_KEY")
            if isinstance(value, str) and value.strip():
                discovered_key = value.strip()

        # As a secondary fallback, some manual configs pass the key via
        # `args` (e.g. ["--api-key", "<KEY>"]). Sniff for that pattern.
        if not discovered_key:
            args = agentmail_entry.get("args")
            if isinstance(args, list):
                for i, arg in enumerate(args):
                    if isinstance(arg, str) and arg in ("--api-key", "--api-key=", "-k"):
                        if i + 1 < len(args) and isinstance(args[i + 1], str):
                            candidate = args[i + 1].strip()
                            if candidate:
                                discovered_key = candidate
                                break
                    if isinstance(arg, str) and arg.startswith("--api-key="):
                        candidate = arg[len("--api-key="):].strip()
                        if candidate:
                            discovered_key = candidate
                            break

        # Optionally surface a default inbox if the entry happens to
        # advertise one (rare but harmless to extract).
        annotations = agentmail_entry.get("annotations")
        if isinstance(annotations, dict):
            inbox = annotations.get("primary_inbox_id") or annotations.get("inbox_id")
            if isinstance(inbox, str) and inbox.strip():
                primary_inbox_id = inbox.strip()

        emit()
        """#
    }
}
