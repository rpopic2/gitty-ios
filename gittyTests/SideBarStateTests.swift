import CoreGraphics
import Testing
@testable import gitty

@MainActor
struct SideBarStateTests {
    private func state(reveal: CGFloat = 0) -> SideBarState {
        let state = SideBarState()
        state.width = 300
        state.reveal = reveal
        return state
    }

    @Test func trackingStaysWithinTheSidebar() {
        let state = state()
        state.track(-20)
        #expect(state.reveal == 0)
        state.track(120)
        #expect(state.reveal == 120)
        #expect(state.isOpen)
        state.track(500)
        #expect(state.reveal == 300)
    }

    @Test func aSlowReleaseGoesToTheNearerSide() {
        let past = state(reveal: 200)
        past.settle(velocity: 0)
        #expect(past.reveal == 300)

        let short = state(reveal: 100)
        short.settle(velocity: 0)
        #expect(short.reveal == 0)
        #expect(!short.isOpen)
    }

    @Test func aFlingWins() {
        let flungOpen = state(reveal: 40)
        flungOpen.settle(velocity: 900)
        #expect(flungOpen.reveal == 300)

        let flungShut = state(reveal: 260)
        flungShut.settle(velocity: -900)
        #expect(flungShut.reveal == 0)
    }
}
