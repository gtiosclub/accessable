import FirebaseFirestore
import Foundation
import OSLog

private let logger = Logger(subsystem: "AccessAble", category: "UserProfiles")

/// Turns Firestore's permission error into a clear one, and logs the real cause.
private func mapped(_ error: Error) -> Error {
    logger.error("Profile request failed: \(error.localizedDescription, privacy: .public)")
    let nsError = error as NSError
    if nsError.domain == FirestoreErrorDomain,
       nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
        return UserProfileError.permissionDenied
    }
    return error
}

struct FirestoreUserProfileStore: UserProfileStore {
    func load(userID: String) async throws -> UserProfile? {
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await Firestore.firestore().collection("users").document(userID).getDocument()
        } catch { throw mapped(error) }
        guard snapshot.exists else { return nil }
        guard let data = snapshot.data(),
              let rawRole = data["role"] as? String, let role = UserRole(rawValue: rawRole),
              let name = data["displayName"] as? String,
              let languages = data["languages"] as? [String],
              let createdAt = data["createdAt"] as? Timestamp,
              UserProfileValidation.isValid(displayName: name, languages: languages) else {
            throw UserProfileError.invalidProfile
        }
        let details = ProfileDetails(
            location: data["location"] as? String ?? "",
            condition: data["condition"] as? String ?? "",
            availability: (data["availability"] as? String).flatMap(VolunteerAvailability.init(rawValue:)))
        return UserProfile(userID: userID, role: role, displayName: name,
                           languages: languages, createdAt: createdAt.dateValue(), details: details)
    }

    func save(userID: String, role: UserRole, displayName: String,
              languages: [String]) async throws -> UserProfile {
        guard UserProfileValidation.isValid(displayName: displayName, languages: languages) else {
            throw UserProfileError.invalidProfile
        }
        let document = Firestore.firestore().collection("users").document(userID)
        // Confirm whether this is a new profile with the server before writing. Never
        // replace createdAt with the phone's time or overwrite it during an update.
        let existing: DocumentSnapshot
        do {
            existing = try await document.getDocument(source: .server)
        } catch { throw mapped(error) }
        var values: [String: Any] = [
            "role": role.rawValue, "displayName": displayName, "languages": languages
        ]
        if existing.exists {
            do { try await document.updateData(values) } catch { throw mapped(error) }
        } else {
            values["createdAt"] = FieldValue.serverTimestamp()
            do { try await document.setData(values) } catch { throw mapped(error) }
        }
        guard let profile = try await load(userID: userID) else { throw UserProfileError.invalidProfile }
        return profile
    }

    func saveDetails(userID: String, details: ProfileDetails) async throws {
        guard details.isValid else { throw UserProfileError.invalidProfile }
        var values: [String: Any] = [
            "location": details.location.trimmingCharacters(in: .whitespacesAndNewlines),
            "condition": details.condition.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let availability = details.availability { values["availability"] = availability.rawValue }
        do {
            try await Firestore.firestore().collection("users").document(userID).updateData(values)
        } catch { throw mapped(error) }
    }
}

struct UnconfiguredUserProfileStore: UserProfileStore {
    func load(userID: String) async throws -> UserProfile? { throw UserProfileError.notConfigured }
    func save(userID: String, role: UserRole, displayName: String,
              languages: [String]) async throws -> UserProfile { throw UserProfileError.notConfigured }
    func saveDetails(userID: String, details: ProfileDetails) async throws { throw UserProfileError.notConfigured }
}
