import Foundation
import HealthKit
import LoopKit
import os.log

private let log = Logger(subsystem: "org.loopkit.LibreLoop", category: "CGMManager")

extension LibreLoopCGMManager {
    /// Saves the NFC half of pairing the instant it completes successfully,
    /// before any BLE work. Per LibreCRKit author guidance: a successful A8
    /// burns the previous BLE PIN and issues a new one in the response, so
    /// the new PIN MUST be persisted before we touch BLE -- a crash or
    /// handshake failure must not leave the sensor stranded.
    public func applyNFCResponse(_ response: LibreLoopPairingService.NFCResponse) {
        log.info("NFC response applied: serial=\(response.sensorSerial) bleAddress=\(response.bleAddress ?? "nil") blePIN bytes=\(response.blePIN.count)")
        cancelReconnect()
        var newState = state
        newState.receiverID = withUnsafeBytes(of: response.receiverID.littleEndian) { Data($0) }
        newState.sensorSerial = response.sensorSerial
        newState.bleAddress = response.bleAddress
        newState.blePIN = response.blePIN
        newState.activatedAt = response.activatedAt
        setState(newState)
    }

    /// Completes pairing after BLE handshake succeeds: persists session keys
    /// to Keychain and adopts the live monitor. NFC fields are already in
    /// state by this point (see applyNFCResponse).
    public func applyPairingOutcome(_ outcome: LibreLoopPairingService.PairOutcome) throws {
        log.info("pairing outcome applied: serial=\(outcome.result.sensorSerial) peripheral=\(outcome.peripheralID.uuidString); adopting monitor")
        try LibreLoopKeychain.save(
            LibreLoopKeychain.SessionKeys(kEnc: outcome.result.kEnc, ivEnc: outcome.result.ivEnc),
            forSensorSerial: outcome.result.sensorSerial
        )

        var newState = state
        newState.peripheralID = outcome.peripheralID
        newState.lastPairedAt = Date()
        // Switch-receiver re-arms sensor stabilization; clear the prior
        // actionable timestamp so the lifecycle bar correctly reports
        // "Warming up" until the new pairing produces an actionable reading.
        newState.firstActionableReadingAt = nil
        setState(newState)

        adopt(monitor: outcome.monitor)
    }

    func adopt(monitor: LibreLoopSensorMonitor) {
        self.monitor = monitor
        monitor.setHandlers(
            onReading: { [weak self] sample in self?.ingest(sample) },
            onDisconnect: { [weak self] in self?.handleMonitorDisconnect() },
            onStatus: { [weak self] text in self?.updateStatusDetail(text) }
        )
        monitor.start()
        // Start the no-data watchdog immediately after adoption -- if the
        // first reading doesn't arrive within the threshold, the link is
        // probably silently dead and a reconnect is in order.
        startNoDataWatchdog()
    }

