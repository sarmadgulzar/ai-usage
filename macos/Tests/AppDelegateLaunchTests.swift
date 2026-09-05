import AppKit

@main
enum AppDelegateLaunchTests {
    static func main() {
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
