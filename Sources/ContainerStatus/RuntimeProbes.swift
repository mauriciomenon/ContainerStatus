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
    /// Sonda informativa read-only (passo 3 parcial): identifica o dono
    /// efetivo do runtime, ex. o contexto do docker. Vai para o tooltip.
    let info: RuntimeInfo?
    /// Padroes de LaunchAgent (sem ".plist") que marcam auto-start do
    /// runtime - passo 3: dois runtimes subindo sozinhos no login e a
    /// classe de conflito classica. Primeiro padrao encontrado vira tooltip.
    let autoStartPatterns: [String]
    /// Contagem de containers ativos do runtime (`ps -q` = uma linha por
    /// container); nil desativa. So faz sentido com o runtime de pe.
    let countArguments: [String]?
    /// Rodar a sonda a cada N ciclos de poll (1 = todo ciclo). Para CLIs
    /// caras: lume ls custa ~0.9s por chamada, as outras ficam em centesimos.
    let pollEvery: Int
    /// Caminho de app que marca a instalacao (ex.: /Applications/Docker.app).
    /// Quando setado, "detectado" passa a ser existencia deste caminho, nao
    /// do binario - providers de app (Docker Desktop, Rancher) sobrevivem ao
    /// binario sumir do PATH.
    let detectAppPath: String?
    /// Natureza do servico, para o tooltip ("launchd service", "app + VM").
    let nature: String
    /// Provider baseado em app: a acao real e Start/Stop do app, nao
    /// Enable/Disable Daemon (que enganaria quando o daemon nao existe
    /// separadamente).
    let appBased: Bool

    init(label: String, binaryName: String, statusArguments: [String],
         interpret: @Sendable @escaping (CLIRunResult) -> ExternalRuntimeState,
         control: RuntimeControl? = nil, info: RuntimeInfo? = nil,
         autoStartPatterns: [String] = [], countArguments: [String]? = nil,
         pollEvery: Int = 1, detectAppPath: String? = nil, nature: String = "",
         appBased: Bool = false) {
        self.label = label
        self.binaryName = binaryName
        self.statusArguments = statusArguments
        self.interpret = interpret
        self.control = control
        self.info = info
        self.autoStartPatterns = autoStartPatterns
        self.countArguments = countArguments
        self.pollEvery = max(1, pollEvery)
        self.detectAppPath = detectAppPath
        self.nature = nature
        self.appBased = appBased
    }

    /// Consulta informativa de planta: comando + rotulo do que ele responde.
    struct RuntimeInfo: Sendable {
        let label: String
        let arguments: [String]
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

    /// Providers do mesmo backbone docker: so entram no menu quando
    /// detectados. Cada um com toggle proprio quando e o dono do daemon.
    static let dockerFamily: [RuntimeProbeConfig] =
        [.orbstack, .colima, .dockerDesktop, .rancherDesktop, .finch]

    /// `colima status` responde exit 0 com a VM de pe. Start inicializa a VM
    /// (pode passar de minuto no primeiro boot).
    static let colima = RuntimeProbeConfig(
        label: "Colima", binaryName: "colima", statusArguments: ["status"],
        interpret: { $0.exitCode == 0 && $0.spawned ? .running : .stopped },
        control: .selfBinary(binaryName: "colima",
                             startArguments: ["start"], startTimeout: 180,
                             stopArguments: ["stop"], stopTimeout: 120),
        autoStartPatterns: ["homebrew.mxcl.colima"],
        nature: "VM (Lima)"
    )

    /// `docker info` pergunta ao daemon, nao a CLI: CLI sem daemon responde
    /// erro. Exit 0 = algum daemon de container esta respondendo. Read-only:
    /// o daemon e do provider (passo 3 trata o socket). O contexto aponta o
    /// dono efetivo do daemon (ex.: orbstack).
    static let docker = RuntimeProbeConfig(
        label: "Docker", binaryName: "docker", statusArguments: ["info"],
        interpret: { $0.exitCode == 0 && $0.spawned ? .running : .stopped },
        info: RuntimeInfo(label: "contexto", arguments: ["context", "show"]),
        countArguments: ["ps", "-q"],
        nature: "daemon docker (dono no contexto)"
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
                             stopArguments: ["machine", "stop"], stopTimeout: 120),
        countArguments: ["ps", "-q"],
        nature: "podman machine (VM)"
    )

    /// `lume ls --format json` lista as VMs com campo de estado; exit 0
    /// tambem quando nao ha VMs. Rodando = alguma VM "running". Read-only:
    /// liga/desliga VM por nome, e o servidor vive em background. O brew
    /// services instala LaunchAgent de auto-start (planta desta maquina).
    static let lume = RuntimeProbeConfig(
        label: "Lume", binaryName: "lume", statusArguments: ["ls", "--format", "json"],
        interpret: { $0.spawned && $0.stdout.contains("\"running\"") ? .running : .stopped },
        control: RuntimeControl(
            startBinary: "brew", startArguments: ["services", "start", "homebrew.mxcl.lume"],
            startTimeout: 60,
            stopBinary: "brew", stopArguments: ["services", "stop", "homebrew.mxcl.lume"],
            stopTimeout: 60),
        autoStartPatterns: ["homebrew.mxcl.lume"],
        pollEvery: 5,
        nature: "LaunchAgent homebrew.mxcl.lume (brew services)"
    )

    /// Docker Desktop: presenca pelo app; status pelo processo; toggle dele
    /// mesmo, porque quando instalado E o dono do daemon docker.
    static let dockerDesktop = RuntimeProbeConfig(
        label: "Docker Desktop", binaryName: "/usr/bin/pgrep",
        statusArguments: ["-x", "Docker"],
        interpret: { $0.exitCode == 0 && $0.spawned ? .running : .stopped },
        control: RuntimeControl(
            startBinary: "/usr/bin/open", startArguments: ["-a", "Docker"],
            startTimeout: 60,
            stopBinary: "/usr/bin/osascript",
            stopArguments: ["-e", "quit app \"Docker\""], stopTimeout: 60),
        detectAppPath: "/Applications/Docker.app",
        nature: "app Docker Desktop + daemon proprio",
        appBased: true
    )

    /// Rancher Desktop (SUSE): app + VM com daemon docker proprio.
    static let rancherDesktop = RuntimeProbeConfig(
        label: "Rancher Desktop", binaryName: "/usr/bin/pgrep",
        statusArguments: ["-x", "Rancher Desktop"],
        interpret: { $0.exitCode == 0 && $0.spawned ? .running : .stopped },
        control: RuntimeControl(
            startBinary: "/usr/bin/open",
            startArguments: ["-a", "Rancher Desktop"], startTimeout: 60,
            stopBinary: "/usr/bin/osascript",
            stopArguments: ["-e", "quit app \"Rancher Desktop\""], stopTimeout: 60),
        detectAppPath: "/Applications/Rancher Desktop.app",
        nature: "app Rancher Desktop + VM (backbone docker)",
        appBased: true
    )

    /// Finch (AWS, base Lima): CLI rara; exibido como detectado, sem toggle
    /// verificado (vm start/stop varia por versao).
    static let finch = RuntimeProbeConfig(
        label: "Finch", binaryName: "finch", statusArguments: ["--version"],
        interpret: { _ in .stopped },
        nature: "CLI (base Lima)"
    )

    /// `orbctl status` responde "Running" exit 0 quando o OrbStack esta de pe.
    /// Start via LaunchServices (open -a); stop derruba o servico inteiro.
    static let orbstack = RuntimeProbeConfig(
        label: "OrbStack", binaryName: "orbctl", statusArguments: ["status"],
        interpret: { $0.exitCode == 0 && $0.spawned ? .running : .stopped },
        control: RuntimeControl(
            startBinary: "/usr/bin/open", startArguments: ["-a", "OrbStack"],
            startTimeout: 30,
            stopBinary: "orbctl", stopArguments: ["stop"], stopTimeout: 120),
        nature: "app OrbStack + VM (backbone docker)",
        appBased: true
    )
}

