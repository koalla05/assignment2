import XCTest
@testable import TaskProcessor

private enum StudentWorkerError: Error {
    case boom
    case workerShouldNotRun
}

/// Records which jobs started and lets a test hold each job until it opens it.
private actor StartGate {
    private var openIDs: Set<String> = []
    private var blocked: [String: CheckedContinuation<Void, Never>] = [:]
    private var startObservers: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var startedIDs: [String] = []

    func enter(_ id: String) async {
        startedIDs.append(id)
        for observer in startObservers.removeValue(forKey: id) ?? [] {
            observer.resume()
        }
        if openIDs.contains(id) {
            return
        }
        await withCheckedContinuation { continuation in
            blocked[id] = continuation
        }
    }

    func open(_ id: String) {
        openIDs.insert(id)
        blocked.removeValue(forKey: id)?.resume()
    }

    func waitUntilStarted(_ id: String) async {
        if startedIDs.contains(id) {
            return
        }
        await withCheckedContinuation { continuation in
            startObservers[id, default: []].append(continuation)
        }
    }
}

/// Counts how many workers are inside the worker closure at the same time.
private actor ActiveCounter {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func exit() {
        current -= 1
    }
}

/// Records every worker invocation.
private actor InvocationLog {
    private(set) var ids: [String] = []

    func record(_ id: String) {
        ids.append(id)
    }
}

/// Records every (job, attempt) pair in the order workers started.
private actor AttemptLog {
    private(set) var entries: [String] = []

    func record(_ job: Job, attempt: Int) {
        entries.append("\(job.id)#\(attempt)")
    }

    func attempts(for id: String) -> [Int] {
        entries.compactMap { entry in
            let parts = entry.split(separator: "#")
            return parts[0] == id ? Int(parts[1]) : nil
        }
    }
}

@MainActor
final class TaskProcessorStudentTests: XCTestCase {
    func testNegativeMaximumConcurrencyIsRejected() {
        // Arrange
        let negativeLimit = -3

        // Act & Assert
        XCTAssertThrowsError(try TaskProcessor(maximumConcurrency: negativeLimit)) { error in
            XCTAssertEqual(
                error as? TaskProcessorError,
                .nonPositiveMaximumConcurrency
            )
        }
    }

