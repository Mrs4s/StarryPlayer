import AudioProcessing
import Foundation
import StarryCore

@MainActor
final class VocalAttenuationPolicy {
    private(set) var blockingReason: VocalAttenuationStatus.Unavailable?
    var onChange: (() -> Void)?

    private let policy = ProcessingPolicy()
    private var thermalBlocked = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        evaluate()
    }

    private func evaluate() {
        let thermal: ProcessingPolicy.Thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        if thermal >= policy.disableAtThermal {
            thermalBlocked = true
        } else if thermal < policy.resumeBelowThermal {
            thermalBlocked = false
        }
        let reason: VocalAttenuationStatus.Unavailable? =
            thermalBlocked ? .thermal
            : policy.disableOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled ? .lowPowerMode
            : nil
        guard reason != blockingReason else { return }
        blockingReason = reason
        onChange?()
    }
}
