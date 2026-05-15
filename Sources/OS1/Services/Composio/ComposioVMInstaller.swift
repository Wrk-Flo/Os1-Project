import Foundation

struct ComposioVMInstallResult: Decodable, Equatable, Sendable {
    let success: Bool
    let errors: [String]
    let steps_done: [String]
    let discovered_key: String?

    var isAlreadyRegistered: Bool { steps_done.contains("already_registered") }
    var didRegister: Bool { steps_done.contains("registered") }
    var didRotateKey: Bool { steps_done.contains("key_updated") }

    /// True iff the Composio MCP entry exists in `~/.hermes/config.yaml`
    /// (regardless of whether we wrote it just now or it was already there).
    var isInstalled: Bool {
        steps_done.contains("already_registered") ||
        steps_done.contains("registered") ||
        steps_done.contains("key_updated") ||
        steps_done.contains("key_found")
    }

    /// Did the discover action find an existing Composio key on the VM?
    var hasDiscoveredKey: Bool {
        steps_done.contains("key_found") &&
        (discovered_key?.isEmpty == false)
    }
}

/// Installs / refreshes the Composio Connect MCP server in the active VM's
/// Hermes config. Compared to per-app MCP servers (e.g. AgentMail's own
/// `npx agentmail-mcp`), this is a single HTTP MCP entry pointing at
/// `https://connect.composio.dev/mcp` — Composio's `x-consumer-api-key`
/// header authenticates the user, and the agent then sees ~7 meta-tools
/// that proxy to whatever toolkits the user has authorized in Composio.
final class ComposioVMInstaller: @unchecked Sendable {
    static let mcpURL = "https://connect.composio.dev/mcp"

    private let orgoTransport: OrgoTransport
    private let multiplexed: any RemoteTransport

    init(orgoTransport: OrgoTransport, multiplexed: any RemoteTransport) {
        self.orgoTransport = orgoTransport
        self.multiplexed = multiplexed
    }

    func install(on connection: ConnectionProfile, apiKey: String) async throws -> ComposioVMInstallResult {
        let script = Self.makeScript(apiKey: apiKey, action: .install)
        switch connection.transport {
        case .orgo:
            return try await orgoTransport.executeLongPython(
                on: connection,
                pythonScript: script,
                serverTimeoutSeconds: 60,
                responseType: ComposioVMInstallResult.self
            )
        case .ssh:
            return try await multiplexed.executeJSON(
                on: connection,
                pythonScript: script,
                responseType: ComposioVMInstallResult.self
            )
        }
    }

    func checkStatus(on connection: ConnectionProfile) async throws -> ComposioVMInstallResult {
        let script = Self.makeScript(apiKey: "", action: .status)
        switch connection.transport {
        case .orgo:
            return try await orgoTransport.executeJSON(
                on: connection,
                pythonScript: script,
                responseType: ComposioVMInstallResult.self
            )
        case .ssh:
            return try await multiplexed.executeJSON(
                on: connection,
                pythonScript: script,
                responseType: ComposioVMInstallResult.self
            )
        }
    }

    /// Scans the VM for an existing `mcp_servers.composio` entry and
    /// extracts its API key if present. Used in the unconfigured state
    /// of the Connectors tab so users who already installed Composio
    /// through any other tool (composio CLI, Claude Desktop on the VM,
    /// manual config edit) don't have to re-paste the same key.
    func discoverKey(on connection: ConnectionProfile) async throws -> ComposioVMInstallResult {
        let script = Self.makeScript(apiKey: "", action: .discover)
        switch connection.transport {
        case .orgo:
            return try await orgoTransport.executeJSON(
                on: connection,
                pythonScript: script,
                responseType: ComposioVMInstallResult.self
            )
        case .ssh:
            return try await multiplexed.executeJSON(
                on: connection,
                pythonScript: script,
                responseType: ComposioVMInstallResult.self
            )
        }
    }
}

extension ComposioVMInstaller {
    enum ScriptAction { case install, status, discover }

