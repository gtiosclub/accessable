import CoreGraphics
import Foundation

/// Owner: User Interaction (3.1). What the voice agent can operate on screen right now.
/// Views register their controls with the `.agentButton` / `.agentTextField` / … modifiers
/// when they appear and unregister when they go away; the agent reads `snapshot()` and acts
/// through the handlers.
///
/// Not `@Observable` on purpose: controls register and move during view updates, and no
/// view needs to redraw when they do.
@MainActor
final class AgentControlRegistry {
    /// How a control is operated. Each kind fills in the ones it supports.
    struct Handlers {
        var press: (() -> Void)?
        var setText: ((String) -> Void)?
        var submit: (() -> Void)?
        var setOn: ((Bool) -> Void)?
        var setNumber: ((Double) -> Void)?
        var choose: ((String) -> Void)?
    }

    private struct Entry {
        var control: AgentControl
        var handlers: Handlers
        let order: Int
    }

    private var entries: [UUID: Entry] = [:]
    /// Kept apart from `entries`: a control can be laid out before it registers, and keeps its
    /// place while hidden.
    private var frames: [UUID: CGRect] = [:]
    private var nextNumber = 1

    /// Adds the control, or updates it in place (keeping its id) if it is already registered.
    /// `control.id` is ignored: the registry assigns ids.
    func register(_ token: UUID, control: AgentControl, handlers: Handlers) {
        var control = control
        if let existing = entries[token] {
            control.id = existing.control.id
            entries[token] = Entry(control: control, handlers: handlers, order: existing.order)
        } else {
            control.id = "c\(nextNumber)"
            entries[token] = Entry(control: control, handlers: handlers, order: nextNumber)
            nextNumber += 1
        }
    }

    /// - Parameter forget: The control left the screen for good, not just hidden.
    func unregister(_ token: UUID, forget: Bool = false) {
        entries[token] = nil
        if forget { frames[token] = nil }
    }

    func updateFrame(_ token: UUID, frame: CGRect) {
        frames[token] = frame
    }

    /// Everything on screen, top to bottom, then left to right.
    func snapshot() -> [AgentControl] {
        entries
            .map { token, entry in (entry, frames[token] ?? .zero) }
            .sorted { lhs, rhs in
                let (left, leftFrame) = lhs
                let (right, rightFrame) = rhs
                // Rows a few points apart count as one line.
                if abs(leftFrame.minY - rightFrame.minY) > 8 { return leftFrame.minY < rightFrame.minY }
                if leftFrame.minX != rightFrame.minX { return leftFrame.minX < rightFrame.minX }
                return left.order < right.order
            }
            .map(\.0.control)
    }

    func control(id: String) -> AgentControl? {
        entries.values.first { $0.control.id == id }?.control
    }

    func handlers(id: String) -> Handlers? {
        entries.values.first { $0.control.id == id }?.handlers
    }
}
