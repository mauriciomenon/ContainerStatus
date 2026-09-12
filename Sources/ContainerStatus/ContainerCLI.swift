import Foundation
import os

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

    /// Directories scanned for the CLI, in priority order: the official .pkg
    /// install root, Homebrew on Apple Silicon and Intel, user-local prefixes
    /// and system paths, then whatever PATH the launching environment had.
    /// This is deliberately machine-independent: the app must work whether
    /// the CLI arrived via .pkg, brew or a source build with a custom prefix.
    static func searchDirectories() -> [String] {
        var directories = [
            "/usr/local/bin",                  // .pkg / `make install` default
            "/opt/homebrew/bin",               // Homebrew, Apple Silicon
            "/opt/homebrew/sbin",
            "/usr/local/sbin",
            NSHomeDirectory() + "/.local/bin", // pip/cargo-style user prefixes
            "/opt/sbin",
            "/usr/bin",
            "/bin",
        ]
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for item in inherited.split(separator: ":", omittingEmptySubsequences: true) {
            directories.append(String(item))
        }
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    /// First executable `container` found in the given directories.
    static func locateBinary(inDirectories directories: [String] = ContainerCLI.searchDirectories()) -> String? {
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("container").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Resolved CLI path behind a lock so a late install can be picked up
    /// without restarting the app.
    private let pathLock: OSAllocatedUnfairLock<String?>
    private let environment: [String: String]

    private var resolvedBinaryPath: String? {
        pathLock.withLock { $0 }
    }

    init(binaryPath: String? = ContainerCLI.locateBinary()) {
        self.pathLock = OSAllocatedUnfairLock(initialState: binaryPath)
        self.environment = [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]
    }

    // MARK: Operations

    /// Polls service status. Returns the state plus an optional detail line
    /// worth surfacing in the menu (only when something is actually wrong).
    func checkStatus() -> (state: ServiceState, detail: String?) {
        refreshBinaryPathIfNeeded()
        guard let binaryPath = resolvedBinaryPath,
              FileManager.default.isExecutableFile(atPath: binaryPath) else {
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
        guard let binaryPath = resolvedBinaryPath,
              FileManager.default.isExecutableFile(atPath: binaryPath) else {
            return CLIRunResult(stderr: "CLI container nao encontrada")
        }
        return Self.spawn(URL(fileURLWithPath: binaryPath), arguments: arguments,
                          environment: environment, timeout: timeout)
    }

    /// Re-scans only while the CLI has not been found, so installing it later
    /// (pkg, brew, source build) takes effect on the next poll without
    /// relaunching the app. Zero cost once resolved.
    private func refreshBinaryPathIfNeeded() {
        guard pathLock.withLock({ $0 == nil }) else { return }
        pathLock.withLock { $0 = Self.locateBinary() }
    }

    /// Synchronous spawn with a watchdog: waits on the termination handler,
    /// SIGTERMs on timeout and SIGKILLs if the child ignores that.
    private static func spawn(_ executable: URL, arguments: [String], environment: [String: String],
                              timeout: TimeInterval) -> CLIRunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
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
            let stdoutText = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            result = CLIRunResult(exitCode: process.terminationStatus, timedOut: false, spawned: true,
                                  stderr: stderrText.trimmingCharacters(in: .whitespacesAndNewlines),
                                  stdout: stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// CLI version (e.g. "1.4.1") parsed from `container --version`; the two
    /// digit groups of the current release must keep matching as they grow.
    func fetchVersion() -> String? {
        refreshBinaryPathIfNeeded()
        guard let binaryPath = resolvedBinaryPath,
              FileManager.default.isExecutableFile(atPath: binaryPath) else { return nil }
        let result = run(["--version"], timeout: Self.statusTimeout)
        return Self.parseVersion(result.stdout)
    }

    static func parseVersion(_ text: String) -> String? {
        guard let range = text.range(of: #"version\s+(\d+(?:\.\d+)+)"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range]).split(separator: " ").last.map(String.init)
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    }
}
