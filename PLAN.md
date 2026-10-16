# Implementation Plan

Complete this before implementation and update it when the plan changes.

## Approach

**Validation first.** `init` throws `.nonPositiveMaximumConcurrency` if the
limit is `<= 0`. `process` scans the jobs left to right with a `Set<String>`
and throws `.duplicateID(firstRepeatedID)` on the first ID that has already
appeared, before any worker runs. Empty input returns `[]`.

**Bounded scheduling.** Jobs are already ordered in the input array, so no
separate queue is needed: a `nextIndex` counter picks the next unstarted job
left to right. Inside `withThrowingTaskGroup`, I start up to
`maximumConcurrency` child tasks. Each time one finishes, a slot is free and
I start the job at `nextIndex`. Active child tasks therefore never exceed the
limit.

**Indexed result storage.** Each child task returns `(index, outcome)`. Results
are written into an array sized to `jobs.count` at that index, so completion
order does not affect output order. The final array is built in input order
with the same IDs as `jobs`.

**Outcome mapping.** The worker may throw any error. Ii is  catched in the child
task:
- returns `n` -> `.succeeded(n)`
- throws `CancellationError` -> `.cancelled`
- throws any other error -> `.failed` (other jobs keep running)

**Cancellation.** Before starting each job (each scheduling decision) I check
`Task.isCancelled`. If the caller cancelled, we cancel the group's child work,
start nothing new, and mark every never-started job `.cancelled`. Jobs that
completed before cancellation was observed keep their success or failure
outcome. Cooperative workers that throw `CancellationError` are `.cancelled`.

## Milestones

- [ ] Validate configuration and all job IDs before starting work.
- [ ] Schedule jobs within the concurrency limit and preserve input order.
- [ ] Map success, ordinary errors, and cancellation outcomes.
- [ ] Handle caller cancellation and never-started jobs.
- [ ] Add at least six distinct student-authored tests and run `swift test`.

## Risks and checks

| Risk / edge case | How I will test it |
| --- | --- |
| Duplicate ID is not the *first* repeated one, or a worker starts before validation | Jobs like `a, b, b, a` expect `.duplicateID("b")`; a worker that records invocations must record none. |
| Active workers exceed the limit | A counter actor tracks current and peak active count across many jobs; assert peak `<= N`. |
| A freed slot is not reused | Gate the first jobs, release one, and assert the next unstarted job begins. |
| Results returned in completion order | Release gates in reverse order and assert output order equals input order. |
| `CancellationError` treated as `.failed`, or an ordinary error stops other jobs | Mix success, ordinary error and `CancellationError` workers; assert each outcome and that later jobs still run. |
| Queued jobs start after caller cancellation | Cancel the `process` task while jobs are gated; assert unstarted jobs are `.cancelled` and their workers never ran. |
| Results completed before cancellation are overwritten | Let one job finish, then cancel; assert it keeps `.succeeded`. |
| Worker that ignores cancellation | Not guaranteed by the contract (non-goal); not tested. |
