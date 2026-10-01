import SwiftUI

/// Minimum hit target from the accessibility baseline (Apple HIG: 44×44 pt).
enum AccessibilityMetrics {
    static let minimumTapTarget: CGFloat = 44
}

extension View {
    /// Guarantees at least a 44×44 pt hit area without changing the visual size.
    func minimumTapTarget() -> some View {
        frame(minWidth: AccessibilityMetrics.minimumTapTarget, minHeight: AccessibilityMetrics.minimumTapTarget)
            .contentShape(Rectangle())
    }

    /// Applies the baseline every interactive control needs: a label, an optional hint, and traits.
    /// Prefer this over setting them one by one so nothing is forgotten in review.
    func accessibleControl(
        label: LocalizedStringKey,
        hint: LocalizedStringKey? = nil,
        traits: AccessibilityTraits = .isButton
    ) -> some View {
        accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(traits)
    }
}
