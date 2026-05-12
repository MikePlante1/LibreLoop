import Foundation

public struct LibreLoopCGMManagerState: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public var receiverID: Data?
    public var sensorSerial: String?
    public var bleAddress: String?
    public var activatedAt: Date?
    public var latestReadingTimestamp: Date?

    public init() {}

    public init?(rawValue: RawValue) {
        self.receiverID = rawValue["receiverID"] as? Data
        self.sensorSerial = rawValue["sensorSerial"] as? String
        self.bleAddress = rawValue["bleAddress"] as? String
        self.activatedAt = rawValue["activatedAt"] as? Date
        self.latestReadingTimestamp = rawValue["latestReadingTimestamp"] as? Date
    }

    public var rawValue: RawValue {
        var raw: RawValue = [:]
        raw["receiverID"] = receiverID
        raw["sensorSerial"] = sensorSerial
        raw["bleAddress"] = bleAddress
        raw["activatedAt"] = activatedAt
        raw["latestReadingTimestamp"] = latestReadingTimestamp
        return raw
    }
}
