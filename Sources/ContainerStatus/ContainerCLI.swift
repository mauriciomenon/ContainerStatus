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

    /// Every executable `container` in the given directories, priority order
    /// preserved.
    static func existingCandidates(inDirectories directories: [String] = ContainerCLI.searchDirectories()) -> [String] {
        directories.compactMap { directory in
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("container").path
            return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
        }
    }

    /// CLI version of one candidate, or nil when it does not answer with one.
    static func probeVersion(_ path: String) -> String? {
        parseVersion(runBinary(path, arguments: ["--version"], timeout: statusTimeout).stdout)
    }

    /// Strict semver-ish comparison ("1.4.1" > "1.3.1", "10.0" > "9.9.9");
    /// nil (no version) always loses, equal is not newer.
    static func isVersionNewer(_ candidate: String?, than incumbent: String?) -> Bool {
        guard let candidate else { return false }
        guard let incumbent else { return true }
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let incumbentParts = incumbent.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(candidateParts.count, incumbentParts.count) {
            let c = index < candidateParts.count ? candidateParts[index] : 0
            let i = index < incumbentParts.count ? incumbentParts[index] : 0
            if c != i { return c > i }
        }
        return false
    }

    /// A resolved CLI plus the candidate set it was chosen from, so the
    /// instance can detect installs/uninstalls cheaply (stat-only).
    struct ResolvedCLI: Sendable, Equatable {
        var path: String
        var candidates: Set<String>
    }

    /// Picks the newest candidate by version; ties keep the priority order of
    /// the directory list.
    static func resolveNewest(existingCandidates candidates: [String]) -> ResolvedCLI? {
        guard var best = candidates.first else { return nil }
        var bestVersion = probeVersion(best)
        for candidate in candidates.dropFirst() {
            let version = probeVersion(candidate)
            if isVersionNewer(version, than: bestVersion) {
                best = candidate
                bestVersion = version
            }
        }
        return ResolvedCLI(path: best, candidates: Set(candidates))
    }

    static func resolveNewest(inDirectories directories: [String] = ContainerCLI.searchDirectories()) -> ResolvedCLI? {
        resolveNewest(existingCandidates: existingCandidates(inDirectories: directories))
    }

    /// Currently resolved CLI path (lets the controller notice upgrades and
    /// refresh the displayed version).
    func currentBinaryPath() -> String? { resolvedBinaryPath }

    /// Human-readable install info: "<path>", or, when the candidate is a
    /// symlink, "<final resolved path> via <symlink>" — tells a brew install
    /// (Cellar path via /opt/homebrew/bin) apart from a plain .pkg one.
    func resolvedPathInfo() -> String? {
        guard let path = currentBinaryPath() else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved == path ? path : "\(resolved) via \(path)"
    }

    /// Resolved CLI path behind a lock so installs, upgrades and removals are
    /// picked up without restarting the app.
    private let pathLock: OSAllocatedUnfairLock<ResolvedCLI?>
    private let environment: [String: String]

    private var resolvedBinaryPath: String? {
        pathLock.withLock { $0?.path }
    }

    init(binaryPath: String? = nil) {
        self.pathLock = OSAllocatedUnfairLock(initialState: binaryPath.map {
            ResolvedCLI(path: $0, candidates: [])
        })
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

    /// Cheap scan on every poll: stat-only while the candidate set is
    /// unchanged; version probes only when an install/uninstall/upgrade
    /// changed the set, so the newest CLI wins without restarts.
    private func refreshBinaryPathIfNeeded() {
        let existing = Self.existingCandidates()
        let current = pathLock.withLock { $0 }
        if let current, current.candidates == Set(existing) { return }
        let resolved = Self.resolveNewest(existingCandidates: existing)
        pathLock.withLock { $0 = resolved }
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
