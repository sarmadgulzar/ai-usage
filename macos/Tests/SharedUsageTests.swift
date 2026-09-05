import Foundation

@main
enum SharedUsageTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(title: "AI 5h 88% · W —", details: [],
            fiveHour: UsageWindow(remainingPercent: 88, resetsAt: now.addingTimeInterval(120).timeIntervalSince1970),
            weekly: UsageWindow(remainingPercent: nil, resetsAt: nil))
        let cache = WidgetCache(snapshot: snapshot, updatedAt: now, refreshFailed: false)
        assert(!cache.isStale(at: now))
        assert(cache.isStale(at: now.addingTimeInterval(120)), "Reset must invalidate cached usage")
        let noReset = WidgetCache(snapshot: UsageSnapshot(title: "", details: [], fiveHour: nil, weekly: nil),
            updatedAt: now, refreshFailed: false)
        assert(!noReset.isStale(at: now.addingTimeInterval(299)))
        assert(noReset.isStale(at: now.addingTimeInterval(300)), "Stopped app must become stale")
        let failed = WidgetCache(snapshot: snapshot, updatedAt: now, refreshFailed: true)
        assert(failed.isStale(at: now), "Failed refresh must immediately mark retained usage stale")
        assert(WidgetCache(snapshot: nil, updatedAt: nil, refreshFailed: false).isStale(at: now))

        assert(cache.needsReload(comparedTo: nil, at: now, lastReload: nil))
        assert(!cache.needsReload(comparedTo: cache, at: now.addingTimeInterval(60), lastReload: now))
        let fetchedAgain = WidgetCache(snapshot: snapshot, updatedAt: now.addingTimeInterval(60), refreshFailed: false)
        assert(fetchedAgain.needsReload(comparedTo: cache, at: now.addingTimeInterval(60), lastReload: now),
               "A fresh fetch must update the widget timestamp even when quotas are unchanged")
        assert(failed.needsReload(comparedTo: failed, at: now, lastReload: now, force: true),
               "Manual refresh must reload even when a repeated failure preserves the same cache")
        assert(failed.needsReload(comparedTo: cache, at: now, lastReload: now))
        assert(cache.needsReload(comparedTo: failed, at: now, lastReload: now))
        assert(cache.needsReload(comparedTo: cache, at: now.addingTimeInterval(300), lastReload: now))
        let changed = WidgetCache(snapshot: UsageSnapshot(title: "", details: [],
            fiveHour: UsageWindow(remainingPercent: 80, resetsAt: snapshot.fiveHour?.resetsAt), weekly: snapshot.weekly),
            updatedAt: now, refreshFailed: false)
        assert(changed.needsReload(comparedTo: cache, at: now, lastReload: now))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        assert(WidgetStore.read(from: url) == nil)
        try WidgetStore.write(cache, to: url)
        let loaded = WidgetStore.read(from: url)!
        assert(loaded.snapshot?.fiveHour == snapshot.fiveHour)
        assert(loaded.snapshot?.weekly?.remainingPercent == nil, "Missing quota must remain unknown")
        assert(loaded.updatedAt == now)
        try WidgetStore.write(failed, to: url)
        assert(WidgetStore.read(from: url)?.refreshFailed == true)
        try Data("bad json".utf8).write(to: url)
        assert(WidgetStore.read(from: url) == nil)
        var futureVersion = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as! [String: Any]
        futureVersion["version"] = 2
        try JSONSerialization.data(withJSONObject: futureVersion).write(to: url)
        assert(WidgetStore.read(from: url) == nil, "Unknown cache versions must be rejected")
        print("Shared usage tests passed")
    }
}
