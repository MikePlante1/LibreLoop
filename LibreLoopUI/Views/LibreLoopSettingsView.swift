import SwiftUI
import LibreLoop

struct LibreLoopSettingsView: View {
    @ObservedObject var viewModel: LibreLoopSettingsViewModel
    let didFinish: () -> Void
    let deleteCGM: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        List {
            Section("Sensor") {
                LabeledContent("Status", value: viewModel.sensorStatusText)
                if let serial = viewModel.sensorSerial {
                    LabeledContent("Serial", value: serial)
                }
            }
            Section("Last Reading") {
                Text(viewModel.lastReadingText).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete CGM", role: .destructive) {
                    confirmingDelete = true
                }
            }
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
            Text("This removes the FreeStyle Libre 3 CGM from Loop.")
        }
    }
}

final class LibreLoopSettingsViewModel: ObservableObject {
    private let cgmManager: LibreLoopCGMManager

    init(cgmManager: LibreLoopCGMManager) {
        self.cgmManager = cgmManager
    }

    var sensorStatusText: String {
        cgmManager.state.sensorSerial == nil ? "No sensor paired" : "Paired"
    }

    var sensorSerial: String? { cgmManager.state.sensorSerial }

    var lastReadingText: String { "—" }
}
