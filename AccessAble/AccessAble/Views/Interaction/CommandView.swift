//
//  CommandView.swift
//  AccessAble
//
//  Created by narwhal on 10/13/26.
//


import SwiftUI
 
/// Owner: User Interaction (3.1). Type a command or question; the reply is spoken and shown.
struct CommandView: View {
    @State private var viewModel: CommandViewModel
    /// Optional so previews without a router still work; "call a volunteer" then gets the spoken hint.
    @Environment(AppRouter.self) private var router: AppRouter?
 
    init(services: AppServices, savedPlaces: SavedPlacesStore) {
        let destinations = DestinationLookup(
            nicknames: CampusNicknameDictionary.bundled,
            saved: SavedPlacesDestinationSource(store: savedPlaces),
            mapKit: MapKitDestinationSource(region: .georgiaTech)
        )
        _viewModel = State(initialValue: CommandViewModel(services: services, destinations: destinations))
    }
 
    var body: some View {
        @Bindable var viewModel = viewModel
        Form {
            Section {
                TextField("Type a command or question", text: $viewModel.text, axis: .vertical)
                    .submitLabel(.send)
                    .onSubmit { Task { await viewModel.submit() } }
                    .accessibilityHint("For example: describe my surroundings, or where am I")

                Button {
                    Task { await viewModel.toggleDictation() }
                } label: {
                    Label(
                        viewModel.dictation.isRecording ? "Stop and send" : "Dictate",
                        systemImage: viewModel.dictation.isRecording ? "stop.circle.fill" : "mic.fill"
                    )
                    .minimumTapTarget()
                }
                .disabled(viewModel.isWorking)
                .accessibilityHint(viewModel.dictation.isRecording
                    ? "Stops listening and runs what you said"
                    : "Speak a command or question, then tap again to send")

                Button {
                    Task { await viewModel.submit() }
                } label: {
                    HStack {
                        Text(viewModel.isWorking ? "Working…" : "Send")
                        if viewModel.isWorking {
                            Spacer()
                            ProgressView().accessibilityHidden(true)
                        }
                    }
                    .minimumTapTarget()
                }
                .disabled(!viewModel.canSubmit)
            }
 
            if let reply = viewModel.lastReply {
                // Already spoken by the AnnouncementEngine, so this is a plain element, not a live region.
                Section("Reply") {
                    Text(reply)
                        .accessibilityLabel("Reply: \(reply)")
                }
            }
        }
        .navigationTitle("Commands")
        .onAppear {
            // "Call a volunteer" opens the same call flow as the Home button, consent screen first.
            if let router {
                viewModel.onCallVolunteer = { router.push(.call(nil)) }
                viewModel.onOpenDestination = { router.push(.destination($0, origin: nil)) }
            }
        }
        .onDisappear { viewModel.cancelDictation() }
    }
}
 
#Preview {
    let app = AppViewModel.preview
    NavigationStack {
        CommandView(services: app.services, savedPlaces: app.savedPlacesStore)
    }
    .environment(app)
}
