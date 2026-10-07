# Homework 2: Deterministic Concurrent Task Processor

Implement a bounded concurrent task processor as an individual Swift Package
assignment. The package uses only the Swift standard library and XCTest.

The complete, grading-authoritative contract is in
[`TASKS_AND_GRADES.md`](TASKS_AND_GRADES.md). Read it before changing the
starter. Every behavior that can affect the score is published there. Private
tests may vary input values or combine published cases, but they may not add a
new rule or edge-case policy.

## Start here

1. Create your own **public** repository from this template.
2. Read `TASKS_AND_GRADES.md` and write your approach in `PLAN.md`.
3. Implement the base API in
   `Sources/TaskProcessor/TaskProcessor.swift` without changing its public
   signatures.
4. Add at least six distinct student-authored XCTest methods beyond the
   starter tests. Put them in a new test file under
   `Tests/TaskProcessorTests/`.
5. Keep `AGENT_WORKLOG.md` current and review every generated change you use.
6. Run the sole required verification command:

   ```bash
   swift test
   ```

7. Follow `SUBMISSION.md` exactly.

The untouched starter compiles, then stops in the intentional
`fatalError("Implement Homework 2")` implementation stubs. This is expected:
the visible behavior tests cannot pass until you implement the assignment.

## Repository evidence

- `PLAN.md` records your intended design, milestones, and test strategy.
- `AGENT_WORKLOG.md` records agent use (or states that no agent was used), your
  review, and the evidence behind your decisions.
- `artifacts/` may contain selected, non-sensitive exported agent-session
  evidence. Artifacts are optional and there is no minimum file count.

Do not commit secrets, credentials, build output, or private data. Keep the
repository public through the grading and appeal period.
