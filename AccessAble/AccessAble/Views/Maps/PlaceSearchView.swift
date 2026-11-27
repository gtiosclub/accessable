import SwiftUI

/// Owner: Maps (2.x). "Search Destination": a From / To card like a maps app (From is My
/// Location unless another place is picked), category chips, user-saved places first, live
/// campus results from MapKit with the matched letters lit, and recent places. Picking a result
/// looks it up and opens it as a real `Destination`.
struct PlaceSearchView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search: PlaceSearchViewModel
    @State private var showsAllSaved = false
    @State private var showsAllRecents = false
    @State private var confirmsClearRecents = false
    @State private var renamingPlace: SavedPlace?
    @State private var renameText = ""
    @FocusState private var focusedField: PlaceSearchViewModel.Field?

    private static let collapsedCount = 2

    private var showsRenameAlert: Binding<Bool> {
        Binding(
            get: { renamingPlace != nil },
            set: { if !$0 { renamingPlace = nil } }
        )
    }

    init(services: AppServices? = nil, savedPlaces: SavedPlacesStore? = nil, recentPlaces: RecentPlacesStore? = nil) {
        _search = State(initialValue: PlaceSearchViewModel(
            services: services,
            savedPlaces: savedPlaces,
            recentPlaces: recentPlaces
        ))
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
                        if !search.matchingSavedPlaces.isEmpty {
                            savedPlacesSection(
                                "Saved Places",
                                places: search.matchingSavedPlaces,
                                highlight: search.settledQuery,
                                isExpanded: .constant(true)
                            )
                        }
                        resultsList
                        if !search.matchingRecentPlaces.isEmpty {
                            recentPlacesSection(
                                "Recents",
                                places: search.matchingRecentPlaces,
                                highlight: search.settledQuery,
                                isExpanded: .constant(true),
                                showsClearAction: false
                            )
                        }
                    } else {
                        savedPlacesSection(
                            "Saved Places",
                            places: search.savedPlaces,
                            highlight: "",
                            isExpanded: $showsAllSaved
                        )
                        recentPlacesSection(
                            "Recents",
                            places: search.recentPlaces,
                            highlight: "",
                            isExpanded: $showsAllRecents,
                            showsClearAction: true
                        )
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .animation(.easeOut(duration: 0.2), value: search.suggestions)
            .animation(.easeOut(duration: 0.2), value: focusedField)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
        // Choosing a category; follows the Haptics setting.
        .onChange(of: search.category) { Haptics.play(.selection) }
        .task { await search.start() }
        .onDisappear { search.stop() }
        // Result count, "no results" and errors, spoken as in the old search screen.
        .announcesSearch(search.destinationSearch)
        .onChange(of: search.selectedDestination) { _, destination in
            guard let destination else { return }
            router.push(.destination(destination, origin: search.origin.place))
        }
        .alert("Rename saved place", isPresented: showsRenameAlert) {
            TextField("Label, e.g. Home or Class", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingPlace = nil }
        } message: {
            if let renamingPlace {
                Text("Leave blank to use \(renamingPlace.name).")
            }
        }
        .alert("Clear recent places?", isPresented: $confirmsClearRecents) {
            Button("Clear", role: .destructive) {
                showsAllRecents = false
                search.clearRecents()
                AccessibilityNotification.Announcement("Cleared recent places").post()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All recent destinations will be removed. Saved places stay.")
        }
    }

    // MARK: - From / To

    private var usesStackedRouteCard: Bool { dynamicTypeSize.isAccessibilitySize }

    private var routeCard: some View {
        let layout = usesStackedRouteCard ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            VStack(spacing: 0) {
                fieldRow(.origin)
                Divider()
                    .overlay(.white.opacity(0.25))
                    .padding(.leading, usesStackedRouteCard ? 0 : 40)
                fieldRow(.destination)
            }
            swapButton
        }
        .padding(.vertical, 6)
        .padding(.leading, 14)
        .padding(.trailing, usesStackedRouteCard ? 14 : 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
        )
        .overlay(alignment: .leading) {
            if !usesStackedRouteCard {
                // The dotted line joining From to To in the compact card.
                Line()
                    .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [2, 4]))
                    .frame(width: 2, height: 30)
                    .padding(.leading, 14 + 13)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func fieldRow(_ field: PlaceSearchViewModel.Field) -> some View {
        let isOrigin = field == .origin
        let text = isOrigin ? $search.originQuery : $search.query
        let isListening = search.dictatingField == field
        let layout = usesStackedRouteCard
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                if !usesStackedRouteCard {
                    Image(systemName: isOrigin ? "circle.inset.filled" : "mappin.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isOrigin ? Theme.cyan : Theme.red)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                }
                fieldInput(field, text: text)
            }
            HStack(spacing: 12) {
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
        }
        .frame(minHeight: 56)
        .padding(.vertical, usesStackedRouteCard ? 6 : 0)
    }

    private func fieldInput(_ field: PlaceSearchViewModel.Field, text: Binding<String>) -> some View {
        let isOrigin = field == .origin
        return ZStack(alignment: .leading) {
            TextField(
                isOrigin ? "From" : "To",
                text: text,
                // Without a prompt the field shows its label, "From", behind the My Location tag.
                prompt: Text(prompt(for: field)).foregroundStyle(.white.opacity(0.7))
            )
            .font(.title3)
            .foregroundStyle(.white)
            .focused($focusedField, equals: field)
            .submitLabel(isOrigin ? .next : .search)
            // autocorrect rewrites place names like "Ferst" into real words
            .autocorrectionDisabled()
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
    }

    /// Empty while the From tag covers the field; a hint once the user is typing there.
    private func prompt(for field: PlaceSearchViewModel.Field) -> String {
        switch field {
        case .destination: "Search places"
        case .origin: focusedField == .origin ? "Choose a starting point" : ""
        }
    }

    private var originName: String {
        search.origin.place?.displayName ?? "My Location, \(search.locationDetail)"
    }

    /// "My Location" with the street and accuracy, or the chosen place.
    private var originTag: some View {
        HStack(spacing: 8) {
            if let place = search.origin.place {
                Text(place.displayName)
                    .font(.title3)
                    .lineLimit(usesStackedRouteCard ? nil : 1)
            } else {
                if !usesStackedRouteCard {
                    Image(systemName: search.isLocationOff ? "location.slash.fill" : "location.fill")
                        .foregroundStyle(search.isLocationOff ? Theme.red : Theme.cyan)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("My Location")
                        .font(.headline)
                    Text(search.locationDetail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(usesStackedRouteCard ? nil : 2)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: usesStackedRouteCard ? 16 : 100))
    }

    private var swapButton: some View {
        Button {
            search.swap()
            focusedField = nil
        } label: {
            if usesStackedRouteCard {
                Label("Swap", systemImage: "arrow.up.arrow.down")
                    .font(.headline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            } else {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.title3.weight(.semibold))
                    .minimumTapTarget()
                    .background(.white.opacity(0.12), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
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
                Haptics.play(.selection)
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
            ForEach(search.originSavedPlaces) { saved in
                SavedPlaceRow(
                    place: saved,
                    highlight: search.settledOriginQuery,
                    distance: search.distanceText(to: saved),
                    hint: "Plans from here. A live trip still starts where you are.",
                    action: {
                        Haptics.play(.selection)
                        search.chooseOrigin(.place(saved.asSamplePlace()))
                        focusedField = .destination
                    },
                    onRename: { beginRename(saved) },
                    onDelete: { deleteSavedPlace(saved) }
                )
            }
            if search.originResults.isEmpty {
                Text(search.originQuery.isEmpty ? "No saved places yet." : "No places match.")
                    .foregroundStyle(.white)
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
        return Button {
            search.category = isSelected ? nil : item
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.systemImage)
                Text(item.displayName)
            }
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
        .accessibilityLabel(item.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Shows every kind of place" : "Searches for \(item.displayName.lowercased()) near campus")
    }

    /// "3 results for Clough" and a removable tag for each active filter.
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
            if let problem = search.problem {
                problemView(problem)
            }
            if search.showsNoResults {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No places match “\(search.searchText)”.")
                        .foregroundStyle(.white)
                    Button("Clear filters") { search.clearFilters() }
                        .buttonStyle(.pill(.outline, size: .compact))
                }
            }
            ForEach(Array(search.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionRow(
                    suggestion: suggestion,
                    highlight: search.settledQuery,
                    isResolving: search.isResolving(suggestion),
                    spokenLabel: search.spokenLabel(for: suggestion, at: index)
                ) {
                    Haptics.play(.selection)
                    search.select(suggestion)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// No connection, or a picked result that couldn't be looked up.
    @ViewBuilder
    private func problemView(_ problem: SearchProblem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                problem.message,
                systemImage: problem == .suggestionsUnavailable ? "wifi.exclamationmark" : "exclamationmark.triangle"
            )
            .foregroundStyle(.white)
            if case .lookupFailed(let suggestion) = problem {
                Button("Try again") { search.select(suggestion) }
                    .buttonStyle(.pill(.outline, size: .compact))
                    .accessibilityHint("Looks up \(suggestion.title) again")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.red.opacity(0.25), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func selectDestination(_ place: SamplePlace) {
        Haptics.play(.selection)
        router.push(.place(place, origin: search.origin.place))
    }

    // MARK: - Saved and recent

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)
    }

    private func savedPlacesSection(
        _ title: String,
        places: [SavedPlace],
        highlight: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(title, systemImage: "bookmark.fill")
            if places.isEmpty {
                Text("No saved places yet. Save a place from its details screen.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                ForEach(isExpanded.wrappedValue ? places : Array(places.prefix(Self.collapsedCount))) { saved in
                    SavedPlaceRow(
                        place: saved,
                        highlight: highlight,
                        distance: search.distanceText(to: saved),
                        action: {
                            Haptics.play(.selection)
                            router.push(.savedPlace(saved, origin: search.origin.place))
                        },
                        onRename: { beginRename(saved) },
                        onDelete: { deleteSavedPlace(saved) }
                    )
                }
                if places.count > Self.collapsedCount {
                    Button {
                        isExpanded.wrappedValue.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Text(isExpanded.wrappedValue ? "Fewer locations" : "More saved places")
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
        }
        .padding(.top, 8)
    }

    private func beginRename(_ place: SavedPlace) {
        renamingPlace = place
        renameText = place.label ?? place.name
    }

    private func commitRename() {
        guard let place = renamingPlace else { return }
        search.savedPlacesStore.rename(id: place.id, to: renameText)
        let updatedName = search.savedPlacesStore.savedPlace(id: place.id)?.displayName ?? place.displayName
        renamingPlace = nil
        AccessibilityNotification.Announcement("Renamed to \(updatedName)").post()
    }

    private func deleteSavedPlace(_ place: SavedPlace) {
        let deletedName = place.displayName
        search.savedPlacesStore.delete(id: place.id)
        AccessibilityNotification.Announcement("Deleted \(deletedName)").post()
    }

    private func recentPlacesSection(
        _ title: String,
        places: [RecentPlace],
        highlight: String,
        isExpanded: Binding<Bool>,
        showsClearAction: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle(title, systemImage: "clock.arrow.circlepath")
                Spacer()
                if showsClearAction && !places.isEmpty {
                    Button("Clear recents") { confirmsClearRecents = true }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.cyan)
                    .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
                    .contentShape(Rectangle())
                    .accessibilityHint("Removes all recent destinations")
                }
            }

            if places.isEmpty {
                Text("No recent destinations yet. Start a trip to add one.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                ForEach(isExpanded.wrappedValue ? places : Array(places.prefix(Self.collapsedCount))) { place in
                    RecentPlaceRow(
                        place: place,
                        highlight: highlight,
                        distance: search.distanceText(to: place)
                    ) {
                        selectDestination(place.asSamplePlace())
                    }
                }
                if places.count > Self.collapsedCount {
                    Button {
                        isExpanded.wrappedValue.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Text(isExpanded.wrappedValue ? "Fewer locations" : "More recent locations")
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

/// A live search result: what MapKit suggested, before it is looked up.
private struct SuggestionRow: View {
    let suggestion: SearchSuggestion
    var highlight = ""
    var isResolving = false
    var spokenLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    PlaceThumbnail()
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title2)
                        .foregroundStyle(Theme.navy)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(highlightedTitle)
                        .font(.title3)
                        .multilineTextAlignment(.leading)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.leading)
                    }
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
                if isResolving {
                    ProgressView()
                        .tint(.white)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel ?? [suggestion.title, suggestion.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(isResolving ? "Loading details" : "")
        .accessibilityHint("Opens this place")
        .accessibilityAddTraits(.isButton)
    }

    /// The title with the letters that matched the search lit in cyan.
    private var highlightedTitle: AttributedString {
        var title = AttributedString(suggestion.title)
        for range in PlaceSearchViewModel.matchedRanges(in: suggestion.title, for: highlight) {
            guard let attributed = Range(range, in: title) else { continue }
            title[attributed].foregroundColor = Theme.cyan
            title[attributed].inlinePresentationIntent = .stronglyEmphasized
        }
        return title
    }
}

private struct SavedPlaceRow: View {
    let place: SavedPlace
    var highlight = ""
    var distance: String?
    var hint: String?
    let action: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    PlaceThumbnail()
                    Image(systemName: "bookmark.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.navy)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(highlightedTitle)
                        .font(.title3)
                        .multilineTextAlignment(.leading)
                    if let subtitle = place.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    if let detailAddress = place.detailAddress {
                        Text(detailAddress)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    if let distance {
                        Label(distance, systemImage: "figure.walk")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(hint ?? "Opens saved place details")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Rename", onRename)
        .accessibilityAction(named: "Delete", onDelete)
        .contextMenu {
            Button("Rename", systemImage: "pencil", action: onRename)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var highlightedTitle: AttributedString {
        var title = AttributedString(place.displayName)
        for range in PlaceSearchViewModel.matchedRanges(in: place.displayName, for: highlight) {
            guard let attributed = Range(range, in: title) else { continue }
            title[attributed].foregroundColor = Theme.cyan
            title[attributed].inlinePresentationIntent = .stronglyEmphasized
        }
        return title
    }

    private var accessibilityText: String {
        var parts = [place.accessibilitySummary]
        if let distance { parts.append(distance.replacingOccurrences(of: " · ", with: ", ")) }
        return parts.joined(separator: ", ")
    }
}

private struct RecentPlaceRow: View {
    let place: RecentPlace
    var highlight = ""
    let distance: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                ZStack {
                    PlaceThumbnail()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.cyan)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(highlightedTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let address = place.address, !address.isEmpty {
                        Text(address)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2)
                    }
                    if let distance {
                        Label(distance, systemImage: "figure.walk")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens place details")
        .accessibilityAddTraits(.isButton)
    }

    private var highlightedTitle: AttributedString {
        var title = AttributedString(place.name)
        for range in PlaceSearchViewModel.matchedRanges(in: place.name, for: highlight) {
            guard let attributed = Range(range, in: title) else { continue }
            title[attributed].foregroundColor = Theme.cyan
            title[attributed].inlinePresentationIntent = .stronglyEmphasized
        }
        return title
    }

    private var accessibilityText: String {
        var parts = [place.accessibilitySummary]
        if let distance { parts.append(distance.replacingOccurrences(of: " · ", with: ", ")) }
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
