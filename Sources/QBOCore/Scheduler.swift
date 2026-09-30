import Foundation

/// Runs named jobs on intervals inside the app, with "run now" and status.
///
/// In-process on purpose: jobs that talk to QuickBooks must go through the
/// company processes this app owns (they hold the rotating tokens). The app is
/// a login item, so jobs survive reboots without launchd. Reusable for other
/// scheduled syncs on the same host.
public actor JobScheduler {
    public struct Status: Sendable, Equatable {
        public var name: String
        public var interval: TimeInterval
        public var running: Bool
        public var lastStarted: Date?
        public var lastFinished: Date?
        public var lastSummary: String?
        public var lastFailed: Bool
        public var nextRun: Date?
    }

    public struct Outcome: Sendable {
        public var summary: String
        public var failed: Bool

        public init(summary: String, failed: Bool = false) {
            self.summary = summary
            self.failed = failed
        }
    }

    private struct Job {
        let interval: TimeInterval
        let initialDelay: TimeInterval
        let body: @Sendable () async -> Outcome
        var status: Status
        var loop: Task<Void, Never>?
        var wake: CheckedContinuation<Void, Never>?
    }

    private var jobs: [String: Job] = [:]

    public init() {}

    /// Registers and starts a job. The first run is after `initialDelay`.
    public func schedule(
        _ name: String, every interval: TimeInterval, initialDelay: TimeInterval = 10,
        _ body: @escaping @Sendable () async -> Outcome
    ) {
        jobs[name]?.loop?.cancel()
        jobs[name] = Job(
            interval: interval, initialDelay: initialDelay, body: body,
            status: Status(name: name, interval: interval, running: false, lastFailed: false,
                           nextRun: Date().addingTimeInterval(initialDelay)))
        jobs[name]?.loop = Task { [weak self] in await self?.loop(name) }
    }

    /// Runs the job as soon as it's idle, instead of waiting for its turn.
    public func runNow(_ name: String) {
        guard var job = jobs[name] else { return }
        job.status.nextRun = Date()
        let wake = job.wake
        job.wake = nil
        jobs[name] = job
        wake?.resume()
    }

    public func statuses() -> [Status] {
        jobs.values.map(\.status).sorted { $0.name < $1.name }
    }

    public func status(_ name: String) -> Status? { jobs[name]?.status }

    public func stopAll() {
        for (name, job) in jobs {
            job.loop?.cancel()
            job.wake?.resume()
            jobs[name]?.wake = nil
        }
    }

    private func loop(_ name: String) async {
        while !Task.isCancelled {
            await sleepUntilDue(name)
            guard !Task.isCancelled, var job = jobs[name] else { return }
            job.status.running = true
            job.status.lastStarted = Date()
            jobs[name] = job
            let outcome = await job.body()
            guard var finished = jobs[name] else { return }
            finished.status.running = false
            finished.status.lastFinished = Date()
            finished.status.lastSummary = outcome.summary
            finished.status.lastFailed = outcome.failed
            finished.status.nextRun = Date().addingTimeInterval(finished.interval)
            jobs[name] = finished
        }
    }

    /// Sleeps until `nextRun`, waking early for `runNow`.
    private func sleepUntilDue(_ name: String) async {
        while let due = jobs[name]?.status.nextRun, due > Date(), !Task.isCancelled {
            let seconds = due.timeIntervalSinceNow
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                jobs[name]?.wake = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    await self?.wakeIfWaiting(name)
                }
            }
        }
    }

    private func wakeIfWaiting(_ name: String) {
        let wake = jobs[name]?.wake
        jobs[name]?.wake = nil
        wake?.resume()
    }
}
