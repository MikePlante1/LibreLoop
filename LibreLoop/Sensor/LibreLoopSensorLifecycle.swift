import Foundation

/// Computed sensor lifecycle state for the FreeStyle Libre 3.
public enum LibreLoopSensorLifecycle: Equatable {
    case noSensor
    case warmup(progress: Double, remaining: TimeInterval)
    case active(remaining: TimeInterval)
    case expired
    case signalLost(since: Date)

    /// Libre 3 spec values.
    public static let warmupDuration: TimeInterval = 60 * 60          // 1 hour
    public static let activeDuration: TimeInterval = 14 * 24 * 60 * 60 // 14 days
    private static let signalLostThreshold: TimeInterval = 6 * 60      // 6 minutes without a reading

    public static func compute(
        activatedAt: Date?,
        latestReadingAt: Date?,
        hasLiveMonitor: Bool,
        now: Date = Date()
    ) -> LibreLoopSensorLifecycle {
        guard let activatedAt else { return .noSensor }
        let age = now.timeIntervalSince(activatedAt)

        if age >= activeDuration {
            return .expired
        }
        if age < warmupDuration {
            return .warmup(progress: age / warmupDuration, remaining: warmupDuration - age)
        }
        let stale = latestReadingAt.map { now.timeIntervalSince($0) > signalLostThreshold } ?? !hasLiveMonitor
        if stale {
            return .signalLost(since: latestReadingAt ?? activatedAt)
        }
        return .active(remaining: activeDuration - age)
    }

    public var displayName: String {
        switch self {
        case .noSensor:    return "No sensor"
        case .warmup:      return "Warming up"
        case .active:      return "Active"
        case .expired:     return "Expired"
        case .signalLost:  return "Signal loss"
        }
    }
}
