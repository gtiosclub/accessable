import LiveKit
import os
import SwiftUI

extension EnvironmentValues {
    /// Whether the video behind the call text is bright, so the text gets a dark glow, not a white one.
    @Entry var callBackgroundIsBright = false
}

extension View {
    /// The designer's glow on call text: 0 0 20px at 50%, white on a dark background and black on a
    /// bright one. SwiftUI's radius is about half of CSS's blur.
    func callTextGlow() -> some View { modifier(CallTextGlow()) }
}

private struct CallTextGlow: ViewModifier {
    @Environment(\.callBackgroundIsBright) private var isBright

    func body(content: Content) -> some View {
        content.shadow(color: (isBright ? Color.black : Color.white).opacity(0.5), radius: 10)
    }
}

// The in-call look shared by the caller and the volunteer: video behind, the other person's name
// large at the top, round controls down the right.

/// A round call control: cyan by default, black with a white ring when "on" (muted), red to end.
struct CallControlButton: View {
    enum Style { case standard, toggledOn, end }

    let systemImage: String
    let label: String
    var hint: String = ""
    var value: String?
    var style: Style = .standard
    var diameter: CGFloat = 60
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: diameter, height: diameter)
                // Tinted glass over the video, as in the design.
                .glassEffect(.regular.tint(background.opacity(style == .toggledOn ? 0.7 : 0.85)), in: Circle())
                .overlay { if style == .toggledOn { Circle().strokeBorder(.white, lineWidth: 2) } }
                .opacity(isEnabled ? 1 : Theme.dimmedOpacity)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityValue(value ?? "")
    }

    private var foreground: Color {
        switch style {
        case .standard: .black
        case .toggledOn, .end: .white
        }
    }

    private var background: Color {
        switch style {
        case .standard: Theme.cyan
        case .toggledOn: .black
        case .end: Theme.red
        }
    }
}

/// "0:45" since the call connected. VoiceOver reads it on request, not every second.
struct CallTimer: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.subheadline.monospacedDigit())
                .accessibilityLabel("Call time, \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))")
        }
    }
}

/// The name block at the top of a call: an optional small status line, the name, the timer.
struct CallTitleBlock: View {
    let name: String
    var status: String?
    var connectedSince: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let status {
                Text(status.uppercased()).font(.subheadline.weight(.medium))
            }
            Text(name)
                .font(.system(size: 36, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            if let connectedSince { CallTimer(since: connectedSince) }
        }
        .foregroundStyle(.white)
        .callTextGlow()
    }
}

/// A LiveKit track filling the screen, or the dark call background without one. Reports whether
/// the picture is bright through `isBright`.
struct CallVideoBackground: View {
    let track: VideoTrack?
    var mirrored = false
    var label: String
    @Binding var isBright: Bool

    var body: some View {
        ZStack {
            Color(white: 0.2)
            if let track {
                SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: mirrored ? .mirror : .off)
                    .accessibilityLabel(label)
            }
        }
        .ignoresSafeArea()
        .task(id: track.map { ObjectIdentifier($0 as AnyObject) }) {
            guard let track else {
                isBright = false
                return
            }
            let meter = VideoBrightnessMeter { bright in
                Task { @MainActor in isBright = bright }
            }
            track.add(videoRenderer: meter)
            // Stays attached until the track changes or the view goes away.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            track.remove(videoRenderer: meter)
        }
    }
}

/// Watches a video track's frames and says whether the picture is bright. Reads a sparse grid of
/// the luma plane twice a second; the two thresholds keep it from flickering near the middle.
final class VideoBrightnessMeter: NSObject, VideoRenderer, @unchecked Sendable {
    static let brightAbove = 150.0
    static let darkBelow = 120.0

    private let onChange: @Sendable (Bool) -> Void
    private let state = OSAllocatedUnfairLock(initialState: (lastSample: Date.distantPast, isBright: false))

    init(onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }

    func render(frame: VideoFrame) {
        let due = state.withLock { state in
            let now = Date()
            guard now.timeIntervalSince(state.lastSample) >= 0.5 else { return false }
            state.lastSample = now
            return true
        }
        guard due, let luma = Self.averageLuma(of: frame) else { return }
        let changed: Bool? = state.withLock { state in
            let next = Self.isBright(luma: luma, wasBright: state.isBright)
            guard next != state.isBright else { return nil }
            state.isBright = next
            return next
        }
        if let changed { onChange(changed) }
    }

    static func isBright(luma: Double, wasBright: Bool) -> Bool {
        wasBright ? luma >= darkBelow : luma > brightAbove
    }

    private static func averageLuma(of frame: VideoFrame) -> Double? {
        guard let buffer = frame.buffer.toI420() else { return nil }
        return buffer.withUnsafePlanes { planes in
            let width = Int(planes.width), height = Int(planes.height), stride = Int(planes.strideY)
            guard width > 0, height > 0 else { return nil }
            let step = max(1, min(width, height) / 24)
            var total = 0, count = 0
            for y in Swift.stride(from: 0, to: height, by: step) {
                for x in Swift.stride(from: 0, to: width, by: step) {
                    total += Int(planes.dataY[y * stride + x])
                    count += 1
                }
            }
            return count == 0 ? nil : Double(total) / Double(count)
        }
    }
}
