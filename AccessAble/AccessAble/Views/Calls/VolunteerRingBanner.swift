import SwiftUI

/// "Shruthi · Is calling you" at the top of the caller's screen when a volunteer calls (CALLBACK-1).
struct VolunteerRingBanner: View {
    let onAccept: (Volunteer, VolunteerRing) -> Void
    @State private var watcher: VolunteerRingWatcher
    @Environment(\.scenePhase) private var scenePhase
    @AccessibilityFocusState private var acceptFocused: Bool

    init(services: AppServices, onAccept: @escaping (Volunteer, VolunteerRing) -> Void) {
        self.onAccept = onAccept
        _watcher = State(initialValue: VolunteerRingWatcher(
            services: services, alerts: IncomingCallAlerts(haptics: services.haptics)))
    }

    var body: some View {
        Group {
            if let ring = watcher.ring {
                HStack(spacing: 12) {
                    PersonAvatar(userID: ring.volunteerID, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(watcher.volunteerName).font(.headline)
                        Text("Is calling you").font(.footnote)
                    }
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    CallControlButton(systemImage: "phone.fill", label: "Accept",
                                      hint: "Answers the call", diameter: 48) {
                        if let (volunteer, ring) = watcher.accept() { onAccept(volunteer, ring) }
                    }
                    .accessibilityFocused($acceptFocused)
                    CallControlButton(systemImage: "phone.down.fill", label: "Decline",
                                      hint: "Declines this call", style: .end, diameter: 48) {
                        watcher.decline()
                    }
                }
                .padding(14)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.3)))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isModal)
                .task(id: ring.id) {
                    try? await Task.sleep(for: .milliseconds(300))
                    acceptFocused = true
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: watcher.ring?.id)
        .task(id: scenePhase == .active) {
            if scenePhase == .active { await watcher.listen() }
        }
    }
}
