import SwiftUI

struct LibreLoopStartupView: View {
    let didContinue: () -> Void
    let didCancel: () -> Void

    @State private var showingRecovery = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "sensor.tag.radiowaves.forward")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .foregroundStyle(.tint)
            Text("Pair your Libre 3 sensor")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Hold the top of your phone against the sensor when you're ready to begin pairing.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            VStack(spacing: 12) {
                Button(action: didContinue) {
                    Text("Start pairing")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button("Recover existing sensor") { showingRecovery = true }
                    .font(.subheadline)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
        .navigationTitle("FreeStyle Libre 3")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: didCancel)
            }
        }
        .alert("Recovery", isPresented: $showingRecovery) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Recovery flow not yet implemented. Tap \"Start pairing\" for a fresh sensor.")
        }
    }
}
