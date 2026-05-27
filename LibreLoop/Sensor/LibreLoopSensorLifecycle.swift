import Foundation

/// Computed sensor lifecycle state for the FreeStyle Libre 3.
public enum LibreLoopSensorLifecycle: Equatable {
    case noSensor
    /// Sensor is paired but we haven't received the first glucose reading
    /// yet, so we can't compute activatedAt or lifecycle phase. Cleared as
    /// soon as the first sample arrives.
    case initializing
    /// Time-bounded initial warmup, immediately after sensor activation
    /// (first 60 min). We know the remaining time precisely.
    case warmup(progress: Double, remaining: TimeInterval)
    /// Switch-receiver / post-pair stabilization. The sensor flags readings
    /// not-actionable for a duration we can't predict precisely yet, so we
    /// anchor display on time since pair rather than a fake countdown.
    case pairingWarmup(pairedAt: Date)
    /// remaining: time left until expiry; total: sensor's full rated wear duration
    case active(remaining: TimeInterval, total: TimeInterval)
    case expired
    case signalLost(since: Date)

    /// Libre 3 spec default wear duration (14 days). Used when the sensor
    /// has not yet reported its own duration (e.g. legacy persisted state).
    public static let activeDuration: TimeInterval = 14 * 24 * 60 * 60
    /// Spec warmup duration (60 min). The Libre 3 family does not report
    /// a sensor-specific warmup duration; this constant applies to all variants.
    public static let warmupDuration: TimeInterval = 60 * 60
    private static let signalLostThreshold: TimeInterval = 6 * 60      // 6 minutes without a reading

    public static func compute(
        sensorPaired: Bool,
        activatedAt: Date?,
        latestReadingAt: Date?,
        firstActionableReadingAt: Date?,
        lastPairedAt: Date?,
        hasLiveMonitor: Bool,
        wearDurationMinutes: Int? = nil,
        now: Date = Date()
    ) -> LibreLoopSensorLifecycle {
        guard sensorPaired else { return .noSensor }
        guard let activatedAt else { return .initializing }
        let age = now.timeIntervalSince(activatedAt)

        let sensorWearDuration: TimeInterval = wearDurationMinutes
            .map { TimeInterval($0) * 60 }
            ?? activeDuration

        if age >= sensorWearDuration {
            return .expired
        }
        // True initial warmup -- first hour after sensor activation. We
        // know the remaining time exactly.
        if age < warmupDuration {
            return .warmup(progress: age / warmupDuration, remaining: warmupDuration - age)
        }
        // Switch-receiver re-arms a sensor-side stabilization window the
        // library doesn't yet expose a duration for. Show time since pair
        // and let the actionable-flag transition end this state. When we
        // don't have a recorded pair time (state was deserialized from an
        // older build), pass `now` and let the UI suppress the duration.
        if firstActionableReadingAt == nil {
            return .pairingWarmup(pairedAt: lastPairedAt ?? now)
        }
        let stale = latestReadingAt.map { now.timeIntervalSince($0) > signalLostThreshold } ?? !hasLiveMonitor
        if stale {
            return .signalLost(since: latestReadingAt ?? activatedAt)
        }
        return .active(remaining: sensorWearDuration - age, total: sensorWearDuration)
    }

    public var displayName: String {
        switch self {
        case .noSensor:       return "No sensor"
        case .initializing:   return "Initializing"
        case .warmup:         return "Warming up"
        case .pairingWarmup:  return "Warming up"
        case .active:         return "Active"
        case .expired:        return "Expired"
        case .signalLost:     return "Signal loss"
        }
    }
}
