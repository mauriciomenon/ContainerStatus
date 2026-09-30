import Foundation

/// Estado de um runtime externo observado somente-leitura (passo 1 do
/// roadmap multi-runtime: deteccao sem controle e sem tocar na maquina).
enum ExternalRuntimeState: Equatable, Sendable {
    case notInstalled
    case running
    case stopped
}

/// Receita declarativa de um runtime: binario, argumentos de status e a
/// regra que interpreta o resultado. Somente-leitura - controle e o passo 2
/// do roadmap. Cada runtime adiciona uma entrada em `standard` e stubs no
/// selftest; nada aqui dispara mutacao.
struct RuntimeProbeConfig: Sendable {
    /// Rotulo exibido no menu ("Colima: Ligado").
    let label: String
    let binaryName: String
    let statusArguments: [String]
    /// Timeout ou falha de spawn caem sempre em desligado: a linha e
    /// informativa e conservadora, o poll seguinte corrige.
    let interpret: @Sendable (CLIRunResult) -> ExternalRuntimeState
    /// Comandos de controle (passo 2). nil = linha read-only permanente:
    /// docker tem o daemon dono do socket (o provider e quem manda) e lume
    /// liga/desliga VM por nome, nao servico.
    let control: RuntimeControl?

    init(label: String, binaryName: String, statusArguments: [String],
         interpret: @Sendable @escaping (CLIRunResult) -> ExternalRuntimeState,
         control: RuntimeControl? = nil) {
        self.label = label
        self.binaryName = binaryName
        self.statusArguments = statusArguments
        self.interpret = interpret
        self.control = control
    }
}

/// Par ligado/desligado de um runtime. Watchdogs cobrem o pior caso de
/// primeira inicializacao (boot de VM), nao a medicao feliz - regra 3.
struct RuntimeControl: Sendable {
    let startBinary: String
    let startArguments: [String]
    let startTimeout: TimeInterval
    let stopBinary: String
    let stopArguments: [String]
    let stopTimeout: TimeInterval
}

extension RuntimeControl {
    /// Controle pelo proprio binario do runtime.
    static func selfBinary(binaryName: String, startArguments: [String], startTimeout: TimeInterval,
                           stopArguments: [String], stopTimeout: TimeInterval) -> RuntimeControl {
        RuntimeControl(startBinary: binaryName, startArguments: startArguments,
                       startTimeout: startTimeout,
                       stopBinary: binaryName, stopArguments: stopArguments,
                       stopTimeout: stopTimeout)
    }
}

extension RuntimeProbeConfig {
    /// Ordem fixa de exibicao no menu; so aparece quem tiver binario.
    static let standard: [RuntimeProbeConfig] = [.colima, .docker, .podman, .lume, .orbstack]

    /// `colima status` responde exit 0 com a VM de pe. Start inicializa a VM
    /// (pode passar de minuto no primeiro boot).
    static let colima = RuntimeProbeConfig(
        label: "Colima", binaryName: "colima", statusArguments: ["status"],
        interpret: { $0.exitCode == 0 && $0.spawned ? .running : .stopped },
        control: .selfBinary(binaryName: "colima",
                             startArguments: ["start"], startTimeout: 180,
                             stopArguments: ["stop"], stopTimeout: 120)
    )

    /// `docker info` pergunta ao daemon, nao a CLI: CLI sem daemon responde
    /// erro. Exit 0 = algum daemon de container esta respondendo. Read-only:
    /// o daemon e do provider (passo 3 trata o socket).
    static let docker = RuntimeProbeConfig(
        label: "Docker", binaryName: "docker", statusArguments: ["info"],
        interpret: { $0.exitCode == 0 && $0.spawned ? .running : .stopped }
    )

