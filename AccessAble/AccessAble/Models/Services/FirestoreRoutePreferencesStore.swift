import FirebaseFirestore
import Foundation

/// Keeps route preferences at `users/{uid}/settings/routePreferences`, which only that user may read or write.
struct FirestoreRoutePreferencesStore: RoutePreferencesSyncing {
    private func document(_ userID: String) -> DocumentReference {
        Firestore.firestore().collection("users").document(userID).collection("settings").document("routePreferences")
    }

    func load(userID: String) async throws -> RoutePreferences? {
        let snapshot = try await document(userID).getDocument()
        guard snapshot.exists else { return nil }
        return try snapshot.data(as: RoutePreferences.self)
    }

    func save(_ preferences: RoutePreferences, userID: String) async throws {
        var values = try Firestore.Encoder().encode(preferences)
        values["updatedAt"] = FieldValue.serverTimestamp()
        try await document(userID).setData(values)
    }
}
