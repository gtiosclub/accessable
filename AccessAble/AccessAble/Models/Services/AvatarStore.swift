import FirebaseFirestore
import Foundation
import OSLog
import UIKit

private let log = Logger(subsystem: "AccessAble", category: "Avatars")

/// Profile pictures (PROFILE-2): a small JPEG per person, read by anyone signed in.
protocol AvatarStore: Sendable {
    /// The person's picture, or nil when they haven't set one. Cached after the first read.
    func avatar(userID: String) async -> Data?
    /// Sets the signed-in user's picture from any image data; it's cropped and shrunk first.
    func upload(_ imageData: Data) async throws -> Data
}

enum AvatarError: Error, LocalizedError, Equatable, Sendable {
    case signedOut, unreadableImage, unavailable

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to add a profile picture."
        case .unreadableImage: "That picture couldn't be used. Try another one."
        case .unavailable: "Your picture couldn't be saved. Try again."
        }
    }
}

enum AvatarImage {
    /// Firestore rules allow up to this many bytes.
    static let maxBytes = 200_000
    static let side: CGFloat = 256

    /// A centered square, 256 points, as JPEG under the size limit.
    static func jpeg(from data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = side / min(image.size.width, image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
        for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
            if let jpeg = square.jpegData(compressionQuality: quality), jpeg.count <= maxBytes { return jpeg }
        }
        return nil
    }
}

/// Keeps pictures for the session, so lists don't read the same one twice.
actor AvatarCache {
    private var images: [String: Data?] = [:]
    private var loading: [String: Task<Data?, Never>] = [:]

    func image(for userID: String, load: @escaping @Sendable () async -> Data?) async -> Data? {
        if let cached = images[userID] { return cached }
        if let task = loading[userID] { return await task.value }
        let task = Task { await load() }
        loading[userID] = task
        let value = await task.value
        images[userID] = value
        loading[userID] = nil
        return value
    }

    func set(_ data: Data?, for userID: String) { images[userID] = data }
}

struct FirestoreAvatarStore: AvatarStore {
    let auth: any AuthService
    let cache = AvatarCache()

    func avatar(userID: String) async -> Data? {
        await cache.image(for: userID) {
            let data = try? await Firestore.firestore().collection("avatars").document(userID).getDocument().data()
            return data?["jpeg"] as? Data
        }
    }

    func upload(_ imageData: Data) async throws -> Data {
        guard let me = await auth.currentUser()?.id else { throw AvatarError.signedOut }
        guard let jpeg = AvatarImage.jpeg(from: imageData) else { throw AvatarError.unreadableImage }
        do {
            try await Firestore.firestore().collection("avatars").document(me).setData([
                "jpeg": jpeg, "updatedAt": FieldValue.serverTimestamp(),
            ])
        } catch {
            // The screen only says it couldn't be saved; the real reason (often missing rules) goes here.
            log.error("avatar upload failed: \(String(describing: error), privacy: .public)")
            throw AvatarError.unavailable
        }
        await cache.set(jpeg, for: me)
        return jpeg
    }
}

/// Pictures kept in memory, for previews and builds without Firebase.
struct PlaceholderAvatarStore: AvatarStore {
    let cache = AvatarCache()
    var userID = PlaceholderChatService.userID

    func avatar(userID: String) async -> Data? { await cache.image(for: userID) { nil } }

    func upload(_ imageData: Data) async throws -> Data {
        guard let jpeg = AvatarImage.jpeg(from: imageData) else { throw AvatarError.unreadableImage }
        await cache.set(jpeg, for: userID)
        return jpeg
    }
}
