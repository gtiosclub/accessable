import PhotosUI
import SwiftUI

extension EnvironmentValues {
    /// Where profile pictures come from (PROFILE-2).
    @Entry var avatars: any AvatarStore = PlaceholderAvatarStore()
}

// Pieces shared by the caller's Call Help screen and the volunteer's home screen.

extension Theme {
    /// Grouped cards and fields on the Call Help screens.
    static let card = Color(white: 0.17)
    static let field = Color(white: 0.27)
}

/// Live / History / Profile: a dark capsule with the chosen tab in a cyan pill.
struct CapsuleTabs<Tab: Hashable & CaseIterable & RawRepresentable>: View
where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    var hint: (Tab) -> String = { _ in "" }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let isSelected = selection == tab
                Button {
                    selection = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.title3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(isSelected ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(isSelected ? Theme.cyan : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                .accessibilityHint(hint(tab))
            }
        }
        .padding(4)
        // A subtle glass bar, as in the design. Reduce Transparency makes it solid on its own.
        .glassEffect(.regular.tint(Theme.card.opacity(0.6)), in: Capsule())
    }
}

/// A section title, with an optional star and a line under it.
struct CallHelpSectionHeader: View {
    let title: String
    var subtitle: String?
    var starred = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if starred {
                    Image(systemName: "star.fill").accessibilityHidden(true)
                }
                Text(title).font(.title3)
            }
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Rows on a rounded dark card, with a line between each.
struct CardGroup<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(height: 1)
                        .padding(.leading, 64)
                        .accessibilityHidden(true)
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A person on a card: avatar, name, a line under it, and call / message buttons.
struct PersonRow: View {
    var userID: String?
    let name: String
    let subtitle: String
    /// Cyan dot when true, red when false, none when nil.
    var isOnline: Bool?
    var onCall: (() -> Void)?
    var onMessage: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                PersonAvatar(userID: userID, isOnline: isOnline, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .foregroundStyle(.white)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)

            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }

            HStack(spacing: 8) {
                if let onCall {
                    CircleIconButton(systemImage: "phone.fill", label: "Video call \(name)", diameter: 36, action: onCall)
                }
                if let onMessage {
                    CircleIconButton(systemImage: "ellipsis.message", label: "Message \(name)", diameter: 36, action: onMessage)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var spokenLabel: String {
        var parts = [name]
        if let isOnline { parts.append(isOnline ? "online" : "offline") }
        if !subtitle.isEmpty { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }
}

/// The person's profile picture, or a plain circle without one, with an online (cyan) or
/// offline (red) dot.
struct PersonAvatar: View {
    init(userID: String? = nil, isOnline: Bool? = nil, size: CGFloat = 40,
         fill: some ShapeStyle = Theme.placeholder, image: Data? = nil) {
        self.userID = userID; self.isOnline = isOnline; self.size = size
        self.fill = AnyShapeStyle(fill); self.image = image
    }

    var userID: String?
    var isOnline: Bool?
    var size: CGFloat = 40
    var fill: AnyShapeStyle = AnyShapeStyle(Theme.placeholder)
    /// Shown instead of loading, for example right after an upload.
    var image: Data?

    @Environment(\.avatars) private var avatars
    @State private var loaded: UIImage?

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: size, height: size)
            .overlay {
                if let picture = image.flatMap(UIImage.init(data:)) ?? loaded {
                    Image(uiImage: picture).resizable().scaledToFill()
                        .frame(width: size, height: size).clipShape(Circle())
                }
            }
            .task(id: userID) {
                guard let userID else { loaded = nil; return }
                loaded = await avatars.avatar(userID: userID).flatMap(UIImage.init(data:))
            }
            .overlay(alignment: .bottomTrailing) {
                if let isOnline {
                    Circle()
                        .fill(isOnline ? Theme.cyan : Theme.red)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                }
            }
            .accessibilityHidden(true)
    }
}

/// The outlined search field at the top of a list.
struct CallHelpSearchField: View {
    @Binding var text: String
    var prompt = "Search"

    var body: some View {
        HStack {
            TextField("Search", text: $text, prompt: Text(prompt).foregroundStyle(.white.opacity(0.8)))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if text.isEmpty {
                // The keyboard's dictation key fills this in by voice.
                Image(systemName: "mic").foregroundStyle(.white).accessibilityHidden(true)
            } else {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.8)).minimumTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .overlay(Capsule().strokeBorder(.white, lineWidth: 1))
    }
}

