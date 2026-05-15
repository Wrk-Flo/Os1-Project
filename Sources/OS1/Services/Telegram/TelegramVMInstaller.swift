import Foundation

struct TelegramVMResult: Decodable, Equatable, Sendable {
    let success: Bool
    let errors: [String]
    let steps_done: [String]
    let discovered_token: String?
    let discovered_users: String?
    let gateway_status: String?
    /// Raw contents of `~/.hermes/gateway_state.json` if present, written
    /// live by `hermes gateway run`. Populated only by the `.status`
    /// action — install / discover / disconnect leave this nil. Decoded
    /// permissively because partial writes are possible.
    let gateway_state_json: String?
    /// Tail of `~/.hermes/logs/gateway.log` (last ~40 lines, capped at
    /// 3 KB). Populated by `.status`. Useful for the Doctor tab to
    /// surface failure reasons inline without round-tripping again.
    let gateway_log_tail: String?

    var isInstalled: Bool {
        steps_done.contains("env_written") || steps_done.contains("already_configured")
    }

    var hasDiscoveredToken: Bool {
        discovered_token?.isEmpty == false
    }

    /// True when `hermes gateway status` reported the gateway as
    /// running. We don't strictly parse the status string — the
    /// presence of "running" / "active" anywhere is enough signal.
    var isGatewayOnline: Bool {
        guard let status = gateway_status?.lowercased() else { return false }
        return status.contains("running") || status.contains("active") || status.contains("online")
    }
}

/// Installs / refreshes the Telegram messaging gateway on the active
/// host. Hermes already ships first-class Telegram support via its
/// `gateway` subsystem — we just need to drop two env vars
/// (`TELEGRAM_BOT_TOKEN`, optionally `TELEGRAM_ALLOWED_USERS`) into
/// `~/.hermes/.env` and restart the gateway service.
///
/// Same shape as ComposioVMInstaller: action enum, base64-encoded
/// inputs through a Python wrapper so quoting never breaks the
/// generated source.
final class TelegramVMInstaller: @unchecked Sendable {
    enum Action {
        case install        // write env + restart gateway
        case status         // read env + check gateway status
        case discover       // read existing token from env (don't write)
        case disconnect     // remove TELEGRAM_BOT_TOKEN from env + restart gateway
        case approvePairing // run `hermes pairing approve telegram <code>`
    }

    private let orgoTransport: OrgoTransport
    private let multiplexed: any RemoteTransport

    init(orgoTransport: OrgoTransport, multiplexed: any RemoteTransport) {
        self.orgoTransport = orgoTransport
        self.multiplexed = multiplexed
    }

    func install(
        on connection: ConnectionProfile,
        token: String,
        allowedUsers: String? = nil
    ) async throws -> TelegramVMResult {
        let script = Self.makeScript(
            action: .install,
            token: token,
            allowedUsers: allowedUsers ?? "",
            pairingCode: ""
        )
        return try await execute(on: connection, script: script, longRunning: true)
    }

    func checkStatus(on connection: ConnectionProfile) async throws -> TelegramVMResult {
        let script = Self.makeScript(action: .status, token: "", allowedUsers: "", pairingCode: "")
        return try await execute(on: connection, script: script, longRunning: false)
    }

    func discoverToken(on connection: ConnectionProfile) async throws -> TelegramVMResult {
        let script = Self.makeScript(action: .discover, token: "", allowedUsers: "", pairingCode: "")
        return try await execute(on: connection, script: script, longRunning: false)
    }

    func disconnect(on connection: ConnectionProfile) async throws -> TelegramVMResult {
        let script = Self.makeScript(action: .disconnect, token: "", allowedUsers: "", pairingCode: "")
        return try await execute(on: connection, script: script, longRunning: true)
    }

    func approvePairingCode(
        on connection: ConnectionProfile,
        code: String
    ) async throws -> TelegramVMResult {
        let script = Self.makeScript(action: .approvePairing, token: "", allowedUsers: "", pairingCode: code)
        return try await execute(on: connection, script: script, longRunning: false)
    }

