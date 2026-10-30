import Testing
@testable import PlaybackEngine

@Suite struct HeardClockTests {
    @Test func holdsWhenLatencyAppears() {
        var clock = HeardClock()
        #expect(clock.time(raw: 10, latency: 0) == 10)
        #expect(clock.time(raw: 10.1, latency: 0.5) == 10)
        #expect(clock.time(raw: 10.4, latency: 0.5) == 10)
        #expect(abs(clock.time(raw: 10.7, latency: 0.5) - 10.2) < 1e-9)
        #expect(abs(clock.time(raw: 10.8, latency: 0) - 10.8) < 1e-9)
    }

    @Test func seekResetsTheFloor() {
        var clock = HeardClock()
        _ = clock.time(raw: 60, latency: 0.1)
        clock.reset(to: 20)
        #expect(clock.time(raw: 20, latency: 0.1) == 20)
        #expect(abs(clock.time(raw: 20.3, latency: 0.1) - 20.2) < 1e-9)
    }
}