    func testFirstRepeatedIDIsReportedAndNoWorkerRuns() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let log = InvocationLog()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "b", input: 3),
            Job(id: "a", input: 4)
        ]

        // Act
        var thrownError: Error?
        do {
            _ = try await processor.process(jobs) { job in
                await log.record(job.id)
                return job.input
            }
        } catch {
            thrownError = error
        }

        // Assert
        XCTAssertEqual(thrownError as? TaskProcessorError, .duplicateID("b"))
        let invokedIDs = await log.ids
        XCTAssertEqual(invokedIDs, [])
    }

    func testActiveWorkersNeverExceedMaximumConcurrency() async throws {
        // Arrange
        let limit = 2
        let processor = try TaskProcessor(maximumConcurrency: limit)
        let counter = ActiveCounter()
        let jobs = (1...8).map { Job(id: "job\($0)", input: $0) }

        // Act
        let results = try await processor.process(jobs) { job in
            await counter.enter()
            for _ in 0..<5 {
                await Task.yield()
            }
            await counter.exit()
            return job.input
        }

        // Assert
        let peak = await counter.peak
        XCTAssertLessThanOrEqual(peak, limit)
        XCTAssertEqual(
            results,
            jobs.map { JobResult(id: $0.id, outcome: .succeeded($0.input)) }
        )
    }

    func testProcessorFillsAllSlotsButNoMore() async throws {
        // Arrange
        let limit = 3
        let processor = try TaskProcessor(maximumConcurrency: limit)
        let gate = StartGate()
        let counter = ActiveCounter()
        let jobs = (1...6).map { Job(id: "job\($0)", input: $0) }

        // Act
        let processing = Task {
            try await processor.process(jobs) { job in
                await counter.enter()
                await gate.enter(job.id)
                await counter.exit()
                return job.input
            }
        }
        await gate.waitUntilStarted("job1")
        await gate.waitUntilStarted("job2")
        await gate.waitUntilStarted("job3")
        for _ in 0..<20 {
            await Task.yield()
        }
        let startedWhileFull = await gate.startedIDs
        for job in jobs {
            await gate.open(job.id)
        }
        let results = try await processing.value

        // Assert
        // Workers enter concurrently, so only the set of started jobs is deterministic.
        XCTAssertEqual(Set(startedWhileFull), ["job1", "job2", "job3"])
        XCTAssertEqual(startedWhileFull.count, limit)
        let peak = await counter.peak
        XCTAssertEqual(peak, limit)
        XCTAssertEqual(
            results,
            jobs.map { JobResult(id: $0.id, outcome: .succeeded($0.input)) }
        )
    }

    func testFreedSlotStartsNextUnstartedJob() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let gate = StartGate()
        await gate.open("second")
        let jobs = [
            Job(id: "first", input: 1),
            Job(id: "second", input: 2)
        ]

        // Act
        let processing = Task {
            try await processor.process(jobs) { job in
                await gate.enter(job.id)
                return job.input
            }
        }
        await gate.waitUntilStarted("first")
        let startedWhileSlotIsBusy = await gate.startedIDs
        await gate.open("first")
        let results = try await processing.value

        // Assert
        XCTAssertEqual(startedWhileSlotIsBusy, ["first"])
        let startedAfterRelease = await gate.startedIDs
        XCTAssertEqual(startedAfterRelease, ["first", "second"])
        XCTAssertEqual(
            results,
            [
                JobResult(id: "first", outcome: .succeeded(1)),
                JobResult(id: "second", outcome: .succeeded(2))
            ]
        )
    }

    func testOrdinaryErrorDoesNotStopLaterJobs() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let jobs = [
            Job(id: "before", input: 1),
            Job(id: "fails", input: 2),
            Job(id: "after", input: 3)
        ]

        // Act
        let results = try await processor.process(jobs) { job in
            if job.id == "fails" {
                throw StudentWorkerError.boom
            }
            return job.input * 100
        }

        // Assert
        XCTAssertEqual(
            results,
            [
                JobResult(id: "before", outcome: .succeeded(100)),
                JobResult(id: "fails", outcome: .failed),
                JobResult(id: "after", outcome: .succeeded(300))
            ]
        )
    }

    func testWorkerCancellationErrorBecomesCancelledAndOthersContinue() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let jobs = [
            Job(id: "ok", input: 1),
            Job(id: "cancels", input: 2),
            Job(id: "fails", input: 3),
            Job(id: "last", input: 4)
        ]

        // Act
        let results = try await processor.process(jobs) { job in
            switch job.id {
            case "cancels":
                throw CancellationError()
            case "fails":
                throw StudentWorkerError.boom
            default:
                return job.input
            }
        }

        // Assert
        XCTAssertEqual(
            results,
            [
                JobResult(id: "ok", outcome: .succeeded(1)),
                JobResult(id: "cancels", outcome: .cancelled),
                JobResult(id: "fails", outcome: .failed),
                JobResult(id: "last", outcome: .succeeded(4))
            ]
        )
    }

    func testCallerCancellationCancelsQueuedJobsWithoutStartingThem() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let gate = StartGate()
        let jobs = [
            Job(id: "running", input: 1),
            Job(id: "queued1", input: 2),
            Job(id: "queued2", input: 3)
        ]

        // Act
        let processing = Task {
            try await processor.process(jobs) { job in
                await gate.enter(job.id)
                try Task.checkCancellation()
                return job.input
            }
        }
        await gate.waitUntilStarted("running")
        processing.cancel()
        await gate.open("running")
        let results = try await processing.value

        // Assert
        let startedIDs = await gate.startedIDs
        XCTAssertEqual(startedIDs, ["running"])
        XCTAssertEqual(
            results,
            [
                JobResult(id: "running", outcome: .cancelled),
                JobResult(id: "queued1", outcome: .cancelled),
                JobResult(id: "queued2", outcome: .cancelled)
            ]
        )
    }

    func testResultCompletedBeforeCancellationIsKept() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let gate = StartGate()
        await gate.open("done")
        let jobs = [
            Job(id: "done", input: 7),
            Job(id: "interrupted", input: 8),
            Job(id: "queued", input: 9)
        ]

        // Act
        let processing = Task {
            try await processor.process(jobs) { job in
                await gate.enter(job.id)
                try Task.checkCancellation()
                return job.input
            }
        }
        await gate.waitUntilStarted("interrupted")
        processing.cancel()
        await gate.open("interrupted")
        let results = try await processing.value

        // Assert
        let startedIDs = await gate.startedIDs
        XCTAssertEqual(startedIDs, ["done", "interrupted"])
        XCTAssertEqual(
            results,
            [
                JobResult(id: "done", outcome: .succeeded(7)),
                JobResult(id: "interrupted", outcome: .cancelled),
                JobResult(id: "queued", outcome: .cancelled)
            ]
        )
    }

    func testResultsKeepInputOrderWhenJobsFinishInReverse() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let gate = StartGate()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "c", input: 3)
        ]

        // Act
        let processing = Task {
            try await processor.process(jobs) { job in
                await gate.enter(job.id)
                return job.input
            }
        }
        await gate.waitUntilStarted("a")
        await gate.waitUntilStarted("b")
        await gate.waitUntilStarted("c")
        await gate.open("c")
        await gate.open("b")
        await gate.open("a")
        let results = try await processing.value

        // Assert
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(1)),
                JobResult(id: "b", outcome: .succeeded(2)),
                JobResult(id: "c", outcome: .succeeded(3))
            ]
        )
    }

    // MARK: - Retry extension

    func testRetryPolicyRejectsNonPositiveAttempts() {
        for attempts in [0, -1] {
            XCTAssertThrowsError(try RetryPolicy(maximumAttempts: attempts)) { error in
                XCTAssertEqual(error as? RetryPolicyError, .nonPositiveMaximumAttempts)
            }
        }
        XCTAssertEqual(try RetryPolicy(maximumAttempts: 1).maximumAttempts, 1)
    }

    func testRetryStopsAfterFinalAttemptAndReportsFailed() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = AttemptLog()
        let policy = try RetryPolicy(maximumAttempts: 3)

        // Act
        let results = try await processor.process(
            [Job(id: "always-fails", input: 1)],
            retryPolicy: policy
        ) { job, attempt in
            await log.record(job, attempt: attempt)
            throw StudentWorkerError.boom
        }

        // Assert
        let attempts = await log.attempts(for: "always-fails")
        XCTAssertEqual(attempts, [1, 2, 3])
        XCTAssertEqual(results, [JobResult(id: "always-fails", outcome: .failed)])
    }

    func testRetryRecoversBeforeLimitAndStopsRetrying() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let log = AttemptLog()
        let policy = try RetryPolicy(maximumAttempts: 5)
        let jobs = [Job(id: "flaky", input: 10), Job(id: "steady", input: 20)]

        // Act
        let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
            await log.record(job, attempt: attempt)
            if job.id == "flaky" && attempt < 3 {
                throw StudentWorkerError.boom
            }
            return job.input + attempt
        }

        // Assert
        let flakyAttempts = await log.attempts(for: "flaky")
        let steadyAttempts = await log.attempts(for: "steady")
        XCTAssertEqual(flakyAttempts, [1, 2, 3])
        XCTAssertEqual(steadyAttempts, [1])
        XCTAssertEqual(
            results,
            [
                JobResult(id: "flaky", outcome: .succeeded(13)),
                JobResult(id: "steady", outcome: .succeeded(21))
            ]
        )
    }

    func testRetryNeverRetriesCancellationError() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = AttemptLog()
        let policy = try RetryPolicy(maximumAttempts: 4)

        // Act
        let results = try await processor.process(
            [Job(id: "cancels", input: 1), Job(id: "after", input: 2)],
            retryPolicy: policy
        ) { job, attempt in
            await log.record(job, attempt: attempt)
            if job.id == "cancels" {
                throw CancellationError()
            }
            return job.input
        }

        // Assert
        let attempts = await log.attempts(for: "cancels")
        XCTAssertEqual(attempts, [1])
        XCTAssertEqual(
            results,
            [
                JobResult(id: "cancels", outcome: .cancelled),
                JobResult(id: "after", outcome: .succeeded(2))
            ]
        )
    }

    func testRetryKeepsJobInItsSlotAndPreservesLimit() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = AttemptLog()
        let counter = ActiveCounter()
        let policy = try RetryPolicy(maximumAttempts: 2)
        let jobs = [Job(id: "a", input: 1), Job(id: "b", input: 2)]

        // Act
        let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
            await counter.enter()
            await log.record(job, attempt: attempt)
            await Task.yield()
            await counter.exit()
            if job.id == "a" && attempt == 1 {
                throw StudentWorkerError.boom
            }
            return job.input
        }

        // Assert: b must not start between a's first and second attempt.
        let entries = await log.entries
        XCTAssertEqual(entries, ["a#1", "a#2", "b#1"])
        let peak = await counter.peak
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(1)),
                JobResult(id: "b", outcome: .succeeded(2))
            ]
        )
    }

    func testRetryResultsKeepInputOrderWhenRetriesFinishOutOfOrder() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let gate = StartGate()
        let policy = try RetryPolicy(maximumAttempts: 2)
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "c", input: 3)
        ]

        // Act
        let processing = Task {
            try await processor.process(jobs, retryPolicy: policy) { job, attempt in
                if attempt == 1 {
                    await gate.enter(job.id)
                    throw StudentWorkerError.boom
                }
                return job.input * 10
            }
        }
        await gate.waitUntilStarted("a")
        await gate.waitUntilStarted("b")
        await gate.waitUntilStarted("c")
        await gate.open("c")
        await gate.open("b")
        await gate.open("a")
        let results = try await processing.value

        // Assert
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(10)),
                JobResult(id: "b", outcome: .succeeded(20)),
                JobResult(id: "c", outcome: .succeeded(30))
            ]
        )
    }

    func testRetryDuplicateIDThrowsBeforeAnyAttempt() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let log = AttemptLog()
        let policy = try RetryPolicy(maximumAttempts: 3)
        let jobs = [Job(id: "x", input: 1), Job(id: "y", input: 2), Job(id: "x", input: 3)]

        // Act
        var thrownError: Error?
        do {
            _ = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
                await log.record(job, attempt: attempt)
                return job.input
            }
        } catch {
            thrownError = error
        }

        // Assert
        XCTAssertEqual(thrownError as? TaskProcessorError, .duplicateID("x"))
        let entries = await log.entries
        XCTAssertEqual(entries, [])
    }

    func testRetryCallerCancellationCancelsQueuedJobs() async throws {
        // Arrange
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let gate = StartGate()
        let policy = try RetryPolicy(maximumAttempts: 3)
        let jobs = [Job(id: "running", input: 1), Job(id: "queued", input: 2)]

        // Act
        let processing = Task {
            try await processor.process(jobs, retryPolicy: policy) { job, _ in
                await gate.enter(job.id)
                try Task.checkCancellation()
                return job.input
            }
        }
        await gate.waitUntilStarted("running")
        processing.cancel()
        await gate.open("running")
        let results = try await processing.value

        // Assert
        let startedIDs = await gate.startedIDs
        XCTAssertEqual(startedIDs, ["running"])
        XCTAssertEqual(
            results,
            [
                JobResult(id: "running", outcome: .cancelled),
                JobResult(id: "queued", outcome: .cancelled)
            ]
        )
    }
}