    private func execute(
        on connection: ConnectionProfile,
        script: String,
        longRunning: Bool
    ) async throws -> TelegramVMResult {
        switch connection.transport {
        case .orgo:
            if longRunning {
                return try await orgoTransport.executeLongPython(
                    on: connection,
                    pythonScript: script,
                    serverTimeoutSeconds: 90,
                    responseType: TelegramVMResult.self
                )
            } else {
                return try await orgoTransport.executeJSON(
                    on: connection,
                    pythonScript: script,
                    responseType: TelegramVMResult.self
                )
            }
        case .ssh:
            return try await multiplexed.executeJSON(
                on: connection,
                pythonScript: script,
                responseType: TelegramVMResult.self
            )
        }
    }
}

extension TelegramVMInstaller {
    static func makeScript(
        action: Action,
        token: String,
        allowedUsers: String,
        pairingCode: String
    ) -> String {
        let actionLiteral: String
        switch action {
        case .install:        actionLiteral = "\"install\""
        case .status:         actionLiteral = "\"status\""
        case .discover:       actionLiteral = "\"discover\""
        case .disconnect:     actionLiteral = "\"disconnect\""
        case .approvePairing: actionLiteral = "\"approve_pairing\""
        }
        let tokenB64 = Data(token.utf8).base64EncodedString()
        let usersB64 = Data(allowedUsers.utf8).base64EncodedString()
        let pairingB64 = Data(pairingCode.utf8).base64EncodedString()

        return #"""
        import json
        import os
        import shutil
        import subprocess
        import sys
        import time
        from base64 import b64decode

        ACTION = \#(actionLiteral)
        token = b64decode("\#(tokenB64)").decode("utf-8")
        allowed_users = b64decode("\#(usersB64)").decode("utf-8")
        pairing_code = b64decode("\#(pairingB64)").decode("utf-8")

        steps = []
        errors = []
        discovered_token = None
        discovered_users = None
        gateway_status = None
        gateway_state_json = None
        gateway_log_tail = None

        def emit(success):
            print(json.dumps({
                "success": success and len(errors) == 0,
                "errors": errors,
                "steps_done": steps,
                "discovered_token": discovered_token,
                "discovered_users": discovered_users,
                "gateway_status": gateway_status,
                "gateway_state_json": gateway_state_json,
                "gateway_log_tail": gateway_log_tail,
            }))
            sys.exit(0)

        def find_hermes_binary():
            path = shutil.which("hermes")
            if path:
                return path
            for candidate in [
                os.path.expanduser("~/.local/bin/hermes"),
                os.path.expanduser("~/.cargo/bin/hermes"),
                os.path.expanduser("~/.hermes/bin/hermes"),
                "/usr/local/bin/hermes",
                "/usr/bin/hermes",
            ]:
                if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                    return candidate
            return None

        # ----- Supervisor detection & control -----
        # Hermes' `gateway install --user` writes a systemd user unit on Linux
        # or a launchd plist on macOS. Both rely on a running supervisor
        # process (systemd-user / launchd). Orgo VMs and bare containers run
        # plain bash as PID 1 with no supervisor — `gateway install --user`
        # is a silent no-op and `gateway start` exits cleanly without ever
        # spawning a daemon. We detect that environment and fall back to a
        # `setsid + nohup + while-true` loop, which is the same pattern the
        # Hermes FAQ recommends for WSL / Docker / bare-init hosts.
        def has_systemd_user():
            try:
                r = subprocess.run(
                    ["systemctl", "--user", "is-system-running"],
                    capture_output=True, text=True, timeout=5,
                )
                out = (r.stdout or "").lower()
                return r.returncode == 0 or "running" in out or "degraded" in out
            except Exception:
                return False

        def has_launchctl():
            return shutil.which("launchctl") is not None

        def pick_supervisor():
            if has_systemd_user():
                return "systemd"
            if has_launchctl():
                return "launchctl"
            return "foreground"

        def stop_gateway(supervisor, hermes_bin):
            """Best-effort stop. Never raises."""
            if supervisor in ("systemd", "launchctl"):
                try:
                    subprocess.run(
                        [hermes_bin, "gateway", "stop"],
                        capture_output=True, text=True, timeout=15,
                    )
                except Exception:
                    pass
                return
            # Foreground path: order matters.
            #
            # 1) Kill our supervised bash wrapper FIRST. Its cmdline
            #    contains the resolved hermes_bin path, so the f-string
            #    substituted pattern matches it. This stops the wrapper
            #    from relaunching hermes between our two cleanup steps.
            #
            # 2) Then `hermes gateway stop` to kill any python gateway
            #    process. This catches the case our pkill pattern misses:
            #    the python interpreter's cmdline shows the venv path
            #    (e.g. .../venv/bin/hermes) not the user-facing hermes
            #    path, so pattern matching is unreliable. Hermes uses its
            #    own PID file to find the right process.
            #
            # CRITICAL: do NOT spell out any literal resolved path in
            # this comment. Orgo's /exec endpoint runs `python3 -c
            # '<source>'`, so the parent python's cmdline includes this
            # script's text (comments and all). A literal example
            # matching the runtime pkill pattern would make pkill match
            # its own parent and kill the script in 0.4s with empty
            # output. Keep examples abstract.
            try:
                subprocess.run(
                    f"pkill -f '{hermes_bin} gateway run'",
                    shell=True, capture_output=True, text=True, timeout=10,
                )
            except Exception:
                pass
            try:
                subprocess.run(
                    [hermes_bin, "gateway", "stop"],
                    capture_output=True, text=True, timeout=15,
                )
            except Exception:
                pass
            time.sleep(1)

        def start_gateway(supervisor, hermes_bin):
            """Start the gateway under the chosen supervisor.
            Returns (success: bool, detail: str)."""
            if supervisor in ("systemd", "launchctl"):
                # Ensure the user unit exists, then start. `install --user`
                # is idempotent — Hermes treats it as a no-op if already
                # registered.
                try:
                    subprocess.run(
                        [hermes_bin, "gateway", "install", "--user"],
                        capture_output=True, text=True, timeout=60,
                    )
                except Exception:
                    pass
                try:
                    r = subprocess.run(
                        [hermes_bin, "gateway", "start"],
                        capture_output=True, text=True, timeout=60,
                    )
                    if r.returncode == 0:
                        return True, ""
                    tail = ((r.stdout or "")[-600:] + "\n" + (r.stderr or "")[-600:]).strip()
                    return False, f"hermes gateway start exited {r.returncode}:\n{tail}"
                except subprocess.TimeoutExpired:
                    return False, "hermes gateway start timed out."

            # Foreground supervised loop. Survives session detach and
            # auto-restarts on crash. Doesn't survive VM reboot — that's the
            # user's "click reinstall" path and a deliberate v1 limitation.
            log_path = os.path.join(os.path.expanduser("~"), ".hermes", "logs", "gateway.log")
            try:
                os.makedirs(os.path.dirname(log_path), exist_ok=True)
            except Exception:
                pass
            # `--replace` makes each iteration take over from any other
            # gateway instance via Hermes' own lock-file replacement
            # path. Defensive — if stop_gateway above missed something,
            # the wrapper's first iteration still wins the lock instead
            # of crash-looping forever on "❌ Gateway already running".
            cmd = (
                f"setsid nohup bash -c 'while true; do {hermes_bin} gateway run --replace; sleep 5; done' "
                f"> {log_path} 2>&1 < /dev/null &"
            )
            try:
                subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
            except Exception as exc:
                return False, f"setsid launch failed: {exc}"
            # Give bash + python a beat to come up.
            time.sleep(5)
            # Same reasoning as stop_gateway — anchor on the resolved
            # hermes path so we don't match python -c '<source>' on the
            # /exec path.
            verify = subprocess.run(
                f"pgrep -f '{hermes_bin} gateway run'",
                shell=True, capture_output=True, text=True,
            )
            if verify.returncode == 0:
                return True, ""
            log_tail = ""
            try:
                with open(log_path, "r") as fh:
                    log_tail = fh.read()[-600:].strip()
            except Exception:
                pass
            msg = "hermes gateway run did not stay alive after launch."
            if log_tail:
                msg += f" Log tail:\n{log_tail}"
            return False, msg

        env_path = os.path.join(os.path.expanduser("~"), ".hermes", ".env")

        # Read existing env into a dict so we can preserve other vars
        # (DISCORD_BOT_TOKEN, OPENAI_API_KEY, etc. that may already be set).
        # Naive parser — covers the standard `KEY=value` shape; comments
        # and blank lines are passed through verbatim when we rewrite.
        env_lines = []
        if os.path.exists(env_path):
            try:
                with open(env_path, "r") as fh:
                    env_lines = fh.read().splitlines()
            except Exception as exc:
                errors.append(f"Couldn't read .env: {exc}")

        def get_env(key):
            for line in env_lines:
                stripped = line.strip()
                if stripped.startswith("#") or "=" not in stripped:
                    continue
                k, _, v = stripped.partition("=")
                if k.strip() == key:
                    val = v.strip()
                    # Trim outer quotes if present
                    if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                        val = val[1:-1]
                    return val
            return None

        def set_env(key, value):
            """Update or append a key in env_lines. Quotes the value to
            survive whitespace / equals signs."""
            quoted = '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
            new_line = f"{key}={quoted}"
            for i, line in enumerate(env_lines):
                stripped = line.strip()
                if "=" in stripped and stripped.split("=", 1)[0].strip() == key and not stripped.startswith("#"):
                    env_lines[i] = new_line
                    return
            env_lines.append(new_line)

        def remove_env(key):
            """Drop a key from env_lines if present."""
            global env_lines
            env_lines = [
                line for line in env_lines
                if not (
                    "=" in line.strip() and
                    line.strip().split("=", 1)[0].strip() == key and
                    not line.strip().startswith("#")
                )
            ]

        def write_env_lines():
            os.makedirs(os.path.dirname(env_path), exist_ok=True)
            tmp_path = env_path + ".tmp"
            with open(tmp_path, "w") as fh:
                fh.write("\n".join(env_lines).rstrip() + "\n")
            os.replace(tmp_path, env_path)
            try:
                os.chmod(env_path, 0o600)
            except Exception:
                pass

        # ---- DISCOVER ----
        if ACTION == "discover":
            discovered_token = get_env("TELEGRAM_BOT_TOKEN")
            discovered_users = get_env("TELEGRAM_ALLOWED_USERS")
            if discovered_token:
                steps.append("token_found")
            emit(True)

        # ---- STATUS ----
        if ACTION == "status":
            existing_token = get_env("TELEGRAM_BOT_TOKEN")
            if existing_token:
                steps.append("already_configured")
            hermes_bin = find_hermes_binary()
            if hermes_bin:
                try:
                    r = subprocess.run([hermes_bin, "gateway", "status"], capture_output=True, text=True, timeout=15)
                    gateway_status = (r.stdout + r.stderr).strip()[:600]
                except Exception:
                    pass
            # Read live gateway state (written by `hermes gateway run`).
            # We pass through the raw JSON string and let the Swift side
            # decode permissively — partial writes are possible mid-tick.
            state_path = os.path.join(os.path.expanduser("~"), ".hermes", "gateway_state.json")
            try:
                if os.path.exists(state_path):
                    with open(state_path, "r") as fh:
                        gateway_state_json = fh.read()[:4000]
            except Exception:
                pass
            # Tail the gateway log so the Doctor tab can surface failure
            # reasons inline without an extra round trip.
            log_path = os.path.join(os.path.expanduser("~"), ".hermes", "logs", "gateway.log")
            try:
                if os.path.exists(log_path):
                    with open(log_path, "r") as fh:
                        lines = fh.readlines()[-40:]
                        gateway_log_tail = ("".join(lines))[:3000]
            except Exception:
                pass
            emit(True)

        # ---- APPROVE PAIRING ----
        if ACTION == "approve_pairing":
            if not pairing_code:
                errors.append("Pairing code is required.")
                emit(False)
            hermes_bin = find_hermes_binary()
            if not hermes_bin:
                errors.append("Hermes CLI not found on this host. Install Hermes first.")
                emit(False)
            try:
                r = subprocess.run(
                    [hermes_bin, "pairing", "approve", "telegram", pairing_code],
                    capture_output=True, text=True, timeout=30,
                )
                if r.returncode == 0:
                    steps.append("pairing_approved")
                else:
                    tail = (r.stdout or "")[-600:] + "\n" + (r.stderr or "")[-600:]
                    errors.append(f"hermes pairing approve exited {r.returncode}:\n{tail.strip()}")
            except subprocess.TimeoutExpired:
                errors.append("hermes pairing approve timed out.")
            emit(len(errors) == 0)

        # ---- INSTALL ----
        if ACTION == "install":
            if not token:
                errors.append("Bot token is required.")
                emit(False)

            hermes_bin = find_hermes_binary()
            if not hermes_bin:
                errors.append("Hermes CLI not found on this host. Install Hermes Agent from the Overview tab first.")
                emit(False)

            previous = get_env("TELEGRAM_BOT_TOKEN")
            previous_users = get_env("TELEGRAM_ALLOWED_USERS")

            set_env("TELEGRAM_BOT_TOKEN", token)
            if allowed_users:
                set_env("TELEGRAM_ALLOWED_USERS", allowed_users)

            try:
                write_env_lines()
                steps.append("env_written")
                if previous and previous != token:
                    steps.append("token_rotated")
                if previous_users and not allowed_users:
                    # User cleared the allowlist; remove it explicitly so the
                    # gateway falls back to DM pairing.
                    pass  # leave the previous value in for safety; explicit clear is via disconnect
            except Exception as exc:
                errors.append(f"Failed to write ~/.hermes/.env: {exc}")
                emit(False)

            # Pick the right supervisor for this host, then stop any
            # running gateway and start fresh so the new env takes effect.
            supervisor = pick_supervisor()
            stop_gateway(supervisor, hermes_bin)
            ok, detail = start_gateway(supervisor, hermes_bin)
            if ok:
                steps.append("gateway_started")
            else:
                errors.append(detail or "Failed to start hermes gateway.")

            try:
                status_result = subprocess.run(
                    [hermes_bin, "gateway", "status"],
                    capture_output=True, text=True, timeout=15,
                )
                gateway_status = (status_result.stdout + status_result.stderr).strip()[:600]
            except Exception:
                pass

            emit(len(errors) == 0)

        # ---- DISCONNECT ----
        if ACTION == "disconnect":
            removed = False
            if get_env("TELEGRAM_BOT_TOKEN"):
                remove_env("TELEGRAM_BOT_TOKEN")
                removed = True
            if get_env("TELEGRAM_ALLOWED_USERS"):
                remove_env("TELEGRAM_ALLOWED_USERS")
                removed = True
            if removed:
                try:
                    write_env_lines()
                    steps.append("env_cleared")
                except Exception as exc:
                    errors.append(f"Failed to write ~/.hermes/.env: {exc}")

            hermes_bin = find_hermes_binary()
            if hermes_bin:
                supervisor = pick_supervisor()
                stop_gateway(supervisor, hermes_bin)
                # Best-effort restart in case the user still has other
                # platforms configured (Discord, Slack, etc.). If only
                # Telegram was set up and we just removed it, start_gateway
                # will fail cleanly and we just log it as stopped.
                ok, _ = start_gateway(supervisor, hermes_bin)
                steps.append("gateway_restarted" if ok else "gateway_stopped")
            emit(len(errors) == 0)

        emit(False)
        """#
    }
}
