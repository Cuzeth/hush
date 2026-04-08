import Foundation
import Testing
@testable import hush

@MainActor
struct hushTests {

    @Test func timerTracksRemainingFromPersistedEndDate() async throws {
        let state = TimerState()
        let start = Date(timeIntervalSince1970: 1_000)

        state.start(duration: 120, now: start)

        #expect(state.isRunning)
        #expect(state.remainingSeconds == 120)
        #expect(state.endDate == start.addingTimeInterval(120))

        let expired = state.syncRemaining(now: start.addingTimeInterval(45))

        #expect(expired == false)
        #expect(Int(state.remainingSeconds.rounded(.down)) == 75)
        #expect(state.isRunning)
    }

    @Test func timerClearsWhenExpired() async throws {
        let state = TimerState()
        let start = Date(timeIntervalSince1970: 2_000)

        state.start(duration: 30, now: start)
        let expired = state.syncRemaining(now: start.addingTimeInterval(35))

        #expect(expired)
        #expect(state.isRunning == false)
        #expect(state.remainingSeconds == 0)
        #expect(state.endDate == nil)
    }
}
