import Foundation
import Testing
@testable import OS1

struct ConnectionProfileTransportTests {
    @Test
    func legacySSHOnlyJSONDecodesIntoSSHTransport() throws {
        // Pre-port profile JSON shape — top-level sshAlias/sshHost/sshPort/sshUser, no `transport` field.
        let legacy = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "label": "Studio Mac",
          "sshAlias": "studio",
          "sshHost": "studio.local",
          "sshPort": 2222,
          "sshUser": "alex",
          "hermesProfile": "researcher",
          "createdAt": 720000000.0,
          "updatedAt": 720000000.0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: legacy)

        #expect(decoded.label == "Studio Mac")
        #expect(decoded.hermesProfile == "researcher")
        if case .ssh(let cfg) = decoded.transport {
            #expect(cfg.alias == "studio")
            #expect(cfg.host == "studio.local")
            #expect(cfg.port == 2222)
            #expect(cfg.user == "alex")
        } else {
            Issue.record("Expected SSH transport, got \(decoded.transport)")
        }
        // Pass-through accessors must agree with the underlying SSHConfig.
        #expect(decoded.sshAlias == "studio")
        #expect(decoded.sshHost == "studio.local")
        #expect(decoded.sshPort == 2222)
        #expect(decoded.sshUser == "alex")
        #expect(decoded.effectiveTarget == "studio")
    }

    @Test
    func modernRoundTripPreservesSSHTransport() throws {
        let original = ConnectionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            label: "Round Trip",
            sshAlias: "rt",
            sshHost: "rt.local",
            sshPort: 22,
            sshUser: "alice"
        ).updated()

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: encoded)

        #expect(decoded == original)
        if case .ssh(let cfg) = decoded.transport {
            #expect(cfg.alias == "rt")
            #expect(cfg.host == "rt.local")
            #expect(cfg.user == "alice")
        } else {
            Issue.record("Expected SSH transport after round-trip")
        }
    }

    @Test
    func modernRoundTripPreservesOrgoTransport() throws {
        let original = ConnectionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            label: "OS1 1",
            hermesProfile: nil,
            transport: .orgo(OrgoConfig(workspaceId: "ws-abc", computerId: "vm-xyz"))
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: encoded)

        #expect(decoded == original)
        if case .orgo(let cfg) = decoded.transport {
            #expect(cfg.workspaceId == "ws-abc")
            #expect(cfg.computerId == "vm-xyz")
        } else {
            Issue.record("Expected Orgo transport after round-trip")
        }
    }

    @Test
    func sshAccessorsAreInertOnOrgoTransport() {
        var profile = ConnectionProfile(
            label: "Orgo",
            transport: .orgo(OrgoConfig(workspaceId: "ws", computerId: "vm"))
        )

        profile.sshHost = "should-be-ignored.example"
        profile.sshUser = "ignored"

        #expect(profile.sshHost == "")
        #expect(profile.sshUser == "")
        if case .orgo(let cfg) = profile.transport {
            #expect(cfg.workspaceId == "ws")
            #expect(cfg.computerId == "vm")
        } else {
            Issue.record("Setters on SSH-shaped accessors must not switch transport kind")
        }
    }

    @Test
    func validationErrorDispatchesOnTransportKind() {
        let blankSSH = ConnectionProfile(
            label: "SSH",
            transport: .ssh(SSHConfig())
        )
        #expect(blankSSH.validationError == "Add an SSH alias or host.")

        let blankOrgo = ConnectionProfile(
            label: "Orgo",
            transport: .orgo(OrgoConfig())
        )
        #expect(blankOrgo.validationError == "Orgo workspace is required.")

        let validOrgo = ConnectionProfile(
            label: "Orgo",
            transport: .orgo(OrgoConfig(workspaceId: "ws", computerId: "vm"))
        )
        #expect(validOrgo.validationError == nil)
    }
}
