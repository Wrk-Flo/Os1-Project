import Foundation
import Testing
@testable import OS1

private final class StubTransport: RemoteTransport, @unchecked Sendable {
    let label: String
    var executeCalls: [String] = []
    var executeJSONCalls: [String] = []

    init(label: String) {
        self.label = label
    }

    func execute(
        on connection: ConnectionProfile,
        remoteCommand: String,
        standardInput: Data?,
        allocateTTY: Bool
    ) async throws -> RemoteCommandResult {
        executeCalls.append(remoteCommand)
        return RemoteCommandResult(stdout: label, stderr: "", exitCode: 0)
    }

    func executeJSON<Response: Decodable>(
        on connection: ConnectionProfile,
        pythonScript: String,
        responseType: Response.Type
    ) async throws -> Response {
        executeJSONCalls.append(pythonScript)
        // Return the label as a JSON string so the test can decode it.
        let json = "\"\(label)\"".data(using: .utf8)!
        return try JSONDecoder().decode(Response.self, from: json)
    }
}

struct MultiplexedRemoteTransportTests {
    private static func sshProfile() -> ConnectionProfile {
        ConnectionProfile(
            label: "SSH",
            transport: .ssh(SSHConfig(alias: "ssh-test", host: "", port: nil, user: "alice"))
        )
    }

    private static func orgoProfile() -> ConnectionProfile {
        ConnectionProfile(
            label: "Orgo",
            transport: .orgo(OrgoConfig(workspaceId: "ws", computerId: "vm"))
        )
    }

    @Test
    func executeOnSSHProfileRoutesToSSHBackend() async throws {
        let ssh = StubTransport(label: "ssh")
        let orgo = StubTransport(label: "orgo")
        let mux = MultiplexedRemoteTransport(ssh: ssh, orgo: orgo)

        let result = try await mux.execute(
            on: Self.sshProfile(),
            remoteCommand: "uname",
            standardInput: nil,
            allocateTTY: false
        )

        #expect(result.stdout == "ssh")
        #expect(ssh.executeCalls == ["uname"])
        #expect(orgo.executeCalls.isEmpty)
    }

    @Test
    func executeOnOrgoProfileRoutesToOrgoBackend() async throws {
        let ssh = StubTransport(label: "ssh")
        let orgo = StubTransport(label: "orgo")
        let mux = MultiplexedRemoteTransport(ssh: ssh, orgo: orgo)

        let result = try await mux.execute(
            on: Self.orgoProfile(),
            remoteCommand: "uname",
            standardInput: nil,
            allocateTTY: false
        )

        #expect(result.stdout == "orgo")
        #expect(orgo.executeCalls == ["uname"])
        #expect(ssh.executeCalls.isEmpty)
    }

    @Test
    func executeJSONOnSSHProfileRoutesToSSHBackend() async throws {
        let ssh = StubTransport(label: "ssh")
        let orgo = StubTransport(label: "orgo")
        let mux = MultiplexedRemoteTransport(ssh: ssh, orgo: orgo)

        let response: String = try await mux.executeJSON(
            on: Self.sshProfile(),
            pythonScript: "print('x')",
            responseType: String.self
        )

        #expect(response == "ssh")
        #expect(ssh.executeJSONCalls == ["print('x')"])
        #expect(orgo.executeJSONCalls.isEmpty)
    }

    @Test
    func executeJSONOnOrgoProfileRoutesToOrgoBackend() async throws {
        let ssh = StubTransport(label: "ssh")
        let orgo = StubTransport(label: "orgo")
        let mux = MultiplexedRemoteTransport(ssh: ssh, orgo: orgo)

        let response: String = try await mux.executeJSON(
            on: Self.orgoProfile(),
            pythonScript: "print('x')",
            responseType: String.self
        )

        #expect(response == "orgo")
        #expect(orgo.executeJSONCalls == ["print('x')"])
        #expect(ssh.executeJSONCalls.isEmpty)
    }

    @Test
    func mixedSequenceRoutesEachCallToTheCorrectBackend() async throws {
        let ssh = StubTransport(label: "ssh")
        let orgo = StubTransport(label: "orgo")
        let mux = MultiplexedRemoteTransport(ssh: ssh, orgo: orgo)

        _ = try await mux.execute(on: Self.sshProfile(), remoteCommand: "a", standardInput: nil, allocateTTY: false)
        _ = try await mux.execute(on: Self.orgoProfile(), remoteCommand: "b", standardInput: nil, allocateTTY: false)
        _ = try await mux.execute(on: Self.sshProfile(), remoteCommand: "c", standardInput: nil, allocateTTY: false)

        #expect(ssh.executeCalls == ["a", "c"])
        #expect(orgo.executeCalls == ["b"])
    }
}
