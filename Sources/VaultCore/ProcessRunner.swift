import Foundation

public struct ProcessResult: Sendable {
    public let output: Data
    public let status: Int32
}

/// Pipes only. stderr is drained but never exposed: parsers may echo a secret in an error.
public enum ProcessRunner {
    /// Runs are short; serializing them process-wide keeps one child from inheriting another's pipes.
    private static let launchLock = NSLock()

    public static func run(executable: URL, arguments: [String], input: Data = Data(),
                           environment: [String: String], directory: URL? = nil,
                           timeout: TimeInterval = 30) throws -> ProcessResult {
        launchLock.lock()
        defer { launchLock.unlock() }
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
        // Drains read whatever is available without waiting for EOF. EOF never arrives if any other
        // process (for example a helper a tool spawned) still holds the write end of the pipe.
        let output = PipeDrain(stdout.fileHandleForReading)
        let errors = PipeDrain(stderr.fileHandleForReading)
        defer { output.finish(); errors.finish() }
        do { try process.run() } catch {
            throw VaultError.message("No se pudo ejecutar SOPS. Revisá la ruta del binario en Ajustes.")
        }
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue.global().async {
            // Broken pipes throw here rather than exposing a secret or stopping the app.
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            writer.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            _ = writer.wait(timeout: .now() + 1)
            throw VaultError.message("SOPS tardó demasiado. Revisá la clave age y volvé a intentar.")
        }
        // The child has exited, so everything it wrote is already in the kernel buffer.
        _ = writer.wait(timeout: .now() + 1)
        let data = output.finish()
        return ProcessResult(output: data, status: process.terminationStatus)
    }
}

/// Non-blocking reader for one pipe. `finish()` reads what is left and stops; it never waits for EOF.
private final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle  // Owns the descriptor for the drain's lifetime.
    private let fd: Int32
    private let queue = DispatchQueue(label: "sops-vault.pipe-drain")
    private let source: DispatchSourceRead
    private var data = Data()
    private var finished = false

    init(_ handle: FileHandle) {
        self.handle = handle
        fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in
            if self.readAvailable() { self.source.cancel() }
        }
        source.resume()
    }

    /// Returns true at EOF or on a read error.
    private func readAvailable() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { data.append(contentsOf: buffer[0..<count]); continue }
            if count == 0 { return true }
            if errno == EINTR { continue }
            return errno != EAGAIN && errno != EWOULDBLOCK
        }
    }

    @discardableResult func finish() -> Data {
        queue.sync {
            if !finished {
                finished = true
                if !source.isCancelled { _ = readAvailable(); source.cancel() }
            }
            return data
        }
    }

}
