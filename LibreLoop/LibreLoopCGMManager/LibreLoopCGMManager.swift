import Foundation
import HealthKit
import LoopKit

public final class LibreLoopCGMManager: CGMManager {
    public static let pluginIdentifier = "LibreLoopCGMManager"
    public static let localizedTitle = "FreeStyle Libre 3"
    public static let healthKitStorageDelay: TimeInterval = 0

    public var localizedTitle: String { Self.localizedTitle }

    public weak var cgmManagerDelegate: CGMManagerDelegate?
    public var delegateQueue: DispatchQueue!

    public internal(set) var state: LibreLoopCGMManagerState
    public var rawState: CGMManager.RawStateValue { state.rawValue }

    /// Live sensor monitor adopted after a successful pairing. nil before
    /// pairing or after the BLE session has dropped.
    var monitor: LibreLoopSensorMonitor? {
        didSet { notifyStateObservers() }
    }

    /// Pure BLE connection state. Does NOT incorporate data-freshness
    /// signals; those belong in the lifecycle bar / Last Reading card so
    /// this row reflects only Layer 2 reality.
    public var connectionStatus: ConnectionStatus {
        guard state.sensorSerial != nil else { return .notPaired }
        if monitor != nil {
            // We may not have received the first reading yet; that's still a
            // valid "connected" state at the BLE layer.
            return .connected
        }
        return isReconnecting ? .reconnecting : .disconnected
    }

    public enum ConnectionStatus: Equatable {
        case notPaired
        case connecting
        case connected
        case reconnecting
        case disconnected
    }

    /// Most recent glucose sample (in-memory only; not persisted across launches).
    public private(set) var latestSample: LibreLoopGlucoseSample?

    /// Ring buffer of recently received samples, newest first, capped at 100.
    public private(set) var recentSamples: [LibreLoopGlucoseSample] = []
    private static let recentSamplesCap = 100

    /// Computed lifecycle for UI consumption.
    public var sensorLifecycle: LibreLoopSensorLifecycle {
        LibreLoopSensorLifecycle.compute(
            sensorPaired: state.sensorSerial != nil,
            activatedAt: state.activatedAt,
            latestReadingAt: state.latestReadingTimestamp,
            firstActionableReadingAt: state.firstActionableReadingAt,
            lastPairedAt: state.lastPairedAt,
            hasLiveMonitor: monitor != nil
        )
    }

    let stateObservers = LibreLoopWeakObserverSet<LibreLoopStateObserver>()

    /// Short human-readable phase string (e.g. "Searching for sensor",
    /// "Authenticating", "Refreshing notifications", "Waiting for first
    /// reading"). UI shows this under the Bluetooth row so the user sees
    /// progress rather than a generic "Connecting…".
    public internal(set) var statusDetail: String? {
        didSet { notifyStateObservers() }
    }

