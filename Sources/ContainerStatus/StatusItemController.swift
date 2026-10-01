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
    private let item = NSStatusBar.system.statusItem(withLength: 20)
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
    /// contagem (mesma chamada de poll). Teto de linhas: 8 + resumo.
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
    private var loginEnabled: Bool

    // Menu items, kept as references so state changes mutate them in place.
    private let headerItem = NSMenuItem()
    private let pathItem = NSMenuItem()
    private let statusLineItem = NSMenuItem()
    /// Linhas dos containers de pe (pool reutilizado, teto 8 + resumo).
    private var containerRowItems: [NSMenuItem] = []
    /// Uma linha informativa por runtime, criada sob demanda em apply().
    private lazy var runtimeItems: [String: NSMenuItem] = Dictionary(
        uniqueKeysWithValues: runtimes.map { ($0.label, NSMenuItem()) }
    )
    private let actionItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let aboutAppleItem = NSMenuItem()
    private let aboutItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let vmnetRowItem = NSMenuItem()
    private let vmnetActionItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    // MARK: Lifecycle

    init(cli: ContainerCLI = ContainerCLI(),
         runtimes: [RuntimeProbe] = RuntimeProbeConfig.standard.map { RuntimeProbe(config: $0) },
         vmnet: VmnetProbe = VmnetProbe()) {
        self.cli = cli
        self.runtimes = runtimes
        self.vmnet = vmnet
        self.loginEnabled = Self.loginServiceEnabled
        super.init()
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

        headerItem.isEnabled = false
        statusLineItem.isEnabled = false
        vmnetRowItem.isEnabled = false
        vmnetActionItem.target = self
        vmnetActionItem.action = #selector(vmnetClicked(_:))
        for probe in runtimes {
            guard let item = runtimeItems[probe.label] else { continue }
            item.isEnabled = false
            item.target = self
            item.action = #selector(runtimeToggled(_:))
            item.representedObject = probe.label
        }
        actionItem.target = self
        actionItem.action = #selector(actionClicked(_:))
        errorItem.isEnabled = false
        aboutAppleItem.title = "Sobre Apple Container"
        aboutAppleItem.target = self
        aboutAppleItem.action = #selector(openAppleAbout(_:))
        aboutItem.target = self
        aboutItem.action = #selector(showAbout(_:))
        loginItem.title = "Abrir no login"
        loginItem.target = self
        loginItem.action = #selector(toggleLogin(_:))

        quitItem.title = "Sair"
        quitItem.action = #selector(NSApplication.terminate(_:))

        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(headerItem)
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
            menu.addItem(pathItem)
        }
        menu.addItem(.separator())
        menu.addItem(statusLineItem)
        menu.addItem(actionItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(vmnetRowItem)
        menu.addItem(vmnetActionItem)
        menu.addItem(.separator())
        menu.addItem(aboutAppleItem)
        menu.addItem(aboutItem)
        menu.addItem(quitItem)
        apply()
    }

    /// Refreshes menu text and the status icon from the current state.
    private func apply() {
        item.button?.image = Self.dotImage(state: state, dimmed: activity != .none)
        if let detail, !detail.isEmpty {
            errorItem.title = detail
            if errorItem.menu == nil {
                // Anchor fragil se a estrutura do menu mudar: index(of:)
                // retorna -1 e insertItem(at: -1) levanta excecao. O erro
                // entra no fim do menu como fallback seguro.
                let anchor = menu.index(of: loginItem)
                menu.insertItem(errorItem, at: anchor >= 0 ? anchor : menu.numberOfItems)
            }
        } else if errorItem.menu != nil {
            menu.removeItem(errorItem)
        }

        // Linhas dos containers de pe: id e memoria, logo abaixo do Status.
        // Pool de itens reutilizado; remove/insert neste unico caminho (regra 5).
        let visibleContainers = state == .running ? Array(containerItems.prefix(8)) : []
        while containerRowItems.count > visibleContainers.count {
            let row = containerRowItems.removeLast()
            if row.menu != nil { menu.removeItem(row) }
        }
        for (index, container) in visibleContainers.enumerated() {
            if index == containerRowItems.count {
                let row = NSMenuItem()
                row.isEnabled = false
                containerRowItems.append(row)
            }
            let row = containerRowItems[index]
            row.title = container.memoryBytes.map {
                "\(container.id) - \($0 / 1_048_576) MB"
            } ?? container.id
            if row.menu == nil {
                let anchor = menu.index(of: statusLineItem)
                menu.insertItem(row, at: anchor >= 0 ? anchor + 1 + index : menu.numberOfItems)
            }
        }

        // Linhas informativas dos runtimes (passo 1 do roadmap): entram
        // abaixo das linhas de container em ordem fixa e somem quando o
        // binario nao existe. Insert/remove sincronizados neste unico
        // caminho (regra 5). O anchor de cada linha e o item anterior
        // PRESENTE no menu, para nao depender de quem esta instalado.
        var anchorItem = containerRowItems.last.flatMap { $0.menu != nil ? $0 : nil } ?? statusLineItem
        for probe in runtimes {
            let item = runtimeItems[probe.label] ?? NSMenuItem()
            let runtimeState = runtimeStates[probe.label] ?? .notInstalled
            if runtimeState == .notInstalled {
                if item.menu != nil {
                    menu.removeItem(item)
                }
            } else {
                if runtimeActivity[probe.label] == true {
                    item.title = "\(probe.label): Alternando..."
                    item.isEnabled = false
                } else {
                    item.title = "\(probe.label): \(runtimeState == .running ? "Ligado" : "Desligado")"
                    // Passo 2: so e clicavel quem tem receita de controle.
                    item.isEnabled = probe.isControllable
                }
                // Passo 3 parcial: dono efetivo (ex. contexto do docker).
                item.toolTip = runtimeInfo[probe.label]
                if item.menu == nil {
                    let anchor = menu.index(of: anchorItem)
                    menu.insertItem(item, at: anchor >= 0 ? anchor + 1 : menu.numberOfItems)
                }
                anchorItem = item
            }
        }

        // Secao vmnet: so existe com Fusion instalado (regra 5 - remove/
        // insert aqui, unico caminho). Sem opcao de desligar.
        if vmnetState == .notInstalled {
            if vmnetRowItem.menu != nil { menu.removeItem(vmnetRowItem) }
            if vmnetActionItem.menu != nil { menu.removeItem(vmnetActionItem) }
        } else {
            var text = vmnetState == .running ? "VMware vmnet: Ativo" : "VMware vmnet: Parado"
            if vmCount > 0 {
                text += vmCount == 1 ? " - 1 VM" : " - \(vmCount) VMs"
            }
            vmnetRowItem.title = text
            vmnetRowItem.isEnabled = false
            if vmnetBusy {
                vmnetActionItem.title = "Subindo rede virtual..."
                vmnetActionItem.isEnabled = false
            } else {
                vmnetActionItem.title = "Subir rede virtual (vmnet)"
                vmnetActionItem.isEnabled = true
            }
            if vmnetRowItem.menu == nil || vmnetActionItem.menu == nil {
                let anchor = menu.index(of: loginItem)
                let base = anchor >= 0 ? anchor + 1 : menu.numberOfItems
                if vmnetRowItem.menu == nil {
                    menu.insertItem(vmnetRowItem, at: base)
                }
                if vmnetActionItem.menu == nil {
                    menu.insertItem(vmnetActionItem, at: menu.index(of: vmnetRowItem) + 1)
                }
            }
        }

        let versionSuffix = cliVersion.map { " \($0)" } ?? ""
        switch state {
        case .running: item.button?.toolTip = "Apple Container\(versionSuffix): ligado"
        case .stopped: item.button?.toolTip = "Apple Container\(versionSuffix): desligado"
        case .notInstalled: item.button?.toolTip = "Apple Container: CLI indisponivel"
        }

        switch activity {
        case .starting:
            item.button?.toolTip = "Apple Container\(versionSuffix): iniciando..."
        case .stopping:
            item.button?.toolTip = "Apple Container\(versionSuffix): parando..."
        case .none:
            break
        }

        headerItem.title = "Apple Container\(versionSuffix)"
        aboutItem.title = "Sobre ContainerStatus\(appVersion.map { " \($0)" } ?? "")"

        // Sufixo de carga: "Status: Ligado (2 containers)" quando a CLI
        // respondeu a contagem; singular, plural e ausente (CLI muda) tratados.
        func statusSuffix() -> String {
            guard let containerCount else { return "" }
            if containerCount == 1 { return " (1 container)" }
            return " (\(containerCount) containers)"
        }

        if activity != .none {
            statusLineItem.title = state == .running ? "Status: Ligado" : "Status: Desligado"
            actionItem.title = "Alternando..."
            actionItem.isEnabled = false
            actionItem.state = .off
        } else {
            switch state {
            case .running:
                statusLineItem.title = "Status: Ligado\(statusSuffix())"
                actionItem.title = "Desligar daemon"
                actionItem.isEnabled = true
                actionItem.state = .off
            case .stopped:
                statusLineItem.title = "Status: Desligado"
                actionItem.title = "Ligar daemon"
                actionItem.isEnabled = true
                actionItem.state = .off
            case .notInstalled:
                statusLineItem.title = "Status: Nao instalado"
                actionItem.title = Self.projectLinkText
                actionItem.isEnabled = true
                actionItem.state = .off
            }
        }

        loginItem.state = loginEnabled ? .on : .off
        loginItem.isEnabled = true
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
    }    /// Barreira de mutacao: finish()/finishRuntime() avancam a epoca e toda
    /// leitura em voo iniciada antes da mutacao e descartada no absorb.
    private var mutationEpoch = 0

    /// Captura a epoca no main actor ANTES de enfileirar a leitura; o absorb
    /// so aceita leituras da epoca corrente.
    private func spawnPoll(sequence: Int) {
        let epoch = mutationEpoch
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
            self.runtimeStates = runtimes
        }
        if let info {
            self.runtimeInfo = info
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
        loginEnabled = Self.loginServiceEnabled
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

    // MARK: Rede virtual (vmnet) - somente subir, nunca derrubar

    @objc private func vmnetClicked(_ sender: NSMenuItem) {
        guard !vmnetBusy, vmnet.fusionInstalled else { return }
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
        if result.succeeded {
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
            cli: ContainerCLI(directories: []),
            runtimes: [RuntimeProbe(config: .colima, directories: [])])
        controller.item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(controller.item) }

        let initialCount = controller.menu.numberOfItems
        expect(controller.errorItem.menu == nil, "menu inicia sem linha de erro")
        expect(controller.menu.index(of: controller.runtimeItems["Colima"] ?? NSMenuItem()) == -1,
               "menu inicia sem linha de colima")

        // Sufixo de carga no Status: contagem fresca do toggle, singular e
        // plural; finish sem contagem mantem a ultima.
        let listTwo = [ContainerCLI.ContainerSummary(id: "web", memoryBytes: 2_147_483_648),
                       ContainerCLI.ContainerSummary(id: "db", memoryBytes: nil)]
        controller.finish(result: CLIRunResult(exitCode: 0, spawned: true),
                          poll: (.running, nil), containers: listTwo)
        expect(controller.statusLineItem.title == "Status: Ligado (2 containers)",
               "status ligado mostra a contagem de containers")
        let rows = controller.containerRowItems
        expect(rows.count == 2 && rows[0].title == "web - 2048 MB" && rows[1].title == "db",
               "linhas de container mostram id e memoria")
        controller.finish(result: CLIRunResult(exitCode: 0, spawned: true),
                          poll: (.running, nil),
                          containers: [ContainerCLI.ContainerSummary(id: "a", memoryBytes: nil)])
        expect(controller.statusLineItem.title == "Status: Ligado (1 container)",
               "um container aparece no singular")
        expect(controller.containerRowItems.count == 1,
               "linhas de container acompanham a lista")
        controller.finish(result: CLIRunResult(exitCode: 0, spawned: true),
                          poll: (.running, nil))
        expect(controller.statusLineItem.title == "Status: Ligado (1 container)",
               "finish sem contagem mantem a ultima conhecida")
        controller.finish(result: CLIRunResult(exitCode: 1, spawned: true, stderr: "x"),
                          poll: (.stopped, nil))
        expect(controller.containerRowItems.isEmpty,
               "servico parado esconde as linhas de container")
        controller.finish(result: CLIRunResult(exitCode: 0, spawned: true),
                          poll: (.running, nil), containers: [])
        expect(controller.containerRowItems.isEmpty,
               "servico de pe sem carga nao tem linhas de container")

        controller.finish(result: CLIRunResult(exitCode: 1, spawned: true,
                                              stderr: "Falha ao iniciar\nDetalhe adicional"),
                          poll: (.stopped, nil))
        expect(controller.errorItem.title == "Falha ao iniciar"
               && controller.menu.index(of: controller.errorItem) == controller.menu.index(of: controller.loginItem) - 1,
               "falha insere primeira linha do erro antes do login")

        controller.finish(result: CLIRunResult(exitCode: 1, spawned: true, stderr: "Falha ao parar"),
                          poll: (.running, nil))
        expect(controller.errorItem.title == "Falha ao parar" && controller.menu.numberOfItems == initialCount + 1,
               "nova falha atualiza erro sem duplicar item")

        controller.absorb(poll: (.running, nil), sequence: 0)
        expect(controller.errorItem.title == "Falha ao parar" && controller.errorItem.menu === controller.menu,
               "erro local de toggle sobrevive a poll saudavel")

        controller.absorb(poll: (.stopped, "CLI retornou detalhe"), sequence: 1)
        expect(controller.errorItem.title == "CLI retornou detalhe",
               "poll com detalhe proprio substitui erro local")

        controller.finish(result: CLIRunResult(exitCode: 0, spawned: true), poll: (.running, nil))
        expect(controller.errorItem.menu == nil && controller.menu.numberOfItems == initialCount,
               "operacao bem-sucedida remove erro anterior")

        controller.absorb(poll: (.notInstalled, "CLI indisponivel"), sequence: 2)
        expect(controller.errorItem.title == "CLI indisponivel" && controller.errorItem.menu === controller.menu,
               "polling com falha exibe erro")

        controller.absorb(poll: (.running, nil), sequence: 3)
        expect(controller.errorItem.menu == nil && controller.menu.numberOfItems == initialCount,
               "recuperacao no polling remove erro")

        // Checagens em voo fora de ordem: um resultado antigo (sequence menor
        // que o ultimo aplicado) nao sobrescreve o estado recente. O teste
        // exercita o guard de ordem com sequencias explicitas; o poll real
        // (timer e menu) usa o contador compartilhado nextSequence().
        controller.absorb(poll: (.notInstalled, "checagem antiga"), sequence: 1)
        expect(controller.state == .running && controller.errorItem.menu == nil,
               "poll antigo fora de ordem e descartado")
        controller.absorb(poll: (.running, nil), sequence: 4)
        expect(controller.state == .running,
               "poll novo em sequencia correta aplica")

        // Barreira de epoca: uma leitura que comecou ANTES de finish() nao
        // pode aterrissar depois da mutacao com estado de meio-caminho,
        // mesmo com sequence alto (a leitura de epoca antiga e descartada
        // antes do guard de ordem).
        let epochBefore = controller.mutationEpoch
        controller.finish(result: CLIRunResult(exitCode: 0, spawned: true), poll: (.running, nil))
        controller.absorb(poll: (.stopped, nil), sequence: Int.max, epoch: epochBefore)
        expect(controller.state == .running && controller.errorItem.menu == nil,
               "poll de epoca anterior a mutacao e descartado")
        controller.absorb(poll: (.running, nil), sequence: Int.max, epoch: controller.mutationEpoch)
        expect(controller.state == .running,
               "poll da epoca corrente aplica")

        // Anchor degradado: se a estrutura mudar e loginItem sair do menu,
        // o insert precisa cair no fim (index(of:) = -1) sem excecao.
        controller.menu.removeItem(controller.loginItem)
        controller.finish(result: CLIRunResult(exitCode: 1, spawned: true, stderr: "Falha sem anchor"),
                          poll: (.running, nil))
        expect(controller.errorItem.menu === controller.menu
               && controller.menu.index(of: controller.errorItem) == controller.menu.numberOfItems - 1,
               "erro sem loginItem no menu insere no fim sem excecao")

        // Linha read-only do colima: entra abaixo do Status quando o binario
        // existe e some quando ele desaparece (insert/remove em apply, regra 5).
        let colimaController = StatusItemController(
            cli: ContainerCLI(directories: []),
            runtimes: [RuntimeProbe(config: .colima, directories: [])])
        colimaController.item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(colimaController.item) }
        let colimaCount = colimaController.menu.numberOfItems
        let colimaRow = { colimaController.runtimeItems["Colima"] ?? NSMenuItem() }
        colimaController.absorb(poll: (.running, nil), runtimes: ["Colima": .running], sequence: 1)
        expect(colimaController.menu.index(of: colimaRow())
               == colimaController.menu.index(of: colimaController.statusLineItem) + 1
               && colimaRow().title == "Colima: Ligado",
               "colima ligado insere linha informativa abaixo do Status")
        colimaController.absorb(poll: (.running, nil), runtimes: ["Colima": .stopped], sequence: 2)
        expect(colimaRow().title == "Colima: Desligado"
               && colimaController.menu.index(of: colimaRow()) != -1,
               "colima parado atualiza a linha sem duplicar item")
        colimaController.absorb(poll: (.running, nil), runtimes: ["Colima": .notInstalled], sequence: 3)
        expect(colimaController.menu.index(of: colimaRow()) == -1
               && colimaController.menu.numberOfItems == colimaCount,
               "colima removido tira a linha do menu")

        // Passo 2: linha com receita de controle e clicavel; o toggle async
        // (com estado simulado em arquivo) termina aplicando o novo estado.
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
        let statefulPath = toggleDirectory.appendingPathComponent("colima").path
        try? statefulScript.write(toFile: statefulPath, atomically: false, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statefulPath)
        let toggleController = StatusItemController(
            cli: ContainerCLI(directories: []),
            runtimes: [RuntimeProbe(config: .colima, directories: [toggleDirectory.path])])
        toggleController.item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(toggleController.item) }
        let toggleRow = { toggleController.runtimeItems["Colima"] ?? NSMenuItem() }
        toggleController.absorb(poll: (.running, nil), runtimes: ["Colima": .stopped], sequence: 1)
        expect(toggleRow().isEnabled == true, "linha com controle e clicavel")

        toggleController.runtimeToggled(toggleRow())
        expect(toggleRow().title == "Colima: Alternando..." && toggleRow().isEnabled == false,
               "toggle em voo mostra Alternando e desabilita a linha")
        var toggleDeadline = Date().addingTimeInterval(5)
        while Date() < toggleDeadline && toggleController.runtimeStates["Colima"] != .running {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(toggleController.runtimeStates["Colima"] == .running
               && toggleRow().title == "Colima: Ligado" && toggleRow().isEnabled == true,
               "toggle bem-sucedido aplica o novo estado e reabilita a linha")

        // Toggle falho: erro local com o rotulo do runtime, retido por detailIsLocal.
        // O estado atual e Ligado (start acima), entao o toggle executa o stop.
        let failingScript = """
        #!/bin/sh
        case "$1" in
          stop) echo "falhou feio" >&2; exit 1 ;;
          status) [ -f "$0.state" ] && exit 0 || exit 1 ;;
        esac
        """
        let failingPath = toggleDirectory.appendingPathComponent("colima").path
        try? failingScript.write(toFile: failingPath, atomically: false, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingPath)
        toggleController.runtimeToggled(toggleRow())
        toggleDeadline = Date().addingTimeInterval(5)
        while Date() < toggleDeadline && toggleController.errorItem.menu == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(toggleController.errorItem.title.hasPrefix("Colima:")
               && toggleController.errorItem.menu === toggleController.menu,
               "toggle falho mostra erro local com o rotulo do runtime")
        toggleController.absorb(poll: (.running, nil), runtimes: ["Colima": .stopped], sequence: 2)
        expect(toggleController.errorItem.title.hasPrefix("Colima:"),
               "erro local de runtime sobrevive a poll saudavel")

        // Direcao do toggle vem de leitura fresca: o menu (velho) diz
        // Desligado, mas a maquina real esta rodando; start em runtime vivo
        // falharia, entao o toggle correto e o stop.
        let staleScript = """
        #!/bin/sh
        case "$1" in
          start) if [ -f "$0.state" ]; then echo "ja rodando" >&2; exit 1; fi
                 touch "$0.state"; exit 0 ;;
          stop) rm -f "$0.state"; exit 0 ;;
          status) [ -f "$0.state" ] && exit 0 || exit 1 ;;
        esac
        """
        let stalePath = toggleDirectory.appendingPathComponent("colima").path
        try? staleScript.write(toFile: stalePath, atomically: false, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stalePath)
        toggleController.absorb(poll: (.running, nil), runtimes: ["Colima": .stopped], sequence: 3)
        expect(toggleRow().title == "Colima: Desligado",
               "menu velho mostra desligado enquanto a planta roda")
        toggleController.runtimeToggled(toggleRow())
        let freshDeadline = Date().addingTimeInterval(5)
        while Date() < freshDeadline && toggleController.runtimeActivity["Colima"] == true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(toggleController.runtimeStates["Colima"] == .stopped
               && toggleController.errorItem.menu == nil,
               "toggle decide a direcao por leitura fresca, nao pelo menu velho")

        // Start que sobe com atraso (open -a do OrbStack): o controle retorna
        // antes do runtime responder; o retry curto pos-controle pega o estado
        // novo antes de encerrar o "Alternando...".
        let delayedScript = """
        #!/bin/sh
        case "$1" in
          start) /bin/sleep 1; touch "$0.state"; exit 0 ;;
          stop) rm -f "$0.state"; exit 0 ;;
          status) [ -f "$0.state" ] && exit 0 || exit 1 ;;
        esac
        """
        let delayedPath = toggleDirectory.appendingPathComponent("colima").path
        try? delayedScript.write(toFile: delayedPath, atomically: false, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: delayedPath)
        toggleController.absorb(poll: (.running, nil), runtimes: ["Colima": .stopped], sequence: 4)
        toggleController.runtimeToggled(toggleRow())
        let retryDeadline = Date().addingTimeInterval(8)
        while Date() < retryDeadline && toggleController.runtimeActivity["Colima"] == true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(toggleController.runtimeStates["Colima"] == .running,
               "start com subida atrasada converge para ligado no retry")

        // Lado complementar da leitura fresca: menu velho diz Ligado, a
        // maquina real esta parada; o clique LIGA (verdade da maquina vence
        // o rotulo velho, que o poll seguinte corrige). O stub "delayed"
        // starta com exit 0 e a leitura fresca ve parado.
        try? FileManager.default.removeItem(at: toggleDirectory.appendingPathComponent("colima.state"))
        toggleController.absorb(poll: (.running, nil), runtimes: ["Colima": .running], sequence: 5)
        expect(toggleRow().title == "Colima: Ligado",
               "menu velho mostra ligado enquanto a planta esta parada")
        toggleController.runtimeToggled(toggleRow())
        let staleOnDeadline = Date().addingTimeInterval(8)
        while Date() < staleOnDeadline && toggleController.runtimeActivity["Colima"] == true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(toggleController.runtimeStates["Colima"] == .running
               && toggleController.errorItem.menu == nil,
               "toggle com menu velho ligado inicia o runtime parado")

        // Poll periodico vivo: o estado acompanha os flips da CLI por
        // multiplos ciclos. Regressao do P1 da revisao dev: a sentinela
        // Int.max envenenava lastAppliedSequence e congelava o poll apos o
        // primeiro absorb (o dot parava de acompanhar o daemon de verdade).
        // Nota: o loop abaixo drena o RunLoop para que os jobs @MainActor
        // do timer executem; no harness de CLI eles podem rodar em thread
        // cooperativa (warnings de data race sao artefato do harness - no
        // app de verdade o NSApplication.run bombeia a MainActor na main
        // thread). A serializacao do actor garante ausencia de corrida.
        let flipDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs_flip_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: flipDirectory, withIntermediateDirectories: false)
        let flipScript = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "container CLI version 1.0.0"; exit 0; fi
        if [ "$1" = "system" ] && [ "$2" = "status" ]; then
          n=$(cat "$0.n" 2>/dev/null || echo 0)
          n=$((n+1)); echo $n > "$0.n"
          [ $((n % 2)) -eq 1 ] && exit 0 || exit 1
        fi
        exit 0
        """
        let flipPath = flipDirectory.appendingPathComponent("container").path
        try? flipScript.write(toFile: flipPath, atomically: false, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flipPath)
        let pollingController = StatusItemController(
            cli: ContainerCLI(directories: [flipDirectory.path]), runtimes: [])
        pollingController.item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(pollingController.item) }
        pollingController.startPolling(every: 0.2)
        defer { pollingController.pollTimer?.cancel() }
        var transitions = 0
        var lastObserved = pollingController.state
        let flipDeadline = Date().addingTimeInterval(5)
        while Date() < flipDeadline && transitions < 3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if pollingController.state != lastObserved {
                transitions += 1
                lastObserved = pollingController.state
            }
        }
        expect(transitions >= 3,
               "poll periodico acompanha os flips da CLI por multiplos ciclos")
    }

    // MARK: Launch at login

    private static var loginServiceEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
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
        loginEnabled = Self.loginServiceEnabled
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
    /// unavailable, dimmed while a toggle is in flight. The image is compact
    /// (16 px) inside a narrow status item so it takes little menu bar width,
    /// while the dot itself stays large and readable.
    private static func drawDot(state: ServiceState, dimmed: Bool) -> NSImage {
        let side: CGFloat = 16
        let alpha: CGFloat = dimmed ? 0.45 : 1.0
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3.5, dy: 3.5))
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
