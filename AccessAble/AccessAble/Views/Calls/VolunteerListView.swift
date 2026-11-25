import SwiftUI

struct VolunteerListView: View {
    @Environment(AppRouter.self) private var router
    @State private var viewModel: VolunteerListViewModel

    init(services: AppServices) {
        _viewModel = State(initialValue: VolunteerListViewModel(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Volunteers") { router.pop() }
                    .padding(.bottom, 8)
                if !viewModel.hasLoaded {
                    ProgressView("Loading volunteers")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if viewModel.rows.isEmpty {
                    Text("No volunteers yet.")
                        .font(.title3)
                        .padding(.top, 40)
                } else {
                    Text(viewModel.summary)
                        .font(.title3)
                        .padding(.vertical, 8)
                    ForEach(viewModel.rows) { row in
                        VolunteerStatusRow(row: row)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
        .task { await viewModel.start() }
    }
}

private struct VolunteerStatusRow: View {
    let row: VolunteerListViewModel.Row

    var body: some View {
        HStack(spacing: 16) {
            HelperAvatar(isOnline: row.isOnline)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.title3.bold())
                Text(row.isOnline ? "Online" : "Offline")
                    .font(.subheadline)
                if !row.languages.isEmpty {
                    Text("Speaks \(row.languages)")
                        .font(.subheadline)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.cyan.opacity(0.6)).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

#Preview {
    NavigationStack {
        VolunteerListView(services: .preview)
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
