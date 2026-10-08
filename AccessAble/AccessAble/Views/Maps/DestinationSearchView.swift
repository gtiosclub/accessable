import SwiftUI

struct DestinationSearchView: View {
    @State private var viewModel = DestinationSearchViewModel()

    var body: some View {
        List(viewModel.suggestions) { suggestion in
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title)
                    .font(.headline)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .searchable(
            text: $viewModel.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search for a place or address"
        )
        .onChange(of: viewModel.query) { viewModel.queryChanged() }
        .navigationTitle("Destination")
    }
}

#Preview {
    NavigationStack {
        DestinationSearchView()
    }
}
