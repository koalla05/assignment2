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
    public init(maximumConcurrency: Int) throws {
        fatalError("Implement Homework 2")
    }

    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        fatalError("Implement Homework 2")
    }
}
