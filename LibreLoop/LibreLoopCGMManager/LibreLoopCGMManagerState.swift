import Foundation

public struct LibreLoopCGMManagerState: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public var receiverID: Data?
    public var sensorSerial: String?
    public var bleAddress: String?
    /// The BLE PIN the sensor returned with the last activation/switch-receiver
    /// response. Each successful A8 *changes* this value, so it must be
    /// persisted the moment NFC succeeds (before BLE auth is attempted).
    /// Losing this PIN means the sensor can't be authenticated again without
    /// another A8, which would burn yet another PIN.
    public var blePIN: Data?
    /// CBPeripheral.identifier captured at pair time. Reconnect uses this to
    /// match the right discovery instead of accepting any nearby sensor.
    public var peripheralID: UUID?
    public var activatedAt: Date?
    public var latestReadingTimestamp: Date?
    /// Timestamp of the first reading the sensor flagged as actionable for
    /// the current receiver. Switch-receiver puts the sensor into a
    /// stabilization window during which every reading comes through with
    /// `actionability == .notActionable`; using this as the lifecycle-bar
    /// "warmup complete" signal is more reliable than wall-clock heuristics.
    public var firstActionableReadingAt: Date?
    /// Set on successful pairing (fresh or switch-receiver). Anchors the
    /// "time elapsed since pair" display while we're warming up, since we
    /// don't have a reliable sensor-side warmup-remaining signal yet.
    public var lastPairedAt: Date?
    /// Last `lifeCount` we have a backfilled glucose sample for. On each
    /// reconnect we request `historicalBackfillGreaterEqual(this+1)` to
    /// pull only the missed window; nil = first session, request from 0.
    public var lastHistoricalLifeCount: UInt16?
    /// Most-recent realtime sample, persisted so the Last Reading card
    /// stays populated across app kills until the next BLE notification
    /// arrives. Loop's own glucose store is the source of truth for
    /// long-term history; this is purely for UI continuity.
    public var latestSample: LibreLoopGlucoseSample?
    /// Short tail of recent realtime samples, capped at 12 (≈1h at the
    /// 5-min realtime cadence). Sufficient to show recent context in the
    /// settings table without bloating rawState.
    public var recentSamples: [LibreLoopGlucoseSample] = []
    public static let recentSamplesPersistenceCap = 12
    /// Wall-clock timestamp of the most recent realtime sample we actually
    /// forwarded to Loop (not merely received from the sensor). Used by the
    /// default ≥4.5-minute throttle so we don't disturb Loop's 5-minute
    /// dosing cadence with per-minute updates.
    public var latestForwardedToLoopAt: Date?
    /// Opt-in escape hatch from the ≥4.5-minute forward throttle. Off by
    /// default — flipping it on requires reading a warning sheet that
    /// explains the dosing-cadence implications first.
    public var experimentalMinuteByMinuteForwarding: Bool = false
    /// Total sensor wear duration in minutes, as reported by the sensor's
    /// NFC patch-info at pairing time. Nil for state persisted before this
    /// field was added; callers fall back to the 14-day spec default in
    /// that case. Libre 3 Plus sensors report a longer duration.
    public var wearDurationMinutes: Int?
    /// `activatedAt` value for which we last issued sensor-expiry alerts
    /// via Loop's AlertManager. When this matches the current
    /// `activatedAt`, expiry alerts are already scheduled and we skip
    /// re-issuing on every reading. Cleared on `discardSensor()`.
    public var expiryAlertsScheduledForActivatedAt: Date?

    public init() {}

    public init?(rawValue: RawValue) {
        self.receiverID = rawValue["receiverID"] as? Data
        self.sensorSerial = rawValue["sensorSerial"] as? String
        self.bleAddress = rawValue["bleAddress"] as? String
        self.blePIN = rawValue["blePIN"] as? Data
        self.peripheralID = (rawValue["peripheralID"] as? String).flatMap(UUID.init(uuidString:))
        self.activatedAt = rawValue["activatedAt"] as? Date
        self.latestReadingTimestamp = rawValue["latestReadingTimestamp"] as? Date
        self.firstActionableReadingAt = rawValue["firstActionableReadingAt"] as? Date
        self.lastPairedAt = rawValue["lastPairedAt"] as? Date
        self.lastHistoricalLifeCount = (rawValue["lastHistoricalLifeCount"] as? Int).map { UInt16(clamping: $0) }
        if let latestRaw = rawValue["latestSample"] as? [String: Any] {
            self.latestSample = LibreLoopGlucoseSample(rawValue: latestRaw)
        }
        if let recentRaw = rawValue["recentSamples"] as? [[String: Any]] {
            self.recentSamples = recentRaw.compactMap(LibreLoopGlucoseSample.init(rawValue:))
        }
        self.latestForwardedToLoopAt = rawValue["latestForwardedToLoopAt"] as? Date
        self.experimentalMinuteByMinuteForwarding = rawValue["experimentalMinuteByMinuteForwarding"] as? Bool ?? false
        self.wearDurationMinutes = rawValue["wearDurationMinutes"] as? Int
        self.expiryAlertsScheduledForActivatedAt = rawValue["expiryAlertsScheduledForActivatedAt"] as? Date
    }

    public var rawValue: RawValue {
        var raw: RawValue = [:]
        raw["receiverID"] = receiverID
        raw["sensorSerial"] = sensorSerial
        raw["bleAddress"] = bleAddress
        raw["blePIN"] = blePIN
        raw["peripheralID"] = peripheralID?.uuidString
        raw["activatedAt"] = activatedAt
        raw["latestReadingTimestamp"] = latestReadingTimestamp
        raw["firstActionableReadingAt"] = firstActionableReadingAt
        raw["lastPairedAt"] = lastPairedAt
        raw["lastHistoricalLifeCount"] = lastHistoricalLifeCount.map { Int($0) }
        raw["latestSample"] = latestSample?.rawValue
        if !recentSamples.isEmpty {
            raw["recentSamples"] = recentSamples.prefix(Self.recentSamplesPersistenceCap).map { $0.rawValue }
        }
        raw["latestForwardedToLoopAt"] = latestForwardedToLoopAt
        if experimentalMinuteByMinuteForwarding {
            raw["experimentalMinuteByMinuteForwarding"] = true
        }
        raw["wearDurationMinutes"] = wearDurationMinutes
        raw["expiryAlertsScheduledForActivatedAt"] = expiryAlertsScheduledForActivatedAt
        return raw
    }
}
