import Foundation

public final class BookmarkStore {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "vault.references") {
        self.defaults = defaults; self.key = key
    }
    public func save(_ urls: [URL]) throws {
        // Complete all bookmark generation first: failures must not discard existing references.
        let data = try urls.map { try $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
        defaults.set(data, forKey: key)
    }
    public func restore() -> (urls: [URL], unavailable: Int) {
        let saved = defaults.array(forKey: key) as? [Data] ?? []
        var urls: [URL] = [], unavailable = 0
        for data in saved {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                urls.append(url)
            } else { unavailable += 1 }
        }
        // A later explicit add/remove renews stale bookmarks while preserving unresolved ones for now.
        return (urls, unavailable)
    }
}
