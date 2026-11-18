import SwiftUI

// Lets the voice agent operate a control. Add the matching modifier to any button, text
// field, toggle, slider or picker the agent should be able to use:
//
//     Button("Pick Route", action: pick)
//         .agentButton("Pick Route", action: pick)
//
// or, for a plain titled button, use `AgentButton("Pick Route", action: pick)` instead of
// `Button`. The control registers while it is on screen and the agent sees it by its label,
// so use the same words a sighted user would read.

extension EnvironmentValues {
    /// Where controls register. Nil in previews and onboarding, where nothing registers.
    @Entry var agentRegistry: AgentControlRegistry? = nil
    /// The agent asks the user before acting on controls inside (e.g. Settings).
    @Entry var agentActionsNeedConfirmation = false
    /// Controls inside are covered up (e.g. under the trip's paused card) and hidden from the agent.
    @Entry var agentControlsHidden = false
    /// Put before the labels of controls inside ("Prompted Announcements: Directions"), where
    /// the same label appears in more than one group.
    @Entry var agentLabelPrefix: String? = nil
}

extension View {
    /// - Parameter needsConfirmation: Ask before pressing. Nil inherits `agentActionsNeedConfirmation`.
    func agentButton(
        _ label: String,
        hint: String? = nil,
        isSelected: Bool = false,
        needsConfirmation: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        modifier(AgentControlModifier(
            control: AgentControl(id: "", kind: .button, label: label, hint: hint, isSelected: isSelected),
            needsConfirmation: needsConfirmation,
            handlers: .init(press: action)
        ))
    }

    /// `onSubmit` runs when the agent types with `submit`, like pressing return.
    func agentTextField(
        _ label: String,
        text: Binding<String>,
        hint: String? = nil,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        modifier(AgentControlModifier(
            control: AgentControl(id: "", kind: .textField, label: label, hint: hint, value: text.wrappedValue),
            needsConfirmation: false,
            handlers: .init(setText: { text.wrappedValue = $0 }, submit: onSubmit)
        ))
    }

    func agentToggle(_ label: String, isOn: Binding<Bool>, needsConfirmation: Bool? = nil) -> some View {
        modifier(AgentControlModifier(
            control: AgentControl(id: "", kind: .toggle, label: label, value: isOn.wrappedValue ? "on" : "off"),
            needsConfirmation: needsConfirmation,
            handlers: .init(setOn: { isOn.wrappedValue = $0 })
        ))
    }

    func agentSlider(
        _ label: String, value: Binding<Double>, in range: ClosedRange<Double>, needsConfirmation: Bool? = nil
    ) -> some View {
        modifier(AgentControlModifier(
            control: AgentControl(
                id: "", kind: .slider, label: label,
                value: value.wrappedValue.formatted(.number.precision(.fractionLength(0 ... 2))),
                range: range
            ),
            needsConfirmation: needsConfirmation,
            handlers: .init(setNumber: { value.wrappedValue = $0 })
        ))
    }

    /// A picker or segmented control. `choose` gets one of `options`.
    func agentChoice(
        _ label: String,
        options: [String],
        selected: String?,
        needsConfirmation: Bool? = nil,
        choose: @escaping (String) -> Void
    ) -> some View {
        modifier(AgentControlModifier(
            control: AgentControl(id: "", kind: .choice, label: label, value: selected, options: options),
            needsConfirmation: needsConfirmation,
            handlers: .init(choose: choose)
        ))
    }
}

/// `Button` that the voice agent can also press. Takes the button style, `.disabled` and
/// accessibility modifiers like a `Button`.
struct AgentButton<Label: View>: View {
    private let agentLabel: String
    private let hint: String?
    private let role: ButtonRole?
    private let isSelected: Bool
    private let needsConfirmation: Bool?
    private let action: () -> Void
    private let label: Label

    init(
        _ title: String,
        hint: String? = nil,
        role: ButtonRole? = nil,
        needsConfirmation: Bool? = nil,
        action: @escaping () -> Void
    ) where Label == Text {
        self.init(agentLabel: title, hint: hint, role: role, needsConfirmation: needsConfirmation, action: action) {
            Text(title)
        }
    }

    init(
        agentLabel: String,
        hint: String? = nil,
        role: ButtonRole? = nil,
        isSelected: Bool = false,
        needsConfirmation: Bool? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.agentLabel = agentLabel
        self.hint = hint
        self.role = role
        self.isSelected = isSelected
        self.needsConfirmation = needsConfirmation
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(role: role, action: action) { label }
            .agentButton(agentLabel, hint: hint, isSelected: isSelected, needsConfirmation: needsConfirmation, action: action)
    }
}

/// Registers one control while it is on screen and keeps its entry up to date.
private struct AgentControlModifier: ViewModifier {
    let control: AgentControl
    let needsConfirmation: Bool?
    let handlers: AgentControlRegistry.Handlers

    @Environment(\.agentRegistry) private var registry
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.agentActionsNeedConfirmation) private var scopeNeedsConfirmation
    @Environment(\.agentControlsHidden) private var isHidden
    @Environment(\.agentLabelPrefix) private var labelPrefix
    @State private var token = UUID()
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isOnScreen = true
                sync(onScreen: true)
            }
            .onDisappear {
                isOnScreen = false
                registry?.unregister(token, forget: true)
            }
            .onChange(of: resolved) { sync(onScreen: isOnScreen) }
            .onChange(of: isHidden) { sync(onScreen: isOnScreen) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                registry?.updateFrame(token, frame: frame)
            }
    }

    private var resolved: AgentControl {
        var control = control
        if let labelPrefix { control.label = "\(labelPrefix): \(control.label)" }
        control.isEnabled = control.isEnabled && isEnabled
        control.needsConfirmation = needsConfirmation ?? scopeNeedsConfirmation
        return control
    }

    private func sync(onScreen: Bool) {
        guard let registry else { return }
        if onScreen, !isHidden {
            registry.register(token, control: resolved, handlers: handlers)
        } else {
            registry.unregister(token)
        }
    }
}
