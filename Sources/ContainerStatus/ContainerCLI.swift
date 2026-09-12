import Foundation

/// Thread-safe wrapper around the `container` CLI.
///
/// The CLI is the canonical interface to the service: `container system status`
/// answers "can I run containers" with its exit code, and `container system
/// start/stop` stop and start the whole service stack as the logged-in user,
/// with no root and no prompts. Every spawn gets an explicit environment
/// (Finder-launched apps inherit a minimal PATH) and a watchdog that kills a
/// hung child instead of blocking forever.
final class ContainerCLI: Sendable {
    /// Watchdog for `container system status`.
    private static let statusTimeout: TimeInterval = 2
    /// Watchdog for `container system start/stop`.
    private static let mutationTimeout: TimeInterval = 10

    private let binaryPath: String?
    private let environment: [String: String]

    init(binaryPath: String? = ContainerCLI.locateBinary()) {
        self.binaryPath = binaryPath
        self.environment = [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]
    }

    // MARK: Operations

    /// Polls service status. Returns the state plus an optional detail line
    /// worth surfacing in the menu (only when something is actually wrong).
    func checkStatus() -> (state: ServiceState, detail: String?) {
        guard let binaryPath, FileManager.default.isExecutableFile(atPath: binaryPath) else {
            return (.notInstalled, "CLI container nao encontrada")
        }
        let result = run(["system", "status"], timeout: Self.statusTimeout)
        let state = ServiceState.from(exitCode: result.exitCode, timedOut: result.timedOut)
        var detail: String?
        if !result.spawned {
            detail = result.stderr.isEmpty ? "Falha ao executar \(binaryPath)" : Self.firstLine(result.stderr)
        } else if result.timedOut {
            detail = "status: tempo limite excedido"
        } else if result.exitCode > 1 {
            detail = Self.firstLine(result.stderr)
        }
        return (state, detail)
    }

    /// Starts the service stack. Tries the plain `container system start`
    /// first (correct behavior, installs the kernel when needed); if that
    /// fails or hangs, retries once skipping the interactive first-run kernel
    /// prompt.
    func start() -> CLIRunResult {
        let plain = run(["system", "start"], timeout: Self.mutationTimeout)
        if plain.succeeded { return plain }
        let fallback = run(["system", "start", "--disable-kernel-install"], timeout: Self.mutationTimeout)
        if fallback.succeeded { return fallback }
        return plain.spawned ? plain : fallback
    }

    /// Stops the whole service stack (apiserver, machine-apiserver,
    /// core-images, vmnet).
    func stop() -> CLIRunResult {
        run(["system", "stop"], timeout: Self.mutationTimeout)
    }

    // MARK: Process plumbing

    /// Runs an arbitrary binary (used by the self-test against foreign
    /// executables); the production paths go through `run(_:timeout:)`.
    static func runBinary(_ path: String, arguments: [String], timeout: TimeInterval) -> CLIRunResult {
        spawn(URL(fileURLWithPath: path), arguments: arguments, environment: [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ], timeout: timeout)
    }

    private func run(_ arguments: [String], timeout: TimeInterval) -> CLIRunResult {
        guard let binaryPath, FileManager.default.isExecutableFile(atPath: binaryPath) else {
            return CLIRunResult(stderr: "CLI container nao encontrada")
        }
        return Self.spawn(URL(fileURLWithPath: binaryPath), arguments: arguments,
                          environment: environment, timeout: timeout)
    }

    /// Synchronous spawn with a watchdog: waits on the termination handler,
    /// SIGTERMs on timeout and SIGKILLs if the child ignores that.
    private static func spawn(_ executable: URL, arguments: [String], environment: [String: String],
                              timeout: TimeInterval) -> CLIRunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return CLIRunResult(stderr: error.localizedDescription)
        }

        var result: CLIRunResult
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + 1.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                semaphore.wait()
            }
            result = CLIRunResult(exitCode: process.terminationStatus, timedOut: true, spawned: true,
                                  stderr: "tempo limite excedido (\(Int(timeout))s)")
        } else {
            let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            result = CLIRunResult(exitCode: process.terminationStatus, timedOut: false, spawned: true,
                                  stderr: stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    }

    // MARK: Path resolution

    /// Resolves the CLI once at startup: known install locations first, then
    /// a PATH scan, so the app survives the binary moving between prefixes.
    static func locateBinary() -> String? {
        let known = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]
        for candidate in known where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("container").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
