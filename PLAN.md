# Implementation Plan

Complete this before implementation and update it when the plan changes.

## Approach

**Validation first.** `init` throws `.nonPositiveMaximumConcurrency` if the
limit is `<= 0`. `process` scans the jobs left to right with a `Set<String>`
and throws `.duplicateID(firstRepeatedID)` on the first ID that has already
appeared, before any worker runs. Empty input returns `[]`.

**Bounded scheduling.** Jobs are already ordered in the input array, so no
separate queue is needed: a `nextIndex` counter picks the next unstarted job
left to right. Inside a task group, I start up to
`maximumConcurrency` child tasks (a non-throwing `withTaskGroup`, because the
worker's errors are caught inside each child task). Each time one finishes, a slot is free and
I start the job at `nextIndex`. Active child tasks therefore never exceed the
limit.

**Indexed result storage.** Each child task returns `(index, outcome)`. Results
are written into an array sized to `jobs.count` at that index, so completion
order does not affect output order. The final array is built in input order
with the same IDs as `jobs`.

**Outcome mapping.** The worker may throw any error. It is caught in the child
task:
- returns `n` -> `.succeeded(n)`
- throws `CancellationError` -> `.cancelled`
- throws any other error -> `.failed` (other jobs keep running)

**Cancellation.** Before starting each job (each scheduling decision) I check
`Task.isCancelled`. If the caller cancelled, we cancel the group's child work,
start nothing new, and mark every never-started job `.cancelled`. Jobs that
completed before cancellation was observed keep their success or failure
outcome. Cooperative workers that throw `CancellationError` are `.cancelled`.

## Bonus: retry policy

The base scheduling loop moved into a private `schedule(_:execute:)` helper
that takes a closure producing one job's final outcome. The base `process`
passes the single-attempt mapping; the retry overload passes a loop over
attempts `1...maximumAttempts`, so both share validation, the concurrency
limit, input-order results and cancellation. The attempts run sequentially
inside one child task, so a retry stays in the job's slot. An ordinary error is
retried until the last attempt, then `.failed`. `CancellationError` returns
`.cancelled` at once. A retry is not started once the caller has cancelled
(the job becomes `.cancelled`), because starting it would be a new worker start.
`RetryPolicy.init` throws `.nonPositiveMaximumAttempts` for `<= 0`.

## Milestones

- [x] Validate configuration and all job IDs before starting work.
- [x] Schedule jobs within the concurrency limit and preserve input order.
- [x] Map success, ordinary errors, and cancellation outcomes.
- [x] Handle caller cancellation and never-started jobs.
- [x] Add at least six distinct student-authored tests and run `swift test`.
- [x] Bonus: `RetryPolicy`, `RetryPolicyError` and the retry `process` overload, with tests.

## Risks and checks

| Risk / edge case | How I will test it |
| --- | --- |
| Duplicate ID is not the *first* repeated one, or a worker starts before validation | Jobs like `a, b, b, a` expect `.duplicateID("b")`; a worker that records invocations must record none. |
| Active workers exceed the limit | A counter actor tracks current and peak active count across many jobs; assert peak `<= N`. |
| Processor under-uses the limit (e.g. runs one job at a time) | Gate `N` jobs out of `2N`; wait until `N` have started, assert exactly `N` started and peak `== N`. Compare started IDs as a set, since concurrent workers enter in any order. |
| A freed slot is not reused | Gate the first jobs, release one, and assert the next unstarted job begins. |
| Results returned in completion order | Release gates in reverse order and assert output order equals input order. |
| `CancellationError` treated as `.failed`, or an ordinary error stops other jobs | Mix success, ordinary error and `CancellationError` workers; assert each outcome and that later jobs still run. |
| Queued jobs start after caller cancellation | Cancel the `process` task while jobs are gated; assert unstarted jobs are `.cancelled` and their workers never ran. |
| Results completed before cancellation are overwritten | Let one job finish, then cancel; assert it keeps `.succeeded`. |
| Retry attempt numbers wrong, or retries exceed the limit | `AttemptLog` records `job#attempt`; assert `[1, 2, 3]` for a failing job, recovery on attempt 3, and with limit 1 that `b` starts only after `a#2`. |
| `CancellationError` retried | Worker throws it on attempt 1; assert only attempt 1 ran and the outcome is `.cancelled`. |
| Worker that ignores cancellation | Not guaranteed by the contract (non-goal); not tested. |
