import XCTest
@testable import TaskProcessor

private enum SampleWorkerError: Error {
    case expected
    case workerShouldNotRun
}

private actor Gate {
    private var releasedIDs: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var waitingObservers: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var passedIDs: Set<String> = []
    private var passedObservers: [String: [CheckedContinuation<Void, Never>]] = [:]

    func wait(for id: String) async {
        if releasedIDs.remove(id) != nil {
            markPassed(id)
            return
        }

        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            let observers = waitingObservers.removeValue(forKey: id) ?? []
            for observer in observers {
                observer.resume()
            }
        }
        markPassed(id)
    }

    func waitUntilWaiting(for id: String) async {
        if waiters[id] != nil {
            return
        }

        await withCheckedContinuation { continuation in
            waitingObservers[id, default: []].append(continuation)
        }
    }

    func waitUntilPassed(_ id: String) async {
        if passedIDs.contains(id) {
            return
        }

        await withCheckedContinuation { continuation in
            passedObservers[id, default: []].append(continuation)
        }
    }

    func release(_ id: String) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume()
        } else {
            releasedIDs.insert(id)
        }
    }

    private func markPassed(_ id: String) {
        passedIDs.insert(id)
        let observers = passedObservers.removeValue(forKey: id) ?? []
        for observer in observers {
            observer.resume()
        }
    }
}

@MainActor
final class TaskProcessorPublicTests: XCTestCase {
    func testOneSuccessfulJob() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let job = Job(id: "one", input: 21)

        let results = try await processor.process([job]) { job in
            job.input * 2
        }

        XCTAssertEqual(
            results,
            [JobResult(id: "one", outcome: .succeeded(42))]
        )
    }

    func testEmptyJobListReturnsEmptyWithoutCallingWorker() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)

        let results = try await processor.process([]) { _ in
            throw SampleWorkerError.workerShouldNotRun
        }

        XCTAssertEqual(results, [])
    }

    func testOrdinaryWorkerErrorBecomesFailedOutcome() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let job = Job(id: "fails", input: 7)

        let results = try await processor.process([job]) { _ in
            throw SampleWorkerError.expected
        }

        XCTAssertEqual(
            results,
            [JobResult(id: "fails", outcome: .failed)]
        )
    }

    func testResultsKeepInputOrderWhenSecondJobPassesGateFirst() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let gate = Gate()
        let jobs = [
            Job(id: "first", input: 1),
            Job(id: "second", input: 2)
        ]

        let processing = Task {
            try await processor.process(jobs) { job in
                await gate.wait(for: job.id)
                return job.input * 10
            }
        }

        await gate.waitUntilWaiting(for: "first")
        await gate.waitUntilWaiting(for: "second")
        await gate.release("second")
        await gate.waitUntilPassed("second")
        await gate.release("first")

        let results = try await processing.value
        XCTAssertEqual(
            results,
            [
                JobResult(id: "first", outcome: .succeeded(10)),
                JobResult(id: "second", outcome: .succeeded(20))
            ]
        )
    }

    func testZeroMaximumConcurrencyIsRejected() {
        XCTAssertThrowsError(try TaskProcessor(maximumConcurrency: 0)) { error in
            XCTAssertEqual(
                error as? TaskProcessorError,
                .nonPositiveMaximumConcurrency
            )
        }
    }
}
