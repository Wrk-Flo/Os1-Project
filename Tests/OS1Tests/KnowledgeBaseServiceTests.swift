import Foundation
import Testing
@testable import OS1

private final class ExecutingPythonTransport: RemoteTransport, @unchecked Sendable {
    let home: URL

    init(home: URL) {
        self.home = home
    }

    func execute(
        on connection: ConnectionProfile,
        remoteCommand: String,
        standardInput: Data?,
        allocateTTY: Bool
    ) async throws -> RemoteCommandResult {
        throw RemoteTransportError.localFailure("ExecutingPythonTransport only supports executeJSON in tests.")
    }

    func executeJSON<Response: Decodable>(
        on connection: ConnectionProfile,
        pythonScript: String,
        responseType: Response.Type
    ) async throws -> Response {
        let scriptURL = home.appendingPathComponent("script-\(UUID().uuidString).py")
        try pythonScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path]
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let outputText = String(data: outputData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw RemoteTransportError.remoteFailure("Python failed: \(errorText)\n\(outputText)")
        }

        do {
            return try JSONDecoder().decode(Response.self, from: outputData)
        } catch {
            throw RemoteTransportError.invalidResponse("Failed to decode JSON: \(error.localizedDescription)\n\(outputText)")
        }
    }
}

struct KnowledgeBaseServiceTests {
    @Test
    func loadVaultTreatsNonEmptyKnowledgeFolderWithoutManifestAsMountedVault() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-kb-test-\(UUID().uuidString)", isDirectory: true)
        let hermesHome = home.appendingPathComponent(".hermes", isDirectory: true)
        let knowledge = hermesHome.appendingPathComponent("knowledge", isDirectory: true)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try "# Seeded note\n".write(
            to: knowledge.appendingPathComponent("seed.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = KnowledgeBaseService(transport: ExecutingPythonTransport(home: home))
        let response = try await service.loadVault(connection: ConnectionProfile(label: "Local"))

        let vault = try #require(response.vault)
        #expect(vault.manifest.name == "Hermes Knowledge Base")
        #expect(vault.manifest.fileCount == 1)
        #expect(vault.manifest.totalBytes > 0)
        #expect(vault.rootPath == "~/.hermes/knowledge")
        #expect(response.skillInstalled == false)
    }
}
