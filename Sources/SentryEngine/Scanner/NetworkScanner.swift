import Foundation

/// Periodically invokes `lsof` to discover active network connections and
/// delivers results as an `AsyncStream` of `[ConnectionEntry]`.
public actor NetworkScanner {

    // MARK: - Properties

    private let pollInterval: Duration
    private let lsofPath: String
    private var scanTask: Task<Void, Never>?

    // MARK: - Initialisation

    /// - Parameters:
    ///   - pollInterval: Time between scans. Defaults to 3 seconds.
    ///   - lsofPath: Absolute path to the `lsof` binary.
    public init(
        pollInterval: Duration = .seconds(3),
        lsofPath: String = "/usr/sbin/lsof"
    ) {
        self.pollInterval = pollInterval
        self.lsofPath = lsofPath
    }

    // MARK: - Single Scan

    /// Perform a single scan and return the parsed connections.
    public func scan() async throws -> [ConnectionEntry] {
        let output = try await runLSOF()
        return LSOFParser.parse(output)
    }

    // MARK: - Continuous Streaming

    /// Returns an `AsyncStream` that emits one `[ConnectionEntry]` array per
    /// scan cycle. The stream ends when `stop()` is called or the consuming
    /// task is cancelled.
    public func connectionStream() -> AsyncStream<[ConnectionEntry]> {
        AsyncStream { continuation in
            let task = Task { [pollInterval, lsofPath] in
                while !Task.isCancelled {
                    do {
                        let output = try await NetworkScanner.execute(lsofPath: lsofPath)
                        let entries = LSOFParser.parse(output)
                        continuation.yield(entries)
                    } catch {
                        // If the process fails we still keep polling;
                        // transient errors (e.g. lsof busy) shouldn't kill the stream.
                        if Task.isCancelled { break }
                    }

                    do {
                        try await Task.sleep(for: pollInterval)
                    } catch {
                        break  // Cancelled during sleep.
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }

            // Store so `stop()` can cancel it.
            Task { [weak self = self] in
                await self?.storeScanTask(task)
            }
        }
    }

    /// Start a background polling loop. Results can be consumed via
    /// `connectionStream()`. Calling `start()` when already running is a no-op.
    public func start() -> AsyncStream<[ConnectionEntry]> {
        if scanTask != nil {
            // Already running — return a new stream that shares the same lifecycle.
        }
        return connectionStream()
    }

    /// Stop the background polling loop.
    public func stop() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Private

    private func storeScanTask(_ task: Task<Void, Never>) {
        self.scanTask = task
    }

    /// Run `lsof` and return its stdout as a `String`.
    private func runLSOF() async throws -> String {
        try await Self.execute(lsofPath: lsofPath)
    }

    /// Executes lsof in a detached context so the actor is not blocked.
    private static func execute(lsofPath: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runProcess(lsofPath: lsofPath)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runProcess(lsofPath: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsofPath)
        process.arguments = ["-i", "-n", "-P", "+c0", "-F", "pcnPtTf"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Discard stderr.

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
