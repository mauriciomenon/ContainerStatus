import AppKit
import os
import ServiceManagement

/// Owns the status bar item, the menu, and the idle/starting/stopping state
/// machine. All mutable state is main-actor; the CLI runs on background
/// queues and results hop back to the main actor.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let projectURL = URL(string: "https://github.com/apple/container")!
    private static let projectLinkText = "github.com/apple/container"
    private static let repoURL = URL(string: "https://github.com/mauriciomenon/ContainerStatus")!

    private let cli: ContainerCLI
    /// Sondas read-only dos runtimes do roadmap, ordem fixa de exibicao.
    private let runtimes: [RuntimeProbe]
    private let vmnet: VmnetProbe
    /// Comprimento no estilo Stats: ponto de 7.5 pt quase colado na borda
    /// do canvas 9 - sem margem morta, o glass do sistema da o resto.
    private let item = NSStatusBar.system.statusItem(withLength: 10)
    private let menu = NSMenu()
    private let pollQueue = DispatchQueue(label: "local.containerstatus.poll", qos: .utility)

    private var state: ServiceState = .stopped
    private var detail: String?
    /// Erro gravado pelo proprio app (toggle/login) sobrevive a polls saudaveis
    /// ate um novo toggle ou um poll que traga detalhe proprio.
    private var detailIsLocal = false
    private var activity: ServiceActivity = .none
    /// Estados read-only por runtime (passo 1 do roadmap multi-runtime),
    /// atualizados em absorb no main actor.
    private var runtimeStates: [String: ExternalRuntimeState] = [:]
    /// Runtimes com toggle em voo (passo 2); a linha mostra "Alternando...".
    private var runtimeActivity: [String: Bool] = [:]
    /// Informacao de planta por runtime (passo 3 parcial), ex. contexto do
    /// docker; vai para o tooltip da linha.
    private var runtimeInfo: [String: String] = [:]
    /// Containers rodando no Apple container (nil quando a CLI nao responde).
    private var containerCount: Int?
    /// Lista (id, memoria) exibida como linhas sob o Status; acompanha a
    /// contagem (mesma chamada de poll). Teto de 8 linhas - o estouro
    /// aparece no sufixo "(N containers)" do Status.
    private var containerItems: [ContainerCLI.ContainerSummary] = []
    /// Rede virtual do VMware (vmnet): estado, VMs e subida em voo.
    private var vmnetState: VmnetState = .notInstalled
    private var vmCount = 0
    private var vmnetBusy = false
    private var cliVersion: String?
    private var pathDisplay: String?
    /// App version shown next to the "Sobre ContainerStatus" item.
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private var pollTimer: DispatchSourceTimer?
    /// Checkmark do login vem daqui; SMAppService faz round-trip XPC, entao
    /// o cache e renovado so ao abrir o menu e no proprio toggle.
    /// Cache do status do login item (marcado, desmarcado ou pendente de
    /// aprovacao); renovado ao abrir o menu e no proprio toggle.
    private var loginStatusCache: SMAppService.Status = .notRegistered

    // Menu items, kept as references so state changes mutate them in place.
    private let headerItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    // Bloco Apple Container
    private let appleRowItem = NSMenuItem()
    private let pathItem = NSMenuItem()
    private let statusLineItem = NSMenuItem()
    /// Linhas dos containers de pe (pool reutilizado, teto 8).
    private var containerRowItems: [NSMenuItem] = []
    private let actionItem = NSMenuItem()
    private let githubItem = NSMenuItem()
    // Bloco Docker: daemon (sem toggle) + familia indentada (so detectados)
    private let dockerRowItem = NSMenuItem()
    private let dockerDetectItem = NSMenuItem()
    private lazy var subStatusItems: [String: NSMenuItem] = Dictionary(
        uniqueKeysWithValues: RuntimeProbeConfig.dockerFamily.map { ($0.label, NSMenuItem()) }
    )
    private lazy var subActionItems: [String: NSMenuItem] = Dictionary(
        uniqueKeysWithValues: RuntimeProbeConfig.dockerFamily.map { ($0.label, NSMenuItem()) }
    )
    // Blocos individuais
    private let podmanRowItem = NSMenuItem()
    private let podmanActionItem = NSMenuItem()
    private let lumeRowItem = NSMenuItem()
    private let lumeDetectItem = NSMenuItem()
    private let vmnetRowItem = NSMenuItem()
    private let vmnetActionItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let aboutItem = NSMenuItem()
    private let quitItem = NSMenuItem()
    private let sepDocker = NSMenuItem.separator()
    private let sepPodman = NSMenuItem.separator()
    private let sepLume = NSMenuItem.separator()
    private let sepVmnet = NSMenuItem.separator()
    private let tailSep = NSMenuItem.separator()

    // MARK: Lifecycle

    init(cli: ContainerCLI = ContainerCLI(),
         runtimes: [RuntimeProbe] = RuntimeProbeConfig.standard.map { RuntimeProbe(config: $0) },
         vmnet: VmnetProbe = VmnetProbe()) {
        self.cli = cli
        self.runtimes = runtimes
        self.vmnet = vmnet
        super.init()
        loginStatusCache = Self.loginStatus
        buildMenu()
        item.menu = menu
        item.button?.image = Self.dotImage(state: state, dimmed: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startPolling()
        refreshNow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.cancel()
    }

    // MARK: Menu

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        // Cabecalho clicavel: varedura completa de deteccao (⟳).
        headerItem.isEnabled = true
        headerItem.target = self
        headerItem.action = #selector(headerClicked(_:))

        appleRowItem.isEnabled = false
        statusLineItem.isEnabled = false
        actionItem.target = self
        actionItem.action = #selector(actionClicked(_:))
        githubItem.title = "GitHub"
        githubItem.target = self
        githubItem.action = #selector(openAppleAbout(_:))
        dockerRowItem.isEnabled = false
        dockerDetectItem.isEnabled = false
        for probe in runtimes {
            guard let row = subStatusItems[probe.label] else { continue }
            row.isEnabled = false
            row.indentationLevel = 1
            row.action = #selector(runtimeToggled(_:))
            row.target = self
            row.representedObject = probe.label
            if let action = subActionItems[probe.label] {
                action.indentationLevel = 1
                action.target = self
                action.action = #selector(runtimeToggled(_:))
                action.representedObject = probe.label
            }
        }
        vmnetRowItem.isEnabled = false
        vmnetActionItem.target = self
        vmnetActionItem.action = #selector(vmnetClicked(_:))
        errorItem.isEnabled = false
        aboutItem.title = "About."
        aboutItem.target = self
        aboutItem.action = #selector(showAbout(_:))
        loginItem.title = "Open at Login"
        loginItem.target = self
        loginItem.action = #selector(toggleLogin(_:))

        quitItem.title = "Quit"
        quitItem.action = #selector(NSApplication.terminate(_:))

        rebuildMenu()
    }

    /// Esqueleto fixo: cabecalho, login, e a cauda About/Quit. Todo o resto
    /// e zona dinamica que o apply() reconstrói em ordem canonica.
    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(headerItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(tailSep)
        menu.addItem(aboutItem)
        menu.addItem(quitItem)
        apply()
    }

    /// Refreshes menu text and the status icon from the current state.
    /// A zona dinamica do menu e reconstruida aqui em ordem canonica: cada
    /// bloco (Apple, Docker+familia, Podman, Lume, vmnet) entra apos o
    /// ultimo item PRESENTE do anterior - remove/insert neste unico
    /// caminho (regra 5).
    private func apply() {
        item.button?.image = Self.dotImage(state: state, dimmed: activity != .none)
        headerItem.title = "Container Status \(appVersion ?? "") ⟳"
        headerItem.toolTip = "Click to rescan detections"

        var anchorItem = loginItem  // ultimo item fixo do cabecalho

        func place(_ item: NSMenuItem, present: Bool) {
            if present {
                if item.menu == nil {
                    let anchor = menu.index(of: anchorItem)
                    menu.insertItem(item, at: anchor >= 0 ? anchor + 1 : menu.numberOfItems)
                }
                anchorItem = item
            } else if item.menu != nil {
                menu.removeItem(item)
            }
        }

        if let detail, !detail.isEmpty {
            errorItem.title = detail
            place(errorItem, present: true)
        } else {
            place(errorItem, present: false)
        }

        // ---- Bloco Apple Container ----
        place(appleRowItem, present: true)
        if let pathDisplay {
            // Long symlink chains break in two: resolved path on top,
            // "via <symlink>" underneath.
            let rendered = pathDisplay.count > 40 && pathDisplay.contains(" via ")
                ? pathDisplay.replacingOccurrences(of: " via ", with: "\nvia ")
                : pathDisplay
            pathItem.attributedTitle = NSAttributedString(string: rendered, attributes: [
                .font: NSFont.menuFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            pathItem.isEnabled = false
        }
        place(pathItem, present: pathDisplay != nil)
        place(statusLineItem, present: true)

        // Linhas dos containers de pe: id e memoria. Pool reutilizado.
        let visibleContainers = state == .running ? Array(containerItems.prefix(8)) : []
        while containerRowItems.count < visibleContainers.count {
            let row = NSMenuItem()
            row.isEnabled = false
            containerRowItems.append(row)
        }
        for (index, container) in visibleContainers.enumerated() {
            let row = containerRowItems[index]
            row.title = container.memoryBytes.map {
                "\(container.id) - \($0 / 1_048_576) MB"
            } ?? container.id
            place(row, present: true)
        }
        for row in containerRowItems.dropFirst(visibleContainers.count) {
            place(row, present: false)
        }

        let actionLabel = activity != .none
            ? "Working..."
            : (state == .running ? "Disable Daemon" : "Enable Daemon")
        actionItem.title = actionLabel
        actionItem.isEnabled = activity == .none && state != .notInstalled
        place(actionItem, present: state != .notInstalled)
        place(githubItem, present: true)

        // ---- Bloco Docker: daemon sem toggle + familia indentada ----
        place(sepDocker, present: true)
        place(dockerRowItem, present: true)
        let dockerProbe = runtimes.first { $0.label == "Docker" }
        let dockerState = runtimeStates["Docker"] ?? .notInstalled
        dockerRowItem.title = "Docker: \(dockerState == .running ? "Running" : "Not Running")"
        dockerRowItem.toolTip = dockerProbe.flatMap { $0.tooltipInfo(state: dockerState) }
        dockerDetectItem.title = dockerState == .notInstalled ? "Not Detected" : "Detected"
        place(dockerDetectItem, present: true)

        for config in RuntimeProbeConfig.dockerFamily {
            guard config.label != "Docker" else { continue }
            let probe = runtimes.first { $0.label == config.label }
            let subState = runtimeStates[config.label] ?? .notInstalled
            guard let statusItem = subStatusItems[config.label],
                  let actionItem = subActionItems[config.label] else { continue }
            let detected = subState != .notInstalled
            if detected {
                statusItem.title = "\(config.label): \(subState == .running ? "Running" : "Not Running")"
                statusItem.toolTip = probe?.tooltipInfo(state: subState)
                statusItem.attributedTitle = NSAttributedString(
                    string: statusItem.title,
                    attributes: [.font: NSFont.menuFont(ofSize: 11),
                                 .foregroundColor: NSColor.secondaryLabelColor])
                statusItem.indentationLevel = 1
                statusItem.isEnabled = false
                place(statusItem, present: true)
                if config.control != nil {
                    if runtimeActivity[config.label] == true {
                        actionItem.title = "Working..."
                        actionItem.isEnabled = false
                    } else {
                        actionItem.title = subState == .running ? "Disable Daemon" : "Enable Daemon"
                        actionItem.isEnabled = true
                    }
                    actionItem.indentationLevel = 1
                    actionItem.attributedTitle = NSAttributedString(
                        string: actionItem.title,
                        attributes: [.font: NSFont.menuFont(ofSize: 11)])
                    place(actionItem, present: true)
                } else {
                    place(actionItem, present: false)
                }
            } else {
                place(statusItem, present: false)
                place(actionItem, present: false)
            }
        }

        // ---- Podman (bloco proprio) ----
        let podmanState = runtimeStates["Podman"] ?? .notInstalled
        let podmanProbe = runtimes.first { $0.label == "Podman" }
        place(sepPodman, present: podmanState != .notInstalled)
        place(podmanRowItem, present: podmanState != .notInstalled)
        if podmanState != .notInstalled {
            podmanRowItem.title = "Podman: \(podmanState == .running ? "Running" : "Not Running")"
            podmanRowItem.toolTip = podmanProbe.flatMap { $0.tooltipInfo(state: podmanState) }
            if runtimeActivity["Podman"] == true {
                podmanActionItem.title = "Working..."
                podmanActionItem.isEnabled = false
            } else {
                podmanActionItem.title = podmanState == .running ? "Disable Daemon" : "Enable Daemon"
                podmanActionItem.isEnabled = true
            }
        }

        // ---- Lume (bloco proprio, sem toggle) ----
        let lumeState = runtimeStates["Lume"] ?? .notInstalled
        let lumeProbe = runtimes.first { $0.label == "Lume" }
        place(sepLume, present: lumeState != .notInstalled)
        place(lumeRowItem, present: lumeState != .notInstalled)
        if lumeState != .notInstalled {
            lumeRowItem.title = "Lume: \(lumeState == .running ? "Running" : "Not Running")"
            lumeRowItem.toolTip = lumeProbe.flatMap { $0.tooltipInfo(state: lumeState) }
            lumeDetectItem.title = "Detected"
            place(lumeDetectItem, present: true)
        } else {
            place(lumeDetectItem, present: false)
        }

        // ---- VMware vmnet (bloco proprio, somente subir) ----
        let vmnetPresent = vmnetState != .notInstalled
        place(sepVmnet, present: vmnetPresent)
        place(vmnetRowItem, present: vmnetPresent)
        if vmnetPresent {
            var text = vmnetState == .running ? "VMware vmnet: Running" : "VMware vmnet: Not Running"
            if vmCount > 0 {
                text += vmCount == 1 ? " - 1 VM" : " - \(vmCount) VMs"
            }
            vmnetRowItem.title = text
            vmnetRowItem.isEnabled = false
            if vmnetBusy {
                vmnetActionItem.title = "Working..."
                vmnetActionItem.isEnabled = false
            } else {
                vmnetActionItem.title = "Enable Daemon"
                vmnetActionItem.isEnabled = true
            }
            place(vmnetActionItem, present: vmnetState != .running)
        } else {
            place(vmnetActionItem, present: false)
        }

        place(tailSep, present: true)

        let versionSuffix = cliVersion.map { " \($0)" } ?? ""
        switch state {
        case .running: item.button?.toolTip = "Apple Container\(versionSuffix): running"
        case .stopped: item.button?.toolTip = "Apple Container\(versionSuffix): stopped"
        case .notInstalled: item.button?.toolTip = "Apple Container: CLI not found"
        }

        switch activity {
        case .starting:
            item.button?.toolTip = "Apple Container\(versionSuffix): starting..."
        case .stopping:
            item.button?.toolTip = "Apple Container\(versionSuffix): stopping..."
        case .none:
            break
        }

        appleRowItem.title = "Apple Container\(versionSuffix)"
        aboutItem.title = "About."

        statusLineItem.title = activity != .none
            ? (state == .running ? "Status: Running" : "Status: Not Running")
            : (state == .running ? "Status: Running\(statusSuffix())" : "Status: Not Running")

        loginItem.title = "Open at Login"
        loginItem.state = loginStatusCache == .enabled ? .on : .off
        loginItem.isEnabled = true
    }

    private func statusSuffix() -> String {
        guard let containerCount else { return "" }
        if containerCount == 1 { return " (1 container)" }
        return " (\(containerCount) containers)"
    }

    // MARK: Polling

    private func startPolling(every interval: TimeInterval = 3) {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { @Sendable [weak self] in
            // A classe e @MainActor e o handler roda na pollQueue: a volta a
            // main passa pela main queue com assumeIsolated (a main queue
            // so executa na main thread). A sequencia vem de contador
            // compartilhado (lock) - a antiga sentinela Int.max envenenava
            // o guard de ordem apos o primeiro ciclo e congelava o poll
            // para sempre.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.spawnPoll(sequence: (self?.nextSequence()) ?? 0)
                }
            }
        }
        timer.resume()
        pollTimer = timer
    }

    /// Identifica checagens em voo: resultados velhos (timer + menu aberto)
    /// podem chegar fora de ordem; o mais recente vence e um mais antigo que
    /// chegue depois e descartado.
    private let sequenceLock = OSAllocatedUnfairLock(initialState: 0)
    private var lastAppliedSequence = -1

    private func nextSequence() -> Int {
        sequenceLock.withLock { value in
            value += 1
            return value
        }
    }

    private let cycleLock = OSAllocatedUnfairLock(initialState: 0)

    private func nextCycle() -> Int {
        cycleLock.withLock { value in
            value += 1
            return value
        }
    }    /// Barreira de mutacao: finish()/finishRuntime() avancam a epoca e toda
    /// leitura em voo iniciada antes da mutacao e descartada no absorb.
    private var mutationEpoch = 0

    /// Captura a epoca no main actor ANTES de enfileirar a leitura; o absorb
    /// so aceita leituras da epoca corrente.
    private func spawnPoll(sequence: Int) {
        let epoch = mutationEpoch
        let cycle = nextCycle()
        pollQueue.async { [cli, runtimes, vmnet, weak self] in
            let result = cli.checkStatus()
            // Uma chamada so alimenta contagem e lista do menu.
            let containers = cli.runningContainers()
            // Sondas read-only em serie no pollQueue: cada uma com watchdog
            // proprio de 2s (pior caso por sonda travada ~5.5s com kill e
            // teto de IO; nominal < 1s para as 3 CLIs reais). Quem nao esta
            // instalado custa so stat. Paralelizar so se virar queixa real.
            var states: [String: ExternalRuntimeState] = [:]
            var info: [String: String] = [:]
            for probe in runtimes {
                // Cadencia por sonda: caras (lume ~0.9s) rodam a cada N
                // ciclos; quem nao vence mantem o ultimo estado no absorb.
                if (cycle - 1) % probe.config.pollEvery != 0 { continue }
                let (state, _) = probe.currentStatus()
                states[probe.label] = state
                if let tooltip = probe.tooltipInfo(state: state) {
                    info[probe.label] = tooltip
                }
            }
            let vmnetStatus = vmnet.currentStatus()
            Task { @MainActor [weak self] in
                self?.absorb(poll: result, containers: containers, runtimes: states, info: info,
                             vmnet: vmnetStatus, sequence: sequence, epoch: epoch)
            }
        }
    }

    /// One-shot background check (used when the menu opens).
    func refreshNow() {
        spawnPoll(sequence: nextSequence())
    }

    private func absorb(poll: (state: ServiceState, detail: String?),
                        containers: [ContainerCLI.ContainerSummary]? = nil,
                        runtimes: [String: ExternalRuntimeState]? = nil,
                        info: [String: String]? = nil,
                        vmnet: (state: VmnetState, vmCount: Int)? = nil,
                        sequence: Int, epoch: Int = Int.max) {
        guard epoch >= mutationEpoch else { return }
        guard sequence > lastAppliedSequence else { return }
        if let vmnet, vmnetBusy != true {
            self.vmnetState = vmnet.state
            self.vmCount = vmnet.vmCount
        }
        if let containers {
            containerItems = containers
            containerCount = containers.count
        }
        if let runtimes {
            for (label, runtimeState) in runtimes {
                self.runtimeStates[label] = runtimeState
            }
        }
        if let info {
            for (label, tooltip) in info {
                self.runtimeInfo[label] = tooltip
            }
        }
        lastAppliedSequence = sequence
        if activity == .none {
            state = poll.state
            if let pollDetail = poll.detail {
                detail = pollDetail
                detailIsLocal = false
            } else if !detailIsLocal {
                detail = nil
            }
        }
        cliVersion = cli.currentVersion()
        let newPathDisplay = cli.resolvedPathInfo()
        if newPathDisplay != pathDisplay {
            pathDisplay = newPathDisplay
            rebuildMenu()
            return
        }
        apply()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginStatusCache = Self.loginStatus
        refreshNow()
        if activity == .none { apply() }
    }

    // MARK: Actions

    @objc private func actionClicked(_ sender: NSMenuItem) {
        // In the not-installed state the action row is a link to the project.
        if state == .notInstalled {
            openProjectPage()
            return
        }
        guard activity == .none else { return }
        let turningOff = (state == .running)
        activity = turningOff ? .stopping : .starting
        detail = nil
        detailIsLocal = false
        apply()

        let cli = self.cli
        Task.detached(priority: .userInitiated) {
            let result = turningOff ? cli.stop() : cli.start()
            let poll = cli.checkStatus()
            // Contagem e lista frescas junto: sem isso o status mostraria a
            // carga do poll anterior por ate 3s apos o toggle.
            let containers = cli.runningContainers()
            await MainActor.run { [weak self] in
                self?.finish(result: result, poll: poll, containers: containers)
            }
        }
    }

    private func finish(result: CLIRunResult, poll: (state: ServiceState, detail: String?),
                        containers: [ContainerCLI.ContainerSummary]? = nil) {
        mutationEpoch += 1
        activity = .none
        state = poll.state
        if let containers {
            containerItems = containers
            containerCount = containers.count
        }
        if result.succeeded {
            detail = poll.detail
            detailIsLocal = false
        } else {
            let message = ContainerCLI.firstLine(result.stderr)
            detail = message.isEmpty ? "Operacao falhou" : message
            detailIsLocal = true
        }
        apply()
    }

    // MARK: Runtime toggles (passo 2)

    @objc private func runtimeToggled(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String,
              let probe = runtimes.first(where: { $0.label == label }),
              probe.isControllable,
              runtimeActivity[label] != true else { return }
        runtimeActivity[label] = true
        detail = nil
        detailIsLocal = false
        apply()

        Task.detached(priority: .userInitiated) { [weak self] in
            // O estado do menu pode estar ate 3s velho; a direcao do toggle
            // vem de uma leitura fresca, no momento do clique.
            let fresh = probe.currentStatus().state
            let turningOff = fresh == .running
            let result = turningOff ? probe.stop() : probe.start()
            // Controle pode retornar antes do runtime terminar de subir
            // (ex.: open -a do OrbStack e imediato, o app ainda nao responde);
            // sondar com retry curto antes de decidir o estado final.
            var state = probe.currentStatus().state
            if result.succeeded {
                let expected: ExternalRuntimeState = turningOff ? .stopped : .running
                var attempts = 0
                while state != expected && attempts < 3 {
                    try? await Task.sleep(for: .seconds(1))
                    attempts += 1
                    state = probe.currentStatus().state
                }
            }
            await MainActor.run { [weak self] in
                self?.finishRuntime(label: label, result: result, state: state)
            }
        }
    }

    // MARK: Varedura ativa (⟳ do cabecalho)

    @objc private func headerClicked(_ sender: NSMenuItem) {
        cli.rescan()
        refreshNow()
    }

    // MARK: Rede virtual (vmnet) - somente subir, nunca derrubar

    @objc private func vmnetClicked(_ sender: NSMenuItem) {
        guard !vmnetBusy, activity == .none, vmnet.fusionInstalled else { return }
        vmnetBusy = true
        detail = nil
        detailIsLocal = false
        apply()

        let probe = vmnet
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = probe.start()
            let status = probe.currentStatus()
            await MainActor.run { [weak self] in
                self?.finishVmnet(result: result, state: status.state, vmCount: status.vmCount)
            }
        }
    }

    private func finishVmnet(result: CLIRunResult, state: VmnetState, vmCount: Int) {
        mutationEpoch += 1
        vmnetBusy = false
        vmnetState = state
        self.vmCount = vmCount
        // Cancelar o dialogo de senha nao e falha: sai silencioso.
        let canceled = result.exitCode == 2 || result.stderr.contains("User canceled")
        if result.succeeded || canceled {
            detail = nil
            detailIsLocal = false
        } else {
            let message = ContainerCLI.firstLine(result.stderr)
            detail = "vmnet: \(message.isEmpty ? "falha ao subir" : message)"
            detailIsLocal = true
        }
        apply()
    }

    /// Mesmo contrato do finish() do Apple container: avanca a barreira de
    /// epoca (polls em voo da era anterior sao descartados) e retenta o erro
    /// local ate o proximo toggle ou um poll com detalhe proprio.
    private func finishRuntime(label: String, result: CLIRunResult,
                               state: ExternalRuntimeState) {
        mutationEpoch += 1
        runtimeActivity[label] = nil
        runtimeStates[label] = state
        if result.succeeded {
            detail = nil
            detailIsLocal = false
        } else {
            let message = ContainerCLI.firstLine(result.stderr)
            detail = "\(label): \(message.isEmpty ? "Operacao falhou" : message)"
            detailIsLocal = true
        }
        apply()
        // Tooltip fresco junto (contexto/auto-start/contagem mudam com o
        // toggle); sondas fora da main, escrita de volta no main actor.
        guard let probe = runtimes.first(where: { $0.label == label }) else { return }
        Task.detached(priority: .utility) { [weak self] in
            let tooltip = probe.tooltipInfo(state: state)
            await MainActor.run { [weak self] in
                self?.runtimeInfo[label] = tooltip
                self?.apply()
            }
        }
    }

    // Regressao opcional de AppKit, sem iniciar polling ou executar a CLI real.
    static func checkMenuErrors(expect: (Bool, String) -> Void) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = StatusItemController(
            cli: ContainerCLI(directories: []), runtimes: [],
            vmnet: VmnetProbe(fusionAppPath: "/no/such/Fusion.app"))
        controller.item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(controller.item) }
        let menu = controller.menu

        func hasConsecutiveSeparators(_ menu: NSMenu) -> Bool {
            var previousWasSeparator = false
            for item in menu.items {
                let isSeparator = item.isSeparatorItem
                if isSeparator && previousWasSeparator { return true }
                previousWasSeparator = isSeparator
            }
            return false
        }

        // Estrutura inicial: cabecalho + login fixos, sem blocos (nada
        // detectado com runtimes: [] e Fusion ausente), sem erro.
        expect(controller.headerItem.menu != nil && controller.loginItem.menu != nil,
               "cabecalho e login fixos no menu")
        expect(controller.appleRowItem.menu != nil && controller.dockerRowItem.menu != nil,
               "blocos Apple e Docker sempre presentes")
        expect(controller.podmanRowItem.menu == nil && controller.lumeRowItem.menu == nil,
               "podman e lume fora do menu quando nao detectados")
        expect(controller.vmnetRowItem.menu == nil,
               "vmnet fora do menu sem Fusion")
        expect(!hasConsecutiveSeparators(menu), "sem separadores consecutivos")
        expect(controller.errorItem.menu == nil, "menu inicia sem linha de erro")

        // Header: titulo com versao do app e acao de varedura.
        expect(controller.headerItem.title.contains("Container Status")
               && controller.headerItem.title.contains("⟳"),
               "cabecalho mostra nome, versao e ⟳")

        // Bloco Apple: estado, linhas de container com memoria, acao.
        let listTwo = [ContainerCLI.ContainerSummary(id: "web", memoryBytes: 2_147_483_648),
                       ContainerCLI.ContainerSummary(id: "db", memoryBytes: nil)]
        controller.finish(result: CLIRunResult(exitCode: 0, spawned: true),
                          poll: (.running, nil), containers: listTwo)
        expect(controller.statusLineItem.title == "Status: Running (2 containers)",
               "status em ingles com contagem quando rodando")
        let rows = controller.containerRowItems
        expect(rows.count == 2 && rows[0].title == "web - 2048 MB" && rows[1].title == "db",
               "linhas de container mostram id e memoria")
        expect(controller.actionItem.title == "Disable Daemon" && controller.actionItem.isEnabled,
               "acao do daemon em ingles e habilitada")
        expect(controller.githubItem.menu != nil && controller.githubItem.title == "GitHub",
               "GitHub presente no bloco Apple")

        // Ciclo de vida da linha de erro: entra, atualiza, sai.
        controller.finish(result: CLIRunResult(exitCode: 1, spawned: true, stderr: "Start failed"),
                          poll: (.running, nil))
        expect(controller.errorItem.title == "Start failed" && controller.errorItem.menu != nil,
               "falha insere linha de erro")
        controller.absorb(poll: (.running, nil), containers: listTwo, sequence: 1)
        expect(controller.errorItem.title == "Start failed",
               "erro local sobrevive a poll saudavel")
        controller.finish(result: CLIRunResult(exitCode: 0, spawned: true),
                          poll: (.running, nil), containers: listTwo)
        expect(controller.errorItem.menu == nil, "sucesso remove a linha de erro")
        controller.finish(result: CLIRunResult(exitCode: 1, spawned: true, stderr: "x"),
                          poll: (.stopped, nil), containers: [])
        expect(controller.containerRowItems.allSatisfy { $0.menu == nil }
               && controller.actionItem.title == "Enable Daemon",
               "servico parado esconde linhas e troca a acao")

        // Bloco Docker: daemon sempre presente, sem toggle; familia so com
        // detectados, indentada, com acao proprio.
        expect(controller.dockerRowItem.menu != nil && controller.dockerDetectItem.menu != nil,
               "bloco Docker sempre presente")
        controller.absorb(poll: (.running, nil),
                          runtimes: ["Docker": .running, "OrbStack": .running,
                                     "Colima": .notInstalled, "Docker Desktop": .notInstalled],
                          sequence: 2)
        expect(controller.dockerRowItem.title == "Docker: Running"
               && controller.dockerDetectItem.title == "Detected",
               "docker mostra estado e Detected")
        expect(controller.subStatusItems["OrbStack"]?.menu != nil,
               "OrbStack detectado entra como sub-item")
        expect(controller.subStatusItems["OrbStack"]?.indentationLevel == 1,
               "sub-item indentado no bloco Docker")
        expect(controller.subActionItems["OrbStack"]?.title == "Disable Daemon"
               && controller.subActionItems["OrbStack"]?.isEnabled == true,
               "OrbStack com toggle proprio")
        expect(controller.subStatusItems["Colima"]?.menu == nil
               && controller.subStatusItems["Docker Desktop"]?.menu == nil,
               "providers nao detectados ficam fora do menu")
        controller.absorb(poll: (.running, nil),
                          runtimes: ["Docker": .notInstalled, "OrbStack": .notInstalled],
                          sequence: 3)
        expect(controller.dockerDetectItem.title == "Not Detected"
               && controller.subStatusItems["OrbStack"]?.menu == nil,
               "sem deteccao o bloco Docker esvazia a familia")

        // Toggle de sub-provider: ciclo completo com stub stateful.
        let toggleDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs_toggle_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: toggleDirectory, withIntermediateDirectories: false)
        let statefulScript = """
        #!/bin/sh
        case "$1" in
          start) touch "$0.state"; exit 0 ;;
          stop) rm -f "$0.state"; exit 0 ;;
          status) [ -f "$0.state" ] && exit 0 || exit 1 ;;
        esac
        """
        let stubPath = toggleDirectory.appendingPathComponent("colima").path
        try? statefulScript.write(toFile: stubPath, atomically: false, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)
        let toggleController = StatusItemController(
            cli: ContainerCLI(directories: []),
            runtimes: [RuntimeProbe(config: .colima, directories: [toggleDirectory.path])],
            vmnet: VmnetProbe(fusionAppPath: "/no/such/Fusion.app"))
        toggleController.item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(toggleController.item) }
        let colimaRow = { toggleController.subStatusItems["Colima"] ?? NSMenuItem() }
        toggleController.absorb(poll: (.running, nil),
                                runtimes: ["Colima": .stopped], sequence: 1)
        expect(colimaRow().menu != nil && colimaRow().isEnabled == false,
               "colima detectado entra como sub-item do bloco Docker")
        expect(toggleController.subActionItems["Colima"]?.title == "Enable Daemon",
               "colima parado oferece Enable Daemon")
        toggleController.subActionItems["Colima"]?.representedObject = "Colima"
        toggleController.runtimeToggled(toggleController.subActionItems["Colima"] ?? NSMenuItem())
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && toggleController.runtimeActivity["Colima"] == true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(toggleController.runtimeStates["Colima"] == .running,
               "toggle do sub-provider completa o ciclo")

        // Cancelar dialogo do vmnet nao e falha.
        toggleController.finishVmnet(
            result: CLIRunResult(exitCode: 2, spawned: true, stderr: "User canceled. (-128)"),
            state: .running, vmCount: 1)
        expect(toggleController.errorItem.menu == nil,
               "cancelar vmnet sai sem linha de erro")

        // Ordem: epoca e sequencia seguem descartando leituras velhas.
        let epochBefore = toggleController.mutationEpoch
        toggleController.finish(result: CLIRunResult(exitCode: 0, spawned: true),
                                poll: (.running, nil), containers: [])
        toggleController.absorb(poll: (.stopped, nil), sequence: Int.max,
                                epoch: epochBefore)
        expect(toggleController.runtimeStates["Colima"] == .running,
               "poll de epoca anterior nao sobrescreve o toggle")
    }
    // MARK: Launch at login

    private static var loginStatus: SMAppService.Status {
        guard #available(macOS 13.0, *) else { return .notRegistered }
        return SMAppService.mainApp.status
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        if service.status == .requiresApproval {
            // Ja registrado, esperando o slider: o clique guia para o painel
            // no ponto certo. A linha do login ja anuncia o pendente; nao e
            // erro, entao nada de linha de diagnostico com retencao.
            SMAppService.openSystemSettingsLoginItems()
            loginStatusCache = Self.loginStatus
            apply()
            return
        }
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            detail = "Login: \(error.localizedDescription)"
            detailIsLocal = true
        }
        loginStatusCache = Self.loginStatus
        apply()
    }

    @objc private func openAppleAbout(_ sender: NSMenuItem) {
        menu.cancelTracking()
        NSWorkspace.shared.open(Self.projectURL)
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        menu.cancelTracking()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: "ContainerStatus",
                .applicationVersion: self.appVersion ?? "",
                .credits: Self.makeCredits(),
            ])
        }
    }

    /// About panel content, centered top to bottom: author, base commit,
    /// repository and project links, license, build date (baked at package
    /// time).
    private static func makeCredits() -> NSAttributedString {
        let info = Bundle.main.infoDictionary
        let commit = info?["GitCommit"] as? String
        let buildDate = info?["BuildDate"] as? String

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let text = NSMutableAttributedString()
        func append(_ string: String, font: NSFont, color: NSColor = .labelColor, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if let link { attributes[.link] = link }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        let regular = NSFont.systemFont(ofSize: 11)
        let small = NSFont.systemFont(ofSize: 10)

        append("Mauricio Menon\n", font: NSFont.boldSystemFont(ofSize: 12))
        if let commit, !commit.isEmpty {
            append("Commit \(commit)\n", font: small, color: .secondaryLabelColor)
        }
        append("Repositorio\n", font: regular, link: repoURL)
        if let buildDate, !buildDate.isEmpty {
            append(buildDate + "\n", font: small, color: .secondaryLabelColor)
        }
        append("GPL 2.0", font: small, color: .secondaryLabelColor)
        return text
    }

    @objc private func openProjectPage() {
        menu.cancelTracking()
        NSWorkspace.shared.open(Self.projectURL)
    }

    // MARK: Icon

    /// All dot variants pre-rendered once: apply() runs a cada poll (3s) e
    /// nao deve alocar NSImage nova a cada vez.
    private static let dotImages: [String: NSImage] = {
        var cache: [String: NSImage] = [:]
        for dimmed in [false, true] {
            for state in [ServiceState.running, .stopped, .notInstalled] {
                cache[dotKey(state, dimmed)] = drawDot(state: state, dimmed: dimmed)
            }
        }
        return cache
    }()

    private static func dotKey(_ state: ServiceState, _ dimmed: Bool) -> String {
        let base: String
        switch state {
        case .running: base = "run"
        case .stopped: base = "stop"
        case .notInstalled: base = "none"
        }
        return dimmed ? base + "-d" : base
    }

    /// Draws the status dot: filled green/red, hollow gray when the CLI is
    /// unavailable, dimmed while a toggle is in flight. Canvas 9 px com o
    /// circulo de 7.5 pt na borda - a margem morta do canvas era o espaco
    /// que fazia o item parecer largo perto do Stats.
    private static func drawDot(state: ServiceState, dimmed: Bool) -> NSImage {
        let side: CGFloat = 9
        let alpha: CGFloat = dimmed ? 0.45 : 1.0
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            switch state {
            case .running:
                NSColor.systemGreen.withAlphaComponent(alpha).setFill()
                circle.fill()
            case .stopped:
                NSColor.systemRed.withAlphaComponent(alpha).setFill()
                circle.fill()
            case .notInstalled:
                NSColor.systemGray.withAlphaComponent(alpha).setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func dotImage(state: ServiceState, dimmed: Bool) -> NSImage {
        dotImages[dotKey(state, dimmed)]!
    }
}
