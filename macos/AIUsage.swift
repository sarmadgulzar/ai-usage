import AppKit

struct UsageSnapshot: Decodable {
    let title: String
    let details: [String]
}

enum UsageReader {
    static func read() throws -> UsageSnapshot {
        let process = Process()
        process.executableURL = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("ai-usage")
        process.arguments = ["--menu-bar-json"]

        // Finder does not inherit the terminal's PATH. The build records the
        // resolved Codex executable; CODEX_BIN remains available as an override.
        var environment = ProcessInfo.processInfo.environment
        if environment["CODEX_BIN"] == nil,
           let path = Bundle.main.url(forResource: "codex-path", withExtension: "txt"),
           let executable = try? String(contentsOf: path, encoding: .utf8) {
            environment["CODEX_BIN"] = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        process.environment = environment

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        refresh()
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc private func refresh() {
        guard !refreshing else { return }
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
                self.render()
            }
        }
    }

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

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
