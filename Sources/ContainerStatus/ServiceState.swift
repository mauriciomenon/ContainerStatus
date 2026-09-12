import Foundation

/// Visual and semantic state of the Apple container service as shown in the menu bar.
enum ServiceState: Equatable, Sendable {
    /// Service is up; green dot.
    case running
    /// Service is off; red dot.
    case stopped
    /// The CLI exists but could not be executed or answered in time; gray hollow dot.
    case notInstalled

    /// Maps a `container system status` outcome to a state.
    /// Exit 0 = running, exit 1 = not running (the CLI's documented output),
    /// any other nonzero code is still "not usable now" (red), and a timeout
    /// means the tool itself is wedged (treated as unavailable).
    static func from(exitCode: Int32, timedOut: Bool) -> ServiceState {
        if timedOut { return .notInstalled }
        return exitCode == 0 ? .running : .stopped
    }
}

/// Whether a start/stop requested from the menu is in flight.
enum ServiceActivity: Equatable, Sendable {
    case none
    case starting
    case stopping
}

/// Outcome of one CLI invocation.
struct CLIRunResult: Sendable {
    var exitCode: Int32 = -1
    var timedOut: Bool = false
    /// True when the process was actually launched (as opposed to spawn failure).
    var spawned: Bool = false
    var stderr: String = ""
    var stdout: String = ""

    var succeeded: Bool { spawned && !timedOut && exitCode == 0 }
}
