import Foundation
import CoreBluetooth
import LibreCRKit
import os.log

private let log = Logger(subsystem: "org.loopkit.LibreLoop", category: "Monitor")

/// Wraps a live `SensorSession` after pairing has succeeded. Decrypts
/// glucose-channel notifications using the session keys (`kEnc`/`ivEnc`)
/// and surfaces usable readings via a callback.
///
/// Lifetime: monitor is alive only while the underlying BLE session is
/// connected. LibreCRKit has no reconnect-with-saved-keys API, so an
/// app kill or out-of-range disconnect requires a re-pair to resume.
public final class LibreLoopSensorMonitor: @unchecked Sendable {
    public typealias ReadingHandler = @Sendable (LibreLoopGlucoseSample) -> Void
    public typealias DisconnectHandler = @Sendable () -> Void
    public typealias StatusHandler = @Sendable (String) -> Void

    private let session: SensorSession
    // Held strongly so the underlying CBCentralManager survives past pairing.
    // SensorScanner owns the central manager + a [UUID: SensorSession] strong
    // map; dropping it tears the BLE connection down.
    private let scanner: SensorScanner
    private let decoder: DataPlaneDecoder
    private let assembler = DataPlaneNotificationAssembler()
    private let lock = NSLock()

    private var task: Task<Void, Never>?
    private var readingHandler: ReadingHandler?
    private var disconnectHandler: DisconnectHandler?
    private var statusHandler: StatusHandler?

    init(scanner: SensorScanner, session: SensorSession, kEnc: Data, ivEnc: Data) throws {
        self.scanner = scanner
        self.session = session
        let crypto = try DataPlaneCrypto(kEnc: kEnc, ivEnc: ivEnc)
        self.decoder = DataPlaneDecoder(crypto: crypto)
    }

    public func setHandlers(onReading: @escaping ReadingHandler,
                            onDisconnect: @escaping DisconnectHandler,
                            onStatus: @escaping StatusHandler = { _ in }) {
        lock.lock()
        defer { lock.unlock() }
        self.readingHandler = onReading
        self.disconnectHandler = onDisconnect
        self.statusHandler = onStatus
    }

    private func emitStatus(_ text: String) {
        lock.lock()
        let h = statusHandler
        lock.unlock()
        h?(text)
    }

    public func start() {
        lock.lock()
        let alreadyRunning = task != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let newTask = Task { [weak self] in
            guard let self else { return }
            log.info("monitor starting; refreshing post-auth notifications")
            self.emitStatus("Refreshing notifications")
            await self.refreshPostAuthNotifications()
            log.info("monitor consuming session.notifications()")
            self.emitStatus("Waiting for first reading")
            var eventCount = 0
            for await event in self.session.notifications() {
                eventCount += 1
                log.debug("notify #\(eventCount) char=\(event.characteristic.uuidString) len=\(event.fragment.count)")
                self.handle(event)
                if Task.isCancelled { break }
            }
            log.warning("monitor notification stream ended after \(eventCount) events")
            self.lock.lock()
            let handler = self.disconnectHandler
            self.lock.unlock()
            handler?()
        }
        lock.lock()
        task = newTask
        lock.unlock()
    }

    /// After Phase 6 the sensor's data-plane characteristics need a CCCD
    /// off→on cycle before the sensor will start streaming. Without this
    /// the BLE session stays open but no glucose notifications arrive, and
    /// eventually iOS or the sensor drops the link.
    ///
    /// Delegated to LibreCRKit's `SensorSession.refreshDataPlaneNotifications()`
    /// (added in the refresh-data-plane-notifications branch); LibreLoop
    /// previously implemented this inline.
    private func refreshPostAuthNotifications() async {
        do {
            log.info("CCCD refresh starting")
            try await session.refreshDataPlaneNotifications()
            log.info("CCCD refresh complete")
        } catch {
            log.error("CCCD refresh failed: \(String(describing: error))")
        }
    }

    public func stop() {
        lock.lock()
        let t = task
        task = nil
        lock.unlock()
        t?.cancel()
    }

