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
}

extension RuntimeProbeConfig {
    /// Ordem fixa de exibicao no menu; so aparece quem tiver binario.
    static let standard: [RuntimeProbeConfig] = [.colima, .docker, .podman, .lume, .orbstack]

    /// `colima status` responde exit 0 com a VM de pe.
    static let colima = RuntimeProbeConfig(
        label: "Colima", binaryName: "colima", statusArguments: ["status"]
    ) { $0.exitCode == 0 && $0.spawned ? .running : .stopped }

    /// `docker info` pergunta ao daemon, nao a CLI: CLI sem daemon responde
    /// erro. Exit 0 = algum daemon de container esta respondendo.
    static let docker = RuntimeProbeConfig(
        label: "Docker", binaryName: "docker", statusArguments: ["info"]
    ) { $0.exitCode == 0 && $0.spawned ? .running : .stopped }

    /// `podman machine list --format json` sai exit 0 mesmo sem VM; o estado
    /// da maquina aparece como "Running" no JSON. Heuristica documentada:
    /// sem parse completo, procuramos o valor do campo de estado.
    static let podman = RuntimeProbeConfig(
        label: "Podman", binaryName: "podman",
        statusArguments: ["machine", "list", "--format", "json"]
    ) { $0.spawned && $0.stdout.contains("\"Running\"") ? .running : .stopped }

    /// `lume ls --format json` lista as VMs com campo de estado; exit 0
    /// tambem quando nao ha VMs. Rodando = alguma VM "running".
    static let lume = RuntimeProbeConfig(
        label: "Lume", binaryName: "lume", statusArguments: ["ls", "--format", "json"]
    ) { $0.spawned && $0.stdout.contains("\"running\"") ? .running : .stopped }

    /// `orbctl status` responde "Running" exit 0 quando o OrbStack esta de pe.
    static let orbstack = RuntimeProbeConfig(
        label: "OrbStack", binaryName: "orbctl", statusArguments: ["status"]
    ) { $0.exitCode == 0 && $0.spawned ? .running : .stopped }
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
}