    func updateStatusDetail(_ text: String?) {
        if Thread.isMainThread {
            self.statusDetail = text
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusDetail = text
            }
        }
    }

    /// True when a reconnect Task is either sleeping before the next attempt
    /// or actively scanning/handshaking. Drives the "Reconnecting..." status
    /// in the UI so the user can see we're working on it rather than seeing
    /// a bare "Disconnected" with no recourse.
    var isReconnecting: Bool = false {
        didSet { notifyStateObservers() }
    }

    /// Last reconnect-attempt failure message, surfaced in the UI under the
    /// Bluetooth row so failures are visible without diving into Console.app.
    /// Cleared on successful reconnect.
    public internal(set) var lastReconnectError: String? {
        didSet { notifyStateObservers() }
    }

    /// Wall-clock time of the most recent reconnect attempt (success or fail).
    /// Used together with `lastReconnectError` to show "Last attempt Xs ago".
    public internal(set) var lastReconnectAttemptAt: Date? {
        didSet { notifyStateObservers() }
    }

    func recordSample(_ sample: LibreLoopGlucoseSample) {
        latestSample = sample
        recentSamples.insert(sample, at: 0)
        if recentSamples.count > Self.recentSamplesCap {
            recentSamples.removeLast(recentSamples.count - Self.recentSamplesCap)
        }
    }

    /// Wipe everything sensor-specific so the user can pair a new sensor while
    /// keeping the CGM configured with Loop. Stops the BLE monitor, kills the
    /// reconnect loop, clears in-memory samples, and zeros the per-sensor
    /// fields of rawState (serial, blePIN, receiverID, peripheralID,
    /// bleAddress, activatedAt, latestReadingTimestamp).
    ///
    /// Session keys for the discarded sensor stay in Keychain (we never
    /// delete other apps' keys); on Keychain reuse, the new sensor's keys
    /// overwrite the entry keyed by the new serial.
    public func discardSensor() {
        cancelReconnect()
        monitor?.stop()
        monitor = nil
        isReconnecting = false
        latestSample = nil
        recentSamples = []
        var blank = state
        blank.receiverID = nil
        blank.sensorSerial = nil
        blank.bleAddress = nil
        blank.blePIN = nil
        blank.peripheralID = nil
        blank.activatedAt = nil
        blank.latestReadingTimestamp = nil
        setState(blank)
    }

    public let isOnboarded = true

    public var appURL: URL? { nil }
    public var providesBLEHeartbeat: Bool { true }
    public var shouldSyncToRemoteService: Bool { true }
    public var managedDataInterval: TimeInterval? { nil }
    public var glucoseDisplay: GlucoseDisplayable? { nil }

    public var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(hasValidSensorSession: state.sensorSerial != nil,
                         lastCommunicationDate: state.latestReadingTimestamp,
                         device: device)
    }

    public var device: HKDevice? {
        HKDevice(name: "FreeStyle Libre 3",
                 manufacturer: "Abbott",
                 model: "Libre 3",
                 hardwareVersion: nil,
                 firmwareVersion: nil,
                 softwareVersion: nil,
                 localIdentifier: state.sensorSerial,
                 udiDeviceIdentifier: nil)
    }

    public var debugDescription: String {
        """
        ## LibreLoopCGMManager
        * sensorSerial: \(state.sensorSerial ?? "nil")
        * activatedAt: \(String(describing: state.activatedAt))
        * latestReadingTimestamp: \(String(describing: state.latestReadingTimestamp))
        """
    }

    private var noDataWatchdog: Task<Void, Never>?

    /// True once we've issued a backfill request for the current BLE session.
    /// Reset when the monitor is cleared so the next session re-requests.
    var hasRequestedBackfillThisSession: Bool = false

    public init() {
        self.state = LibreLoopCGMManagerState()
    }

    deinit {
        noDataWatchdog?.cancel()
    }

    /// Watchdog: if a monitor is alive but no glucose readings have arrived
    /// within the threshold, treat the session as silently dead and force a
    /// reconnect. Covers the case where BLE is technically "connected" but
    /// the link is no longer producing notifications (rare; Loop has
    /// bluetooth-central background mode so backgrounding alone doesn't
    /// trigger this).
    private static let noDataThreshold: TimeInterval = 3 * 60

    func startNoDataWatchdog() {
        noDataWatchdog?.cancel()
        noDataWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.noDataThreshold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.monitor != nil else { return }
            // Only force reconnect if we still haven't seen a recent reading.
            let last = self.state.latestReadingTimestamp
            let stale = last.map { Date().timeIntervalSince($0) > Self.noDataThreshold } ?? true
            if stale {
                await MainActor.run {
                    self.monitor?.stop()
                    self.monitor = nil
                }
            }
        }
    }

    func cancelNoDataWatchdog() {
        noDataWatchdog?.cancel()
        noDataWatchdog = nil
    }

    public required convenience init?(rawState: CGMManager.RawStateValue) {
        self.init()
        if let parsed = LibreLoopCGMManagerState(rawValue: rawState) {
            self.state = parsed
        }
        // Saved sensor state restored -> kick off a connect attempt so we
        // start receiving glucose without waiting for Loop's next poll.
        // Same disconnect path is reused; gated on having a saved blePIN.
        if state.blePIN != nil && state.sensorSerial != nil {
            scheduleInitialReconnect()
        }
    }

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        // Glucose samples are delivered asynchronously via
        // `cgmManagerDelegate?.cgmManager(_, hasNew:)` from the BLE monitor,
        // so this poll-style API never has anything new to add. But Loop's
        // periodic calls are a useful nudge to keep the link healthy:
        //   - No monitor + saved state -> revive reconnect loop.
        //   - Monitor alive but readings stale -> the session is silently
        //     dead; drop the monitor so the disconnect path kicks in.
        let needsRevive = monitor == nil && state.blePIN != nil
        let isStalled: Bool
        if monitor != nil,
           let last = state.latestReadingTimestamp,
           Date().timeIntervalSince(last) > Self.noDataThreshold {
            isStalled = true
        } else {
            isStalled = false
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if needsRevive {
                self.scheduleInitialReconnect()
            } else if isStalled {
                self.monitor?.stop()
                self.monitor = nil
            }
        }
        completion(.noData)
    }

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }

    private let statusObservers = WeakSynchronizedSet<CGMManagerStatusObserver>()

    public func addStatusObserver(_ observer: CGMManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: CGMManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    public func delete(completion: @escaping () -> Void) {
        completion()
    }
}
