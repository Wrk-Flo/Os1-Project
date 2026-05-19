import Foundation

struct HermesRuntimeProcessRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]?
    let workingDirectoryURL: URL?
    let timeoutSeconds: TimeInterval?

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectoryURL: URL? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.timeoutSeconds = timeoutSeconds
    }
}

struct HermesRuntimeProcessResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol HermesRuntimeProcessRunning: Sendable {
    func run(_ request: HermesRuntimeProcessRequest) async throws -> HermesRuntimeProcessResult
}

enum HermesRuntimeProcessError: LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut(executablePath: String, timeoutSeconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return message
        case .timedOut(let executablePath, let timeoutSeconds):
            return "\(executablePath) timed out after \(Int(timeoutSeconds))s."
        }
    }
}

final class HermesRuntimeProcessRunner: HermesRuntimeProcessRunning, @unchecked Sendable {
    private let outputLimitBytes: Int

    init(outputLimitBytes: Int = 128 * 1024) {
        self.outputLimitBytes = outputLimitBytes
    }

    func run(_ request: HermesRuntimeProcessRequest) async throws -> HermesRuntimeProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let outputLimitBytes = outputLimitBytes
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try Self.runBlocking(request, outputLimitBytes: outputLimitBytes)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(
        _ request: HermesRuntimeProcessRequest,
        outputLimitBytes: Int
    ) throws -> HermesRuntimeProcessResult {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.workingDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutBuffer = HermesRuntimeProcessOutputBuffer(limit: outputLimitBytes)
        let stderrBuffer = HermesRuntimeProcessOutputBuffer(limit: outputLimitBytes)

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
        }

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw HermesRuntimeProcessError.launchFailed(error.localizedDescription)
        }

        let waitResult: DispatchTimeoutResult
        if let timeoutSeconds = request.timeoutSeconds {
            waitResult = completion.wait(timeout: .now() + timeoutSeconds)
        } else {
            waitResult = completion.wait(timeout: .distantFuture)
        }

        if case .timedOut = waitResult {
            if process.isRunning {
                process.terminate()
                _ = completion.wait(timeout: .now() + 2)
            }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw HermesRuntimeProcessError.timedOut(
                executablePath: request.executableURL.path,
                timeoutSeconds: request.timeoutSeconds ?? 0
            )
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        if let remaining = try? stdout.fileHandleForReading.readToEnd() {
            stdoutBuffer.append(remaining)
        }
        if let remaining = try? stderr.fileHandleForReading.readToEnd() {
            stderrBuffer.append(remaining)
        }

        return HermesRuntimeProcessResult(
            stdout: stdoutBuffer.stringValue(),
            stderr: stderrBuffer.stringValue(),
            exitCode: process.terminationStatus
        )
    }
}

private final class HermesRuntimeProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
    }

    func stringValue() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
