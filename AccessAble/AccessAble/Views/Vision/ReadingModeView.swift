import SwiftUI

/// Owner: Computer Vision (1.3 / task T29). A focused "read signs and text" screen: speaks
/// each new sign once as the camera finds it, and lets the user ask for the last one again.
struct ReadingModeView: View {
    @State private var viewModel: ReadingModeViewModel

    init(services: AppServices) {
        _viewModel = State(initialValue: ReadingModeViewModel(services: services))
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            Section {
                AccessibleActionButton(
                    title: "Replay last reading",
                    systemImage: "arrow.counterclockwise",
                    hint: "Speaks the most recent sign or text again"
                ) {
                    Task { await viewModel.replayLastReading() }
                }
                .disabled(viewModel.lastReading == nil)
            }

            Section("Currently visible") {
                if viewModel.visibleText.isEmpty {
                    Text("Looking for signs and text…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.visibleText) { text in
                        Text(text.string)
                    }
                }
            }
        }
        .navigationTitle("Read signs & text")
        .task { await viewModel.start() }
    }
}

#Preview {
    NavigationStack {
        ReadingModeView(services: .preview)
    }
}
