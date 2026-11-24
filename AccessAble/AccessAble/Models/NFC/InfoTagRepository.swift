import Foundation

/// Where info tags are stored. Today a JSON file on this phone (`LocalInfoTagRepository`);
/// a Firebase implementation can replace it without touching the views or `InfoTagsModel`.
protocol InfoTagRepository: Sendable {
    func loadAll() async throws -> [InfoTag]
    /// Inserts the tag, or replaces the stored one with the same ID.
    func save(_ tag: InfoTag) async throws
}

/// Keeps tags in a JSON file in Application Support. Only this phone sees them, so a tag set
/// up on one phone won't show on another until a shared backend replaces this.
actor LocalInfoTagRepository: InfoTagRepository {
    private let fileURL: URL
    private var cache: [InfoTag]?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL.applicationSupportDirectory.appending(path: "InfoTags.json")
    }

    func loadAll() async throws -> [InfoTag] {
        if let cache { return cache }
        let tags: [InfoTag]
        if FileManager.default.fileExists(atPath: fileURL.path()) {
            tags = try JSONDecoder().decode([InfoTag].self, from: Data(contentsOf: fileURL))
        } else {
            tags = []
        }
        cache = tags
        return tags
    }

    func save(_ tag: InfoTag) async throws {
        var tags = try await loadAll()
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[index] = tag
        } else {
            tags.append(tag)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(tags).write(to: fileURL, options: .atomic)
        cache = tags
    }
}

/// In memory only, for previews and tests.
actor InMemoryInfoTagRepository: InfoTagRepository {
    private var tags: [InfoTag]

    init(tags: [InfoTag] = []) {
        self.tags = tags
    }

    func loadAll() async throws -> [InfoTag] { tags }

    func save(_ tag: InfoTag) async throws {
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[index] = tag
        } else {
            tags.append(tag)
        }
    }
}
