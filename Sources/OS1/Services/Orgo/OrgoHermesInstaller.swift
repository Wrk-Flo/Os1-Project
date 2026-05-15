import Foundation

/// View-state for the install flow. AppState publishes this; OverviewView
/// reads it to render the banner.
enum HermesInstallStatus: Equatable {
    case idle
    case running
    case failed(message: String)
}

struct HermesInstallResult: Equatable, Sendable {
    let exitCode: Int
    let stdoutTail: String
    let stderrTail: String

    var succeeded: Bool { exitCode == 0 }
}

/// Runs the official Hermes Agent installer on an Orgo VM via /exec.
///
/// Bound to OrgoTransport directly (not the multiplexer protocol) because
/// it needs the long-running /exec timeout that's specific to Orgo's
/// platform; SSH hosts are expected to have Hermes installed by the user.
final class OrgoHermesInstaller: @unchecked Sendable {
    private let transport: OrgoTransport
    private let installScriptURL: String

    init(
        transport: OrgoTransport,
        installScriptURL: String = "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
    ) {
        self.transport = transport
        self.installScriptURL = installScriptURL
    }

    func installHermes(on connection: ConnectionProfile) async throws -> HermesInstallResult {
        let script = OrgoHermesInstaller.makeInstallScript(installScriptURL: installScriptURL)
        let response: InstallScriptResponse = try await transport.executeLongPython(
            on: connection,
            pythonScript: script,
            serverTimeoutSeconds: 295,
            responseType: InstallScriptResponse.self
        )

        return HermesInstallResult(
            exitCode: response.exit_code,
            stdoutTail: response.stdout_tail,
            stderrTail: response.stderr_tail
        )
    }
}

private struct InstallScriptResponse: Decodable {
    let exit_code: Int
    let stdout_tail: String
    let stderr_tail: String
}

extension OrgoHermesInstaller {
    /// Generates the Python source that runs the installer on the VM.
    /// Exposed for testing so a Python-syntax check can run against it
    /// without needing a real OrgoTransport call.
    static func makeInstallScript(installScriptURL: String) -> String {
        // Both URL and bash source are base64-encoded so quoting/escaping
        // never breaks the generated Python source — base64 only contains
        // [A-Za-z0-9+/=], safe inside any Python string literal.
        let urlBase64 = Data(installScriptURL.utf8).base64EncodedString()

        // Bash side: a few fixes the official installer assumes are already
        // taken care of, but Orgo's base image doesn't ship.
        // 1. Clock sync — Orgo VM clocks drift (we observed Apr 8 vs real
        //    May 5, a 17-day skew that broke astral.sh's cert validation).
        //    Sync from Google's HTTP Date header — no TLS needed because we
        //    go over plain http://, so cert validation isn't even attempted.
        // 2. git — the Hermes installer clones the agent repo. Orgo's
        //    Ubuntu base image doesn't include git by default.
        // Then run the actual installer.
        let bashSource = """
        # Normalize PATH so dpkg/ldconfig/start-stop-daemon are findable; the
        # /exec environment ships with a minimal one missing /usr/sbin, /sbin.
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
        export DEBIAN_FRONTEND=noninteractive

        # Sync clock from Google's HTTP Date header — Orgo VM clocks drift,
        # which breaks TLS cert validation on later HTTPS calls (e.g. astral.sh
        # for the uv installer). Plain http:// here, no cert check at all.
        NEW_DATE=$(curl -sI http://www.google.com 2>/dev/null | awk -F': ' '/^[Dd]ate:/ {print $2}' | tr -d '\\r' | head -n1)
        [ -n "$NEW_DATE" ] && date -s "$NEW_DATE" >/dev/null 2>&1 || true

        # If a prior install attempt timed out HTTP-side, its apt-get may
        # still be running on the VM, holding the dpkg/apt lock. Clean up.
        # IMPORTANT: -x (exact name) not -f (full command line). -f would
        # match this very wrapper script (which mentions "apt-get" in its
        # text) and SIGKILL ourselves.
        pkill -9 -x apt-get >/dev/null 2>&1 || true
        pkill -9 -x dpkg >/dev/null 2>&1 || true
        sleep 1
        rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || true
        dpkg --configure -a >/dev/null 2>&1 || true

        # Hermes installer needs git for repo clone — Orgo's base image
        # doesn't include it.
        if ! command -v git >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq git >/dev/null 2>&1 || true
        fi

        # Run the actual Hermes Agent installer.
        curl -fsSL "$INSTALL_URL" | bash
        """
        let bashBase64 = Data(bashSource.utf8).base64EncodedString()

        // Python wrapper so /exec gives us up to 290s server-side. /bash
        // caps at 30s, which isn't enough for the installer's downloads
        // + venv setup.
        return """
        import base64
        import json
        import os
        import subprocess

        install_url = base64.b64decode("\(urlBase64)").decode("utf-8")
        bash_cmd = base64.b64decode("\(bashBase64)").decode("utf-8")

        env = os.environ.copy()
        env["INSTALL_URL"] = install_url

        try:
            result = subprocess.run(
                ["bash", "-lc", bash_cmd],
                capture_output=True,
                text=True,
                timeout=290,
                env=env,
            )
            exit_code = result.returncode
            stdout_tail = result.stdout[-4000:]
            stderr_tail = result.stderr[-4000:]
        except subprocess.TimeoutExpired as exc:
            exit_code = -1
            stdout_tail = (exc.stdout or "")[-4000:] if isinstance(getattr(exc, "stdout", None), str) else ""
            stderr_tail = "Hermes installer exceeded 290s and was aborted."
        except Exception as exc:
            exit_code = -1
            stdout_tail = ""
            stderr_tail = f"Installer raised: {exc}"

        print(json.dumps({
            "exit_code": exit_code,
            "stdout_tail": stdout_tail,
            "stderr_tail": stderr_tail,
        }))
        """
    }
}
