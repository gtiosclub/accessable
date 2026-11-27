import SwiftUI

/// Terminal call results. Reporting/blocking use SETTINGS-1's durable service unchanged.
struct EndOfCallView: View {
    let status: String
    let failure: CallFailure?
    let summary: CallSafetySummary?
    let safety: any CallSafetyService
    let onRetry: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool
    @State private var safetyModel: CallSafetyActionsViewModel?

    init(status: String, failure: CallFailure?, summary: CallSafetySummary?, safety: any CallSafetyService,
         onRetry: @escaping () -> Void, onOpenSettings: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.status = status; self.failure = failure; self.summary = summary; self.safety = safety
        self.onRetry = onRetry; self.onOpenSettings = onOpenSettings; self.onClose = onClose
        _safetyModel = State(initialValue: summary.map { CallSafetyActionsViewModel(summary: $0, service: safety) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(failure == nil ? "Call ended" : "Call couldn't finish")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text(status).font(.title3).fixedSize(horizontal: false, vertical: true)
                if let safetyModel {
                    Text("Call safety").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    CallSafetyActionsView(model: safetyModel).id(safetyModel.summary.id)
                }
                if failure?.needsSettings == true {
                    AccessibleActionButton(title: "Open Settings", systemImage: "gear",
                                           hint: "Opens iPhone settings to allow camera or microphone access", action: onOpenSettings)
                        .disabled(safetyModel?.isBusy == true)
                }
                AccessibleActionButton(title: failure == nil ? "Call again" : "Try again", systemImage: "arrow.clockwise",
                                       hint: "Starts another call. Blocked volunteers will be skipped.", action: onRetry)
                    .disabled(safetyModel?.isBusy == true)
                AccessibleActionButton(title: "Done", systemImage: "checkmark",
                                       hint: "Returns to the previous screen", action: onClose)
                    .disabled(safetyModel?.isBusy == true)
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white).background(Color.black.ignoresSafeArea())
        .accessibilityAction(.escape) { if safetyModel?.isBusy != true { onClose() } }
        .task { titleFocused = true }
    }
}

#Preview("Call ended, largest text") {
    EndOfCallView(status: "The volunteer left the call.", failure: nil,
        summary: CallSafetySummary(id: "preview", otherUserID: "helper", canBlockVolunteer: true),
        safety: PlaceholderCallSafety(), onRetry: {}, onOpenSettings: {}, onClose: {})
        .environment(\.dynamicTypeSize, .accessibility5)
}