    /// `podman machine list --format json` sai exit 0 mesmo sem VM; o estado
    /// da maquina aparece como "Running" no JSON. Heuristica documentada:
    /// sem parse completo, procuramos o valor do campo de estado. Start
    /// inicializa a maquina padrao.
    static let podman = RuntimeProbeConfig(
        label: "Podman", binaryName: "podman",
        statusArguments: ["machine", "list", "--format", "json"],
        interpret: { $0.spawned && $0.stdout.contains("\"Running\"") ? .running : .stopped },
        control: .selfBinary(binaryName: "podman",
                             startArguments: ["machine", "start"], startTimeout: 180,
                             stopArguments: ["machine", "stop"], stopTimeout: 120)
    )

    /// `lume ls --format json` lista as VMs com campo de estado; exit 0
    /// tambem quando nao ha VMs. Rodando = alguma VM "running". Read-only:
    /// liga/desliga VM por nome, e o servidor vive em background.
    static let lume = RuntimeProbeConfig(
        label: "Lume", binaryName: "lume", statusArguments: ["ls", "--format", "json"],
        interpret: { $0.spawned && $0.stdout.contains("\"running\"") ? .running : .stopped }
    )

    /// `orbctl status` responde "Running" exit 0 quando o OrbStack esta de pe.
    /// Start via LaunchServices (open -a); stop derruba o servico inteiro.
    static let orbstack = RuntimeProbeConfig(
        label: "OrbStack", binaryName: "orbctl", statusArguments: ["status"],
        interpret: { $0.exitCode == 0 && $0.spawned ? .running : .stopped },
        control: RuntimeControl(
            startBinary: "/usr/bin/open", startArguments: ["-a", "OrbStack"],
            startTimeout: 30,
            stopBinary: "orbctl", stopArguments: ["stop"], stopTimeout: 120)
    )
}

/// Executor read-only de uma receita: resolve o binario (ordem dos
/// diretorios = prioridade), roda o status com watchdog e interpreta.
final class RuntimeProbe: Sendable {
    private static let statusTimeout: TimeInterval = 2

    let config: RuntimeProbeConfig
    private let directories: [String]

    init(config: RuntimeProbeConfig, directories: [String] = ContainerCLI.searchDirectories()) {
        self.config = config
        self.directories = directories
    }

    var label: String { config.label }

    /// Binario com maior prioridade, ou nil quando nao instalado.
    func resolvedPath() -> String? {
        directories.compactMap { directory in
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(config.binaryName).path
            return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
        }.first
    }

    func currentStatus() -> (state: ExternalRuntimeState, path: String?) {
        guard let path = resolvedPath() else {
            return (.notInstalled, nil)
        }
        let result = ContainerCLI.runBinary(path, arguments: config.statusArguments,
                                            timeout: Self.statusTimeout)
        guard result.spawned, !result.timedOut else {
            return (.stopped, path)
        }
        return (config.interpret(result), path)
    }

    /// Linha clicavel (passo 2)? Exige receita de controle.
    var isControllable: Bool { config.control != nil }

    /// Resolve o binario de controle: caminho absoluto usa como esta; nome
    /// simples (o proprio runtime) cai na mesma lista de diretorios da sonda.
    private func resolveControlBinary(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        return directories.compactMap { directory in
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
        }.first
    }

    private func runControl(_ pair: (binary: KeyPath<RuntimeControl, String>,
                                     arguments: KeyPath<RuntimeControl, [String]>,
                                     timeout: KeyPath<RuntimeControl, TimeInterval>)) -> CLIRunResult {
        guard let control = config.control,
              let binary = resolveControlBinary(control[keyPath: pair.binary]) else {
            return CLIRunResult(stderr: "runtime \(config.label) indisponivel")
        }
        return ContainerCLI.runBinary(binary, arguments: control[keyPath: pair.arguments],
                                      timeout: control[keyPath: pair.timeout])
    }

    func start() -> CLIRunResult {
        runControl((\.startBinary, \.startArguments, \.startTimeout))
    }

    func stop() -> CLIRunResult {
        runControl((\.stopBinary, \.stopArguments, \.stopTimeout))
    }
}
