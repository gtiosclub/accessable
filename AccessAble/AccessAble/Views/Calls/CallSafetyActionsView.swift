import SwiftUI

/// The summary contains no media token. Both actions await server confirmation before success.
struct CallSafetyActionsView: View {
    @State private var model: CallSafetyActionsViewModel
    @State private var reporting = false
    @State private var confirmingBlock = false

    init(summary: CallSafetySummary, service: any CallSafetyService) {
        _model = State(initialValue: CallSafetyActionsViewModel(summary: summary, service: service))
    }

    var body: some View {
        VStack(spacing: 12) {
            Button(model.reported ? "Report sent" : "Report this call", systemImage: "flag") { reporting = true }
                .disabled(model.reported || model.isBusy)
                .frame(minHeight: 44)
                .accessibilityHint("Opens a private report for the club moderators")
            if model.summary.canBlockVolunteer {
                Button(model.blocked ? "Volunteer blocked" : "Block this volunteer", systemImage: "hand.raised", role: .destructive) {
                    confirmingBlock = true
                }
                .disabled(model.blocked || model.isBusy).frame(minHeight: 44)
                .accessibilityHint("Prevents this volunteer from being matched to you again")
            }
            if model.isBusy { ProgressView("Saving") }
            if let message = model.message { Text(message).font(.callout).multilineTextAlignment(.center) }
        }
        .sheet(isPresented: $reporting) { CallReportView(model: model) }
        .confirmationDialog("Block this volunteer?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block volunteer", role: .destructive) { Task { await model.block() } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.message) { _, text in
            if !reporting, let text { AccessibilityNotification.Announcement(text).post() }
        }
    }
}

private struct CallReportView: View {
    @Bindable var model: CallSafetyActionsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if model.reported {
                    Text("Report sent to the club moderators.")
                    Button("Done") { dismiss() }.frame(minHeight: 44)
                } else {
                    Picker("Reason", selection: $model.reason) {
                        ForEach(CallReportReason.allCases) { Text($0.title).tag($0) }
                    }.disabled(model.isBusy)
                    TextField("Additional details (optional)", text: $model.details, axis: .vertical)
                        .lineLimit(4...10).disabled(model.isBusy)
                    Text("\(model.details.count)/2000 characters").font(.caption)
                    Button(model.isBusy ? "Sending…" : "Send report") { Task { await model.report() } }
                        .disabled(model.isBusy || model.details.count > 2000).frame(minHeight: 44)
                }
                if let message = model.message { Text(message) }
            }
            .navigationTitle("Report call")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(model.isBusy) } }
            .interactiveDismissDisabled(model.isBusy)
            .onChange(of: model.message) { _, text in if let text { AccessibilityNotification.Announcement(text).post() } }
        }
    }
}