/// Estado da rede virtual do VMware (vmnet), para a secao propria do menu.
enum VmnetState: Equatable, Sendable {
    /// Fusion nao instalado: secao escondida.
    case notInstalled
    case running
    case stopped
}

/// Sonda e acao da rede virtual do VMware Fusion. Os daemons vmnet sao
/// servicos de root gerenciados pelo `vmnet-cli`; "subir" pede senha via
/// dialogo de administrador (o app continua sem privilegios). Sem caminho
/// de desligar: o pedido e recuperar rede, nao derrubar.
final class VmnetProbe: Sendable {
    private static let statusTimeout: TimeInterval = 5
    private static let startTimeout: TimeInterval = 300

    private let fusionAppPath: String
    private let pgrepPath: String

    init(fusionAppPath: String = "/Applications/VMware Fusion.app",
         pgrepPath: String = "/usr/bin/pgrep") {
        self.fusionAppPath = fusionAppPath
        self.pgrepPath = pgrepPath
    }

    var vmnetCliPath: String {
        URL(fileURLWithPath: fusionAppPath)
            .appendingPathComponent("Contents/Library/vmnet-cli").path
    }

    var fusionInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: vmnetCliPath)
    }

    /// Daemon vmnet de pe (natd/dhcpd/bridge) e VMs rodando (vmware-vmx).
    func currentStatus() -> (state: VmnetState, vmCount: Int) {
        guard fusionInstalled else { return (.notInstalled, 0) }
        // -x (nome exato): -f casaria qualquer processo com "vmnet" nos
        // argumentos (grep, tail de log) e mentiria "Ativo" com a rede caida.
        let daemons = ContainerCLI.runBinary(pgrepPath,
                                             arguments: ["-x", "vmnet-(natd|dhcpd|bridge)"],
                                             timeout: Self.statusTimeout)
        let vms = ContainerCLI.runBinary(pgrepPath,
                                         arguments: ["-x", "vmware-vmx"],
                                         timeout: Self.statusTimeout)
        let vmCount = vms.succeeded
            ? vms.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
            : 0
        // pgrep: exit 0 com pids = tem daemon; 1 = nenhum; falha de spawn =
        // conservador, mostra parado e o poll seguinte corrige.
        let state: VmnetState = daemons.spawned && daemons.exitCode == 0 ? .running : .stopped
        return (state, vmCount)
    }

    /// Comando de subida com elevacao: o macOS pede a senha no dialogo de
    /// administrador. Para o repair: para (best-effort) e sobe de novo.
    func startScript() -> String {
        let cli = vmnetCliPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let inner = "\"\(cli)\" --stop >/dev/null 2>&1; \"\(cli)\" --start"
        return "do shell script \"\(inner)\" with administrator privileges"
    }

    func start() -> CLIRunResult {
        ContainerCLI.runBinary("/usr/bin/osascript", arguments: ["-e", startScript()],
                               timeout: Self.startTimeout)
    }
}

