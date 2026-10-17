# Agent Worklog

Name the tools you used. If you used no coding agent, state that explicitly.
Do not paste secrets or an unreviewed raw transcript.

| Date | Tool / model | Task or recommendation | My review and decision | Evidence |
| --- | --- | --- | --- | --- |
| 2026-10-16 | Claude Code (Claude Sonnet 5.5) | Reviewed the repo and explained the assignment steps. | Accepted as orientation; I read TASKS_AND_GRADES.md myself. | Conversation only. |
| 2026-10-16 | Claude Code (Claude Sonnet 5.5) | Wrote PLAN.md from my own notes on scheduling, ordering, errors and unstarted jobs. | Revised: it corrected three of my assumptions. I do not need a queue, because an array plus a next-index counter schedules in order and indexed storage keeps result order. `CancellationError` is thrown by the worker, not created by the processor, and other errors map to `.failed`. Never-started jobs are marked `.cancelled` immediately on cancellation, not handled later. | PLAN.md in git. |
| 2026-10-16 | Claude Code (Claude Sonnet 5.5) | Reviewed my `init`. | Accepted: `< 0` was a bug because `0` must also throw (`<= 0`), and the limit was never stored. I applied the `guard maximumConcurrency > 0` version and the stored property. | `testZeroMaximumConcurrencyIsRejected` passes. |
| 2026-10-16 | Claude Code (Claude Sonnet 5.5) | Implemented `process`: duplicate-ID preflight, `withTaskGroup` with a next-index counter and active count, indexed `outcomes` array, a `run` helper mapping outcomes, and cancellation checks via `Task.isCancelled`. | Accepted after asking about `Set.insert(...).inserted`, `Array(repeating:count:)`, `?? .cancelled` (nil only means the job never started; a worker `CancellationError` is stored explicitly) and why `while true` terminates. Cancellation and concurrency-limit behavior are not yet covered by tests. | `swift test`: 5 starter tests pass. |
| 2026-10-17 | Claude Code (Claude Sonnet 5.5) | Checked my new `TaskProcessorStudentTests.swift` against TASKS_AND_GRADES.md and the starter tests. | Accepted: the 5 starter tests in `TaskProcessorPublicTests.swift` are unchanged (no diff against the initial commit), and I have 9 distinct student tests covering all five graded categories. | `git diff`, `swift test`: 14 tests pass. |
| 2026-10-17 | Claude Code (Claude Sonnet 5.5) | Pointed out that my peak-concurrency test only asserts `peak <= limit`, so a processor that runs one job at a time would pass. Added `testProcessorFillsAllSlotsButNoMore`. | Accepted. It found a flaw in the test, not in the processor: I first asserted the exact start order `job1, job2, job3`, but concurrent workers enter in any order, and it failed in about 1 of 10 runs. I now compare the started jobs as a set and check the count equals the limit. | 200 repeated runs of `swift test --skip-build` with no failures. |
| 2026-10-17 | Claude Code (Claude Sonnet 5.5) | Implemented the optional retry extension: `RetryPolicy`, `RetryPolicyError`, the retry `process` overload, and a refactor of the scheduling loop into a shared private `schedule` helper. Added 7 retry tests. | Accepted after reading the diff. The base `process` behaves as before and the retry overload reuses the same loop. Decision for an unlisted case: once the caller has cancelled, a retry is not started and the job is `.cancelled`; I chose this because the base rules say no new worker starts after cancellation. | `swift test`: 23 tests pass, 100 repeated runs with no failures. |

## Final review

<!-- Fill in after implementation: summarize remaining risks and confirm that
you inspected the final diff. -->
