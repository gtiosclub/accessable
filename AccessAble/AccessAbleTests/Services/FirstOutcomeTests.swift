import Testing
@testable import AccessAble

@Suite(.timeLimit(.minutes(1)))
struct FirstOutcomeTests {
    private struct Boom: Error {}

    @Test
    func anOutcomeBeforeTheWaitResumesItAtOnce() async throws {
        let outcome = FirstOutcome<Int>()
        #expect(outcome.finish(.success(1)))
        #expect(!outcome.finish(.success(2)))

        let value = try await withCheckedThrowingContinuation { outcome.wait($0) }

        #expect(value == 1)
    }

    @Test
    func onlyTheFirstOutcomeResumes() async {
        let outcome = FirstOutcome<Int>()

        await #expect(throws: Boom.self) {
            try await withCheckedThrowingContinuation { continuation in
                outcome.wait(continuation)
                outcome.finish(.failure(Boom()))
                outcome.finish(.success(1))
            }
        }
    }

    @Test
    func theRacingTasksAreCancelledOnceOneWins() async {
        let outcome = FirstOutcome<Void>()
        let racing = Task { for await _ in AsyncStream<Never>.makeStream().stream {} }
        outcome.cancelsOnFinish(racing)

        outcome.finish(.success(()))
        await racing.value

        #expect(racing.isCancelled)
        let late = Task {}
        outcome.cancelsOnFinish(late)
        #expect(late.isCancelled)
    }
}
