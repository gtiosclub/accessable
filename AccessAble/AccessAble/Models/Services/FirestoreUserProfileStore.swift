import FirebaseFirestore
import Foundation

struct FirestoreUserProfileStore: UserProfileStore {
    func load(userID: String) async throws -> UserProfile? {
        let snapshot = try await Firestore.firestore().collection("users").document(userID).getDocument()
        guard snapshot.exists else { return nil }
        guard let data = snapshot.data(),
              let rawRole = data["role"] as? String, let role = UserRole(rawValue: rawRole),
              let name = data["displayName"] as? String,
              let languages = data["languages"] as? [String],
              let createdAt = data["createdAt"] as? Timestamp,
              UserProfileValidation.isValid(displayName: name, languages: languages) else {
            throw UserProfileError.invalidProfile
        }
        return UserProfile(userID: userID, role: role, displayName: name,
                           languages: languages, createdAt: createdAt.dateValue())
    }

    func save(userID: String, role: UserRole, displayName: String,
              languages: [String]) async throws -> UserProfile {
        guard UserProfileValidation.isValid(displayName: displayName, languages: languages) else {
            throw UserProfileError.invalidProfile
        }
        let document = Firestore.firestore().collection("users").document(userID)
        // Confirm whether this is a new profile with the server before writing. Never
        // replace createdAt with the phone's time or overwrite it during an update.
        let existing = try await document.getDocument(source: .server)
        var values: [String: Any] = [
            "role": role.rawValue, "displayName": displayName, "languages": languages
        ]
        if existing.exists {
            try await document.updateData(values)
        } else {
            values["createdAt"] = FieldValue.serverTimestamp()
            try await document.setData(values)
        }
        guard let profile = try await load(userID: userID) else { throw UserProfileError.invalidProfile }
        return profile
    }
}

struct UnconfiguredUserProfileStore: UserProfileStore {
    func load(userID: String) async throws -> UserProfile? { throw UserProfileError.notConfigured }
    func save(userID: String, role: UserRole, displayName: String,
              languages: [String]) async throws -> UserProfile { throw UserProfileError.notConfigured }
}
