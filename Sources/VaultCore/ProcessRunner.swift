import Foundation

public struct ProcessResult: Sendable {
    public let output: Data
    public let status: Int32
}

/// Pipes only. stderr is drained but never exposed: parsers may echo a secret in an error.
public enum ProcessRunner {
    public static func run(executable: URL, arguments: [String], input: Data = Data(),
                           environment: [String: String], directory: URL? = nil,
                           timeout: TimeInterval = 30) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            throw VaultError.message("No se pudo ejecutar SOPS. Revisá la ruta del binario en Ajustes.")
        }
        let reader = OutputBuffer()
        let io = DispatchGroup()
        io.enter()
        DispatchQueue.global().async {
            reader.set(stdout.fileHandleForReading.readDataToEndOfFile())
            io.leave()
        }
        io.enter()
        DispatchQueue.global().async {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            io.leave()
        }
        io.enter()
        DispatchQueue.global().async {
            // Broken pipes throw here rather than exposing a secret or stopping the app.
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            io.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            io.wait()
            throw VaultError.message("SOPS tardó demasiado. Revisá la clave age y volvé a intentar.")
        }
        io.wait()
        return ProcessResult(output: reader.get(), status: process.terminationStatus)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func set(_ data: Data) { lock.lock(); defer { lock.unlock() }; value = data }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}
