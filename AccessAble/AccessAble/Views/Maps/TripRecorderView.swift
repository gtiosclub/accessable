import SwiftUI

/// Owner: Maps (2.x). Turns trip recording on or off and shares the recordings, for field tests.
struct TripRecorderView: View {
    let recorder: TripRecorder
    @State private var isEnabled: Bool
    @State private var recordings: [URL] = []
    @State private var listError: String?

    init(recorder: TripRecorder) {
        self.recorder = recorder
        _isEnabled = State(initialValue: recorder.isEnabled)
    }

    var body: some View {
        List {
            Section {
                Toggle("Record trips", isOn: $isEnabled)
                    .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
            } footer: {
                Text("While on, each trip saves every location fix and announcement to a file on this phone. "
                    + "Nothing leaves the phone unless you share a file. Turns off when the app restarts.")
            }

            if let error = listError ?? recorder.lastError {
                Section("Problem") {
                    Text(error)
                }
            }

            Section("Recordings") {
                if recordings.isEmpty {
                    Text("No recordings yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(recordings, id: \.self) { url in
                    ShareLink(item: url) {
                        Label(url.deletingPathExtension().lastPathComponent, systemImage: "square.and.arrow.up")
                            .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
                    }
                    .accessibilityHint("Shares this recording as a CSV file")
                }
            }
        }
        .navigationTitle("Trip recorder")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isEnabled) { _, enabled in
            recorder.setEnabled(enabled)
            refresh()
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        do {
            recordings = try recorder.recordings()
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }
}
