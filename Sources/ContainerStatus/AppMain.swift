import AppKit
import Foundation

@main
struct AppMain {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
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
