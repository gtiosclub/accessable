import SwiftUI

/// Owner: Maps (2.x). "Search Destination": from/to fields, category chips, results, saved, recents.
/// Searches `SampleContent` until the destination search service is wired in.
struct PlaceSearchView: View {
    @Environment(AppRouter.self) private var router
    @State private var origin = ""
    @State private var query = ""
    @State private var category: PlaceCategory?
    @State private var showsAllSaved = false
    @State private var showsAllRecents = false
    @FocusState private var focusedField: Field?

    private enum Field { case origin, destination }

    private static let collapsedCount = 2

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Search Destination") { router.pop() }

                VStack(spacing: 16) {
                    searchField(label: "From:", prompt: "Current Location", text: $origin, field: .origin)
                    searchField(label: "To:", prompt: "Search", text: $query, field: .destination)
                }

                FlowLayout(spacing: 12) {
                    ForEach(PlaceCategory.allCases, id: \.self) { item in
                        chip(item)
                    }
                }

                if !results.isEmpty || isFiltering {
                    VStack(alignment: .leading, spacing: 16) {
                        if results.isEmpty {
                            Text("No places match.")
                                .foregroundStyle(.white)
                        }
                        ForEach(results) { PlaceRow(place: $0) }
                        if !results.isEmpty {
                            Text("Showing all results")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }
                    }
                }

                placeSection(
                    "Saved Locations",
                    places: SampleContent.savedPlaces,
                    isExpanded: $showsAllSaved,
                    moreLabel: "More saved locations"
                )
                placeSection(
                    "Recents",
                    places: SampleContent.recentPlaces,
                    isExpanded: $showsAllRecents,
                    moreLabel: "More recent locations"
                )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
    }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || category != nil
    }

    private var results: [SamplePlace] {
        SampleContent.search(query, category: category)
    }

    private func searchField(label: String, prompt: String, text: Binding<String>, field: Field) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            HStack {
                TextField(label, text: text, prompt: Text(prompt).foregroundStyle(.white.opacity(0.85)))
                    .font(.title3)
                    .foregroundStyle(.white)
                    .focused($focusedField, equals: field)
                    .submitLabel(.search)
                    .accessibilityLabel(field == .origin ? "From" : "To")
                Button {
                    // The keyboard's dictation key does the listening for now.
                    focusedField = field
                } label: {
                    Image(systemName: "mic")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .minimumTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dictate \(field == .origin ? "starting point" : "destination")")
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(minHeight: 56)
            .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
        }
    }

    private func chip(_ item: PlaceCategory) -> some View {
        let isSelected = category == item
        return Button {
            category = isSelected ? nil : item
        } label: {
            Text(item.displayName)
                .font(.callout)
                .foregroundStyle(isSelected ? Theme.cyan : .black)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.black : Theme.cyan, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.cyan, lineWidth: 2))
                .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Shows only \(item.displayName.lowercased())")
    }

    private func placeSection(
        _ title: String,
        places: [SamplePlace],
        isExpanded: Binding<Bool>,
        moreLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            ForEach(isExpanded.wrappedValue ? places : Array(places.prefix(Self.collapsedCount))) {
                PlaceRow(place: $0)
            }
            if places.count > Self.collapsedCount {
                Button {
                    isExpanded.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(isExpanded.wrappedValue ? "Fewer locations" : moreLabel)
                        Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                            .accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}

private struct PlaceRow: View {
    @Environment(AppRouter.self) private var router
    let place: SamplePlace

    var body: some View {
        Button {
            router.push(.place(place))
        } label: {
            HStack(spacing: 16) {
                PlaceThumbnail()
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.title3)
                        .multilineTextAlignment(.leading)
                    if place.recordedRouteCount > 0 {
                        Text(recordedRoutesText)
                            .font(.subheadline)
                    }
                    RatingView(rating: place.rating, reviewCount: place.reviewCount)
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var recordedRoutesText: String {
        place.recordedRouteCount == 1 ? "1 recorded route" : "\(place.recordedRouteCount) recorded routes"
    }

    private var accessibilityText: String {
        var parts = [place.name]
        if place.recordedRouteCount > 0 { parts.append(recordedRoutesText) }
        parts.append("rated \(place.rating.formatted(.number.precision(.fractionLength(1)))) out of 5, \(place.reviewCount) reviews")
        return parts.joined(separator: ", ")
    }
}

#Preview {
    NavigationStack {
        PlaceSearchView()
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
