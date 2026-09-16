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
    /// Prazo de `container system start`.
    private static let mutationTimeout: TimeInterval = 10
    /// Cobre os 5s + 20s de espera da CLI e a comunicacao com o servico.
    private static let stopTimeout: TimeInterval = 40

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

    /// Caminho e versao obtidos na mesma consulta.
    struct ResolvedCLI: Sendable, Equatable {
        var path: String
        var version: String?
        /// "caminho", ou "destino via caminho" quando symlink. Calculado em
        /// thread de fundo na resolucao para nao statar na main thread.
        var pathInfo: String?
    }

    private struct CandidateSignature: Sendable, Equatable {
        var path: String
        var destination: String
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
        var changedSeconds: Int
        var changedNanoseconds: Int
    }

    private struct ResolutionState: Sendable {
        var resolved: ResolvedCLI?
        var signatures: [CandidateSignature]?
        var revision: UInt64 = 0
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
        return ResolvedCLI(path: best, version: bestVersion, pathInfo: makePathInfo(best))
    }

    /// "path", ou "resolved destination via path" when the candidate is a
    /// symlink — tells a brew install (Cellar path via /opt/homebrew/bin)
    /// apart from a plain .pkg one.
    static func makePathInfo(_ path: String) -> String {
        let destination = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return destination == path ? path : "\(destination) via \(path)"
    }

    static func resolveNewest(inDirectories directories: [String] = ContainerCLI.searchDirectories()) -> ResolvedCLI? {
        resolveNewest(existingCandidates: existingCandidates(inDirectories: directories))
    }

    /// Currently resolved CLI path (lets the controller notice upgrades and
    /// refresh the displayed version).
    func currentBinaryPath() -> String? { resolvedBinaryPath }

    func currentVersion() -> String? { pathLock.withLock { $0.resolved?.version } }

    /// Human-readable install info, served from the resolution cache (the
    /// symlink walk happens on the background queue, at resolution time).
    func resolvedPathInfo() -> String? {
        pathLock.withLock { $0.resolved?.pathInfo }
    }

    /// Resolved CLI path behind a lock so installs, upgrades and removals are
    /// picked up without restarting the app.
    private let pathLock: OSAllocatedUnfairLock<ResolutionState>
    private let directories: [String]
    private let environment: [String: String]

    private var resolvedBinaryPath: String? {
        pathLock.withLock { $0.resolved?.path }
    }

    init(binaryPath: String? = nil, directories: [String] = ContainerCLI.searchDirectories()) {
        self.pathLock = OSAllocatedUnfairLock(initialState: ResolutionState(resolved: binaryPath.map {
            ResolvedCLI(path: $0, version: nil, pathInfo: Self.makePathInfo($0))
        }))
        self.directories = directories
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
        run(["system", "stop"], timeout: Self.stopTimeout)
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

    private func candidateSignatures() -> [CandidateSignature] {
        Self.existingCandidates(inDirectories: directories).compactMap { path in
            let destination = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var metadata = stat()
            guard stat(destination, &metadata) == 0 else {
                if errno != ENOENT && errno != ENOTDIR {
                    NSLog("Falha ao consultar CLI %@: %s", path, strerror(errno))
                }
                return nil
            }
            return CandidateSignature(path: path, destination: destination,
                                      device: metadata.st_dev, inode: metadata.st_ino, size: metadata.st_size,
                                      modifiedSeconds: metadata.st_mtimespec.tv_sec,
                                      modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
                                      changedSeconds: metadata.st_ctimespec.tv_sec,
                                      changedNanoseconds: metadata.st_ctimespec.tv_nsec)
        }
    }

    /// Consulta metadados a cada poll; executa --version somente apos mudancas.
    private func refreshBinaryPathIfNeeded() {
        let current = pathLock.withLock { $0 }
        let signatures = candidateSignatures()
        if current.signatures == signatures { return }
        let resolved = Self.resolveNewest(existingCandidates: signatures.map(\.path))
        guard candidateSignatures() == signatures else { return }
        pathLock.withLock { state in
            guard state.revision == current.revision else { return }
            state.resolved = resolved
            state.signatures = signatures
            state.revision += 1
        }
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

        // Os pipes sao lidos em paralelo a execucao: ler so depois da saida
        // travaria o filho se a saida exceder o buffer do pipe (64KB).
        var stdoutData = Data()
        var stderrData = Data()
        let ioQueue = DispatchQueue(label: "local.containerstatus.io", qos: .utility)
        let ioGroup = DispatchGroup()
        ioGroup.enter()
        ioQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }
        ioGroup.enter()
        ioQueue.async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }

        var timedOut = false
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if semaphore.wait(timeout: .now() + 1.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                semaphore.wait()
            }
        }
        // Teto para o caso de um processo neto segurar o pipe aberto. Se
        // expirar, as Data ainda pertencem a ioQueue: nao le-las evita corrida
        // e devolve saida vazia de proposito.
        let ioCompleted = ioGroup.wait(timeout: .now() + 2) == .success

        if timedOut {
            return CLIRunResult(exitCode: process.terminationStatus, timedOut: true, spawned: true,
                                stderr: "tempo limite excedido (\(Int(timeout))s)")
        }
        if !ioCompleted {
            return CLIRunResult(exitCode: process.terminationStatus, timedOut: false, spawned: true,
                                stderr: "saida nao disponivel: pipe mantido aberto por processo filho")
        }
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        return CLIRunResult(exitCode: process.terminationStatus, timedOut: false, spawned: true,
                            stderr: stderrText.trimmingCharacters(in: .whitespacesAndNewlines),
                            stdout: stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
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
