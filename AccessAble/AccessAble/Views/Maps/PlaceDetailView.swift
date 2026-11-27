import SwiftUI

/// Owner: Maps (2.x). A chosen place: name, address, the real walking route to it (summary
/// and steps), and how to start.
struct PlaceDetailView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(AppRouter.self) private var router
    /// What the route and trip screens take. For a place from search, made from the destination.
    let place: SamplePlace
    /// Picked in search; nil for My Location.
    var origin: SamplePlace?
    private let savedPlaceID: UUID?
    @State private var details: PlaceDetailViewModel
    @State private var showsSaveAlert = false
    @State private var saveLabel = ""
    @State private var showsRenameAlert = false
    @State private var renameLabel = ""

    /// A sample or recent place. Its coordinate is real, so its route is too.
    init(place: SamplePlace, origin: SamplePlace? = nil, services: AppServices) {
        let destination = Destination(
            name: place.name,
            coordinate: GeoCoordinate(latitude: place.latitude, longitude: place.longitude),
            address: place.address.isEmpty ? nil : place.address
        )
        self.place = place
        self.origin = origin
        self.savedPlaceID = nil
        _details = State(initialValue: PlaceDetailViewModel(destination: destination, services: services))
    }

    /// A real place picked from search results.
    init(destination: Destination, origin: SamplePlace? = nil, services: AppServices) {
        place = SamplePlace(destination: destination)
        self.origin = origin
        self.savedPlaceID = nil
        _details = State(initialValue: PlaceDetailViewModel(destination: destination, services: services))
    }

    /// A place previously saved by the user.
    init(savedPlace: SavedPlace, origin: SamplePlace? = nil, services: AppServices) {
        place = savedPlace.asSamplePlace()
        self.origin = origin
        self.savedPlaceID = savedPlace.id
        _details = State(initialValue: PlaceDetailViewModel(destination: savedPlace.destination, services: services))
    }

    private var savedPlace: SavedPlace? {
        if let savedPlaceID, let match = app.savedPlacesStore.savedPlace(id: savedPlaceID) {
            return match
        }
        return app.savedPlacesStore.savedPlace(matching: details.destination)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraBackdrop()
            ScrollView {
                BottomCard {
                    if let saved = savedPlace, let label = saved.label {
                        Label(label, systemImage: "bookmark.fill")
                            .font(.title2.bold())
                            .foregroundStyle(Theme.cyan)
                            .accessibilityAddTraits(.isHeader)
                        Text(details.destination.name)
                            .font(.headline)
                    } else {
                        Text(details.destination.name)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let address = details.destination.address {
                        Text(address)
                            .font(.subheadline.weight(.semibold))
                    }
                    Label("From: \(origin?.displayName ?? "My Location")", systemImage: origin == nil ? "location.fill" : "circle.inset.filled")
                        .font(.subheadline)
                        .accessibilityLabel("From \(origin?.displayName ?? "my location")")
                    RoutePreview(details: details, origin: origin)
                        .padding(.top, 4)
                    VStack(spacing: 14) {
                        Button("Start & Record New Route") {
                            Haptics.play(.success)
                            router.push(.trip(TripPlan(
                                place: place, route: nil, isRecording: true, origin: origin,
                                plannedRoute: details.plannedRoute
                            )))
                        }
                        .buttonStyle(.pill(.destructive))
                        .accessibilityHint("Starts walking and saves the route you take")

                        if place.recordedRouteCount > 0 {
                            Button("Start Recorded Route") { chooseRoutes(.recorded) }
                                .buttonStyle(.pill(.primary))
                        }
                        Button("Start New Route") { chooseRoutes(.new, planned: details.plannedRoute) }
                            .buttonStyle(.pill(.primary))

                        if let saved = savedPlace {
                            savedStatusButton(for: saved)
                        } else {
                            Button("Save place") {
                                saveLabel = ""
                                showsSaveAlert = true
                            }
                            .buttonStyle(.pill(.outline))
                            .accessibilityHint("Saves this place with an optional label like Home or Class")
                        }

                        Button("Back") { router.pop() }
                            .buttonStyle(.pill(.outline))
                    }
                    .padding(.top, 8)
                }
                .foregroundStyle(.white)
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
            .blackToBottomEdge()
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
        // route failed is spoken as on the Trip screen; route ready adds the summary
        .announcesRoute(details.planner) { details.routeReadyAnnouncement }
        .task { await details.start() }
        .alert("Save place", isPresented: $showsSaveAlert) {
            TextField("Label, e.g. Home or Class", text: $saveLabel)
            Button("Save") {
                let saved = app.savedPlacesStore.save(
                    destination: details.destination,
                    label: saveLabel,
                    category: place.category
                )
                AccessibilityNotification.Announcement("Saved \(saved.displayName)").post()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add an optional label like Home or Class, or leave blank to save as \(details.destination.name).")
        }
        .alert("Rename saved place", isPresented: $showsRenameAlert) {
            TextField("Label, e.g. Home or Class", text: $renameLabel)
            Button("Save") {
                guard let saved = savedPlace else { return }
                app.savedPlacesStore.rename(id: saved.id, to: renameLabel)
                let updatedName = app.savedPlacesStore.savedPlace(id: saved.id)?.displayName ?? saved.displayName
                AccessibilityNotification.Announcement("Renamed to \(updatedName)").post()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave blank to use \(details.destination.name).")
        }
    }

    private func savedStatusButton(for saved: SavedPlace) -> some View {
        Button {
            renameLabel = saved.label ?? saved.name
            showsRenameAlert = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(Theme.cyan)
                Text(saved.label.map { "Saved as \($0)" } ?? "Saved place")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("Edit")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.cyan)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.cyan.opacity(0.5), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(saved.label.map { "Saved as \($0)" } ?? "Saved place")
        .accessibilityHint("Opens rename dialog. Use actions to rename or delete.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Rename") {
            renameLabel = saved.label ?? saved.name
            showsRenameAlert = true
        }
        .accessibilityAction(named: "Delete") {
            deleteSavedPlace(saved)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameLabel = saved.label ?? saved.name
                showsRenameAlert = true
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleteSavedPlace(saved)
            }
        }
    }

    private func deleteSavedPlace(_ saved: SavedPlace) {
        let deletedName = saved.displayName
        app.savedPlacesStore.delete(id: saved.id)
        AccessibilityNotification.Announcement("Deleted \(deletedName)").post()
    }

    /// Start Route → Success, as for every Start button.
    private func chooseRoutes(_ mode: RoutePlanMode, planned: PlannedRoute? = nil) {
        Haptics.play(.success)
        router.push(.routes(place, mode, origin: origin, planned: planned))
    }
}

/// The walking route to a place: its summary and the first few steps, or why it isn't
/// here yet (finding it, failed with Try again, location off). On place details and the
/// route picker.
struct RoutePreview: View {
    let details: PlaceDetailViewModel
    /// Picked in search; nil for My Location.
    var origin: SamplePlace?

    /// Steps shown before "+ N more steps".
    private static let stepCount = 3

    var body: some View {
        if let summary = details.summary {
            VStack(alignment: .leading, spacing: 8) {
                Label(summary, systemImage: "figure.walk")
                    .font(.headline)
                if let note = details.backupNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
                if origin != nil {
                    Text("Walking directions start where you are.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 6) {
                    // A preview only, so the card fits under the title; the trip reads every step.
                    ForEach(Array(details.steps.prefix(Self.stepCount).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).")
                                .monospacedDigit()
                                .accessibilityHidden(true)
                            Text(step)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(index + 1), \(step)")
                    }
                    let remaining = details.steps.count - Self.stepCount
                    if remaining > 0 {
                        Text(remaining == 1 ? "+ 1 more step" : "+ \(remaining) more steps")
                            .foregroundStyle(.white.opacity(0.7))
                            .accessibilityLabel(remaining == 1 ? "1 more step" : "\(remaining) more steps")
                    }
                }
                .font(.subheadline)
            }
        } else if let message = details.errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                Button("Try again") { details.retry() }
                    .buttonStyle(.pill(.outline, size: .compact))
                    .accessibilityHint("Asks for the walking route again")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.red.opacity(0.25), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if details.needsLocationAccess {
            Label("Location is off. Turn it on in Settings to see the walking route.", systemImage: "location.slash.fill")
                .font(.subheadline)
        } else {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("Finding a walking route…")
                    .font(.subheadline)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PlaceDetailView(place: MapsPreviewData.place, services: .preview)
    }
    .environment(AppViewModel.preview)
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
#endif

#Preview("From search") {
    NavigationStack {
        PlaceDetailView(destination: Destination(
            name: "Clough Undergraduate Learning Commons",
            coordinate: GeoCoordinate(latitude: 33.7746, longitude: -84.3964),
            address: "266 4th St NW, Atlanta, GA"
        ), services: .preview)
    }
    .environment(AppViewModel.preview)
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
