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
