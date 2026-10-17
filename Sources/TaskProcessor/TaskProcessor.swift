public struct Job: Sendable, Equatable {
    public let id: String
    public let input: Int

    public init(id: String, input: Int) {
        self.id = id
        self.input = input
    }
}

public enum JobOutcome: Sendable, Equatable {
    case succeeded(Int)
    case failed
    case cancelled
}

public struct JobResult: Sendable, Equatable {
    public let id: String
    public let outcome: JobOutcome

    public init(id: String, outcome: JobOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

public enum TaskProcessorError: Error, Equatable {
    case nonPositiveMaximumConcurrency
    case duplicateID(String)
}

public actor TaskProcessor {
    private let maximumConcurrency: Int

    public init(maximumConcurrency: Int) throws {
        guard maximumConcurrency > 0 else {
            throw TaskProcessorError.nonPositiveMaximumConcurrency
        }
        self.maximumConcurrency = maximumConcurrency
    }

    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        try await schedule(jobs) { job in
            await Self.run(job, with: worker)
        }
    }

    /// Shared scheduling: validation, bounded concurrency, input-order results
    /// and cancellation. `execute` produces the final outcome of one job.
    fileprivate func schedule(
        _ jobs: [Job],
        execute: @escaping @Sendable (Job) async -> JobOutcome
    ) async throws -> [JobResult] {
        var seenIDs = Set<String>()
        for job in jobs {
            if !seenIDs.insert(job.id).inserted {
                throw TaskProcessorError.duplicateID(job.id)
            }
        }

        if jobs.isEmpty {
            return []
        }

        let limit = maximumConcurrency
        var outcomes = [JobOutcome?](repeating: nil, count: jobs.count)

        await withTaskGroup(of: (Int, JobOutcome).self) { group in
            var nextIndex = 0
            var active = 0

            while true {
                if Task.isCancelled {
                    group.cancelAll()
                }

                // Fill free slots from left to right, unless cancelled.
                while active < limit, nextIndex < jobs.count, !Task.isCancelled {
                    let index = nextIndex
                    let job = jobs[index]
                    group.addTask {
                        (index, await execute(job))
                    }
                    nextIndex += 1
                    active += 1
                }

                guard active > 0, let (index, outcome) = await group.next() else {
                    break
                }
                outcomes[index] = outcome
                active -= 1
            }
        }

        // Jobs that never started have no outcome: they are cancelled.
        return jobs.indices.map { index in
            JobResult(id: jobs[index].id, outcome: outcomes[index] ?? .cancelled)
        }
    }

    private static func run(
        _ job: Job,
        with worker: @Sendable (Job) async throws -> Int
    ) async -> JobOutcome {
        do {
            return .succeeded(try await worker(job))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
    }
}

public struct RetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int

    public init(maximumAttempts: Int) throws {
        guard maximumAttempts > 0 else {
            throw RetryPolicyError.nonPositiveMaximumAttempts
        }
        self.maximumAttempts = maximumAttempts
    }
}

public enum RetryPolicyError: Error, Equatable {
    case nonPositiveMaximumAttempts
}

public extension TaskProcessor {
    func process(
        _ jobs: [Job],
        retryPolicy: RetryPolicy,
        worker: @escaping @Sendable (Job, Int) async throws -> Int
    ) async throws -> [JobResult] {
        let maximumAttempts = retryPolicy.maximumAttempts
        return try await schedule(jobs) { job in
            // Attempts run one after another inside the job's single slot.
            for attempt in 1...maximumAttempts {
                // A retry is a new worker start, so it is not allowed once cancelled.
                if Task.isCancelled && attempt > 1 {
                    return .cancelled
                }
                do {
                    return .succeeded(try await worker(job, attempt))
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    continue
                }
            }
            return .failed
        }
    }
}
