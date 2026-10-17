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
    /// Binario absoluto que responde o status no lugar do proprio runtime
    /// (ex.: launchctl para servico brew); a deteccao continua pelo binaryName.
    let statusBinary: String?
    /// Prazo da consulta de status (Lima da ate 3s por instancia).
    let statusTimeout: TimeInterval
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
         statusBinary: String? = nil, statusTimeout: TimeInterval = 2,
         detectAppPath: String? = nil, nature: String = "",
         appBased: Bool = false) {
        self.label = label
        self.binaryName = binaryName
        self.statusArguments = statusArguments
        self.interpret = interpret
        self.control = control
        self.info = info
        self.autoStartPatterns = autoStartPatterns
        self.countArguments = countArguments
        self.statusBinary = statusBinary
        self.statusTimeout = statusTimeout
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
    /// Inclui toda a familia docker: receita fora desta lista nunca e
    /// sondada e o provider ficava escondido mesmo instalado.
    static let standard: [RuntimeProbeConfig] =
        [.colima, .docker, .podman, .lume, .lima, .orbstack, .dockerDesktop, .rancherDesktop, .finch]

    /// Lima (limactl): instancias VM sem servico unico, entao linha so
    /// informativa; tooltip lista "nome estado" de cada uma. Ligado = alguma
    /// instancia Running.
    static let lima = RuntimeProbeConfig(
        label: "Lima", binaryName: "limactl",
        statusArguments: ["list", "--format", "{{.Name}} {{.Status}}"],
        interpret: { result in
            result.succeeded && result.stdout.split(separator: "\n").contains { $0.hasSuffix(" Running") }
                ? .running : .stopped
        },
        info: RuntimeInfo(label: "Instances", arguments: ["list", "--format", "{{.Name}} {{.Status}}"]),
        statusTimeout: 10,  // ate 3s por instancia com hostagent lento
        nature: "VMs Lima (limactl)"
    )

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
        info: RuntimeInfo(label: "Context", arguments: ["context", "show"]),
        countArguments: ["ps", "-q"],
        nature: "daemon docker (dono no contexto)"
    )

    /// `podman machine list --format json` sai exit 0 mesmo sem VM; cada
    /// maquina traz o booleano `"Running"`. Procurar o texto "Running" dava
    /// ligado com qualquer maquina existente, ate parada. Start inicializa a
    /// maquina padrao.
    static let podman = RuntimeProbeConfig(
        label: "Podman", binaryName: "podman",
        statusArguments: ["machine", "list", "--format", "json"],
        interpret: { podmanState($0) },
        control: .selfBinary(binaryName: "podman",
                             startArguments: ["machine", "start"], startTimeout: 180,
                             stopArguments: ["machine", "stop"], stopTimeout: 120),
        countArguments: ["ps", "-q"],
        nature: "podman machine (VM)"
    )

    /// Alvo de `podman machine start/stop` sem nome (docs do podman). A
    /// lista pode marcar com "*" a conexao padrao no Name.
    static let podmanControlledMachine = "podman-machine-default"

    static func podmanState(_ result: CLIRunResult) -> ExternalRuntimeState {
        guard result.succeeded,
              let machines = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
        else { return .stopped }
        // `machine start/stop` sem nome agem em podman-machine-default; o
        // campo Default da lista e a CONEXAO padrao, que pode ser outra. O
        // estado e so o dessa maquina (nome exato, com o "*" opcional da
        // conexao padrao): outra VM ligada nunca vira "Disable Daemon" sobre ela.
        let target = machines.first {
            let name = $0["Name"] as? String
            return name == podmanControlledMachine || name == podmanControlledMachine + "*"
        }
        return target?["Running"] as? Bool == true ? .running : .stopped
    }

    /// O toggle controla o servidor `lume serve` (servico brew), entao o
    /// estado e o do LaunchAgent no launchd, nao o das VMs: servidor de pe
    /// sem VM nenhuma e "Running". `brew services` recebe o nome da formula
    /// (`lume`), nao o label do launchd.
    static let lume = makeLume()

    static func makeLume(launchctl: String = "/bin/launchctl") -> RuntimeProbeConfig {
        RuntimeProbeConfig(
            label: "Lume", binaryName: "lume",
            statusArguments: ["print", "gui/\(getuid())/homebrew.mxcl.lume"],
            interpret: { $0.succeeded && $0.stdout.contains("state = running") ? .running : .stopped },
            control: RuntimeControl(
                startBinary: "brew", startArguments: ["services", "start", "lume"],
                startTimeout: 60,
                stopBinary: "brew", stopArguments: ["services", "stop", "lume"],
                stopTimeout: 60),
            autoStartPatterns: ["homebrew.mxcl.lume"],
            statusBinary: launchctl,
            nature: "LaunchAgent homebrew.mxcl.lume (brew services)"
        )
    }

    /// Docker Desktop: presenca pelo app; status por qualquer processo
    /// executando de dentro do bundle (pgrep -x compara so 16 caracteres do
    /// nome e o executavel mudou de nome entre versoes); toggle dele mesmo,
    /// porque quando instalado E o dono do daemon docker.
    static let dockerDesktop = RuntimeProbeConfig(
        label: "Docker Desktop", binaryName: "/usr/bin/pgrep",
        statusArguments: ["-f", "^/Applications/Docker.app/Contents/MacOS/"],
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
        statusArguments: ["-f", "^/Applications/Rancher Desktop.app/Contents/MacOS/"],
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

    /// Finch (AWS, base Lima): `finch vm status` imprime Running, Stopped ou
    /// Nonexistent (cmd/finch/virtual_machine_status.go). Antes rodava
    /// --version e mostrava sempre desligado.
    static let finch = RuntimeProbeConfig(
        label: "Finch", binaryName: "finch", statusArguments: ["vm", "status"],
        interpret: { $0.succeeded && ContainerCLI.firstLine($0.stdout) == "Running" ? .running : .stopped },
        control: .selfBinary(binaryName: "finch",
                             startArguments: ["vm", "start"], startTimeout: 180,
                             stopArguments: ["vm", "stop"], stopTimeout: 120),
        nature: "VM (base Lima)"
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
                                             arguments: ["-U", "0", "-x", "vmnet-(natd|dhcpd|bridge)"],  // so do root: processo homonimo do usuario nao esconde o reparo
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
    /// Duas camadas de escape: o caminho vai entre aspas simples para o
    /// shell, e o comando inteiro vira literal AppleScript. Aspas duplas
    /// cruas dentro do literal quebravam a compilacao do script.
    /// Team ID da VMware (codesign -dv do vmnet-cli instalado).
    static let vmwareTeamID = "EG7KH642X6"
    /// Requisito designado do vmnet-cli instalado (codesign -dr -): nome,
    /// Developer ID e o team. So o team aceitaria qualquer binario da VMware
    /// chamado vmnet-cli, inclusive versoes antigas ou builds de desenvolvimento.
    static let vmwareRequirement = "identifier \"vmnet-cli\" and anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        + " and certificate leaf[subject.OU] = \"\(vmwareTeamID)\""

    /// O shell ja root confere a assinatura da VMware antes de executar:
    /// /Applications e gravavel pelo grupo admin, entao o bundle poderia ser
    /// trocado durante o dialogo de senha, depois da checagem do app.
    /// O shell root fixa o diretorio com cd (renomear o bundle depois nao
    /// muda o que ./vmnet-cli aponta), confere como root que diretorio e
    /// arquivo sao do root, sem escrita de grupo/outros e sem symlink, e so
    /// entao executa o ./vmnet-cli verificado. Residual aceito: os daemons
    /// que o vmnet-cli dispara vem do proprio bundle da VMware.
    func startScript() -> String {
        // Ambiente zerado como root: o vmnet-cli le config de $HOME (gravavel
        // pelo usuario) e o do shell script herda o ambiente do app; com o
        // HOME do usuario, um config plantado viraria escrita de arquivo como root.
        let rootEnv = "/usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = "\(verificationShell()); \(rootEnv) ./vmnet-cli --stop >/dev/null 2>&1; \(rootEnv) ./vmnet-cli --start"
        let literal = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(literal)\" with administrator privileges"
    }

    /// Etapa de verificacao do shell elevado (testavel sem root): sai com
    /// erro se algo nao confere, e deixa o shell no diretorio fixado.
    func verificationShell() -> String {
        func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let directory = shellQuote(URL(fileURLWithPath: vmnetCliPath).deletingLastPathComponent().path)
        let requirement = Self.vmwareRequirement
        return "cd \(directory) || exit 1; [ -L vmnet-cli ] && exit 1; "
            + "[ \"$(/usr/bin/find . vmnet-cli -maxdepth 0 -user 0 ! -perm -020 ! -perm -002 | /usr/bin/wc -l)\" -eq 2 ] || exit 1; "
            + "/usr/bin/codesign --verify --strict -R='\(requirement)' ./vmnet-cli || exit 1"
    }

    func start() -> CLIRunResult {
        guard Self.isRootOwned(vmnetCliPath) else {
            return CLIRunResult(stderr: "vmnet-cli nao pertence ao root ou e gravavel; elevacao recusada")
        }
        // osascript com ambiente minimo: sem HOME do usuario e sem prefixos
        // gravaveis no PATH herdado pelo shell elevado.
        return ContainerCLI.runBinary("/usr/bin/osascript", arguments: ["-e", startScript()],
                                      timeout: Self.startTimeout,
                                      environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    /// O binario roda como root apos a senha: se o usuario (ou quem roda
    /// como ele) pudesse troca-lo, o dialogo viraria escalada de privilegio.
    /// Exige dono root e nada gravavel por grupo/outros no arquivo e nos
    /// diretorios do caminho.
    static func isRootOwned(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while true {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0, metadata.st_uid == 0 else { return false }
            let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
            // /Applications e root:admin 775 por padrao no macOS: grupo admin
            // ja e quem pode digitar a senha, entao so "outros" conta ali.
            let forbidden = isDirectory && url.path == "/Applications" ? S_IWOTH : S_IWGRP | S_IWOTH
            guard metadata.st_mode & forbidden == 0 else { return false }
            if url.path == "/" { return true }
            url.deleteLastPathComponent()
        }
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
            return ContainerCLI.isTrustedExecutable(candidate) ? candidate : nil
        }.first
    }

    func currentStatus() -> (state: ExternalRuntimeState, path: String?) {
        let status = statusWithResult()
        return (status.state, status.path)
    }

    /// Status e a saida que o gerou: o tooltip reaproveita quando o comando
    /// informativo e o mesmo (Lima), em vez de rodar o CLI duas vezes.
    func statusWithResult() -> (state: ExternalRuntimeState, path: String?, result: CLIRunResult?) {
        guard let path = resolvedPath() else {
            return (.notInstalled, nil, nil)
        }
        let result = ContainerCLI.runBinary(config.statusBinary ?? path, arguments: config.statusArguments,
                                            timeout: config.statusTimeout)
        // Resultado volta tambem na falha: o tooltip reaproveita e nao repete
        // um CLI que acabou de estourar o prazo (Lima travado custava 2x 10s).
        guard result.spawned, !result.timedOut else {
            return (.stopped, path, result)
        }
        return (config.interpret(result), path, result)
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
            return ContainerCLI.isTrustedExecutable(candidate) ? candidate : nil
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
    func currentInfo(reusing statusResult: CLIRunResult? = nil) -> String? {
        guard let info = config.info, let path = resolvedPath() else { return nil }
        let reusable = config.statusBinary == nil && info.arguments == config.statusArguments
        let result = (reusable ? statusResult : nil)
            ?? ContainerCLI.runBinary(path, arguments: info.arguments, timeout: config.statusTimeout)
        // Ate 6 linhas (uma por instancia no Lima; o docker context e uma so).
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
            .map { ContainerCLI.menuSafe(String($0).trimmingCharacters(in: .whitespaces)) }
        guard result.succeeded, !lines.isEmpty else { return nil }
        let shown = lines.prefix(6).joined(separator: ", ")
        return "\(info.label): \(shown)\(lines.count > 6 ? ", ..." : "")"
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
    func tooltipInfo(state: ExternalRuntimeState, statusResult: CLIRunResult? = nil) -> String? {
        guard state != .notInstalled else { return nil }
        var parts: [String] = []
        if !config.nature.isEmpty {
            parts.append(config.nature)
        }
        if let runtimeInfo = currentInfo(reusing: statusResult) {
            parts.append(runtimeInfo)
        }
        if let autoStart = autoStartLabel() {
            parts.append("Auto-start: On (\(autoStart))")
        }
        if state == .running, let runningCount = runningCount() {
            parts.append("Containers: \(runningCount)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
