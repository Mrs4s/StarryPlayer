import Foundation

/// Audible clock = item time − processing latency. Never run backwards between seeks;
/// hold while attenuation primes and skip ahead when its latency is removed.
public struct HeardClock: Sendable {
    private var floor: TimeInterval = 0

    public init() {}

    public mutating func reset(to time: TimeInterval) {
        floor = max(0, time)
    }

    public mutating func time(raw: TimeInterval, latency: TimeInterval) -> TimeInterval {
        let heard = max(0, raw - latency)
        guard heard >= floor else { return floor }
        floor = heard
        return heard
    }
}
