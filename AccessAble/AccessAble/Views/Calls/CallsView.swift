import SwiftUI

/// Owner: Calls (MATCH-x). Stub screen that lists placeholder volunteers.
struct CallsView: View {
    @State private var model: CallsViewModel

    init(services: AppServices) {
        _model = State(initialValue: CallsViewModel(services: services))
    }

    var body: some View {
        List {
            Section("Volunteers") {
                if model.volunteers.isEmpty {
                    Text("No volunteers online")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.volunteers) { volunteer in
                    HStack {
                        Text(volunteer.name)
                        Spacer()
                        Text(volunteer.availableUntil)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(volunteer.name), online, \(volunteer.availableUntil)")
                }
            }
        }
        .navigationTitle("Calls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await model.listen() }
    }
}

#Preview {
    NavigationStack {
        CallsView(services: .preview)
    }
    .preferredColorScheme(.dark)
}
