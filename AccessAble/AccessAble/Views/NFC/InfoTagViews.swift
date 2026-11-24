import MapKit
import SwiftUI

/// Owner: Maps + Interaction. NFC info tags: the pins on each map, the pop-up for scanning,
/// and the description screen (read aloud for blind users, editable by volunteers).

/// Pins for every info tag. Each pin is tagged with its ID so the map's selection opens it.
struct InfoTagPins: MapContent {
    let tags: [InfoTag]

    var body: some MapContent {
        ForEach(tags) { tag in
            Marker("Info tag", systemImage: "wave.3.right", coordinate: tag.coordinate.clCoordinate)
                .tint(.orange)
                .tag(tag.id)
        }
    }
}

extension View {
    /// Adds the info tag button to a map and opens the pop-up when it, or a pin, is tapped.
    /// `selection` is the map's selection binding; it is cleared again once the pop-up closes.
    func infoTagOverlay(selection: Binding<String?>, alignment: Alignment) -> some View {
        modifier(InfoTagMapOverlay(selection: selection, alignment: alignment))
    }
}

struct InfoTagRoute: Hashable {
    let tagID: String
    var startsEditing = false
}

private struct InfoTagMapOverlay: ViewModifier {
    @Binding var selection: String?
    let alignment: Alignment
    // Optional so maps still render in previews without the app's environment.
    @Environment(InfoTagsModel.self) private var model: InfoTagsModel?
    @State private var isPresented = false
    @State private var path: [InfoTagRoute] = []

    func body(content: Content) -> some View {
        if let model {
            content
                .overlay(alignment: alignment) {
                    CircleIconButton(
                        systemImage: "wave.3.right",
                        label: "Info tags",
                        hint: model.tags.isEmpty
                            ? "Scan an NFC info tag"
                            : "Scan an NFC info tag, or hear the \(model.tags.count) tags on the map",
                        fill: .orange,
                        diameter: 52
                    ) {
                        Haptics.play(.selection)
                        path = []
                        isPresented = true
                    }
                    .padding(12)
                }
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    Haptics.play(.selection)
                    path = [InfoTagRoute(tagID: id)]
                    isPresented = true
                }
                .sheet(isPresented: $isPresented, onDismiss: { selection = nil }) {
                    NavigationStack(path: $path) {
                        InfoTagPanel(path: $path)
                            .navigationDestination(for: InfoTagRoute.self) { route in
                                InfoTagDetailView(tagID: route.tagID, startsEditing: route.startsEditing)
                            }
                    }
                    .environment(model)
                    .presentationDetents([.medium, .large])
                }
                .task { await model.load() }
        } else {
            content
        }
    }
}

/// The pop-up from the map button: scan a tag, set one up (volunteers), or pick one from the list.
struct InfoTagPanel: View {
    @Binding var path: [InfoTagRoute]
    @Environment(InfoTagsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isBusy = false
    @State private var busyMessage = ""
    @State private var errorMessage: String?
    @State private var here: GeoCoordinate?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.isVolunteer
                     ? "Scan a tag to read or edit its description, or set up a new sticker where you're standing."
                     : "Scan a tag to hear a description of the area around it.")
                    .foregroundStyle(.secondary)

                if model.canScan {
                    AccessibleActionButton(
                        title: "Scan tag",
                        systemImage: "wave.3.right",
                        hint: "Hold the top of your iPhone near the NFC tag"
                    ) {
                        run("Scanning…") { await model.scanTag() }
                    }
                    .disabled(isBusy)

                    if model.isVolunteer {
                        AccessibleActionButton(
                            title: "Set up new tag here",
                            systemImage: "plus.circle",
                            hint: "Pins a blank NFC sticker at your current location"
                        ) {
                            run("Finding your location…") { await model.setUpTagHere() }
                        }
                        .disabled(isBusy)
                    }
                } else {
                    Label("This device can't scan NFC tags. You can still open the tags on the map below.",
                          systemImage: "exclamationmark.triangle")
                }

