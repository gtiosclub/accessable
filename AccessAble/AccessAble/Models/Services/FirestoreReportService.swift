import FirebaseFirestore
import Foundation

struct ReportServiceConfigurationError: Error, Sendable {
    enum Reason: Sendable {
        case notSignedIn
        case permissionDenied
        case invalidReport
        case rateLimited
        case unavailable
    }

    let reason: Reason
}

private final class ReportListenerRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var registration: ListenerRegistration?

    func set(_ registration: ListenerRegistration) {
        lock.lock()
        self.registration = registration
        lock.unlock()
    }

    func remove() {
        lock.lock()
        let current = registration
        registration = nil
        lock.unlock()
        current?.remove()
    }
}

final class FirestoreReportService: ReportService, @unchecked Sendable {
    private let auth: any AuthService
    private let database: Firestore

    init(
        auth: any AuthService,
        database: Firestore = Firestore.firestore()
    ) {
        self.auth = auth
        self.database = database
    }

    func submit(_ report: Report) async throws {
        guard let user = await auth.currentUser() else {
            throw ReportServiceConfigurationError(reason: .notSignedIn)
        }

        guard user.id == report.reporterID,
              report.expiresAt > report.createdAt,
              report.coordinate.latitude.isFinite,
              report.coordinate.longitude.isFinite,
              (-90.0...90.0).contains(report.coordinate.latitude),
              (-180.0...180.0).contains(report.coordinate.longitude) else {
            throw ReportServiceConfigurationError(reason: .invalidReport)
        }

        let reportReference = database.collection("reports").document(report.id)
        let rateLimitReference = database.collection("rateLimits").document(user.id)

        var values: [String: Any] = [
            "id": report.id,
            "kind": report.kind.rawValue,
            "coordinate": Self.dictionary(report.coordinate),
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: report.expiresAt),
            "confirmations": 0,
            "reporterID": user.id
        ]

        if let area = report.area {
            values["area"] = area.map(Self.dictionary)
        }

        let batch = database.batch()
        batch.setData(values, forDocument: reportReference)
        batch.setData([
            "lastReportAt": FieldValue.serverTimestamp(),
            "lastReportId": report.id
        ], forDocument: rateLimitReference, merge: true)

        do {
            try await batch.commit()
        } catch {
            let failure = error as NSError
            if failure.domain == FirestoreErrorDomain,
               failure.code == FirestoreErrorCode.permissionDenied.rawValue {
                throw ReportServiceConfigurationError(reason: .permissionDenied)
            }
            throw ReportServiceConfigurationError(reason: .unavailable)
        }
    }

    func reports(
        near coordinate: GeoCoordinate,
        radius: Double
    ) async throws -> [Report] {
        guard radius.isFinite, radius >= 0 else {
            throw ReportServiceConfigurationError(reason: .invalidReport)
        }
        guard await auth.currentUser() != nil else {
            throw ReportServiceConfigurationError(reason: .notSignedIn)
        }

        let snapshot: QuerySnapshot
        do {
            snapshot = try await database.collection("reports")
                .order(by: "createdAt", descending: true)
                .limit(to: 200)
                .getDocuments()
        } catch {
            throw ReportServiceConfigurationError(reason: .unavailable)
        }

        return snapshot.documents.compactMap(Self.decode)
            .filter {
                $0.expiresAt > .now
                    && Self.isNear($0, coordinate: coordinate, radius: radius)
            }
    }

    func reportChanges(
        near coordinate: GeoCoordinate,
        radius: Double
    ) -> AsyncStream<[Report]> {
        let holder = ReportListenerRegistration()

        return AsyncStream { continuation in
            let query = database.collection("reports")
                .order(by: "createdAt", descending: true)
                .limit(to: 200)

            let registration = query.addSnapshotListener { snapshot, error in
                guard error == nil, let snapshot else {
                    // Keep the last known snapshot; an error is not proof that the area is empty.
                    return
                }

                let reports = snapshot.documents.compactMap(Self.decode)
                    .filter {
                        $0.expiresAt > .now
                            && Self.isNear($0, coordinate: coordinate, radius: radius)
                    }
                continuation.yield(reports)
            }

            holder.set(registration)
            continuation.onTermination = { @Sendable _ in holder.remove() }
        }
    }

    private static func decode(_ document: QueryDocumentSnapshot) -> Report? {
        let data = document.data()

        guard let id = data["id"] as? String,
              id == document.documentID,
              let rawKind = data["kind"] as? String,
              let kind = ReportKind(rawValue: rawKind),
              let coordinateData = data["coordinate"] as? [String: Double],
              let latitude = coordinateData["latitude"],
              let longitude = coordinateData["longitude"],
              let createdAt = data["createdAt"] as? Timestamp,
              let expiresAt = data["expiresAt"] as? Timestamp,
              let reporterID = data["reporterID"] as? String else {
            return nil
        }

        let area = (data["area"] as? [[String: Double]])?
            .compactMap { point -> GeoCoordinate? in
                guard let latitude = point["latitude"],
                      let longitude = point["longitude"] else {
                    return nil
                }
                return GeoCoordinate(latitude: latitude, longitude: longitude)
            }

        if let rawArea = data["area"] as? [[String: Double]], area?.count != rawArea.count {
            return nil
        }

        return Report(
            id: id,
            kind: kind,
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            area: area,
            createdAt: createdAt.dateValue(),
            expiresAt: expiresAt.dateValue(),
            confirmations: data["confirmations"] as? Int ?? 0,
            reporterID: reporterID
        )
    }

    private static func dictionary(_ coordinate: GeoCoordinate) -> [String: Double] {
        ["latitude": coordinate.latitude, "longitude": coordinate.longitude]
    }

    private static func isNear(
        _ report: Report,
        coordinate: GeoCoordinate,
        radius: Double
    ) -> Bool {
        if let area = report.area, !area.isEmpty {
            return area.contains {
                GeoMath.distance(from: coordinate, to: $0) <= radius
            } || GeoMath.distance(from: coordinate, to: report.coordinate) <= radius
        }
        return GeoMath.distance(from: coordinate, to: report.coordinate) <= radius
    }
}