/// Profile fields whose boxes all start on the same line. At accessibility text sizes each label
/// sits above its box instead.
struct ProfileFields<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) { content }
                .environment(\.profileFieldsStacked, true)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) { content }
        }
    }
}

extension EnvironmentValues {
    @Entry var profileFieldsStacked = false
}

/// A label and a dark rounded text field, as on the Profile tab. Put these in `ProfileFields`.
struct ProfileFieldRow: View {
    let label: String
    @Binding var text: String
    var axis: Axis = .horizontal
    @Environment(\.profileFieldsStacked) private var stacked

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                labelText
                field
            }
        } else {
            GridRow {
                labelText.gridColumnAlignment(.leading)
                field
            }
        }
    }

    private var labelText: some View {
        Text("\(label):").font(.subheadline.bold()).foregroundStyle(.white)
    }

    private var field: some View {
        TextField(label, text: $text, axis: axis)
            .font(.subheadline)
            .foregroundStyle(.white)
            .lineLimit(axis == .vertical ? 1...4 : 1...1)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(label)
    }
}

/// A label and a plain value on the same lines as `ProfileFieldRow`.
struct ProfileValueRow: View {
    let label: String
    let value: String
    @Environment(\.profileFieldsStacked) private var stacked

    var body: some View {
        if stacked {
            row
        } else {
            GridRow { row.gridCellColumns(2) }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Text("\(label):").font(.subheadline.bold()).foregroundStyle(.white)
            Text(value).font(.subheadline).foregroundStyle(Theme.cyan)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A label and a pop-up menu, like "Availability: Available ⌃⌄".
struct ProfileMenuRow: View {
    let label: String
    let value: String
    let choices: [String]
    let onSelect: (String) -> Void
    @Environment(\.profileFieldsStacked) private var stacked

    var body: some View {
        if stacked {
            row
        } else {
            GridRow { row.gridCellColumns(2) }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Text("\(label):").font(.subheadline.bold()).foregroundStyle(.white)
            Menu {
                ForEach(choices, id: \.self) { choice in
                    Button(choice) { onSelect(choice) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 44)
            }
            .accessibilityLabel(label)
            .accessibilityValue(value)
        }
    }
}

/// The picture and name at the top of a Profile tab, with "Upload Profile Picture".
struct ProfileHeader: View {
    let name: String
    var userID: String?
    var subtitle: String?

    @Environment(\.avatars) private var avatars
    @State private var pick: PhotosPickerItem?
    @State private var uploaded: Data?
    @State private var isUploading = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 8) {
            PersonAvatar(userID: userID, size: 96, fill: Theme.cyan, image: uploaded)
                .id(uploaded)
            Text(name).font(.title2).foregroundStyle(.white).accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
            if userID != nil {
                PhotosPicker(selection: $pick, matching: .images) {
                    Text(isUploading ? "Uploading…" : "Upload Profile Picture")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 44)
                        .background(Theme.field, in: Capsule())
                }
                .disabled(isUploading)
                .accessibilityHint("Choose a photo for callers and volunteers to see next to your name")
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.white) }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .onChange(of: message) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        isUploading = true
        defer { isUploading = false; pick = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw AvatarError.unreadableImage }
            uploaded = try await avatars.upload(data)
            message = "Profile picture saved."
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? AvatarError.unavailable.localizedDescription
        }
    }
}

/// A gray card listing choices, the chosen one in cyan (the volunteer's availability).
struct ChoiceList<Choice: Hashable & Identifiable>: View {
    let choices: [Choice]
    let selection: Choice?
    let title: (Choice) -> String
    let onSelect: (Choice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(choices) { choice in
                let isSelected = choice == selection
                Button { onSelect(choice) } label: {
                    Text(title(choice))
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 14)
                        .background(isSelected ? Theme.cyan : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The star in a chat header: fills when the person is saved.
struct SaveStarButton: View {
    let name: String
    let isSaved: Bool
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSaved ? "star.fill" : "star")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.cyan)
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(Theme.cyan, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(isSaved ? "Saved" : "Save \(name)")
        .accessibilityHint(isSaved ? "Removes \(name) from your saved people" : "Adds \(name) to your saved people")
        .accessibilityAddTraits(isSaved ? .isSelected : [])
    }
}

extension VolunteerAvailability: Identifiable {
    var id: String { rawValue }
}
