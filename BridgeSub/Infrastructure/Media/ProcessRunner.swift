import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct ProcessRunResult: Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
    let elapsedTime: TimeInterval
}

struct ProcessRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 60
    ) async throws -> Data {
        try await runDetailed(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ).stdout
    }

    func runDetailed(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 60
    ) async throws -> ProcessRunResult {
        try await Task.detached(priority: .userInitiated) {
            try self.runBlocking(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }.value
    }

    private func runBlocking(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = PipeDataCollector()
        let errorCollector = PipeDataCollector()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.append(handle.availableData)
        }

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let start = Date()
        try process.run()

        var didTimeOut = false
        while process.isRunning && Date().timeIntervalSince(start) < timeout {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            didTimeOut = true
            process.terminate()
            let terminationStart = Date()
            while process.isRunning && Date().timeIntervalSince(terminationStart) < 0.5 {
                Thread.sleep(forTimeInterval: 0.05)
            }
#if canImport(Darwin)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
#endif
        }

        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputCollector.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        errorCollector.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        let stdout = outputCollector.data()
        let stderr = errorCollector.data()
        let elapsed = Date().timeIntervalSince(start)

        if didTimeOut {
            let commandName = URL(fileURLWithPath: executable).lastPathComponent
            throw WorkflowError.processTimedOut(
                "`\(commandName)` timed out after \(Self.formattedTimeout(timeout)) seconds."
            )
        }

        guard process.terminationStatus == 0 else {
            var message = String(data: stderr, encoding: .utf8) ?? ""
            if message.isEmpty {
                message = "Process exited with code \(process.terminationStatus)"
            }
            throw WorkflowError.runtime(message)
        }

        return ProcessRunResult(
            stdout: stdout,
            stderr: stderr,
            terminationStatus: process.terminationStatus,
            elapsedTime: elapsed
        )
    }

    func runText(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 60
    ) async throws -> String {
        let data = try await run(executable: executable, arguments: arguments, timeout: timeout)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkflowError.runtime("Unable to decode process output as UTF-8 text.")
        }
        return text
    }

    private static func formattedTimeout(_ timeout: TimeInterval) -> String {
        if timeout >= 1 {
            return "\(Int(timeout.rounded()))"
        }
        return String(format: "%.1f", timeout)
    }
}

private final class PipeDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
