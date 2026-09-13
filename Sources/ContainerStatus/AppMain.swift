import AppKit
import Foundation

@main
struct AppMain {
    @MainActor
    static func main() {
        let includeUI = CommandLine.arguments.contains("--selftest-ui")
        if includeUI || CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit(includeUI: includeUI)
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let controller = StatusItemController()
            app.delegate = controller
            app.run()
        }
    }
}
