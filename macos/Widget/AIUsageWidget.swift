import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let cache: WidgetCache?

    static var preview: UsageEntry {
        let now = Date()
        return UsageEntry(date: now, cache: WidgetCache(
            snapshot: UsageSnapshot(title: "", details: [],
                fiveHour: UsageWindow(remainingPercent: 88, resetsAt: now.addingTimeInterval(7200).timeIntervalSince1970),
                weekly: UsageWindow(remainingPercent: 62, resetsAt: now.addingTimeInterval(172800).timeIntervalSince1970)),
            updatedAt: now, refreshFailed: false))
    }
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(context.isPreview ? .preview : UsageEntry(date: Date(), cache: readCache()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let cache = readCache()
        var entries = [UsageEntry(date: now, cache: cache)]
        // A future entry marks cached figures stale even after the app quits.
        if let expiry = cache?.expiresAt, expiry > now {
            entries.append(UsageEntry(date: expiry, cache: cache))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(5 * 60))))
    }

    private func readCache() -> WidgetCache? {
        guard let url = try? WidgetStore.sharedURL() else { return nil }
        return WidgetStore.read(from: url)
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry
    private var isStale: Bool { entry.cache?.isStale(at: entry.date) ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(.teal)
                Text("Codex").fontWeight(.semibold)
                Spacer()
                if isStale && entry.cache?.snapshot != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Cached usage is stale")
                }
            }
            .font(.caption)

            if let snapshot = entry.cache?.snapshot {
                if family == .systemMedium {
                    HStack(alignment: .top, spacing: 20) {
                        quota(snapshot.fiveHour, label: "5-hour", expanded: true)
                        quota(snapshot.weekly, label: "Weekly", expanded: true)
                    }
                } else {
                    quota(snapshot.fiveHour, label: "5-hour", expanded: false)
                    quota(snapshot.weekly, label: "Weekly", expanded: false)
                }
                Spacer(minLength: 0)
                footer
            } else {
                Spacer(minLength: 0)
                Text("Your allowance,\nat a glance.")
                    .font(.headline)
                Text("Open AI Usage to load usage.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .widgetURL(URL(string: "aiusage://refresh"))
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color.teal.opacity(0.12), Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func quota(_ window: UsageWindow?, label: String, expanded: Bool) -> some View {
        let remaining = window?.remainingPercent.map { min(100, max(0, $0)) }
        let tint: Color = remaining.map { $0 <= 10 ? .red : ($0 <= 25 ? .orange : .teal) } ?? .secondary
        return VStack(alignment: .leading, spacing: expanded ? 5 : 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                if !expanded {
                    Spacer(minLength: 2)
                    Text(remaining.map { String(format: "%.0f%%", $0) } ?? "—")
                        .font(.system(.headline, design: .rounded)).monospacedDigit()
                }
            }
            if expanded {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(remaining.map { String(format: "%.0f%%", $0) } ?? "—")
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("left").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Unknown is a neutral track, never a full allowance.
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        if let remaining {
                            Capsule().fill(tint).frame(width: geometry.size.width * remaining / 100)
                        }
                    }
            }.frame(height: 4)
            if expanded {
                if let reset = window?.resetDate {
                    Text("Resets \(reset.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Reset unavailable").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isStale ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(remaining.map { String(format: "%.0f percent remaining", $0) } ?? "unavailable")\(isStale ? ", stale" : "")")
        .accessibilityValue(window?.resetDate.map { "Resets \($0.formatted())" } ?? "Reset unavailable")
    }

    @ViewBuilder private var footer: some View {
        if isStale {
            Text("Stale · tap to refresh")
                .foregroundStyle(.secondary)
                .font(.system(size: 10))
        } else if let updated = entry.cache?.updatedAt {
            HStack(spacing: 3) {
                Text("Updated")
                Text(updated, style: .time)
            }
            .foregroundStyle(.secondary)
            .font(.system(size: 10))
        }
    }
}

@main
struct AIUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetCache.kind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("AI Usage")
        .description("Your remaining Codex allowances. Keep AI Usage running to stay up to date.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
