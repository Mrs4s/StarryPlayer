import Foundation

public struct ProcessingPolicy: Sendable {
    public enum Thermal: Int, Sendable, Comparable {
        case nominal, fair, serious, critical
        public static func < (lhs: Thermal, rhs: Thermal) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var disableAtThermal: Thermal = .serious
    public var resumeBelowThermal: Thermal = .fair
    public var disableOnLowPower = true
    public var overrunBudget: Double = 0.75
    public var overrunLimit = 5
    public var overrunWindow: TimeInterval = 1

    public init() {}
}

public struct OverrunCounter: Sendable {
    private var stamps: [TimeInterval] = []
    public var policy: ProcessingPolicy

    public init(policy: ProcessingPolicy = ProcessingPolicy()) {
        self.policy = policy
        // `record` runs on the audio thread; keep it from allocating.
        stamps.reserveCapacity(max(policy.overrunLimit, 1) * 2)
    }

    public mutating func record(blockDuration: TimeInterval, elapsed: TimeInterval, now: TimeInterval) -> Bool {
        stamps.removeAll { now - $0 > policy.overrunWindow }
        guard elapsed > blockDuration * policy.overrunBudget else { return false }
        stamps.append(now)
        return stamps.count >= policy.overrunLimit
    }

    public mutating func reset() { stamps.removeAll() }
}