    func ingest(_ sample: LibreLoopGlucoseSample) {
        recordSample(sample)
        cancelNoDataWatchdog()

        var updated = state
        updated.latestReadingTimestamp = sample.date
        // Back-derive activation timestamp from the sensor's own age counter
        // (lifeCount, minutes since activation). Only set it once -- later
        // readings shouldn't shift it (small drift would otherwise jitter the
        // lifecycle bar).
        if updated.activatedAt == nil {
            updated.activatedAt = sample.date.addingTimeInterval(-TimeInterval(sample.lifeCount) * 60)
        }
        // First time the sensor flags a reading actionable post-pair tells
        // us warmup is done. Pin it so the lifecycle bar can leave warmup.
        if sample.isActionable, updated.firstActionableReadingAt == nil {
            updated.firstActionableReadingAt = sample.date
        }
        setState(updated)

        notifyStateObservers()

        // Status detail moves out of "Waiting for first reading" the instant
        // any reading arrives, even unactionable ones -- the link is proven.
        if !sample.isActionable {
            updateStatusDetail("Reading received (not actionable)")
            log.info("ingested non-actionable sample (\(Int(sample.valueMgDL)) mg/dL); not forwarding to Loop")
            return
        }
        updateStatusDetail(nil)

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

    /// Delay between reconnect attempts. The first attempt after a disconnect
    /// uses this delay to let the BLE stack finish tearing down the dead link
    /// (avoids racing the disconnect cleanup). Subsequent attempts after a
    /// failed attempt also wait this long before retrying. CoreBluetooth's
    /// scan keeps the radio efficient under the hood, so a constant interval
    /// here doesn't need backoff.
    private static let reconnectDelay: TimeInterval = 2

    private static var reconnectTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    private func handleMonitorDisconnect() {
        log.warning("monitor reported disconnect; clearing and reconnecting")
        self.monitor = nil
        cancelReconnect()
        startReconnectLoop()
    }

    /// Persistent reconnect loop. Keeps trying as long as the manager exists
    /// and we have saved state to reconnect with. Stops only on success
    /// (a monitor is adopted) or on Task cancellation (CGM deleted, manager
    /// torn down). The user never has to push a button.
    private func startReconnectLoop() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.monitor == nil else { return }
                guard self.state.blePIN != nil, self.state.sensorSerial != nil else {
                    log.error("reconnect loop: no saved state; aborting")
                    await MainActor.run { self.isReconnecting = false }
                    return
                }
                await MainActor.run { self.isReconnecting = true }
                try? await Task.sleep(nanoseconds: UInt64(Self.reconnectDelay * 1_000_000_000))
                if Task.isCancelled { break }
                await self.runReconnectOnce()
                if self.monitor != nil {
                    await MainActor.run { self.isReconnecting = false }
                    return
                }
                // failure -> loop back, sleep, retry. Never gives up.
            }
            // Cancelled: make sure the indicator clears.
            await MainActor.run { self?.isReconnecting = false }
        }
        Self.reconnectTasks[ObjectIdentifier(self)] = task
    }

    func cancelReconnect() {
        let key = ObjectIdentifier(self)
        if let task = Self.reconnectTasks[key] {
            task.cancel()
            Self.reconnectTasks.removeValue(forKey: key)
        }
    }

    private func runReconnectOnce() async {
        guard let blePIN = state.blePIN, let serial = state.sensorSerial else {
            return
        }
        let expectedPeripheral = state.peripheralID
        log.info("reconnect: attempt starting (peripheralID=\(expectedPeripheral?.uuidString ?? "any"))")
        do {
            let outcome = try await LibreLoopPairingService().reconnect(
                blePIN: blePIN,
                expectedPeripheralID: expectedPeripheral
            ) { [weak self] stage in
                log.info("reconnect stage: \(String(describing: stage))")
                self?.updateStatusDetail(Self.statusText(for: stage))
            }
            try LibreLoopKeychain.save(
                LibreLoopKeychain.SessionKeys(kEnc: outcome.kEnc, ivEnc: outcome.ivEnc),
                forSensorSerial: serial
            )
            await MainActor.run {
                self.adopt(monitor: outcome.monitor)
            }
            log.info("reconnect: succeeded")
        } catch {
            log.error("reconnect: attempt failed: \(String(describing: error)) - looping")
        }
    }

    /// Trigger an automatic reconnect loop if we have saved state and aren't
    /// already running one. Called from app-launch state restore and from
    /// Loop's periodic fetchNewDataIfNeeded poll.
    func scheduleInitialReconnect() {
        let key = ObjectIdentifier(self)
        guard Self.reconnectTasks[key] == nil else {
            return
        }
        guard monitor == nil else {
            return
        }
        log.info("reconnect: auto-trigger (launch or poll)")
        startReconnectLoop()
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

    static func statusText(for stage: LibreLoopPairingService.Stage) -> String {
        switch stage {
        case .nfcScanning:   return "Scanning sensor"
        case .bleSearching:  return "Searching for sensor"
        case .bleConnecting: return "Connecting"
        case .handshaking:   return "Authenticating"
        }
    }

    func setState(_ newState: LibreLoopCGMManagerState) {
        state = newState
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManagerDidUpdateState(self)
        }
        notifyStateObservers()
    }
}
