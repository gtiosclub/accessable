import FirebaseFirestore
import Foundation

struct FirestoreCallSafety: CallSafetyService {
    let auth: any AuthService
    private func uid() async throws -> String {
        guard let id = await auth.currentUser()?.id else { throw CallSafetyError.signedOut }
        return id
    }

    func hasConsent() async throws -> Bool {
        let id = try await uid()
        let data = try await Firestore.firestore().collection("callConsents").document(id).getDocument(source: .server).data()
        return data?["version"] as? Int == 1
    }

    func acceptConsent() async throws {
        let id = try await uid()
        let ref = Firestore.firestore().collection("callConsents").document(id)
        _ = try await Firestore.firestore().runTransaction { transaction, errorPointer -> Any? in
            do {
                let existing = try transaction.getDocument(ref)
                if existing.exists {
                    guard existing.data()?["version"] as? Int == 1 else { throw CallSafetyError.consentRequired }
                    return nil
                }
                transaction.setData(["version": 1, "acceptedAt": FieldValue.serverTimestamp()], forDocument: ref)
                return nil
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }
    }

    func report(callID: String, subjectID: String, reason: CallReportReason, details: String) async throws {
        guard !callID.isEmpty, !subjectID.isEmpty, CallSafetyReportLimit.length(of: details) <= CallSafetyReportLimit.maxLength else { throw CallSafetyError.invalidReport }
        let id = try await uid()
        // No client read of somebody else's report or private profile is needed.
        try await Firestore.firestore().collection("callSafetyReports").addDocument(data: [
            "callId": callID, "reporterId": id, "subjectId": subjectID,
            "reason": reason.rawValue, "details": details.trimmingCharacters(in: .whitespacesAndNewlines),
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    func block(volunteerID: String, callID: String) async throws {
        let id = try await uid()
        let ref = Firestore.firestore().collection("users").document(id)
            .collection("blockedVolunteers").document(volunteerID)
        _ = try await Firestore.firestore().runTransaction { transaction, errorPointer -> Any? in
            do {
                if try transaction.getDocument(ref).exists { return nil }
                transaction.setData(["callId": callID, "createdAt": FieldValue.serverTimestamp()], forDocument: ref)
                return nil
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }
    }
}

struct FirestoreVolunteerSettings: VolunteerSettingsStore {
    let auth: any AuthService
    private func uid() async throws -> String {
        guard let id = await auth.currentUser()?.id else { throw CallSafetyError.signedOut }
        return id
    }
    func preferences() async throws -> VolunteerPreferences {
        let id = try await uid()
        let data = try await Firestore.firestore().collection("volunteerSettings").document(id).getDocument(source: .server).data()
        guard let data else { return VolunteerPreferences() }
        guard let online = data["onlineByDefault"] as? Bool, let awake = data["keepScreenAwake"] as? Bool else {
            throw CallSafetyError.unavailable
        }
        return VolunteerPreferences(onlineByDefault: online, keepScreenAwake: awake)
    }
    func save(_ preferences: VolunteerPreferences) async throws {
        let id = try await uid()
        try await Firestore.firestore().collection("volunteerSettings").document(id).setData([
            "onlineByDefault": preferences.onlineByDefault, "keepScreenAwake": preferences.keepScreenAwake,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }
    /// No invites for the demo: any account that signed up as a volunteer may volunteer.
    func isInvited() async throws -> Bool {
        let id = try await uid()
        let data = try await Firestore.firestore().collection("users").document(id).getDocument(source: .server).data()
        return data?["role"] as? String == "volunteer"
    }
}

struct UnavailableCallSettings: CallSafetyService, VolunteerSettingsStore {
    func hasConsent() async throws -> Bool { throw CallSafetyError.unavailable }
    func acceptConsent() async throws { throw CallSafetyError.unavailable }
    func report(callID: String, subjectID: String, reason: CallReportReason, details: String) async throws { throw CallSafetyError.unavailable }
    func block(volunteerID: String, callID: String) async throws { throw CallSafetyError.unavailable }
    func preferences() async throws -> VolunteerPreferences { throw CallSafetyError.unavailable }
    func save(_ preferences: VolunteerPreferences) async throws { throw CallSafetyError.unavailable }
    func isInvited() async throws -> Bool { throw CallSafetyError.unavailable }
}
