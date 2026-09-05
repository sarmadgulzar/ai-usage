import Foundation

struct UsageWindow: Codable, Equatable {
    let remainingPercent: Double?
    let resetsAt: Double?

    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
}

struct UsageSnapshot: Codable {
    let title: String
    let details: [String]
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
}

// Only allowance data crosses into the sandboxed widget, never credentials or
// CLI diagnostics. The menu bar app remains responsible for fetching usage.
struct WidgetCache: Codable {
    static let kind = "AIUsageWidget"
    static let staleInterval: TimeInterval = 5 * 60
    let version: Int
    let snapshot: UsageSnapshot?
    let updatedAt: Date?
    let refreshFailed: Bool

    init(snapshot: UsageSnapshot?, updatedAt: Date?, refreshFailed: Bool) {
        version = 1
        self.snapshot = snapshot
        self.updatedAt = updatedAt
        self.refreshFailed = refreshFailed
    }

    var expiresAt: Date? {
        guard let updatedAt else { return nil }
        let resets = [snapshot?.fiveHour?.resetDate, snapshot?.weekly?.resetDate].compactMap { $0 }
        return ([updatedAt.addingTimeInterval(Self.staleInterval)] + resets).min()
    }

    func isStale(at date: Date) -> Bool {
        refreshFailed || expiresAt.map { date >= $0 } ?? true
    }

    func needsReload(comparedTo previous: WidgetCache?, at date: Date, lastReload: Date?, force: Bool = false) -> Bool {
        if force { return true }
        guard let previous, let lastReload else { return true }
        // The fetch timestamp is visible widget data, even when allowances
        // haven't changed. Publish each successful fetch, not just quota changes.
        return updatedAt != previous.updatedAt
            || snapshot?.fiveHour != previous.snapshot?.fiveHour
            || snapshot?.weekly != previous.snapshot?.weekly
            || refreshFailed != previous.refreshFailed
            || isStale(at: date) != previous.isStale(at: date)
            || date.timeIntervalSince(lastReload) >= Self.staleInterval
    }
}

enum WidgetStore {
    static func sharedURL() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AIUsageAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw NSError(domain: "AIUsage.Widget", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot access the widget app group. Rebuild with an Apple signing identity."
            ])
        }
        return container.appendingPathComponent("usage.json")
    }

    static func read(from url: URL) -> WidgetCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(WidgetCache.self, from: data),
              cache.version == 1 else { return nil }
        return cache
    }

    static func write(_ cache: WidgetCache, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }
}
