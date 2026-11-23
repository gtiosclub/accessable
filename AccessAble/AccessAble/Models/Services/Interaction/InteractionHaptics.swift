import SwiftUI
import UIKit

/// The system haptics from Apple's Human Interface Guidelines ("Playing haptics"), named the
/// way the interaction spec names them: Action → Interaction → Haptic.
/// - Selection: a subtle tick when a choice or value changes.
/// - Impact: a physical tap, light to heavy.
/// - Notification: the outcome of a task: success, warning, or error.
enum InteractionHaptic: Sendable, Hashable {
    case selection
    case light, medium, heavy, rigid, soft
    case success, warning, error
}

/// Owner: User Interaction (3.4). Plays `InteractionHaptic`s for taps and app feedback.
/// Follows the Haptics switch and Haptic Strength in Settings, which `AppViewModel` keeps in
/// step; guidance haptics (turns, obstacles) go through `HapticRendering` instead.
@MainActor
enum Haptics {
    /// Off when the user turns Haptics off in Settings.
    static var isEnabled = true
    /// Haptic Strength, 0...1. Scales impacts; selection and notification haptics have a
    /// fixed strength set by the system.
    static var intensity: Float = 1

    static func play(_ haptic: InteractionHaptic) {
        guard isEnabled else { return }
        render(haptic, intensity: intensity)
    }

    /// Plays regardless of the Haptics switch: for callers that have already checked it,
    /// like the announcement engine.
    static func render(_ haptic: InteractionHaptic, intensity: Float) {
        guard intensity > 0 else { return }
        HapticSounds.shared.play(haptic.taps, intensity: intensity)
        switch haptic {
        case .selection: selection.selectionChanged()
        case .light: impact(.light, intensity)
        case .medium: impact(.medium, intensity)
        case .heavy: impact(.heavy, intensity)
        case .rigid: impact(.rigid, intensity)
        case .soft: impact(.soft, intensity)
        case .success: notification.notificationOccurred(.success)
        case .warning: notification.notificationOccurred(.warning)
        case .error: notification.notificationOccurred(.error)
        }
    }

    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()
    private static var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, _ intensity: Float) {
        let generator = impacts[style] ?? UIImpactFeedbackGenerator(style: style)
        impacts[style] = generator
        generator.impactOccurred(intensity: CGFloat(min(intensity, 1)))
    }
}

extension Binding {
    /// The same binding, with a selection tick each time it is set from the UI.
    @MainActor
    func withSelectionHaptic() -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { newValue, transaction in
                // Ticks when haptics were on before or are on after, so the Haptics switch
                // itself confirms both ways.
                let wasEnabled = Haptics.isEnabled
                self.transaction(transaction).wrappedValue = newValue
                if wasEnabled || Haptics.isEnabled {
                    Haptics.render(.selection, intensity: Haptics.intensity)
                }
            }
        )
    }
}
