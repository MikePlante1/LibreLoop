import Foundation
import HealthKit
import LoopKit

extension LibreLoopCGMManager {
    /// Persists a successful pairing outcome and adopts the live monitor:
    ///   - sensor metadata is folded into `state` (rawState-persisted)
    ///   - session crypto keys (kEnc, ivEnc) go into the Keychain keyed by serial
    ///   - the monitor's reading stream is wired to this manager
    public func applyPairingOutcome(_ outcome: LibreLoopPairingService.PairOutcome) throws {
        try LibreLoopKeychain.save(
            LibreLoopKeychain.SessionKeys(kEnc: outcome.result.kEnc, ivEnc: outcome.result.ivEnc),
            forSensorSerial: outcome.result.sensorSerial
        )

        var newState = state
        newState.receiverID = withUnsafeBytes(of: outcome.result.receiverID.littleEndian) { Data($0) }
        newState.sensorSerial = outcome.result.sensorSerial
        newState.bleAddress = outcome.result.bleAddress
        newState.activatedAt = outcome.result.activatedAt
        setState(newState)

        adopt(monitor: outcome.monitor)
    }

    func adopt(monitor: LibreLoopSensorMonitor) {
        self.monitor = monitor
        monitor.setHandlers(
            onReading: { [weak self] sample in self?.ingest(sample) },
            onDisconnect: { [weak self] in self?.handleMonitorDisconnect() }
        )
        monitor.start()
    }

    func ingest(_ sample: LibreLoopGlucoseSample) {
        var updated = state
        updated.latestReadingTimestamp = sample.date
        setState(updated)

        let newSample = NewGlucoseSample(
            date: sample.date,
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL),
            condition: nil,
            trend: Self.mapTrend(sample.trend),
            trendRate: sample.rateOfChangeMgDLPerMinute.map {
                HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
            },
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "libreloop-\(state.sensorSerial ?? "unknown")-\(sample.lifeCount)",
            syncVersion: 1,
            device: device
        )

        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData([newSample]))
        }
    }

    private func handleMonitorDisconnect() {
        self.monitor = nil
    }

    private static func mapTrend(_ trend: LibreLoopGlucoseSample.Trend) -> GlucoseTrend? {
        switch trend {
        case .notDetermined: return nil
        case .risingQuickly:  return .upUp
        case .rising:         return .up
        case .stable:         return .flat
        case .falling:        return .down
        case .fallingQuickly: return .downDown
        }
    }

    func setState(_ newState: LibreLoopCGMManagerState) {
        state = newState
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManagerDidUpdateState(self)
        }
    }
}
