import SwiftUI
import LibreLoop

struct LibreLoopSettingsView: View {
    @ObservedObject var viewModel: LibreLoopSettingsViewModel
    let didFinish: () -> Void
    let deleteCGM: () -> Void

    @State private var confirmingDelete = false
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
        .onAppear { viewModel.subscribe() }
        .onDisappear { viewModel.unsubscribe() }
    }

    private var sensorSection: some View {
        Section("Sensor") {
            LibreLoopLifecycleBar(lifecycle: viewModel.lifecycle)
                .padding(.vertical, 4)
            if let serial = viewModel.sensorSerial {
                LabeledContent("Serial", value: serial)
                    .monospaced()
            }
            if let ble = viewModel.bleAddress {
                LabeledContent("Bluetooth", value: ble)
                    .monospaced()
                    .font(.footnote)
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
            Button("Delete CGM", role: .destructive) {
                confirmingDelete = true
            }
        }
    }

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
                .frame(width: 48, alignment: .trailing)
            if let rate = sample.rateOfChangeMgDLPerMinute {
                Text(String(format: "%+.1f", rate))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
            Spacer()
            Image(systemName: trendSymbol)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
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
    @Published private(set) var latestSample: LibreLoopGlucoseSample?
    @Published private(set) var recentSamples: [LibreLoopGlucoseSample]
    @Published private(set) var sensorSerial: String?
    @Published private(set) var bleAddress: String?
    @Published private(set) var activatedAt: Date?

    init(cgmManager: LibreLoopCGMManager) {
        self.cgmManager = cgmManager
        self.lifecycle = cgmManager.sensorLifecycle
        self.latestSample = cgmManager.latestSample
        self.recentSamples = cgmManager.recentSamples
        self.sensorSerial = cgmManager.state.sensorSerial
        self.bleAddress = cgmManager.state.bleAddress
        self.activatedAt = cgmManager.state.activatedAt
    }

    func subscribe() {
        cgmManager.addStateObserver(self)
    }

    func unsubscribe() {
        cgmManager.removeStateObserver(self)
    }

    func libreLoopCGMManager(_ manager: LibreLoopCGMManager,
                              didUpdate state: LibreLoopCGMManagerState,
                              latestSample: LibreLoopGlucoseSample?) {
        DispatchQueue.main.async {
            self.lifecycle = manager.sensorLifecycle
            self.latestSample = latestSample
            self.recentSamples = manager.recentSamples
            self.sensorSerial = state.sensorSerial
            self.bleAddress = state.bleAddress
            self.activatedAt = state.activatedAt
        }
    }
}
