import SwiftUI
import LibreLoop

struct LibreLoopSettingsView: View {
    @ObservedObject var viewModel: LibreLoopSettingsViewModel
    let didFinish: () -> Void
    let replaceSensor: () -> Void
    let deleteCGM: () -> Void

    @State private var confirmingDelete = false
    @State private var confirmingReplace = false
    @State private var showingAllReadings = false

    var body: some View {
        List {
            sensorSection
            lastReadingSection
            recentReadingsSection
            deleteSection
        }
        .navigationTitle("FreeStyle Libre 3")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: didFinish)
            }
        }
        .confirmationDialog("Delete CGM?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteCGM)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the FreeStyle Libre 3 CGM from Loop. You'll need to re-pair to resume readings.")
        }
        .confirmationDialog("Pair a new sensor?", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Continue", action: replaceSensor)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops monitoring the current sensor and starts pairing for a new one. The CGM stays configured with Loop.")
        }
        .onAppear { viewModel.subscribe() }
        .onDisappear { viewModel.unsubscribe() }
    }

    private var sensorSection: some View {
        Section("Sensor") {
            LibreLoopLifecycleBar(lifecycle: viewModel.lifecycle,
                                  statusDetail: viewModel.statusDetail)
                .padding(.vertical, 4)
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 10, height: 10)
                Text("Bluetooth")
                Spacer()
                Text(connectionLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let serial = viewModel.sensorSerial {
                LabeledContent("Serial", value: serial)
                    .monospaced()
            }
            if let ble = viewModel.bleAddress {
                LabeledContent("Bluetooth", value: ble)
                    .monospaced()
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            if let pin = viewModel.blePINHex {
                LabeledContent("BLE PIN", value: pin)
                    .monospaced()
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            if let rid = viewModel.receiverIDHex {
                LabeledContent("Receiver ID", value: rid)
                    .monospaced()
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            if let activated = viewModel.activatedAt {
                LabeledContent("Activated", value: activated.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    @ViewBuilder
    private var lastReadingSection: some View {
        Section("Last Reading") {
            if let sample = viewModel.latestSample {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(sample.valueMgDL))")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(sample.isActionable ? .primary : .secondary)
                    Text("mg/dL")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: trendSymbol(sample.trend))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(sample.date, style: .relative)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let rate = sample.rateOfChangeMgDLPerMinute {
                        Text(String(format: "%+.1f mg/dL/min", rate))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.footnote)
                if !sample.isActionable {
                    Label(sample.qualityIssue ?? "Not sent to Loop",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Waiting for first reading…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var recentReadingsSection: some View {
        if !viewModel.recentSamples.isEmpty {
            Section("Recent Readings") {
                let visible = showingAllReadings ? viewModel.recentSamples : Array(viewModel.recentSamples.prefix(8))
                ForEach(visible.indices, id: \.self) { idx in
                    LibreLoopReadingRow(sample: visible[idx])
                }
                if viewModel.recentSamples.count > 8 {
                    Button(showingAllReadings ? "Show fewer" : "Show all \(viewModel.recentSamples.count)") {
                        showingAllReadings.toggle()
                    }
                }
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Pair new sensor") {
                confirmingReplace = true
            }
            Button("Delete CGM", role: .destructive) {
                confirmingDelete = true
            }
        }
    }

    private var connectionColor: Color {
        switch viewModel.connectionStatus {
        case .connected:     return .green
        case .connecting:    return .yellow
        case .reconnecting:  return .yellow
        case .disconnected:  return .red
        case .notPaired:     return .gray
        }
    }

    private var connectionLabel: String {
        switch viewModel.connectionStatus {
        case .notPaired:    return "Not paired"
        case .connecting:   return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .connected:    return "Connected"
        case .disconnected: return "Disconnected"
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func trendSymbol(_ trend: LibreLoopGlucoseSample.Trend) -> String {
        switch trend {
        case .notDetermined:   return "minus"
        case .risingQuickly:   return "arrow.up"
        case .rising:          return "arrow.up.right"
        case .stable:          return "arrow.right"
        case .falling:         return "arrow.down.right"
        case .fallingQuickly:  return "arrow.down"
        }
    }
}

struct LibreLoopReadingRow: View {
    let sample: LibreLoopGlucoseSample

    var body: some View {
        HStack {
            Text(sample.date, style: .time)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 72, alignment: .leading)
            Text("\(Int(sample.valueMgDL))")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(sample.isActionable ? .primary : .secondary)
                .frame(width: 48, alignment: .trailing)
            if let rate = sample.rateOfChangeMgDLPerMinute {
                Text(String(format: "%+.1f", rate))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
            if !sample.isActionable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            }
            Spacer()
            Image(systemName: trendSymbol)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .opacity(sample.isActionable ? 1.0 : 0.7)
    }

    private var trendSymbol: String {
        switch sample.trend {
        case .notDetermined:   return "minus"
        case .risingQuickly:   return "arrow.up"
        case .rising:          return "arrow.up.right"
        case .stable:          return "arrow.right"
        case .falling:         return "arrow.down.right"
        case .fallingQuickly:  return "arrow.down"
        }
    }
}

final class LibreLoopSettingsViewModel: ObservableObject, LibreLoopStateObserver {
    private let cgmManager: LibreLoopCGMManager

    @Published private(set) var lifecycle: LibreLoopSensorLifecycle
    @Published private(set) var connectionStatus: LibreLoopCGMManager.ConnectionStatus
    @Published private(set) var statusDetail: String?
    @Published private(set) var latestSample: LibreLoopGlucoseSample?
    @Published private(set) var recentSamples: [LibreLoopGlucoseSample]
    @Published private(set) var sensorSerial: String?
    @Published private(set) var bleAddress: String?
    @Published private(set) var blePINHex: String?
    @Published private(set) var receiverIDHex: String?
    @Published private(set) var activatedAt: Date?

    init(cgmManager: LibreLoopCGMManager) {
        self.cgmManager = cgmManager
        self.lifecycle = cgmManager.sensorLifecycle
        self.connectionStatus = cgmManager.connectionStatus
        self.statusDetail = cgmManager.statusDetail
        self.latestSample = cgmManager.latestSample
        self.recentSamples = cgmManager.recentSamples
        self.sensorSerial = cgmManager.state.sensorSerial
        self.bleAddress = cgmManager.state.bleAddress
        self.blePINHex = cgmManager.state.blePIN.map(Self.hex)
        self.receiverIDHex = cgmManager.state.receiverID.map(Self.hex)
        self.activatedAt = cgmManager.state.activatedAt
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func subscribe() {
        cgmManager.addStateObserver(self)
        // Sync immediately from current state. Without this, any changes
        // that happened while we weren't observing (e.g. a Pair-new-sensor
        // flow run from a pushed view) leave the @Published fields stale.
        libreLoopCGMManager(cgmManager,
                            didUpdate: cgmManager.state,
                            latestSample: cgmManager.latestSample)
    }

    func unsubscribe() {
        cgmManager.removeStateObserver(self)
    }

    func libreLoopCGMManager(_ manager: LibreLoopCGMManager,
                              didUpdate state: LibreLoopCGMManagerState,
                              latestSample: LibreLoopGlucoseSample?) {
        DispatchQueue.main.async {
            self.lifecycle = manager.sensorLifecycle
            self.connectionStatus = manager.connectionStatus
            self.statusDetail = manager.statusDetail
            self.latestSample = latestSample
            self.recentSamples = manager.recentSamples
            self.sensorSerial = state.sensorSerial
            self.bleAddress = state.bleAddress
            self.blePINHex = state.blePIN.map(Self.hex)
            self.receiverIDHex = state.receiverID.map(Self.hex)
            self.activatedAt = state.activatedAt
        }
    }
}