                if isBusy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(busyMessage)
                    }
                    .accessibilityElement(children: .combine)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                tagList
            }
            .padding()
        }
        .navigationTitle("Info tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task { here = await model.currentLocation(timeout: .seconds(5)) }
    }

    @ViewBuilder
    private var tagList: some View {
        if !model.tags.isEmpty {
            Text("Tags on the map")
                .font(.headline)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(sortedTags) { tag in
                NavigationLink(value: InfoTagRoute(tagID: tag.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tag.hasDescription ? tag.text : "No description yet")
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(tag.hasDescription ? .primary : .secondary)
                        if let distance = distance(to: tag) {
                            Text(distance)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: AccessibilityMetrics.minimumTapTarget, alignment: .leading)
                    .padding(12)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Nearest first once the location is known.
    private var sortedTags: [InfoTag] {
        guard let here else { return model.tags }
        return model.tags.sorted {
            GeoMath.distance(from: here, to: $0.coordinate) < GeoMath.distance(from: here, to: $1.coordinate)
        }
    }

    private func distance(to tag: InfoTag) -> String? {
        guard let here else { return nil }
        let metres = GeoMath.distance(from: here, to: tag.coordinate)
        let text = Measurement(value: metres, unit: UnitLength.meters)
            .formatted(.measurement(width: .wide, usage: .road))
        return "\(text) away"
    }

    private func run(_ message: String, _ action: @escaping () async -> InfoTagsModel.ScanOutcome) {
        Haptics.play(.selection)
        errorMessage = nil
        busyMessage = message
        isBusy = true
        Task {
            let outcome = await action()
            isBusy = false
            switch outcome {
            case .opened(let id):
                Haptics.play(.success)
                path.append(InfoTagRoute(tagID: id))
            case .created(let id):
                Haptics.play(.success)
                path.append(InfoTagRoute(tagID: id, startsEditing: true))
            case .failed(let message):
                Haptics.play(.error)
                errorMessage = message
                AccessibilityNotification.Announcement(message).post()
            case .cancelled:
                break
            }
        }
    }
}

/// One tag's description. Read aloud on open for blind users; volunteers can edit it.
struct InfoTagDetailView: View {
    let tagID: String
    @Environment(InfoTagsModel.self) private var model
    @State private var isEditing: Bool
    @State private var draft = ""
    @State private var isSaving = false
    @State private var saveFailed = false
    @FocusState private var editorFocused: Bool

    init(tagID: String, startsEditing: Bool = false) {
        self.tagID = tagID
        _isEditing = State(initialValue: startsEditing)
    }

    var body: some View {
        ScrollView {
            if let tag = model.tag(id: tagID) {
                VStack(alignment: .leading, spacing: 16) {
                    if isEditing {
                        editor
                    } else {
                        Text(tag.hasDescription ? tag.text : "No description has been added for this tag yet.")
                            .font(.title3)
                            .foregroundStyle(tag.hasDescription ? .primary : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Updated \(tag.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        AccessibleActionButton(
                            title: "Read aloud",
                            systemImage: "speaker.wave.2.fill",
                            hint: "Speaks the description"
                        ) {
                            Haptics.play(.selection)
                            model.readAloud(tag)
                        }

                        if model.isVolunteer {
                            AccessibleActionButton(
                                title: tag.hasDescription ? "Edit description" : "Add description",
                                systemImage: "square.and.pencil",
                                hint: "Describe the surroundings for blind and low vision users"
                            ) {
                                startEditing(tag)
                            }
                        }
                    }
                }
                .padding()
                .onAppear {
                    if isEditing { startEditing(tag) }
                    // Blind and low vision users hear it straight away.
                    if !model.isVolunteer { model.readAloud(tag) }
                }
            } else {
                Text("This tag is no longer on the map.")
                    .padding()
            }
        }
        .navigationTitle("Info tag")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe what's around this tag: what's nearby, which way things are, and anything to watch out for.")
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 180)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .focused($editorFocused)
                .accessibilityLabel("Description")

            if saveFailed {
                Label("Couldn't save. Try again.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    isEditing = false
                    saveFailed = false
                }
                .buttonStyle(.pill(.outline, size: .compact))

                Button("Save") { save() }
                    .buttonStyle(.pill(.primary, size: .compact))
                    .disabled(isSaving)
            }
        }
    }

    private func startEditing(_ tag: InfoTag) {
        draft = tag.text
        saveFailed = false
        isEditing = true
        editorFocused = true
    }

    private func save() {
        isSaving = true
        Task {
            let saved = await model.saveDescription(draft, for: tagID)
            isSaving = false
            saveFailed = !saved
            if saved {
                Haptics.play(.success)
                isEditing = false
                AccessibilityNotification.Announcement("Description saved.").post()
            } else {
                Haptics.play(.error)
            }
        }
    }
}
