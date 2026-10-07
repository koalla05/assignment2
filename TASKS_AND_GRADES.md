# Tasks and Grades

This file is the canonical Homework 2 contract and rubric. The base assignment
is worth 12 points. The deterministic retry extension is optional and worth up
to 4 bonus points.

Every point-bearing behavior is listed below. Private tests may vary values
and combine published cases, but they may not impose an unlisted policy or
edge case.

## Required public API

Keep these names, access levels, argument labels, conformances, and return
types exactly as written:

```swift
public struct Job: Sendable, Equatable {
    public let id: String
    public let input: Int
    public init(id: String, input: Int)
}

public enum JobOutcome: Sendable, Equatable {
    case succeeded(Int)
    case failed
    case cancelled
}

public struct JobResult: Sendable, Equatable {
    public let id: String
    public let outcome: JobOutcome
    public init(id: String, outcome: JobOutcome)
}

public enum TaskProcessorError: Error, Equatable {
    case nonPositiveMaximumConcurrency
    case duplicateID(String)
}

public actor TaskProcessor {
    public init(maximumConcurrency: Int) throws

    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult]
}
```

The injected worker is the work performed for each job. The concurrency limit
is per `process` invocation. Grading covers one invocation at a time; behavior
of overlapping calls on the same processor instance is not graded.

## Base acceptance matrix

The word “cancelled” means Swift structured-concurrency cancellation; there is
no separate processor cancellation method.

| Situation | Required result |
| --- | --- |
| `maximumConcurrency <= 0` | `init` throws `.nonPositiveMaximumConcurrency`. |
| Repeated job ID | `process` throws `.duplicateID(firstRepeatedID)` before invoking any worker. "First" means the first job in input order whose ID has appeared earlier. |
| Empty jobs | Returns `[]` and invokes no worker. |
| Valid jobs | Invokes no more than `maximumConcurrency` workers at once. A slot made free by a completed job may start the next unstarted job. |
| Worker returns an integer | Matching job has `.succeeded(returnedInteger)`. |
| Worker throws an ordinary error | Matching job has `.failed`; the processor continues with other jobs. |
| Worker throws `CancellationError` | Matching job has `.cancelled`; the processor continues unless its own task is cancelled. |
| Input ordering | The returned array has exactly one result per started or accounted-for input job, in the same order and with the same IDs as `jobs`, regardless of completion order. |
| Caller cancels `process` | At the next scheduling decision, the processor observes cancellation, cancels its child work, starts no new worker, and records every never-started job as `.cancelled`. Cooperative workers that then throw `CancellationError` have `.cancelled` results. Results that completed before cancellation was observed keep their completed success or failure outcome. |

Duplicate-ID validation is a preflight check: scan from left to right and do
not invoke any worker if a duplicate exists. Input-order scheduling means the
initial bounded set and every replacement job are chosen from left to right.

## Base grading: 12 points

Each category is worth 2 points and is evaluated automatically against the
published contract.

| Category | Points | Automatic evidence |
| --- | ---: | --- |
| Configuration and input validation | 2 | Non-positive capacity and first duplicate ID, including proof that no worker began. |
| Bounded scheduling | 2 | Gate/probe cases show the active count never exceeds the declared maximum and later jobs start when a slot is released. |
| Stable result ordering | 2 | Controlled out-of-order completions still return input-order IDs and outcomes. |
| Outcome handling | 2 | Success, ordinary error, and `CancellationError` map to the required outcome while unaffected work continues. |
| Cooperative cancellation | 2 | After cancellation is observed, no queued job starts and queued/cooperatively cancelled work has the required outcomes. |
| Student tests and submission evidence | 2 | At least six distinct student-authored XCTest methods beyond the starter tests; completed `PLAN.md` and `AGENT_WORKLOG.md`; valid submission metadata. Files in `artifacts/` are optional and have no minimum count. |

For the student-test check, only distinct XCTest test methods in student-owned
test case source count. Comments, string literals, renamed/copied starter test
methods, and non-test helper methods do not count.

## Optional extension: deterministic retry policy (+4)

Bonus is not required for a 12/12 base score. Bonus grading is enabled only
when the first four base categories—configuration/input validation, bounded
scheduling, stable result ordering, and outcome handling—earn all 8 available
points.

To opt in, add this API without changing the base API:

```swift
public struct RetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int
    public init(maximumAttempts: Int) throws
}

public enum RetryPolicyError: Error, Equatable {
    case nonPositiveMaximumAttempts
}

public extension TaskProcessor {
    func process(
        _ jobs: [Job],
        retryPolicy: RetryPolicy,
        worker: @escaping @Sendable (Job, Int) async throws -> Int
    ) async throws -> [JobResult]
}
```

All bonus rules are explicit:

- `maximumAttempts <= 0` throws `.nonPositiveMaximumAttempts`.
- Attempt numbers start at 1. An ordinary worker error is retried until a
  success or the final allowed attempt; the final ordinary error yields
  `.failed`.
- `CancellationError` is never retried and yields `.cancelled`.
- Attempts for one job are sequential. A retry remains part of that job's one
  concurrency slot; it never creates an extra active job.
- There is no delay, backoff, jitter, randomness, or retry of validation
  errors.
- Input-order output and every base cancellation rule still apply.

Bonus tests use deterministic attempt-counting workers. They check validation,
exact attempt numbers, recovery before the limit, final failure, cancellation,
ordering, and preservation of the job-level concurrency limit.

## Non-goals

The base processor does not:

- retry work or impose a timeout;
- guarantee completion of a worker that ignores cancellation;
- normalize job IDs;
- expose progress through another API;
- promise fairness beyond input-order scheduling; or
- define graded behavior for overlapping calls on one processor instance.

The homework requires no UI, network call, persistence layer, app extension,
platform framework, printed trace, random input, elapsed-time assertion,
intentional data race, GCD, or lock. It is individual work: no pair/group
submission, shared repository, or peer-review requirement applies.
