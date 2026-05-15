import Foundation
import Testing
@testable import OS1

/// Live integration tests against a real Orgo VM.
///
/// Skipped unless all three are set:
///   ORGO_LIVE_TESTS=1
///   ORGO_API_KEY=sk_live_...
///   ORGO_DEFAULT_COMPUTER_ID=<uuid>
///
/// When skipped, each test silently no-ops (passes without assertions).
struct OrgoTransportLiveTests {
    private static var isLive: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ORGO_LIVE_TESTS"] == "1"
            && (env["ORGO_API_KEY"]?.isEmpty == false)
            && (env["ORGO_DEFAULT_COMPUTER_ID"]?.isEmpty == false)
    }

    private static func makeFixture() -> (transport: OrgoTransport, profile: ConnectionProfile) {
        let env = ProcessInfo.processInfo.environment
        let apiKey = env["ORGO_API_KEY"] ?? ""
        let computerId = env["ORGO_DEFAULT_COMPUTER_ID"] ?? ""

        let transport = OrgoTransport(apiKeyProvider: { apiKey })
        let profile = ConnectionProfile(
            label: "Live Test",
            transport: .orgo(OrgoConfig(workspaceId: "", computerId: computerId))
        )
        return (transport, profile)
    }

    @Test
    func bashHappyPathReturnsZeroExit() async throws {
        guard Self.isLive else { return }
        let (transport, profile) = Self.makeFixture()

        let result = try await transport.execute(
            on: profile,
            remoteCommand: "uname -s",
            standardInput: nil,
            allocateTTY: false
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("Linux"))
    }

    @Test
    func bashFailureReturnsRealExitCodeNotHardcodedZero() async throws {
        guard Self.isLive else { return }
        let (transport, profile) = Self.makeFixture()

        let result = try await transport.execute(
            on: profile,
            remoteCommand: "false",
            standardInput: nil,
            allocateTTY: false
        )

        // Orgo /bash hardcodes exit_code: 0 in its response. The sentinel-
        // trailer parsing must recover the real exit code (1) from `false`.
        #expect(result.exitCode == 1)
    }

    @Test
    func bashWithMultiCommandReturnsLastExit() async throws {
        guard Self.isLive else { return }
        let (transport, profile) = Self.makeFixture()

        let result = try await transport.execute(
            on: profile,
            remoteCommand: "true; false; true",
            standardInput: nil,
            allocateTTY: false
        )

        #expect(result.exitCode == 0)
    }

    @Test
    func bashOutputContainingMarkerPrefixDoesNotCollide() async throws {
        guard Self.isLive else { return }
        let (transport, profile) = Self.makeFixture()

        // Print a string that contains the marker prefix (without nonce or
        // anchor) plus a fake exit code in the middle of the stream. The
        // wrapper's per-call nonce + line-anchored regex must ignore it
        // and parse the real trailer at the end.
        let result = try await transport.execute(
            on: profile,
            remoteCommand: "echo '__ORGO_RC_INLINE__:99' && echo done",
            standardInput: nil,
            allocateTTY: false
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("__ORGO_RC_INLINE__:99"))
        #expect(result.stdout.contains("done"))
    }

    @Test
    func executeJSONHappyPathDecodesPayload() async throws {
        guard Self.isLive else { return }
        let (transport, profile) = Self.makeFixture()

        struct Payload: Decodable, Equatable {
            let answer: Int
            let label: String
        }

        let response: Payload = try await transport.executeJSON(
            on: profile,
            pythonScript: "import json; print(json.dumps({\"answer\": 42, \"label\": \"orgo\"}))",
            responseType: Payload.self
        )

        #expect(response == Payload(answer: 42, label: "orgo"))
    }

    @Test
    func executeJSONPythonErrorThrowsRemoteFailure() async throws {
        guard Self.isLive else { return }
        let (transport, profile) = Self.makeFixture()

        struct Payload: Decodable {}

        await #expect(throws: RemoteTransportError.self) {
            _ = try await transport.executeJSON(
                on: profile,
                pythonScript: "1/0",
                responseType: Payload.self
            )
        }
    }

    @Test
    func resolveTerminalEndpointReturnsValidWSSURL() async throws {
        guard Self.isLive else { return }
        let (transport, _) = Self.makeFixture()
        let computerId = ProcessInfo.processInfo.environment["ORGO_DEFAULT_COMPUTER_ID"] ?? ""

        let endpoint = try await transport.resolveTerminalEndpoint(
            computerId: computerId,
            cols: 200,
            rows: 50
        )

        // URL shape: wss://<fly_id>.orgo.dev/terminal?token=...&cols=200&rows=50
        let url = endpoint.webSocketURL
        #expect(url.scheme == "wss")
        #expect(url.host?.hasSuffix(".orgo.dev") == true)
        #expect(url.path == "/terminal")
        let queryString = url.query ?? ""
        #expect(queryString.contains("token="))
        #expect(queryString.contains("cols=200"))
        #expect(queryString.contains("rows=50"))
        #expect(!endpoint.vncPassword.isEmpty)
    }

    @Test
    func ensureRunningOnAlreadyRunningVMSucceeds() async throws {
        guard Self.isLive else { return }
        let (transport, _) = Self.makeFixture()
        let computerId = ProcessInfo.processInfo.environment["ORGO_DEFAULT_COMPUTER_ID"] ?? ""

        // Idempotent — calling ensure-running on a running VM is a no-op that
        // should return successfully.
        try await transport.ensureRunning(computerId: computerId)
    }

    @Test
    func executeJSONServerTimeoutThrows() async throws {
        guard Self.isLive else { return }
        let (transport, profile) = Self.makeFixture()

        struct Payload: Decodable {}

        // Sleep beyond the 60s server-side cap that OrgoTransport sets in
        // the /exec request body. Server returns success=false with no
        // output; OrgoTransport must surface this as RemoteTransportError.
        await #expect(throws: RemoteTransportError.self) {
            _ = try await transport.executeJSON(
                on: profile,
                pythonScript: "import time; time.sleep(120)",
                responseType: Payload.self
            )
        }
    }
}
