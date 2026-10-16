import Foundation

/// Visual and semantic state of the Apple container service as shown in the menu bar.
enum ServiceState: Equatable, Sendable {
    /// Service is up; green dot.
    case running
    /// Service is off; red dot.
    case stopped
    /// No CLI found, or it did not answer `system status` in time; gray hollow dot.
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
    /// Saida cortada no teto de captura: JSON ou tabela incompletos nao
    /// podem ser lidos como resposta valida.
    var truncated: Bool = false

    /// O processo terminou com exit 0 dentro do prazo. Vale para mutacoes
    /// (start/stop/toggle): saida grande ou incompleta nao desfaz um start.
    var exitedCleanly: Bool { spawned && !timedOut && exitCode == 0 }
    /// exitedCleanly E saida completa: exigido por quem interpreta stdout.
    var succeeded: Bool { exitedCleanly && !truncated }
}
