import Foundation
import Testing
@testable import OS1

struct OrgoHermesInstallerTests {
    /// Pipes the generated Python source through `python3 -c "import ast; ast.parse(...)"`
    /// to confirm it parses cleanly. Catches the previous regression where
    /// quoting the URL into the bash command produced unbalanced double
    /// quotes and broke the install on first use.
    @Test
    func generatedInstallScriptParsesAsValidPython() throws {
        let url = "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
        let script = OrgoHermesInstaller.makeInstallScript(installScriptURL: url)

        try assertPythonParses(script)
    }

    /// Edge cases that would have broken the old quoting strategy.
    @Test
    func generatedScriptParsesEvenWithUnusualURLs() throws {
        let cases = [
            "https://example.com/with-quote\"inside.sh",
            "https://example.com/with'apostrophe.sh",
            "https://example.com/with backslash\\inside.sh",
            "https://example.com/with$dollar/sign.sh",
            "https://example.com/with`backtick`.sh",
        ]

        for url in cases {
            let script = OrgoHermesInstaller.makeInstallScript(installScriptURL: url)
            try assertPythonParses(script, comment: "URL: \(url)")
        }
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