    static func makeScript(apiKey: String, action: ScriptAction) -> String {
        let apiKeyB64 = Data(apiKey.utf8).base64EncodedString()
        let mcpURLB64 = Data(mcpURL.utf8).base64EncodedString()
        let actionLiteral: String
        switch action {
        case .install:  actionLiteral = "\"install\""
        case .status:   actionLiteral = "\"status\""
        case .discover: actionLiteral = "\"discover\""
        }

        return #"""
        import json
        import os
        import subprocess
        import sys
        from base64 import b64decode

        ACTION = \#(actionLiteral)
        api_key = b64decode("\#(apiKeyB64)").decode("utf-8")
        mcp_url = b64decode("\#(mcpURLB64)").decode("utf-8")

        steps = []
        errors = []
        discovered_key = None

        def emit(payload):
            print(json.dumps(payload))
            sys.exit(0)

        def emit_with_key(payload):
            payload["discovered_key"] = discovered_key
            emit(payload)

        def ensure_yaml():
            try:
                import yaml  # noqa: F401
                return True
            except ImportError:
                pass
            try:
                subprocess.run(
                    [sys.executable, "-m", "pip", "install", "--quiet", "--user", "pyyaml"],
                    check=True,
                    timeout=45,
                    capture_output=True,
                )
                import yaml  # noqa: F401
                return True
            except subprocess.TimeoutExpired:
                errors.append("pip install pyyaml timed out after 45s.")
                return False
            except subprocess.CalledProcessError as exc:
                tail = (exc.stderr or b"").decode("utf-8", errors="replace")[-800:]
                errors.append(f"pip install pyyaml failed: {tail.strip()}")
                return False
            except ImportError as exc:
                errors.append(f"PyYAML import failed even after install: {exc}")
                return False

        if not ensure_yaml():
            emit_with_key({"success": False, "errors": errors, "steps_done": steps})

        import yaml as _yaml

        config_path = os.path.join(os.path.expanduser("~"), ".hermes", "config.yaml")

        existing = {}
        if os.path.exists(config_path):
            try:
                with open(config_path, "r") as fh:
                    loaded = _yaml.safe_load(fh) or {}
                    if isinstance(loaded, dict):
                        existing = loaded
            except Exception as exc:
                errors.append(f"Couldn't read existing config.yaml: {exc}")

        previous = (existing.get("mcp_servers") or {}).get("composio") if isinstance(existing.get("mcp_servers"), dict) else None

        # Pull the API key from the existing entry's headers, regardless
        # of header name — Composio's docs use both `x-consumer-api-key`
        # (current) and `x-api-key` (older) and we want both to flow.
        if isinstance(previous, dict):
            headers = previous.get("headers") or {}
            if isinstance(headers, dict):
                for header_name in ("x-consumer-api-key", "x-api-key", "x-user-api-key"):
                    candidate = headers.get(header_name)
                    if isinstance(candidate, str) and candidate.strip():
                        discovered_key = candidate.strip()
                        break

        if ACTION == "discover":
            if discovered_key:
                steps.append("key_found")
            emit_with_key({"success": True, "errors": errors, "steps_done": steps})

        if ACTION == "status":
            if previous is not None:
                steps.append("already_registered")
            emit_with_key({"success": True, "errors": errors, "steps_done": steps})

        # ---- install: write/update mcp_servers.composio ----
        target_entry = {
            "url": mcp_url,
            "headers": {"x-consumer-api-key": api_key},
        }

        if previous == target_entry:
            steps.append("already_registered")
            emit_with_key({"success": True, "errors": errors, "steps_done": steps})

        previous_key = None
        if isinstance(previous, dict) and isinstance(previous.get("headers"), dict):
            previous_key = previous["headers"].get("x-consumer-api-key")

        mcp_servers = existing.setdefault("mcp_servers", {})
        if not isinstance(mcp_servers, dict):
            mcp_servers = {}
            existing["mcp_servers"] = mcp_servers
        mcp_servers["composio"] = target_entry

        try:
            os.makedirs(os.path.dirname(config_path), exist_ok=True)
            tmp_path = config_path + ".tmp"
            with open(tmp_path, "w") as fh:
                _yaml.safe_dump(existing, fh, sort_keys=False, default_flow_style=False)
            os.replace(tmp_path, config_path)
            try:
                os.chmod(config_path, 0o600)
            except Exception:
                pass  # not fatal on platforms where chmod is restricted
            if previous_key and previous_key != api_key:
                steps.append("key_updated")
            else:
                steps.append("registered")
        except Exception as exc:
            errors.append(f"Failed to write config.yaml: {exc}")

        emit_with_key({"success": len(errors) == 0, "errors": errors, "steps_done": steps})
        """#
    }
}
