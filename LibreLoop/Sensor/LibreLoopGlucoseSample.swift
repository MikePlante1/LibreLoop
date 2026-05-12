import Foundation

/// A glucose reading produced by the LibreLoop CGM. Wraps LibreCRKit's
/// realtime reading so callers (UI, the manager itself, tests) don't need
/// to import LibreCRKit.
public struct LibreLoopGlucoseSample: Equatable, Sendable {
    public enum Trend: Equatable, Sendable {
        case notDetermined
        case fallingQuickly
        case falling
        case stable
        case rising
        case risingQuickly
    }

    public let date: Date
    public let valueMgDL: Double
    public let trend: Trend
    public let rateOfChangeMgDLPerMinute: Double?
    public let lifeCount: UInt16
    public let sensorTemperatureRaw: UInt16
    public let isActionable: Bool

    public init(
        date: Date,
        valueMgDL: Double,
        trend: Trend,
        rateOfChangeMgDLPerMinute: Double?,
        lifeCount: UInt16,
        sensorTemperatureRaw: UInt16,
        isActionable: Bool
    ) {
        self.date = date
        self.valueMgDL = valueMgDL
        self.trend = trend
        self.rateOfChangeMgDLPerMinute = rateOfChangeMgDLPerMinute
        self.lifeCount = lifeCount
        self.sensorTemperatureRaw = sensorTemperatureRaw
        self.isActionable = isActionable
    }
}