/// Executor read-only de uma receita: resolve o binario (ordem dos
/// diretorios = prioridade), roda o status com watchdog e interpreta.
final class RuntimeProbe: Sendable {
    private static let statusTimeout: TimeInterval = 2

    let config: RuntimeProbeConfig
    private let directories: [String]
    private let launchAgentsDirectories: [String]

    init(config: RuntimeProbeConfig,
         directories: [String] = ContainerCLI.searchDirectories(),
         launchAgentsDirectories: [String] = [NSHomeDirectory() + "/Library/LaunchAgents",
                                              "/Library/LaunchAgents"]) {
        self.config = config
        self.directories = directories
        self.launchAgentsDirectories = launchAgentsDirectories
    }

    var label: String { config.label }

    /// Binario com maior prioridade, ou nil quando nao instalado. Com
    /// detectAppPath, a existencia do app e que decide.
    func resolvedPath() -> String? {
        if let appPath = config.detectAppPath {
            return FileManager.default.fileExists(atPath: appPath)
                ? (FileManager.default.isExecutableFile(atPath: config.binaryName)
                   ? config.binaryName : nil)
                : nil
        }
        if config.binaryName.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: config.binaryName)
                ? config.binaryName : nil
        }
        return directories.compactMap { directory in
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

    /// Informacao de planta (ex.: contexto do docker), ou nil quando o
    /// runtime nao tem sonda informativa ou o comando falhou.
    func currentInfo() -> String? {
        guard let info = config.info, let path = resolvedPath() else { return nil }
        let result = ContainerCLI.runBinary(path, arguments: info.arguments,
                                            timeout: Self.statusTimeout)
        let line = ContainerCLI.firstLine(result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !line.isEmpty else { return nil }
        return "\(info.label): \(line)"
    }

    /// LaunchAgent de auto-start presente (primeiro padrao encontrado), ou
    /// nil. Read-only: existencia de arquivo, sem executar nada.
    func autoStartLabel() -> String? {
        for directory in launchAgentsDirectories {
            for pattern in config.autoStartPatterns {
                let path = URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(pattern).plist").path
                if FileManager.default.fileExists(atPath: path) {
                    return pattern
                }
            }
        }
        return nil
    }

    /// Containers ativos do runtime: uma linha por container em `ps -q`.
    /// nil quando a receita nao existe ou o comando falhou.
    func runningCount() -> Int? {
        guard let arguments = config.countArguments, let path = resolvedPath() else {
            return nil
        }
        let result = ContainerCLI.runBinary(path, arguments: arguments,
                                            timeout: Self.statusTimeout)
        guard result.succeeded, result.spawned, !result.timedOut else { return nil }
        return result.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// Tooltip composto (contexto, auto-start, contagem de containers) na
    /// Unica versao verdadeira - spawnPoll, finishRuntime e o diagnostico
    /// consomem daqui. nil quando nao ha nada a mostrar. Bloqueante: chamar
    /// fora da main thread.
    func tooltipInfo(state: ExternalRuntimeState) -> String? {
        guard state != .notInstalled else { return nil }
        var parts: [String] = []
        if !config.nature.isEmpty {
            parts.append(config.nature)
        }
        if let runtimeInfo = currentInfo() {
            parts.append(runtimeInfo)
        }
        if let autoStart = autoStartLabel() {
            parts.append("auto-start: \(autoStart)")
        }
        if state == .running, let runningCount = runningCount() {
            parts.append(runningCount == 1 ? "1 container" : "\(runningCount) containers")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
