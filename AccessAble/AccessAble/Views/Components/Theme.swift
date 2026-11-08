import SwiftUI
import UIKit

/// Colors from the AccessAble design.
enum Theme {
    /// Primary action fill. Black text on it.
    static let cyan = Color(red: 0.76, green: 0.97, blue: 0.96)
    /// Destructive / urgent fill. White text on it (4.6:1).
    static let red = Color(red: 0.78, green: 0.29, blue: 0.26)
    static let navy = Color(red: 0.12, green: 0.16, blue: 0.23)
    /// Bottom control panel behind Call Help / Pause Trip.
    static let panel = Color(white: 0.2)
    static let bubble = Color(white: 0.33)
    static let placeholder = Color(white: 0.94)
    static let online = Color(red: 0.24, green: 0.45, blue: 0.27)
    static let sparkle = Color(red: 0.98, green: 0.92, blue: 0.48)
    /// Opacity for controls that are shown but not active (tutorial, first/last route).
    static let dimmedOpacity = 0.45
}

// MARK: - Buttons

/// Full-width capsule button used across the redesigned screens.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, destructive, outline }
    enum Size { case regular, compact }

    var kind: Kind
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind, size: size)
    }

    private struct PillButtonBody: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(size == .regular ? .title3.weight(.semibold) : .body)
                .multilineTextAlignment(.center)
                .foregroundStyle(foreground)
                .padding(.horizontal, size == .regular ? 20 : 18)
                .padding(.vertical, size == .regular ? 12 : 8)
                .frame(maxWidth: size == .regular ? .infinity : nil)
                .frame(minHeight: size == .regular ? 52 : AccessibilityMetrics.minimumTapTarget)
                .background(background, in: Capsule())
                .overlay {
                    if kind == .outline {
                        Capsule().strokeBorder(Theme.cyan, lineWidth: 2)
                    }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : Theme.dimmedOpacity)
        }

        private var foreground: Color {
            switch kind {
            case .primary: .black
            case .destructive: .white
            case .outline: Theme.cyan
            }
        }

        private var background: Color {
            switch kind {
            case .primary: Theme.cyan
            case .destructive: Theme.red
            case .outline: .black.opacity(0.001)
            }
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ kind: PillButtonStyle.Kind, size: PillButtonStyle.Size = .regular) -> PillButtonStyle {
        PillButtonStyle(kind: kind, size: size)
    }
}

/// Round icon button (settings, info, microphone, call, message).
struct CircleIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var hint: LocalizedStringKey?
    var fill: Color = Theme.cyan
    var foreground: Color = .black
    var diameter: CGFloat = 64
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.42, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: diameter, height: diameter)
                .background(fill, in: Circle())
                .opacity(isEnabled ? 1 : Theme.dimmedOpacity)
                .frame(minWidth: AccessibilityMetrics.minimumTapTarget, minHeight: AccessibilityMetrics.minimumTapTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }
}

// MARK: - Shared pieces

/// The AccessAble mark: an eye with a sparkle, in a dark outlined circle.
struct AppLogo: View {
    var size: CGFloat = 170

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Color(white: 0.36), Color(white: 0.12)],
                    center: .center, startRadius: 0, endRadius: size / 2
                ))
            Image(systemName: "eye")
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(Color(white: 0.8))
                .frame(width: size * 0.62)
            Image(systemName: "sparkle")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Theme.sparkle)
                .shadow(color: Theme.sparkle.opacity(0.8), radius: size * 0.06)
                .frame(width: size * 0.42)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
        .accessibilityHidden(true)
    }
}

/// Stands in for the live camera feed until the camera is wired into these screens.
struct CameraBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.13, blue: 0.20),
                Color(red: 0.16, green: 0.19, blue: 0.25),
                Color(red: 0.34, green: 0.25, blue: 0.13),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Large title with a back chevron, as on Search Destination and Call Help.
struct ScreenHeader: View {
    let title: LocalizedStringKey
    let onBack: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            // One line like the design; wrap instead at accessibility text sizes.
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }
}

/// Black card with rounded top corners that sits on the bottom edge.
struct BottomCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32, style: .continuous)
                .fill(.black)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Light-gray rounded square where a place photo will go.
struct PlaceThumbnail: View {
    var size: CGFloat = 72

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.placeholder)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// "4.5 ★★★★☆ (45)"
struct RatingView: View {
    let rating: Double
    let reviewCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(rating, format: .number.precision(.fractionLength(1)))
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: symbol(for: index))
                }
            }
            Text(verbatim: "(\(reviewCount))")
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating.formatted(.number.precision(.fractionLength(1)))) out of 5, \(reviewCount) reviews")
    }

    private func symbol(for index: Int) -> String {
        let value = rating - Double(index)
        if value >= 1 { return "star.fill" }
        if value >= 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// Gray circle avatar with a green dot when the person is available.
struct HelperAvatar: View {
    var isOnline: Bool
    var size: CGFloat = 60

    var body: some View {
        Circle()
            .fill(Theme.placeholder)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if isOnline {
                    Circle()
                        .fill(Theme.online)
                        .frame(width: size * 0.27, height: size * 0.27)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Wraps children onto new lines, like the category chips on Search Destination.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let neededWidth = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if neededWidth > maxWidth, !row.indices.isEmpty {
                let nextY = row.y + row.height + spacing
                rows.append(Row(indices: [index], y: nextY, width: size.width, height: size.height))
            } else {
                row.indices.append(index)
                row.width = neededWidth
                row.height = max(row.height, size.height)
                rows[rows.count - 1] = row
            }
        }
        return rows
    }
}

/// Two-finger swipe, used to switch between the camera and map views.
/// VoiceOver takes multi-finger swipes for itself, so screens also offer an accessibility action.
struct TwoFingerSwipe: UIGestureRecognizerRepresentable {
    var direction: UISwipeGestureRecognizer.Direction = .right
    let action: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UISwipeGestureRecognizer {
        let recognizer = UISwipeGestureRecognizer()
        recognizer.numberOfTouchesRequired = 2
        recognizer.direction = direction
        recognizer.cancelsTouchesInView = false
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UISwipeGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }
}