    private func handle(_ event: NotifyEvent) {
        guard let channel = DataPlaneChannel(uuidString: event.characteristic.uuidString) else {
            log.debug("notify on unmapped char \(event.characteristic.uuidString)")
            return
        }
        guard let fullFrame = assembler.feed(fragment: event.fragment, channel: channel) else {
            log.debug("\(channel.rawValue) partial fragment buffered, waiting for completion")
            return
        }
        do {
            let frame = try DataFrame.parse(fullFrame)
            let packet = try decoder.decrypt(frame: frame, channel: channel)
            switch packet.payload {
            case .realtimeGlucose(let reading):
                // Build a SensorLifecycle from the reading's own age counter so
                // the quality assessment can correctly attribute "not actionable"
                // to warmup when applicable (and report remaining warmup minutes).
                let lifecycle = SensorLifecycle(currentLifeCountMinutes: Int(reading.lifeCount))
                let assessment = reading.currentGlucoseQualityAssessment(lifecycle: lifecycle)
                if assessment.issues.isEmpty {
                    log.info("glucose mgdl=\(reading.currentGlucoseMgDL.map(String.init) ?? "nil") lifeCount=\(reading.lifeCount) trend=\(String(describing: reading.trendKind))")
                } else {
                    let issueText = assessment.issues.map { String(describing: $0) }.joined(separator: ", ")
                    log.info("glucose mgdl=\(reading.currentGlucoseMgDL.map(String.init) ?? "nil") lifeCount=\(reading.lifeCount) issues=[\(issueText)]")
                }
                if let sample = Self.makeSample(from: reading, assessment: assessment, receivedAt: event.receivedAt) {
                    lock.lock()
                    let handler = readingHandler
                    lock.unlock()
                    handler?(sample)
                }
            default:
                log.debug("\(channel.rawValue) packet kind=\(packet.kind.rawValue) (no sample)")
            }
        } catch {
            log.error("\(channel.rawValue) decode failed: \(String(describing: error))")
        }
    }

    /// Make a sample whenever we get a numeric mg/dL value, regardless of
    /// the sensor's actionability/quality flags. The flags are propagated to
    /// the manager via `isActionable` (which decides whether to forward the
    /// sample to Loop) and `qualityIssue` (UI text). Lower layers still see
    /// the reading so the link is proven alive even during not-actionable
    /// windows.
    private static func makeSample(
        from reading: RealtimeGlucoseReading,
        assessment: Libre3GlucoseQualityAssessment,
        receivedAt: Date
    ) -> LibreLoopGlucoseSample? {
        guard let mgdl = reading.currentGlucoseMgDL else { return nil }
        return LibreLoopGlucoseSample(
            date: receivedAt,
            valueMgDL: Double(mgdl),
            trend: mapTrend(reading.trendKind),
            rateOfChangeMgDLPerMinute: reading.rateOfChangeMgDLPerMinute.map(Double.init),
            lifeCount: reading.lifeCount,
            sensorTemperatureRaw: reading.temperature,
            isActionable: assessment.isUsable,
            qualityIssue: describeIssues(assessment.issues)
        )
    }

    /// Pick the most user-relevant issue and render it as a short UI string.
    /// Warmup and expiration are the most actionable signals to a user; we
    /// surface those preferentially and fall back to a one-line summary of
    /// the rest.
    private static func describeIssues(_ issues: [Libre3GlucoseQualityIssue]) -> String? {
        guard !issues.isEmpty else { return nil }
        for issue in issues {
            switch issue {
            case .sensorWarmup(let remaining):
                return "Warming up — \(remaining) min remaining"
            case .sensorExpired:
                return "Sensor expired"
            default:
                continue
            }
        }
        // No warmup/expired; describe the first remaining issue compactly.
        switch issues[0] {
        case .currentGlucoseUnavailable:
            return "Glucose unavailable"
        case .currentDataQuality(let dq):
            return "Data quality: \(dq)"
        case .sensorCondition(let cond):
            return "Sensor condition: \(cond)"
        case .notActionable:
            return "Not actionable"
        default:
            return "Reading not actionable"
        }
    }

    private static func mapTrend(_ libre: Libre3Trend) -> LibreLoopGlucoseSample.Trend {
        switch libre {
        case .notDetermined: return .notDetermined
        case .fallingQuickly: return .fallingQuickly
        case .falling: return .falling
        case .stable: return .stable
        case .rising: return .rising
        case .risingQuickly: return .risingQuickly
        case .raw: return .notDetermined
        }
    }
}

extension LibreLoopSensorMonitor {
    /// Internal builder used by `LibreLoopPairingService`.
    static func make(scanner: SensorScanner, session: SensorSession, kEnc: Data, ivEnc: Data) throws -> LibreLoopSensorMonitor {
        try LibreLoopSensorMonitor(scanner: scanner, session: session, kEnc: kEnc, ivEnc: ivEnc)
    }
}
