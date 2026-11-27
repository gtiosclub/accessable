import Foundation
import Observation

/// The caller's side of CALLBACK-1: notices a volunteer who saved them back calling, while the
/// app is open, and rings until they answer, decline, or the ring ends.
@MainActor
@Observable
final class VolunteerRingWatcher {
    private(set) var ring: VolunteerRing?
    private(set) var volunteerName = "Volunteer"

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let alerts: any IncomingCallAlerting
    @ObservationIgnored private var dismissed: Set<String> = []
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private let now: () -> Date

    init(services: AppServices, alerts: any IncomingCallAlerting, now: @escaping () -> Date = Date.init) {
        self.services = services
        self.alerts = alerts
        self.now = now
    }

    func listen() async {
        guard let me = await services.auth.currentUser()?.id else { return }
        let saves = Task { [weak self, services] in
            do {
                for try await people in services.saves.savedPeople() {
                    self?.names = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                    if let ring = self?.ring { self?.volunteerName = self?.names[ring.volunteerID] ?? "Volunteer" }
                }
            } catch {}
        }
        defer { saves.cancel(); clear() }
        do {
            for try await rings in services.callSignaling.volunteerRings(callerID: me) {
                receive(rings)
            }
        } catch {}
    }

    func receive(_ rings: [VolunteerRing]) {
        let live = rings.first {
            !dismissed.contains($0.id) && now().timeIntervalSince($0.createdAt) < VolunteerRing.lifetime
        }
        guard live?.id != ring?.id else { return }
        if let live {
            ring = live
            volunteerName = names[live.volunteerID] ?? "Volunteer"
            alerts.start()
            alerts.announce("\(volunteerName) is calling you")
            let id = live.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(VolunteerRing.lifetime))
                if self?.ring?.id == id { self?.clear() }
            }
        } else {
            clear()
        }
    }

    /// Returns the ring to answer and the volunteer it's from.
    func accept() -> (Volunteer, VolunteerRing)? {
        guard let ring else { return nil }
        let volunteer = Volunteer(id: ring.volunteerID, name: volunteerName, availableUntil: "", isOnline: true)
        dismissed.insert(ring.id)
        clear()
        return (volunteer, ring)
    }

    func decline() {
        guard let ring else { return }
        dismissed.insert(ring.id)
        clear()
        Task { [services] in try? await services.callSignaling.declineVolunteerRing(callID: ring.id) }
    }

    private func clear() {
        if ring != nil { alerts.stop() }
        ring = nil
    }
}
