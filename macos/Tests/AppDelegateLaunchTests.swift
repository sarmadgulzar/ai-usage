import AppKit

@main
enum AppDelegateLaunchTests {
    static func main() {
        // Simulate Finder on another Mac where the build machine's CLI is absent.
        let discovered = UsageReader.launchEnvironment(["PATH": "/usr/bin:/bin"], recordedPath: "/old/mac/codex") {
            $0 == "/opt/homebrew/bin/codex"
        }
        precondition(discovered["CODEX_BIN"] == "/opt/homebrew/bin/codex")
        let release = UsageReader.launchEnvironment([:], recordedPath: nil) {
            $0 == "/usr/local/bin/codex"
        }
        precondition(release["CODEX_BIN"] == "/usr/local/bin/codex")
        let override = UsageReader.launchEnvironment(["CODEX_BIN": "/custom/codex"], recordedPath: "/build/codex") { _ in true }
        precondition(override["CODEX_BIN"] == "/custom/codex")
        let local = UsageReader.launchEnvironment([:], recordedPath: "/local/codex\n") { $0 == "/local/codex" }
        precondition(local["CODEX_BIN"] == "/local/codex")
        let missing = UsageReader.launchEnvironment([:], recordedPath: nil) { _ in false }
        precondition(missing["CODEX_BIN"] == nil)
        let inherited = UsageReader.launchEnvironment(["PATH": "/custom/bin:/usr/bin"], recordedPath: nil) { $0 == "/custom/bin/codex" }
        precondition(inherited["CODEX_BIN"] == "/custom/bin/codex")
        print("Codex discovery works across installations and preserves explicit overrides")

        let application = NSApplication.shared
        let delegate = AppDelegate()

        // AppKit delivers cold-launch URLs before applicationDidFinishLaunching.
        // This must return without trying to render the uninitialized status item.
        let url = URL(string: "aiusage://refresh")!
        delegate.application(application, open: [url])
        delegate.application(application, open: [url])

        print("Pre-launch refresh requests safely deferred")
    }
}
