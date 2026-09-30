import Foundation

/// How to run one company's upstream server.
public struct ChildLaunch: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// A stdio MCP server process: newline-delimited JSON-RPC on stdin/stdout,
/// diagnostics on stderr.
final class UpstreamChild: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let writeQueue = DispatchQueue(label: "qbobar.child.write")
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    init(_ launch: ChildLaunch) {
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = launch.workingDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    var pid: Int32 { process.processIdentifier }

    func start(
        onStdoutLine: @escaping @Sendable (String) -> Void,
        onStderrLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            for line in self.lines(appending: data, stderr: false) { onStdoutLine(line) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            for line in self.lines(appending: data, stderr: true) { onStderrLine(line) }
        }
        process.terminationHandler = { [weak self] process in
            self?.stdout.fileHandleForReading.readabilityHandler = nil
            self?.stderr.fileHandleForReading.readabilityHandler = nil
            onExit(process.terminationStatus)
        }
        try process.run()
    }

    /// Queues one JSON-RPC message. Writes happen off the caller's thread
    /// because a large message (an attachment upload is base64 in JSON) can
    /// block on a full pipe.
    func send(_ message: JSON) {
        var line = message.encoded()
        line.append(0x0A)
        let data = line
        let handle = stdin.fileHandleForWriting
        writeQueue.async {
            // The throwing variant: the legacy `write(_:)` raises an
            // Objective-C exception on EPIPE, which would take the app down
            // when a child dies with a message in flight.
            try? handle.write(contentsOf: data)
        }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        // Node normally exits on SIGTERM at once; make sure a wedged child
        // cannot linger holding a token chain.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func lines(appending data: Data, stderr isStderr: Bool) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var buffer = isStderr ? stderrBuffer : stdoutBuffer
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if isStderr { stderrBuffer = buffer } else { stdoutBuffer = buffer }
        return lines
    }
}
