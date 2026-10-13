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
 
    init(services: AppServices) {
        _viewModel = State(initialValue: CommandViewModel(services: services))
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
    }
}
 
#Preview {
    let app = AppViewModel.preview
    NavigationStack {
        CommandView(services: app.services)
    }
    .environment(app)
}
