import AppKit
#if WIDGET_ENABLED
import WidgetKit
#endif

enum UsageReader {
    static func launchEnvironment(
        _ inherited: [String: String], recordedPath: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String: String] {
        var environment = inherited
        // Finder does not inherit the terminal's PATH. Release builds discover
        // Codex on the recipient's Mac instead of embedding the builder's path.
        let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", inherited["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        environment["PATH"] = searchPath
        if environment["CODEX_BIN"] == nil {
            let hint = recordedPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let hint, !hint.isEmpty, isExecutable(hint) {
                environment["CODEX_BIN"] = hint
            } else {
                environment["CODEX_BIN"] = searchPath.split(separator: ":")
                    .map { "\($0)/codex" }.first(where: isExecutable)
            }
        }
        return environment
    }

    static func read() throws -> UsageSnapshot {
        let process = Process()
        process.executableURL = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("ai-usage")
        process.arguments = ["--menu-bar-json"]

        let recordedPath = Bundle.main.url(forResource: "codex-path", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        process.environment = launchEnvironment(ProcessInfo.processInfo.environment, recordedPath: recordedPath)

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // Drain both pipes concurrently so verbose Codex diagnostics cannot
        // block the child while we wait for its JSON response.
        let errorReader = DispatchGroup()
        let capturedErrors = ErrorBuffer()
        errorReader.enter()
        DispatchQueue.global(qos: .utility).async {
            capturedErrors.data = errors.fileHandleForReading.readDataToEndOfFile()
            errorReader.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errorReader.wait()
        guard process.terminationStatus == 0 else {
            let diagnostics = String(decoding: capturedErrors.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "AIUsage", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: diagnostics.isEmpty ? "Usage reader failed." : diagnostics
            ])
        }
        return try JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    // Written by one background task and read only after its DispatchGroup joins.
    private final class ErrorBuffer: @unchecked Sendable {
        var data = Data()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var snapshot: UsageSnapshot?
    private var lastUpdated: Date?
    private var refreshError: String?
    private var refreshing = false
    #if WIDGET_ENABLED
    private var widgetError: String?
    private var publishedCache: WidgetCache?
    private var lastWidgetReload: Date?
    private var widgetReloadRequested = false
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        #if WIDGET_ENABLED
        if let url = try? WidgetStore.sharedURL(), let cache = WidgetStore.read(from: url) {
            snapshot = cache.snapshot
            lastUpdated = cache.updatedAt
        }
        #endif
        refresh()
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(scheduledRefresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc private func refresh() {
        #if WIDGET_ENABLED
        // Keep a manual request pending if a scheduled fetch is already running.
        widgetReloadRequested = true
        #endif
        performRefresh()
    }

    @objc private func scheduledRefresh() {
        performRefresh()
    }

    private func performRefresh() {
        // A cold-launch URL can arrive before applicationDidFinishLaunching.
        // Its unconditional refresh will service the request after setup.
        guard statusItem != nil, !refreshing else { return }
        refreshing = true
        render()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try UsageReader.read() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.lastUpdated = Date()
                    self.refreshError = nil
                case .failure(let error):
                    self.refreshError = error.localizedDescription
                }
                #if WIDGET_ENABLED
                self.publishWidget()
                #endif
                self.render()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "aiusage" && $0.host == "refresh" }) {
            refresh()
        }
    }

    #if WIDGET_ENABLED
    private func publishWidget() {
        let cache = WidgetCache(snapshot: snapshot, updatedAt: lastUpdated, refreshFailed: refreshError != nil)
        do {
            try WidgetStore.write(cache, to: WidgetStore.sharedURL())
            let now = Date()
            if cache.needsReload(comparedTo: publishedCache, at: now, lastReload: lastWidgetReload,
                                 force: widgetReloadRequested) {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetCache.kind)
                lastWidgetReload = now
            }
            widgetReloadRequested = false
            publishedCache = cache
            widgetError = nil
        } catch {
            widgetError = error.localizedDescription
        }
    }
    #endif

    private func render() {
        let title = snapshot?.title ?? (refreshing ? "AI …" : "AI unavailable")
        statusItem.button?.title = title + (refreshError == nil ? "" : " ⚠︎")
        statusItem.button?.toolTip = "Codex allowance remaining · refreshes every minute"
        let menu = NSMenu()
        menu.autoenablesItems = false
        addInfo("Codex · remaining allowance", to: menu)
        menu.addItem(.separator())
        if let snapshot {
            for detail in snapshot.details {
                // Put the reset on its own line to keep the menu compact.
                for (index, line) in detail.components(separatedBy: "; ").enumerated() {
                    let item = addInfo(line, to: menu)
                    item.indentationLevel = index == 0 ? 0 : 1
                }
            }
        } else {
            addInfo(refreshing ? "Fetching usage…" : "Usage unavailable", to: menu)
        }
        menu.addItem(.separator())
        if let lastUpdated {
            let formatted = DateFormatter.localizedString(from: lastUpdated, dateStyle: .short, timeStyle: .medium)
            addInfo("\(refreshError == nil ? "Updated" : "Stale · last updated") \(formatted)", to: menu)
        }
        if let refreshError {
            let item = addInfo("Refresh failed · retrying every minute", to: menu)
            item.toolTip = refreshError
            addAction("Show Error…", action: #selector(showError), to: menu)
        }
        #if WIDGET_ENABLED
        if let widgetError {
            addInfo("Widget sync failed", to: menu).toolTip = widgetError
        }
        #endif
        let refreshItem = addAction(refreshing ? "Refreshing…" : "Refresh Now", action: #selector(refresh), to: menu)
        refreshItem.isEnabled = !refreshing
        menu.addItem(.separator())
        addAction("Quit AI Usage", action: #selector(quit), to: menu).keyEquivalent = "q"
        statusItem.menu = menu
    }

    @discardableResult
    private func addInfo(_ title: String, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func addAction(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func showError() {
        let alert = NSAlert()
        alert.messageText = "Could not refresh Codex usage"
        alert.informativeText = String((refreshError ?? "Unknown error").suffix(6000))
            + "\n\nCheck your connection and run `codex login status` in Terminal. If needed, run `codex login`, then choose Refresh Now."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

#if !APP_DELEGATE_TESTING
@main
enum AIUsageApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
#endif
