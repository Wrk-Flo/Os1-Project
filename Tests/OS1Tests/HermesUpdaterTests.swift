import Foundation
import Testing
@testable import OS1

/// Mirrors OrgoHermesInstallerTests: validates the Python source emitted
/// by HermesUpdater parses cleanly via `python3 -c "import ast;
/// ast.parse(...)"`. Catches quoting / escape regressions before they
/// hit a real VM.
struct HermesUpdaterTests {
    @Test
    func generatedAvailabilityScriptParsesAsValidPython() throws {
        let script = HermesUpdater.makeAvailabilityScript()
        try assertPythonParses(script)
    }

    @Test
    func generatedUpdateScriptParsesAsValidPython() throws {
        let script = HermesUpdater.makeUpdateScript()
        try assertPythonParses(script)
    }

    @Test
    func availabilityScriptReferencesExpectedHermesEntrypoints() {
        let script = HermesUpdater.makeAvailabilityScript()
        // Spot-check that the script invokes the right CLI surfaces — if
        // someone refactors away `hermes version` or `hermes update --check`
        // the test fails before a release ships a broken probe.
        #expect(script.contains("\"version\""))
        #expect(script.contains("\"update\", \"--check\""))
        #expect(script.contains(".update_check"))
    }

    @Test
    func updateScriptRunsBackupVariant() {
        let script = HermesUpdater.makeUpdateScript()
        // --backup is non-negotiable: dropping it removes the rollback
        // path the upstream docs document. Locking it in via test.
        #expect(script.contains("\"update\", \"--backup\""))
        #expect(script.contains("update.log"))
    }

    private func assertPythonParses(
        _ script: String,
        comment: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import ast, sys; ast.parse(sys.stdin.read())"]

        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let stderrData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let label = comment.map { "\($0). " } ?? ""
        #expect(
            process.terminationStatus == 0,
            "\(label)Python parse failed: \(stderrText)",
            sourceLocation: sourceLocation
        )
    }
}
