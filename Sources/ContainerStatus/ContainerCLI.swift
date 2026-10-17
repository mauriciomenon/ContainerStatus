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
    /// Prazo de `container system start`. Cobre o pior caso oficial: instalacao
    /// de kernel pode demorar minutos, e um start morto pelo watchdog deixa o
    /// bootstrap em andamento no launchd - um fallback rodaria sobre ele.
    /// Alinhado com o stop: esperar e mais seguro que tentar de novo.
    private static let mutationTimeout: TimeInterval = 40
    /// Cobre os 5s + 20s de espera da CLI e a comunicacao com o servico.
    private static let stopTimeout: TimeInterval = 40

    /// Install roots of the official .pkg, Homebrew and the system, in
    /// priority order. Machine-independent: .pkg, brew or `make install`.
    static let systemDirectories = [
        "/usr/local/bin",                  // .pkg / `make install` default
        "/opt/homebrew/bin",               // Homebrew, Apple Silicon
        "/opt/homebrew/sbin",
        "/usr/local/sbin",
        "/opt/sbin",
        "/usr/bin",
        "/bin",
    ]

    /// User-writable prefixes (`~/.local/bin`, inherited PATH): only consulted
    /// when no system directory has the CLI. Mixing them in let a planted
    /// binary claiming "version 99" win the newest-version race.
    static func fallbackDirectories() -> [String] {
        var directories = [NSHomeDirectory() + "/.local/bin"]
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for item in inherited.split(separator: ":", omittingEmptySubsequences: true)
        where item.hasPrefix("/") {
            directories.append(String(item))
        }
        var seen = Set(systemDirectories)
        return directories.filter { seen.insert($0).inserted }
    }

    /// Search order for the other runtimes (first match wins).
    static func searchDirectories() -> [String] {
        systemDirectories + fallbackDirectories()
    }

    /// The production CLI: system directories, user prefixes as fallback.
    static func installed() -> ContainerCLI {
        ContainerCLI(fallbackDirectories: fallbackDirectories())
    }

    /// Every executable `container` in the given directories, priority order
    /// preserved. A binary writable by group or others is skipped: anyone
    /// with that access could swap what the app executes.
    static func existingCandidates(inDirectories directories: [String] = ContainerCLI.systemDirectories) -> [String] {
        directories.compactMap { directory in
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("container").path
            return isTrustedExecutable(candidate) ? candidate : nil
        }
    }

    /// Executavel que o app aceita rodar: nao gravavel por grupo/outros
    /// (stat segue o symlink ate o destino). Vale para a CLI e as sondas.
    /// Dono tambem conta: em /opt/homebrew/bin (gravavel pelo grupo admin) um
    /// binario 0755 de OUTRA conta admin passaria so pelo modo.
    static func isTrustedExecutable(_ path: String) -> Bool {
        var metadata = stat()
        return FileManager.default.isExecutableFile(atPath: path)
            && stat(path, &metadata) == 0
            && metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
            && (metadata.st_uid == 0 || metadata.st_uid == getuid())
    }

    /// Prazo do `--version`: so roda quando o binario muda, e a primeira
    /// execucao de um binario novo passa pela verificacao do Gatekeeper.
    private static let versionTimeout: TimeInterval = 5

    /// CLI version of one candidate, or nil when it does not answer with one.
    /// Exit diferente de zero nao conta, mesmo com versao no stdout: o
    /// resultado iria para o cache como resolucao completa.
    static func probeVersion(_ path: String) -> String? {
        let result = runBinary(path, arguments: ["--version"], timeout: versionTimeout)
        return result.succeeded ? parseVersion(result.stdout) : nil
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
        resolveNewestReportingFailures(candidates).resolved
    }

    /// Como resolveNewest, informando se algum candidato ficou sem versao:
    /// essa resolucao e provisoria e nao pode ser cacheada.
    private static func resolveNewestReportingFailures(_ candidates: [String])
        -> (resolved: ResolvedCLI?, complete: Bool) {
        guard var best = candidates.first else { return (nil, true) }
        var bestVersion = probeVersion(best)
        var complete = bestVersion != nil
        for candidate in candidates.dropFirst() {
            let version = probeVersion(candidate)
            if version == nil { complete = false }
            if isVersionNewer(version, than: bestVersion) {
                best = candidate
                bestVersion = version
            }
        }
        return (ResolvedCLI(path: best, version: bestVersion, pathInfo: makePathInfo(best)), complete)
    }

    /// "path", ou "resolved destination via path" when the candidate is a
    /// symlink - tells a brew install (Cellar path via /opt/homebrew/bin)
    /// apart from a plain .pkg one.
    static func makePathInfo(_ path: String) -> String {
        let destination = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return destination == path ? path : "\(destination) via \(path)"
    }

    static func resolveNewest(inDirectories directories: [String] = ContainerCLI.systemDirectories) -> ResolvedCLI? {
        resolveNewest(existingCandidates: existingCandidates(inDirectories: directories))
    }

    /// Currently resolved CLI path (lets the controller notice upgrades and
    /// refresh the displayed version).
    func currentBinaryPath() -> String? { resolvedBinaryPath }

    /// Limpa as assinaturas de cache: a proxima leitura re-resolve e
    /// re-probe a versao (varedura ativa do item Refresh).
    func rescan() {
        pathLock.withLock { $0.signatures = nil }
    }

    func currentVersion() -> String? { pathLock.withLock { $0.resolved?.version } }

    /// Versao do container-apiserver em execucao (nil com servico parado).
    /// Depois de um upgrade da CLI o servico antigo segue de pe ate um
    /// stop/start; o menu avisa quando as duas divergem.
    func currentServiceVersion() -> String? { serviceLock.withLock { $0?.version } }

    /// Tabela de `container system version`: linha do container-apiserver.
    static func parseServiceVersion(_ table: String) -> String? {
        for line in table.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2, fields[0] == "container-apiserver" {
                return parseVersion("version \(fields[1])")
            }
        }
        return nil
    }

    /// Consulta o servico so quando preciso: CLI trocou, start/stop do app,
    /// ou versoes ainda divergem (restart feito pelo terminal aparece no
    /// poll seguinte). Com tudo igual, nenhum processo extra por poll.
    func refreshServiceVersion(running: Bool, now: Date = Date()) {
        guard running else {
            serviceLock.withLock { $0 = nil }
            return
        }
        let (revision, cliVersion) = pathLock.withLock { ($0.revision, $0.resolved?.version) }
        let cached = serviceLock.withLock { $0 }
        if let cached, cached.revision == revision {
            if cached.version == cliVersion { return }
            // Sem versao (falha transitoria, CLI sem o verbo ou saida sem o
            // apiserver): tenta de novo com folga, nunca desiste de vez.
            if cached.version == nil,
               now.timeIntervalSince(cached.checkedAt) < Self.serviceRetryInterval { return }
        }
        let result = run(["system", "version"], timeout: Self.statusTimeout)
        let version = result.succeeded ? Self.parseServiceVersion(result.stdout) : nil
        serviceLock.withLock { $0 = (revision, version, now) }
    }

    static let serviceRetryInterval: TimeInterval = 30

    /// Human-readable install info, served from the resolution cache (the
    /// symlink walk happens on the background queue, at resolution time).
    func resolvedPathInfo() -> String? {
        pathLock.withLock { $0.resolved?.pathInfo }
    }

    /// Resolved CLI path behind a lock so installs, upgrades and removals are
    /// picked up without restarting the app.
    private let pathLock: OSAllocatedUnfairLock<ResolutionState>
    /// Versao do apiserver e a revisao da resolucao em que foi lida.
    private let serviceLock =
        OSAllocatedUnfairLock<(revision: UInt64, version: String?, checkedAt: Date)?>(initialState: nil)
    private let directories: [String]
    private let fallbackDirectories: [String]
    private let environment: [String: String]

    private var resolvedBinaryPath: String? {
        pathLock.withLock { $0.resolved?.path }
    }

    init(binaryPath: String? = nil, directories: [String] = ContainerCLI.systemDirectories,
         fallbackDirectories: [String] = []) {
        self.pathLock = OSAllocatedUnfairLock(initialState: ResolutionState(resolved: binaryPath.map {
            ResolvedCLI(path: $0, version: nil, pathInfo: Self.makePathInfo($0))
        }))
        self.directories = directories
        self.fallbackDirectories = fallbackDirectories
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
    /// first (correct behavior, installs the kernel when needed); the retry
    /// skipping the interactive first-run kernel prompt roda somente apos
    /// falha explicita - nunca apos timeout, porque um start morto pelo
    /// watchdog deixa o bootstrap em andamento no launchd e um segundo start
    /// colidiria com ele.
    func start() -> CLIRunResult {
        serviceLock.withLock { $0 = nil }
        let plain = run(["system", "start"], timeout: Self.mutationTimeout)
        // Fallback so apos falha EXPLICITA (exit != 0): exit 0 com saida
        // truncada ou pipe preso ja e start feito, e timeout deixa o
        // bootstrap em andamento.
        guard plain.spawned, !plain.timedOut, !plain.signaled, plain.exitCode != 0 else { return plain }
        let fallback = run(["system", "start", "--disable-kernel-install"], timeout: Self.mutationTimeout)
        return fallback.exitedCleanly ? fallback : plain
    }

    /// Stops the whole service stack (apiserver, machine-apiserver,
    /// core-images, vmnet).
    func stop() -> CLIRunResult {
        serviceLock.withLock { $0 = nil }
        return run(["system", "stop"], timeout: Self.stopTimeout)
    }

    /// Containers rodando com uso de memoria (do mesmo `ls --format json`).
    /// nil quando a CLI nao responde; lista vazia = servico de pe sem carga.
    struct ContainerSummary: Equatable, Sendable {
        var id: String
        var memoryBytes: Int64?
    }

    func runningContainers() -> [ContainerSummary]? {
        refreshBinaryPathIfNeeded()
        guard resolvedBinaryPath != nil else { return nil }
        let result = run(["ls", "--format", "json"], timeout: Self.statusTimeout)
        guard result.succeeded, result.spawned, !result.timedOut,
              let data = result.stdout.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return list.map { entry in
            let id = Self.menuSafe(entry["id"] as? String ?? "?")
            let memory = (entry["configuration"] as? [String: Any])?["resources"] as? [String: Any]
            return ContainerSummary(id: id,
                                    memoryBytes: (memory?["memoryInBytes"] as? NSNumber)?.int64Value)
        }
    }

    /// O id vira titulo de item de menu: quebra de linha forjaria linhas
    /// falsas ("Status: ..."), e um id enorme alargaria o menu inteiro.
    static func menuSafe(_ text: String, limit: Int = 64) -> String {
        let flat = String(text.unicodeScalars.map {
            CharacterSet.controlCharacters.union(.newlines).contains($0) ? " " : Character($0)
        })
        return flat.count > limit ? String(flat.prefix(max(0, limit - 3))) + "..." : flat
    }

    // MARK: Process plumbing

    /// Runs an arbitrary binary (used by the self-test against foreign
    /// executables); the production paths go through `run(_:timeout:)`.
    static func runBinary(_ path: String, arguments: [String], timeout: TimeInterval,
                          environment: [String: String] = [
                              "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                              "HOME": NSHomeDirectory(),
                          ]) -> CLIRunResult {
        spawn(URL(fileURLWithPath: path), arguments: arguments, environment: environment, timeout: timeout)
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
        let primary = Self.existingCandidates(inDirectories: directories)
        let candidates = primary.isEmpty ? Self.existingCandidates(inDirectories: fallbackDirectories) : primary
        return candidates.compactMap { path in
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
    /// Resolucao com probe falho publica o resultado mas nao grava as
    /// assinaturas: o poll seguinte tenta de novo. Cachear o nil prendia o
    /// app no binario e na versao antigos ate um novo upgrade ou o Refresh.
    // ponytail: candidato que nunca responde versao e re-consultado a cada
    // poll (um --version de ~10ms); backoff so se isso aparecer de verdade.
    private func refreshBinaryPathIfNeeded() {
        let current = pathLock.withLock { $0 }
        let signatures = candidateSignatures()
        if current.signatures == signatures { return }
        let (resolved, complete) = Self.resolveNewestReportingFailures(signatures.map(\.path))
        guard candidateSignatures() == signatures else { return }
        pathLock.withLock { state in
            guard state.revision == current.revision else { return }
            state.resolved = resolved
            state.signatures = complete ? signatures : nil
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

        // Os pipes sao drenados durante a execucao (ler so no fim travaria um
        // filho com mais de 64KB de saida), cada um por readabilityHandler:
        // nada fica bloqueado em read(), entao um neto segurando o pipe nao
        // prende threads, e cancelar e so tirar o handler. Teto de 1MB por
        // stream: os parsers so usam o comeco da saida.
        final class IOBox: @unchecked Sendable {
            static let cap = 1 << 20
            private let lock = NSLock()
            private var storage = Data()
            private var finished = false
            private var overflowed = false
            let done = DispatchSemaphore(value: 0)
            var truncated: Bool { lock.withLock { overflowed } }
            /// Decodificacao tolerante: corte no meio de um caractere UTF-8
            /// nao pode descartar a saida inteira.
            var text: String {
                String(decoding: get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func append(_ chunk: Data) {
                lock.withLock {
                    if storage.count + chunk.count > Self.cap { overflowed = true }
                    if storage.count < Self.cap { storage.append(chunk.prefix(Self.cap - storage.count)) }
                }
            }
            /// EOF: sinaliza uma unica vez.
            func finish() {
                let first = lock.withLock { () -> Bool in
                    defer { finished = true }
                    return !finished
                }
                if first { done.signal() }
            }
            func get() -> Data { lock.withLock { storage } }
        }
        func drain(_ handle: FileHandle, into box: IOBox) {
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    box.finish()
                } else {
                    box.append(chunk)
                }
            }
        }
        let stdoutBox = IOBox()
        let stderrBox = IOBox()
        drain(stdoutPipe.fileHandleForReading, into: stdoutBox)
        drain(stderrPipe.fileHandleForReading, into: stderrBox)

        var timedOut = false
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // Arvore coletada ANTES de matar o pai: depois os filhos viram
            // filhos do launchd e o vinculo se perde. Um CLI travado num
            // subprocesso (ex.: driver do limactl) deixaria o neto vivo a
            // cada ciclo. So no timeout: daemon de um start bem-sucedido
            // (colima, podman) e intencional e fica.
            let descendants = process.isRunning ? Self.descendants(of: process.processIdentifier) : []
            process.terminate()
            // Logo apos coletar: quanto menor o intervalo, menor a chance de
            // um pid da lista ter sido reciclado por outro processo.
            for pid in descendants { kill(pid, SIGKILL) }
            if semaphore.wait(timeout: .now() + 1.5) == .timedOut {
                // isRunning antes do kill: um pid ja colhido pode ter sido
                // reciclado. Resta uma janela entre o teste e o kill sem
                // pidfd no macOS; e minima porque o pid fica zumbi ate a
                // Foundation colhe-lo e o kernel aloca pids em sequencia.
                // Espera com teto: filho preso no kernel nao congela o poll.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                if semaphore.wait(timeout: .now() + 2) == .timedOut {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    return CLIRunResult(timedOut: true, spawned: true,
                                        stderr: "processo nao terminou apos SIGKILL")
                }
            }
        }
        // Teto para um neto segurando o pipe: sem EOF em 2s, os handlers saem
        // e os descritores fecham junto com os Pipe ao fim desta funcao.
        let ioDeadline = DispatchTime.now() + 2
        let ioCompleted = stdoutBox.done.wait(timeout: ioDeadline) == .success
            && stderrBox.done.wait(timeout: ioDeadline) == .success
        if !ioCompleted {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        if timedOut {
            return CLIRunResult(exitCode: process.terminationStatus, timedOut: true, spawned: true,
                                stderr: "tempo limite excedido (\(Int(timeout))s)")
        }
        if !ioCompleted {
            // Saida incompleta: o exit vale para mutacoes, o stdout nao vale
            // para parsers (stdout vazio viraria "0 containers").
            return CLIRunResult(exitCode: process.terminationStatus, timedOut: false, spawned: true,
                                stderr: "saida nao disponivel: pipe mantido aberto por processo filho",
                                truncated: true, signaled: process.terminationReason == .uncaughtSignal)
        }
        return CLIRunResult(exitCode: process.terminationStatus, timedOut: false, spawned: true,
                            stderr: stderrBox.text, stdout: stdoutBox.text,
                            truncated: stdoutBox.truncated || stderrBox.truncated,
                            signaled: process.terminationReason == .uncaughtSignal)
    }

    /// Filhos, netos etc. de pid (proc_listchildpids), mais fundos primeiro.
    /// Travessia completa: o buffer e dimensionado pela contagem que o kernel
    /// informa (com folga para filhos novos), sem teto fixo por pai. O
    /// conjunto `seen` impede laco, entao a travessia sempre termina.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var seen: Set<pid_t> = [pid]
        var pending = [pid]
        while let current = pending.popLast() {
            let estimate = max(0, Int(proc_listchildpids(current, nil, 0)))
            guard estimate > 0 else { continue }
            var buffer = [pid_t](repeating: 0, count: estimate + 32)
            let count = proc_listchildpids(current, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { continue }
            for child in buffer.prefix(Int(count)) where child > 0 && seen.insert(child).inserted {
                found.append(child)
                pending.append(child)
            }
        }
        return found.reversed()
    }

    static func parseVersion(_ text: String) -> String? {
        // So o numero (grupo 1): separar por espaco deixava passar "version\n1.5.0"
        // inteiro, com quebra de linha, ate o menu.
        guard let match = text.firstMatch(of: /version\s+(\d+(?:\.\d+)+)/) else { return nil }
        return String(match.1)
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    }
}
