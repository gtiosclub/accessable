import SwiftUI

/// Owner: Maps (2.x). "Search Destination": a From / To card like a maps app (From is My
/// Location unless another place is picked), category chips with counts, live results with
/// the matched letters lit and distances from the user, then saved and recent places.
/// Searches `SampleContent` until the destination search service is wired in.
struct PlaceSearchView: View {
    @Environment(AppRouter.self) private var router
    @State private var search: PlaceSearchViewModel
    @State private var showsAllSaved = false
    @State private var showsAllRecents = false
    @FocusState private var focusedField: PlaceSearchViewModel.Field?

    private static let collapsedCount = 2

    init(services: AppServices? = nil) {
        _search = State(initialValue: PlaceSearchViewModel(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Search Destination") { router.pop() }

                routeCard
                searchProgress

                if focusedField == .origin {
                    originChoices
                } else {
                    categoryChips
                    if search.isFiltering {
                        filterSummary
                        resultsList
                    }
                    placeSection(
                        "Saved Locations",
                        systemImage: "bookmark.fill",
                        places: SampleContent.savedPlaces,
                        isExpanded: $showsAllSaved,
                        moreLabel: "More saved locations"
                    )
                    placeSection(
                        "Recents",
                        systemImage: "clock.arrow.circlepath",
                        places: SampleContent.recentPlaces,
                        isExpanded: $showsAllRecents,
                        moreLabel: "More recent locations"
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .animation(.easeOut(duration: 0.2), value: search.results)
            .animation(.easeOut(duration: 0.2), value: focusedField)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
        .sensoryFeedback(.selection, trigger: search.category)
        .sensoryFeedback(.selection, trigger: search.origin)
        .task { await search.start() }
        .onDisappear { search.stop() }
        .onChange(of: search.settledQuery) {
            guard search.isFiltering else { return }
            AccessibilityNotification.Announcement(search.resultsSummary).post()
        }
    }

    // MARK: - From / To

    private var routeCard: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                fieldRow(.origin)
                Divider()
                    .overlay(.white.opacity(0.25))
                    .padding(.leading, 40)
                fieldRow(.destination)
            }
            swapButton
        }
        .padding(.vertical, 6)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
        )
        .overlay(alignment: .leading) {
            // The dotted line joining From to To, as in a maps app.
            Line()
                .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [2, 4]))
                .frame(width: 2, height: 30)
                .padding(.leading, 14 + 13)
                .accessibilityHidden(true)
        }
        .environment(\.colorScheme, .dark)
    }

    private func fieldRow(_ field: PlaceSearchViewModel.Field) -> some View {
        let isOrigin = field == .origin
        let text = isOrigin ? $search.originQuery : $search.query
        let isListening = search.dictatingField == field
        return HStack(spacing: 12) {
            Image(systemName: isOrigin ? "circle.inset.filled" : "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(isOrigin ? Theme.cyan : Theme.red)
                .frame(width: 28)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                TextField(
                    isOrigin ? "From" : "To",
                    text: text,
                    prompt: isOrigin ? nil : Text("Search places").foregroundStyle(.white.opacity(0.7))
                )
                .font(.title3)
                .foregroundStyle(.white)
                .focused($focusedField, equals: field)
                .submitLabel(isOrigin ? .next : .search)
                .onSubmit {
                    search.search()
                    if isOrigin { focusedField = .destination }
                }
                .accessibilityLabel(isOrigin ? "From" : "To")
                .accessibilityValue(isOrigin && search.originQuery.isEmpty ? originName : text.wrappedValue)

                if isOrigin, focusedField != .origin, search.originQuery.isEmpty {
                    originTag
                        // Taps go through to the field underneath.
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                    search.search()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.7))
                        .minimumTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOrigin ? "Clear starting point" : "Clear search")
            }
            Button {
                Task { await search.toggleDictation(into: field) }
            } label: {
                Image(systemName: isListening ? "waveform" : "mic")
                    .font(.title3)
                    .foregroundStyle(isListening ? Theme.red : .white)
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isListening ? "Stop dictating" : "Dictate \(isOrigin ? "starting point" : "destination")")
        }
        .frame(minHeight: 56)
    }

    private var originName: String {
        search.origin.place?.name ?? "My Location, \(search.locationDetail)"
    }

    /// "My Location" with the street and accuracy, or the chosen place.
    private var originTag: some View {
        HStack(spacing: 8) {
            if let place = search.origin.place {
                Text(place.name)
                    .font(.title3)
                    .lineLimit(1)
            } else {
                Image(systemName: search.isLocationOff ? "location.slash.fill" : "location.fill")
                    .foregroundStyle(search.isLocationOff ? Theme.red : Theme.cyan)
                VStack(alignment: .leading, spacing: 0) {
                    Text("My Location")
                        .font(.headline)
                    Text(search.locationDetail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.white.opacity(0.12), in: Capsule())
    }

    private var swapButton: some View {
        Button {
            search.swap()
            focusedField = nil
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .minimumTapTarget()
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!search.canSwap)
        .opacity(search.canSwap ? 1 : Theme.dimmedOpacity)
        .accessibilityLabel("Swap starting point and destination")
        .accessibilityHint(search.canSwap ? "" : "Pick a starting point other than My Location first")
    }

    /// A thin bar while typing settles, so it is clear the results are about to update.
    private var searchProgress: some View {
        ProgressView()
            .progressViewStyle(.linear)
            .tint(Theme.cyan)
            .opacity(search.isSearching ? 1 : 0)
            .frame(height: 2)
            .padding(.top, -10)
            .accessibilityHidden(true)
    }

    // MARK: - Choosing From

    private var originChoices: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                search.chooseOrigin(.myLocation)
                focusedField = .destination
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "location.fill")
                        .font(.title2)
                        .foregroundStyle(.black)
                        .frame(width: 56, height: 56)
                        .background(Theme.cyan, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your location").font(.title3)
                        Text(search.locationDetail).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                    if search.origin == .myLocation {
                        Image(systemName: "checkmark").foregroundStyle(Theme.cyan)
                    }
                }
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your location, \(search.locationDetail)")
            .accessibilityAddTraits(search.origin == .myLocation ? [.isButton, .isSelected] : .isButton)

            sectionTitle(
                search.originQuery.isEmpty ? "Saved places" : "Matches",
                systemImage: search.originQuery.isEmpty ? "bookmark.fill" : "magnifyingglass"
            )
            ForEach(search.originResults) { place in
                PlaceRow(
                    place: place,
                    highlight: search.settledOriginQuery,
                    distance: search.distanceText(to: place),
                    hint: "Plans from here. A live trip still starts where you are."
                ) {
                    search.chooseOrigin(.place(place))
                    focusedField = .destination
                }
            }
            if search.originResults.isEmpty {
                Text("No places match.").foregroundStyle(.white)
            }
            Text("Walking directions start where you are. Another starting point is for looking at the route.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Filtering

    private var categoryChips: some View {
        FlowLayout(spacing: 12) {
            ForEach(PlaceCategory.allCases, id: \.self) { chip($0) }
        }
    }

    private func chip(_ item: PlaceCategory) -> some View {
        let isSelected = search.category == item
        let count = search.count(of: item)
        return Button {
            search.category = isSelected ? nil : item
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.systemImage)
                Text(item.displayName)
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background((isSelected ? Theme.cyan : Color.black).opacity(0.2), in: Capsule())
                    .contentTransition(.numericText())
            }
            .font(.callout)
            .foregroundStyle(isSelected ? Theme.cyan : .black)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.black : Theme.cyan, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.cyan, lineWidth: 2))
            .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
            .contentShape(Capsule())
            .opacity(count == 0 && !isSelected ? Theme.dimmedOpacity : 1)
            .animation(.easeOut(duration: 0.2), value: count)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.displayName), \(count) \(count == 1 ? "place" : "places")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Shows every kind of place" : "Shows only \(item.displayName.lowercased())")
    }

    /// "Showing 3 of 24 places" and a removable tag for each active filter.
    private var filterSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Theme.cyan)
                    .accessibilityHidden(true)
                Text(search.resultsSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if search.location != nil, !search.results.isEmpty {
                    Text("· nearest first")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            FlowLayout(spacing: 8) {
                let trimmed = search.settledQuery.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    filterTag("“\(trimmed)”", systemImage: "textformat", label: "Text \(trimmed)") {
                        search.query = ""
                        search.search()
                    }
                }
                if let category = search.category {
                    filterTag(category.displayName, systemImage: category.systemImage, label: category.displayName) {
                        search.category = nil
                    }
                }
            }
        }
    }

    private func filterTag(_ title: String, systemImage: String, label: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.14), in: Capsule())
            .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove filter: \(label)")
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            if search.results.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(search.settledQuery.isEmpty ? "No places match." : "No places match “\(search.settledQuery)”.")
                        .foregroundStyle(.white)
                    Button("Clear filters") { search.clearFilters() }
                        .buttonStyle(.pill(.outline, size: .compact))
                }
            }
            ForEach(search.results) { place in
                PlaceRow(place: place, highlight: search.settledQuery, distance: search.distanceText(to: place)) {
                    router.push(.place(place, origin: search.origin.place))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Saved and recent

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)
    }

    private func placeSection(
        _ title: String,
        systemImage: String,
        places: [SamplePlace],
        isExpanded: Binding<Bool>,
        moreLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(title, systemImage: systemImage)
            ForEach(isExpanded.wrappedValue ? places : Array(places.prefix(Self.collapsedCount))) { place in
                PlaceRow(place: place, distance: search.distanceText(to: place)) {
                    router.push(.place(place, origin: search.origin.place))
                }
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

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

extension PlaceCategory {
    var systemImage: String {
        switch self {
        case .restaurants: "fork.knife"
        case .labeledPlaces: "building.2"
        case .parks: "tree"
        case .publicTransit: "tram"
        }
    }
}

private struct PlaceRow: View {
    let place: SamplePlace
    var highlight = ""
    var distance: String?
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    PlaceThumbnail()
                    Image(systemName: place.category.systemImage)
                        .font(.title2)
                        .foregroundStyle(Theme.navy)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(highlightedName)
                        .font(.title3)
                        .multilineTextAlignment(.leading)
                    if let distance {
                        Label(distance, systemImage: "figure.walk")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
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
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(.isButton)
    }

    /// The name with the letters that matched the search lit in cyan.
    private var highlightedName: AttributedString {
        var name = AttributedString(place.name)
        for range in PlaceSearchViewModel.matchedRanges(in: place.name, for: highlight) {
            guard let attributed = Range(range, in: name) else { continue }
            name[attributed].foregroundColor = Theme.cyan
            name[attributed].inlinePresentationIntent = .stronglyEmphasized
        }
        return name
    }

    private var recordedRoutesText: String {
        place.recordedRouteCount == 1 ? "1 recorded route" : "\(place.recordedRouteCount) recorded routes"
    }

    private var accessibilityText: String {
        var parts = [place.name]
        if let distance { parts.append(distance.replacingOccurrences(of: " · ", with: ", ")) }
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
