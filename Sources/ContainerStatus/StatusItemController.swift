import AppKit
import os
import ServiceManagement

/// Owns the status bar item, the menu, and the idle/starting/stopping state
/// machine. All mutable state is main-actor; the CLI runs on background
/// queues and results hop back to the main actor.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let projectURL = URL(string: "https://github.com/apple/container")!
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
    /// Versao do apiserver de pe; diferente da CLI = upgrade sem restart.
    private var serviceVersion: String?
    /// Ultima release do apple/container vista no GitHub (nil ate a 1a consulta).
    private var upstream: UpstreamRelease?
    private var upstreamTask: Task<Void, Never>?
    private var pathDisplay: String?
    /// App version shown next to the "Sobre ContainerStatus" item.
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private var pollTimer: DispatchSourceTimer?
    /// Cache do status do login item: SMAppService faz round-trip XPC, entao
    /// e renovado so ao abrir o menu e no proprio toggle.
    private var loginStatusCache: SMAppService.Status = .notRegistered

    // Menu items, kept as references so state changes mutate them in place.
    private let loginItem = NSMenuItem()
    // Bloco Apple Container
    private let appleRowItem = NSMenuItem()
    private let pathItem = NSMenuItem()
    private let statusLineItem = NSMenuItem()
    /// Linhas dos containers de pe (pool reutilizado, teto 8).
    private var containerRowItems: [NSMenuItem] = []
    private let actionItem = NSMenuItem()
    /// So aparece quando a release do GitHub supera a CLI instalada.
    private let updateItem = NSMenuItem()
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
    private let limaRowItem = NSMenuItem()
    private let sepLima = NSMenuItem.separator()
    private let vmnetRowItem = NSMenuItem()
    private let vmnetActionItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    /// Rodape: About (submenu com o painel e os links dos projetos) e Quit
    /// na ultima linha.
    private let aboutItem = NSMenuItem()
    private let quitItem = NSMenuItem()
    private let footerSep = NSMenuItem.separator()
    /// Links do submenu About, na ordem exibida.
    static let projectLinks: [(title: String, url: URL)] = [
        ("Apple Container on GitHub", projectURL),
        ("OrbStack on GitHub", URL(string: "https://github.com/orbstack/orbstack")!),
        ("Lima on GitHub", URL(string: "https://github.com/lima-vm/lima")!),
        ("Lume on GitHub", URL(string: "https://github.com/trycua/cua/tree/main/libs/lume")!),
    ]
    /// Linhas de informacao (cache do poll) de cada submenu de runtime,
    /// reaproveitadas para o submenu aberto nao piscar a cada poll.
    private var infoItemPools: [String: [NSMenuItem]] = [:]
    private var infoSeparators: [String: NSMenuItem] = [:]
    /// Cabecalho: titulo em negrito, linha de texto comum (sem view).
    private let headerItem = NSMenuItem()
    /// Varedura ativa (rescan da CLI + poll + release), linha do rodape.
    private let refreshItem = NSMenuItem()
    private let sepDocker = NSMenuItem.separator()
    private let sepPodman = NSMenuItem.separator()
    private let sepLume = NSMenuItem.separator()
    private let sepVmnet = NSMenuItem.separator()
    private let tailSep = NSMenuItem.separator()
    private let firstSep = NSMenuItem.separator()

    // MARK: Lifecycle

    init(cli: ContainerCLI = ContainerCLI.installed(),
         runtimes: [RuntimeProbe] = RuntimeProbeConfig.standard.map { RuntimeProbe(config: $0) },
         vmnet: VmnetProbe = VmnetProbe(), persistPosition: Bool = false) {
        self.cli = cli
        self.runtimes = runtimes
        self.vmnet = vmnet
        super.init()
        loginStatusCache = Self.loginStatus
        buildMenu()
        // Nome estavel: sem ele cada versao virava um "Item-N" novo no
        // defaults, a posicao arrastada pelo usuario se perdia e o ponto
        // podia nascer na borda direita, depois do relogio.
        // So a execucao normal: testes e --dump-menu escondem o item, e com o
        // nome persistente o AppKit gravaria essa invisibilidade para o app.
        if persistPosition {
            item.autosaveName = "ContainerStatusDot"
            item.isVisible = true  // recupera visibilidade gravada por build antigo
        }
        item.menu = menu
        item.button?.image = Self.dotImage(state: state, dimmed: false)
    }

    /// Diagnostico (--dump-menu): um poll real, sem mostrar o item, e imprime
    /// o menu como o usuario o veria, com a largura calculada pelo AppKit.
    static func dumpMenuAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = StatusItemController()
        controller.item.isVisible = false
        controller.refreshNow()
        // Espera o ciclo terminar de fato (pollInFlight zera so depois de
        // todas as CLIs do ciclo voltarem): sair antes deixaria filhos sem
        // watchdog. Prazo cobre o pior caso serial das sondas.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && (controller.lastAppliedSequence < 1 || controller.pollInFlight) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard controller.lastAppliedSequence >= 1, !controller.pollInFlight else {
            print("ERRO: o poll nao terminou no prazo; menu nao impresso")
            exit(1)
        }
        // Sem menuNeedsUpdate: ele dispararia outro poll antes do exit.
        controller.apply()
        func dump(_ items: [NSMenuItem], depth: Int) {
            for item in items {
                let lead = String(repeating: "      ", count: depth)
                if item.isSeparatorItem { print("\(lead)-----"); continue }
                let text = item.view != nil ? "[view \(Int(item.view?.frame.width ?? 0))pt]" : item.title
                let pad = lead + String(repeating: "  ", count: item.indentationLevel)
                let marks = (item.submenu != nil ? "  >" : "") + (item.isEnabled ? "" : "  (desabilitado)")
                print("\(pad)\(text.replacingOccurrences(of: "\n", with: " / "))\(marks)")
                if let submenu = item.submenu { dump(submenu.items, depth: depth + 1) }
            }
        }
        dump(controller.menu.items, depth: 0)
        print("largura do menu: \(Int(controller.menu.size.width))pt")
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startPolling()
        refreshNow()
        startUpstreamChecks()
    }

    /// Reabrir o app ja em execucao (Finder, Spotlight, `open`) nao mostrava
    /// nada: sem janela nem Dock, parecia que "nao abriu". Agora abre o menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.isVisible = true
        item.button?.performClick(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.cancel()
        upstreamTask?.cancel()
    }

    /// Consulta a release mais nova no arranque e a cada checkInterval. A
    /// requisicao roda fora da main (URLSession); so o resultado volta.
    private func startUpstreamChecks() {
        upstreamTask?.cancel()
        upstreamTask = Task { [weak self] in
            while !Task.isCancelled {
                if let release = await UpstreamRelease.fetchLatest() {
                    self?.upstream = release
                    self?.apply()
                }
                try? await Task.sleep(for: .seconds(UpstreamRelease.checkInterval))
            }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        appleRowItem.isEnabled = false
        statusLineItem.isEnabled = false
        statusLineItem.indentationLevel = 1
        actionItem.target = self
        actionItem.action = #selector(actionClicked(_:))
        updateItem.indentationLevel = 1
        updateItem.target = self
        updateItem.action = #selector(openUpdate(_:))
        dockerRowItem.indentationLevel = 1
        dockerDetectItem.isEnabled = false
        for probe in runtimes {
            guard let row = subStatusItems[probe.label] else { continue }
            row.isEnabled = false
            row.action = #selector(runtimeToggled(_:))
            row.target = self
            row.representedObject = probe.label
            if let action = subActionItems[probe.label] {
                action.target = self
                action.action = #selector(runtimeToggled(_:))
                action.representedObject = probe.label
            }
        }
        podmanRowItem.isEnabled = false
        podmanActionItem.target = self
        podmanActionItem.action = #selector(runtimeToggled(_:))
        podmanActionItem.representedObject = "Podman"
        vmnetRowItem.isEnabled = false
        vmnetActionItem.target = self
        vmnetActionItem.action = #selector(vmnetClicked(_:))
        errorItem.isEnabled = false
        loginItem.title = "Open at Login"
        loginItem.target = self
        loginItem.action = #selector(toggleLogin(_:))

        let aboutMenu = NSMenu()
        aboutMenu.autoenablesItems = false
        let panelItem = NSMenuItem(title: "About ContainerStatus \(appVersion ?? "")",
                                   action: #selector(showAbout(_:)), keyEquivalent: "")
        panelItem.target = self
        aboutMenu.addItem(panelItem)
        aboutMenu.addItem(.separator())
        for link in Self.projectLinks {
            let linkItem = NSMenuItem(title: link.title, action: #selector(openLink(_:)), keyEquivalent: "")
            linkItem.target = self
            linkItem.representedObject = link.url
            aboutMenu.addItem(linkItem)
        }
        aboutItem.title = "About"
        aboutItem.submenu = aboutMenu
        quitItem.title = "Quit"
        quitItem.target = self
        quitItem.action = #selector(quitClicked(_:))
        refreshItem.title = "Refresh"
        refreshItem.toolTip = "Rescan detections"
        refreshItem.target = self
        refreshItem.action = #selector(refreshClicked(_:))
        headerItem.attributedTitle = NSAttributedString(
            string: "Container Status \(appVersion ?? "")",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        headerItem.isEnabled = false

        rebuildMenu()
    }

    /// Esqueleto fixo: cabecalho no topo; no fim Refresh, About (com
    /// submenu) e Quit na ultima linha. Todo o resto e zona dinamica que o
    /// apply() reconstroi em ordem canonica, terminando no login.
    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(headerItem)
        menu.addItem(firstSep)
        menu.addItem(footerSep)
        menu.addItem(refreshItem)
        menu.addItem(aboutItem)
        menu.addItem(quitItem)
        apply()
    }

    /// Linhas do submenu a partir do tooltip ("natureza; rotulo: a, b; ..."):
    /// uma por parte, e listas abertas um elemento por linha, indentado.
    static func infoLines(_ info: String?) -> [(text: String, indent: Int)] {
        guard let info else { return [] }
        var lines: [(text: String, indent: Int)] = []
        for part in info.components(separatedBy: "; ") where !part.isEmpty {
            let elements = part.components(separatedBy: ", ")
            lines.append((elements[0], 0))
            lines += elements.dropFirst().map { ($0, 1) }
        }
        return lines
    }

    /// Submenu de um runtime: acoes primeiro, depois as linhas de informacao
    /// do cache do poll (as mesmas do tooltip). So reatribui os itens quando
    /// a lista muda: trocar com o submenu aberto o faria piscar a cada poll.
    /// Sem conteudo, a linha fica sem submenu.
    private func fillSubmenu(_ row: NSMenuItem, label: String, actions: [NSMenuItem]) {
        let lines = Self.infoLines(runtimeInfo[label])
        var pool = infoItemPools[label, default: []]
        while pool.count < lines.count {
            let line = NSMenuItem()
            line.isEnabled = false
            pool.append(line)
        }
        infoItemPools[label] = pool
        for (index, line) in lines.enumerated() {
            if pool[index].title != line.text { pool[index].title = line.text }
            pool[index].indentationLevel = line.indent
        }
        var items = actions
        if !actions.isEmpty && !lines.isEmpty {
            let separator = infoSeparators[label] ?? NSMenuItem.separator()
            infoSeparators[label] = separator
            items.append(separator)
        }
        items += pool.prefix(lines.count)
        row.isEnabled = !items.isEmpty
        guard !items.isEmpty else {
            row.submenu = nil
            return
        }
        let submenu = row.submenu ?? {
            let created = NSMenu()
            created.autoenablesItems = false
            row.submenu = created
            return created
        }()
        if submenu.items != items { submenu.items = items }
    }

    /// Refreshes menu text and the status icon from the current state.
    /// A zona dinamica do menu e reconstruida aqui em ordem canonica: cada
    /// bloco (Apple, Docker+familia, Podman, Lume, vmnet) entra apos o
    /// ultimo item PRESENTE do anterior - remove/insert neste unico
    /// caminho (regra 5).
    private func apply() {
        item.button?.image = Self.dotImage(state: state, dimmed: activity != .none)

        var anchorItem = firstSep  // ultimo item fixo antes da zona dinamica

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

        // ---- Bloco Apple Container ----
        place(appleRowItem, present: true)
        if let pathDisplay {
            // Long symlink chains break in two: resolved path on top,
            // "via <symlink>" underneath.
            let safePath = ContainerCLI.menuSafe(pathDisplay, limit: 200)  // nomes de symlink sao do usuario
            let rendered = safePath.count > 40 && safePath.contains(" via ")
                ? safePath.replacingOccurrences(of: " via ", with: "\nvia ")
                : safePath
            pathItem.attributedTitle = NSAttributedString(string: rendered, attributes: [
                .font: NSFont.menuFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            pathItem.indentationLevel = 1
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
            row.indentationLevel = 1
            place(row, present: true)
        }
        for row in containerRowItems.dropFirst(visibleContainers.count) {
            place(row, present: false)
        }

        let actionLabel = activity != .none
            ? "Working..."
            : (state == .running ? "Disable Daemon" : "Enable Daemon")
        actionItem.title = actionLabel
        actionItem.indentationLevel = 1
        actionItem.isEnabled = activity == .none && state != .notInstalled
        place(actionItem, present: state != .notInstalled)
        let update = UpstreamRelease.update(upstream, installed: cliVersion)
        if let update {
            updateItem.title = "Update available: \(update.version)"
        }
        place(updateItem, present: update != nil)

        // ---- Bloco Docker: linha com submenu (deteccao + familia) ----
        place(sepDocker, present: true)
        place(dockerRowItem, present: true)
        // Tooltips vem do cache montado fora da main (spawnPoll/finishRuntime):
        // tooltipInfo dispara processos e travaria o menu aqui.
        let dockerState = runtimeStates["Docker"] ?? .notInstalled
        dockerRowItem.title = "Docker: \(dockerState == .running ? "Running" : "Not Running")"
        dockerRowItem.toolTip = runtimeInfo["Docker"]
        dockerDetectItem.title = dockerState == .notInstalled ? "Not Detected" : "Detected"
        var dockerSubmenu = [dockerDetectItem]

        for config in RuntimeProbeConfig.dockerFamily {
            let subState = runtimeStates[config.label] ?? .notInstalled
            guard let statusItem = subStatusItems[config.label],
                  let actionItem = subActionItems[config.label] else { continue }
            if subState != .notInstalled {
                statusItem.title = "\(config.label): \(subState == .running ? "Running" : "Not Running")"
                statusItem.toolTip = runtimeInfo[config.label]
                statusItem.attributedTitle = NSAttributedString(
                    string: statusItem.title,
                    attributes: [.font: NSFont.menuFont(ofSize: 11),
                                 .foregroundColor: NSColor.secondaryLabelColor])
                statusItem.isEnabled = false
                dockerSubmenu.append(statusItem)
                if config.control != nil {
                    if runtimeActivity[config.label] == true {
                        actionItem.title = "Working..."
                        actionItem.isEnabled = false
                    } else if config.appBased {
                        actionItem.title = subState == .running ? "Stop \(config.label)" : "Start \(config.label)"
                        actionItem.isEnabled = true
                    } else {
                        actionItem.title = subState == .running ? "Disable Daemon" : "Enable Daemon"
                        actionItem.isEnabled = true
                    }
                    actionItem.indentationLevel = 1
                    actionItem.attributedTitle = NSAttributedString(
                        string: actionItem.title,
                        attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
                    dockerSubmenu.append(actionItem)
                }
            }
        }
        fillSubmenu(dockerRowItem, label: "Docker", actions: dockerSubmenu)

        // ---- Podman (bloco proprio) ----
        let podmanState = runtimeStates["Podman"] ?? .notInstalled
        place(sepPodman, present: podmanState != .notInstalled)
        place(podmanRowItem, present: podmanState != .notInstalled)
        if podmanState != .notInstalled {
            podmanRowItem.title = "Podman: \(podmanState == .running ? "Running" : "Not Running")"
            podmanRowItem.toolTip = runtimeInfo["Podman"]
            podmanRowItem.indentationLevel = 1
            if runtimeActivity["Podman"] == true {
                podmanActionItem.title = "Working..."
                podmanActionItem.isEnabled = false
            } else {
                podmanActionItem.title = podmanState == .running ? "Disable Daemon" : "Enable Daemon"
                podmanActionItem.isEnabled = true
            }
            podmanActionItem.indentationLevel = 1
        }
        place(podmanActionItem, present: podmanState != .notInstalled)

        // ---- Lume (linha com submenu: acao do daemon + informacao) ----
        let lumeState = runtimeStates["Lume"] ?? .notInstalled
        place(sepLume, present: lumeState != .notInstalled)
        place(lumeRowItem, present: lumeState != .notInstalled)
        if lumeState != .notInstalled {
            lumeRowItem.title = "Lume: \(lumeState == .running ? "Running" : "Not Running")"
            lumeRowItem.toolTip = runtimeInfo["Lume"]
            lumeRowItem.indentationLevel = 1
            if runtimeActivity["Lume"] == true {
                lumeDetectItem.title = "Working..."
                lumeDetectItem.isEnabled = false
            } else {
                lumeDetectItem.title = lumeState == .running ? "Disable Daemon" : "Enable Daemon"
                lumeDetectItem.isEnabled = true
                lumeDetectItem.target = self
                lumeDetectItem.action = #selector(runtimeToggled(_:))
                lumeDetectItem.representedObject = "Lume"
            }
            fillSubmenu(lumeRowItem, label: "Lume", actions: [lumeDetectItem])
        }

        // ---- Lima (linha com submenu somente leitura: instancias) ----
        let limaState = runtimeStates["Lima"] ?? .notInstalled
        place(sepLima, present: limaState != .notInstalled)
        if limaState != .notInstalled {
            limaRowItem.title = "Lima: \(limaState == .running ? "Running" : "Not Running")"
            limaRowItem.toolTip = runtimeInfo["Lima"]
            limaRowItem.indentationLevel = 1
            fillSubmenu(limaRowItem, label: "Lima", actions: [])
        }
        place(limaRowItem, present: limaState != .notInstalled)

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
            vmnetRowItem.indentationLevel = 1
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
        // Texto vem do stderr de CLIs externas: sem controle, com teto.
        if let detail, !detail.isEmpty {
            errorItem.title = ContainerCLI.menuSafe(detail, limit: 120)
            place(errorItem, present: true)
        } else {
            place(errorItem, present: false)
        }
        place(loginItem, present: true)

        let versionSuffix = cliVersion.map { " \($0)" } ?? ""
        switch state {
        case .running: item.button?.toolTip = "Apple Container\(versionSuffix): running"
        case .stopped: item.button?.toolTip = "Apple Container\(versionSuffix): stopped"
        case .notInstalled:
            // Timeout do status tambem cai aqui: com caminho resolvido a CLI
            // existe e so nao respondeu.
            item.button?.toolTip = pathDisplay == nil
                ? "Apple Container: CLI not found"
                : "Apple Container\(versionSuffix): not responding"
        }

        switch activity {
        case .starting:
            item.button?.toolTip = "Apple Container\(versionSuffix): starting..."
        case .stopping:
            item.button?.toolTip = "Apple Container\(versionSuffix): stopping..."
        case .none:
            break
        }

        // Servico de pe com versao antiga: o upgrade so vale apos restart.
        var staleService: String?
        if state == .running, let serviceVersion, let cliVersion, serviceVersion != cliVersion {
            staleService = serviceVersion
        }
        appleRowItem.title = "Apple Container\(versionSuffix)"
            + (staleService.map { " (running \($0), restart to update)" } ?? "")

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

    /// Menu fechado so alimenta o ponto da barra: 15s bastam e cortam ~5x os
    /// processos curtos de cada ciclo. Menu aberto volta a 3s.
    static let idlePollInterval: TimeInterval = 15
    static let openPollInterval: TimeInterval = 3
    private(set) var pollInterval: TimeInterval = 0

    func menuWillOpen(_ menu: NSMenu) { startPolling(every: Self.openPollInterval) }
    func menuDidClose(_ menu: NSMenu) { startPolling(every: Self.idlePollInterval) }

    /// Reagenda o timer unico (cancela o anterior: nunca dois timers vivos).
    private func startPolling(every interval: TimeInterval = StatusItemController.idlePollInterval) {
        guard interval != pollInterval || pollTimer == nil else { return }
        pollTimer?.cancel()
        pollInterval = interval
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

    /// Barreira de mutacao: finish()/finishRuntime() avancam a epoca e toda
    /// leitura em voo iniciada antes da mutacao e descartada no absorb.
    private var mutationEpoch = 0

    /// Um ciclo por vez: com sondas travadas um ciclo passa dos 3s do timer,
    /// e enfileirar o proximo mesmo assim fazia a fila crescer sem limite.
    private var pollInFlight = false
    /// Pedido feito com um ciclo em voo (rescan, menu aberto): esse ciclo ja
    /// leu o estado antigo, entao roda mais um assim que ele aterrissar.
    private var pollPending = false

    /// Captura a epoca no main actor ANTES de enfileirar a leitura; o absorb
    /// so aceita leituras da epoca corrente.
    private func spawnPoll(sequence: Int) {
        guard !pollInFlight else {
            pollPending = true
            return
        }
        pollInFlight = true
        let epoch = mutationEpoch
        pollQueue.async { [cli, runtimes, vmnet, weak self] in
            let result = cli.checkStatus()
            cli.refreshServiceVersion(running: result.state == .running)
            // Uma chamada so alimenta contagem e lista do menu.
            let containers = cli.runningContainers()
            // Sondas read-only em serie no pollQueue: cada uma com watchdog
            // proprio de 2s (pior caso por sonda travada ~5.5s com kill e
            // teto de IO; nominal < 1s para as 3 CLIs reais). Quem nao esta
            // instalado custa so stat. Paralelizar so se virar queixa real.
            var states: [String: ExternalRuntimeState] = [:]
            var info: [String: String] = [:]
            for probe in runtimes {
                let status = probe.statusWithResult()
                let state = status.state
                states[probe.label] = state
                if let tooltip = probe.tooltipInfo(state: state, statusResult: status.result) {
                    info[probe.label] = tooltip
                }
            }
            let vmnetStatus = vmnet.currentStatus()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pollInFlight = false
                self.absorb(poll: result, containers: containers, runtimes: states, info: info,
                            vmnet: vmnetStatus, sequence: sequence, epoch: epoch)
                if self.pollPending {
                    self.pollPending = false
                    self.spawnPoll(sequence: self.nextSequence())
                }
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
            // Runtime com toggle em voo: finishRuntime e quem decide o estado;
            // o poll no meio faria a linha piscar para o estado anterior.
            for (label, runtimeState) in runtimes where runtimeActivity[label] != true {
                self.runtimeStates[label] = runtimeState
                // Ausente em info = sem tooltip agora (ex.: desinstalado);
                // nao herda o texto do poll anterior.
                self.runtimeInfo[label] = info?[label]
            }
        }
        lastAppliedSequence = sequence
        if activity == .none {
            state = poll.state
            // Detalhe vazio (stderr vazio) nao apaga um erro local real.
            if let pollDetail = poll.detail, !pollDetail.isEmpty {
                detail = pollDetail
                detailIsLocal = false
            } else if !detailIsLocal {
                detail = nil
            }
        }
        cliVersion = cli.currentVersion()
        serviceVersion = cli.currentServiceVersion()
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
        guard activity == .none, state != .notInstalled else { return }
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
        if result.exitedCleanly {
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
        // A direcao e a do rotulo que o usuario clicou: reler o estado aqui
        // podia transformar um "Start" clicado em stop, se o runtime subiu
        // por fora nesse meio tempo. Start/stop repetidos sao inofensivos.
        let turningOff = runtimeStates[label] == .running
        runtimeActivity[label] = true
        detail = nil
        detailIsLocal = false
        apply()

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = turningOff ? probe.stop() : probe.start()
            // Controle pode retornar antes do runtime terminar de subir
            // (ex.: open -a do OrbStack e imediato, o app ainda nao responde);
            // sondar com retry curto antes de decidir o estado final.
            var state = probe.currentStatus().state
            if result.exitedCleanly {
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

    // MARK: Varedura ativa (item Refresh)

    @objc private func refreshClicked(_ sender: Any) {
        menu.cancelTracking()
        cli.rescan()
        refreshNow()
        startUpstreamChecks()
    }

    @objc private func openUpdate(_ sender: NSMenuItem) {
        menu.cancelTracking()
        guard let url = upstream?.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitClicked(_ sender: Any) {
        menu.cancelTracking()
        NSApplication.shared.terminate(nil)
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
        let canceled = result.stderr.contains("(-128)")  // osascript: exit 1, erro -128
        if result.exitedCleanly || canceled {
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
        if result.exitedCleanly {
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
        let epoch = mutationEpoch
        let sequence = lastAppliedSequence
        Task.detached(priority: .utility) { [weak self] in
            let tooltip = probe.tooltipInfo(state: state)
            await MainActor.run { [weak self] in
                self?.publishTooltip(label: label, tooltip: tooltip, epoch: epoch, sequence: sequence)
            }
        }
    }

    /// Tooltip calculado em segundo plano so entra se nada mais novo chegou
    /// enquanto ele rodava: outra mutacao (epoca) ou um poll ja aplicado
    /// (sequencia), que traz informacao mais recente.
    private func publishTooltip(label: String, tooltip: String?, epoch: Int, sequence: Int) {
        guard mutationEpoch == epoch, lastAppliedSequence == sequence else { return }
        runtimeInfo[label] = tooltip
        apply()
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

        // Estrutura inicial: cabecalho e rodape Refresh/About/Quit fixos, sem
        // blocos (nada detectado com runtimes: [] e Fusion ausente), sem erro.
        expect(controller.headerItem.menu != nil && controller.loginItem.menu != nil,
               "cabecalho e login fixos no menu")
        let count = menu.numberOfItems
        expect(count >= 4 && menu.items[count - 1] === controller.quitItem
               && menu.items[count - 2] === controller.aboutItem
               && menu.items[count - 3] === controller.refreshItem
               && menu.items[count - 4].isSeparatorItem
               && menu.items[count - 5] === controller.loginItem,
               "rodape: login | sep | Refresh | About | Quit na ultima linha")
        expect(menu.items.allSatisfy { $0.view == nil },
               "nenhum item de view: cabecalho, refresh e rodape sao linhas de texto")
        expect(controller.quitItem.action == #selector(quitClicked(_:))
               && controller.refreshItem.action == #selector(refreshClicked(_:)),
               "Quit e Refresh ligados as acoes")
        let aboutEntries = controller.aboutItem.submenu?.items.filter { !$0.isSeparatorItem } ?? []
        expect(aboutEntries.first?.action == #selector(showAbout(_:))
               && aboutEntries.dropFirst().map { $0.representedObject as? URL }
                  == StatusItemController.projectLinks.map { $0.url }
               && aboutEntries.dropFirst().allSatisfy { $0.action == #selector(openLink(_:)) },
               "submenu About: painel e links de Apple Container, OrbStack, Lima, Lume")
        expect(controller.appleRowItem.menu != nil && controller.dockerRowItem.menu != nil,
               "blocos Apple e Docker sempre presentes")
        expect(controller.podmanRowItem.menu == nil && controller.lumeRowItem.menu == nil,
               "podman e lume fora do menu quando nao detectados")
        expect(controller.vmnetRowItem.menu == nil,
               "vmnet fora do menu sem Fusion")
        expect(!hasConsecutiveSeparators(menu), "sem separadores consecutivos")
        expect(controller.errorItem.menu == nil, "menu inicia sem linha de erro")

        expect(controller.menu.size.width < 230,
               "menu estreito: largura segue o conteudo (\(Int(controller.menu.size.width))pt)")

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
        expect(controller.actionItem.title == "Disable Daemon" && controller.actionItem.isEnabled
               && controller.actionItem.indentationLevel == 1,
               "acao do daemon em ingles, habilitada e indentada")

        // Aviso de release nova: so com CLI instalada mais velha que a do GitHub.
        let newer = UpstreamRelease(version: "9.9.9",
                                    url: URL(string: "https://github.com/apple/container/releases/tag/9.9.9")!)
        controller.upstream = newer
        controller.cliVersion = "1.5.0"
        controller.apply()
        expect(controller.updateItem.menu != nil && controller.updateItem.title == "Update available: 9.9.9",
               "release nova no GitHub mostra o aviso no bloco Apple")
        expect(controller.menu.index(of: controller.updateItem)
               == controller.menu.index(of: controller.actionItem) + 1,
               "aviso de atualizacao logo abaixo da acao do daemon")
        controller.cliVersion = "9.9.9"
        controller.apply()
        expect(controller.updateItem.menu == nil, "CLI atualizada some com o aviso")
        controller.upstream = nil

        // CLI nova com servico antigo de pe: pede restart na linha Apple.
        controller.state = .running
        controller.serviceVersion = "1.5.0"
        controller.apply()
        expect(controller.appleRowItem.title == "Apple Container 9.9.9 (running 1.5.0, restart to update)",
               "servico com versao antiga pede restart")
        controller.serviceVersion = "9.9.9"
        controller.apply()
        expect(controller.appleRowItem.title == "Apple Container 9.9.9",
               "servico na mesma versao da CLI sem aviso")
        controller.serviceVersion = nil
        controller.cliVersion = nil

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
                          info: ["Docker": "contexto: orbstack"],
                          sequence: 2)
        expect(controller.dockerRowItem.toolTip == "contexto: orbstack",
               "tooltip do docker vem do cache do poll, sem spawn na main")
        expect(controller.dockerRowItem.title == "Docker: Running"
               && controller.dockerDetectItem.title == "Detected",
               "docker mostra estado e Detected")
        expect(controller.subStatusItems["OrbStack"]?.menu != nil,
               "OrbStack detectado entra como sub-item")
        expect(controller.subStatusItems["OrbStack"]?.menu === controller.dockerRowItem.submenu
               && controller.dockerDetectItem.menu === controller.dockerRowItem.submenu
               && controller.dockerRowItem.isEnabled,
               "deteccao e familia ficam no submenu da linha Docker, nao no menu principal")
        expect(controller.dockerRowItem.submenu?.items.last?.title == "contexto: orbstack",
               "submenu Docker termina com a informacao do poll")
        expect(controller.subActionItems["OrbStack"]?.title == "Stop OrbStack"
               && controller.subActionItems["OrbStack"]?.isEnabled == true,
               "OrbStack rodando oferece Stop (nao Disable Daemon)")
        expect(controller.subStatusItems["Colima"]?.menu == nil
               && controller.subStatusItems["Docker Desktop"]?.menu == nil,
               "providers nao detectados ficam fora do menu")
        controller.absorb(poll: (.running, nil),
                          runtimes: ["Docker": .notInstalled, "OrbStack": .notInstalled],
                          sequence: 3)
        expect(controller.dockerDetectItem.title == "Not Detected"
               && controller.subStatusItems["OrbStack"]?.menu == nil,
               "sem deteccao o bloco Docker esvazia a familia")
        expect(controller.dockerRowItem.toolTip == nil,
               "poll sem informacao limpa o tooltip anterior")

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

        // Menu mostra parado, runtime ja subiu por fora: o clique em
        // "Enable Daemon" tem de pedir start, nunca stop.
        toggleController.absorb(poll: (.running, nil), runtimes: ["Colima": .stopped],
                                sequence: toggleController.lastAppliedSequence + 1)
        toggleController.runtimeToggled(toggleController.subActionItems["Colima"] ?? NSMenuItem())
        let staleDeadline = Date().addingTimeInterval(5)
        while Date() < staleDeadline && toggleController.runtimeActivity["Colima"] == true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(toggleController.runtimeStates["Colima"] == .running,
               "clique segue o rotulo exibido, nao uma releitura do estado")

        // Tooltip atrasado de toggle nao sobrescreve poll aplicado depois.
        let tooltipEpoch = toggleController.mutationEpoch
        let tooltipSequence = toggleController.lastAppliedSequence
        toggleController.absorb(poll: (.running, nil), runtimes: ["Colima": .running],
                                info: ["Colima": "novo"], sequence: tooltipSequence + 1)
        toggleController.publishTooltip(label: "Colima", tooltip: "velho",
                                        epoch: tooltipEpoch, sequence: tooltipSequence)
        expect(toggleController.runtimeInfo["Colima"] == "novo",
               "tooltip atrasado nao sobrescreve poll mais recente")
        toggleController.publishTooltip(label: "Colima", tooltip: "atual", epoch: toggleController.mutationEpoch,
                                        sequence: toggleController.lastAppliedSequence)
        expect(toggleController.runtimeInfo["Colima"] == "atual", "tooltip sem nada mais novo e publicado")

        // Toggle em voo: poll nao reescreve o estado do runtime.
        toggleController.runtimeActivity["Colima"] = true
        toggleController.absorb(poll: (.running, nil), runtimes: ["Colima": .stopped],
                                sequence: toggleController.lastAppliedSequence + 1)
        expect(toggleController.runtimeStates["Colima"] == .running,
               "poll durante toggle nao faz a linha voltar ao estado anterior")
        toggleController.runtimeActivity["Colima"] = nil

        // Erro vindo de stderr: sem controle no titulo; vazio nao apaga erro local.
        toggleController.detail = "falhou\u{1B}[31m\nlinha falsa"
        toggleController.apply()
        expect(!toggleController.errorItem.title.contains("\n")
               && !toggleController.errorItem.title.contains("\u{1B}"),
               "linha de erro sem caracteres de controle")
        toggleController.detail = "Login: x"
        toggleController.detailIsLocal = true
        toggleController.absorb(poll: (.running, ""), sequence: toggleController.lastAppliedSequence + 1)
        expect(toggleController.detail == "Login: x", "detalhe vazio do poll nao apaga erro local")
        toggleController.detail = nil
        toggleController.detailIsLocal = false

        // Tooltip do ponto: CLI ausente x CLI presente que nao respondeu.
        toggleController.state = .notInstalled
        toggleController.pathDisplay = nil
        toggleController.apply()
        expect(toggleController.item.button?.toolTip == "Apple Container: CLI not found",
               "sem CLI o tooltip diz nao encontrada")
        toggleController.pathDisplay = "/usr/local/bin/container"
        toggleController.cliVersion = "1.5.0"
        toggleController.apply()
        expect(toggleController.item.button?.toolTip == "Apple Container 1.5.0: not responding",
               "CLI presente com status estourado diz que nao respondeu")
        toggleController.pathDisplay = nil
        toggleController.cliVersion = nil

        // Login: sucesso apos falha limpa o erro de login, nao o de outros.
        toggleController.recordLoginResult(error: CocoaError(.featureUnsupported))
        toggleController.apply()
        expect(toggleController.errorItem.menu != nil, "falha de login mostra linha de erro")
        toggleController.recordLoginResult(error: nil)
        toggleController.apply()
        expect(toggleController.errorItem.menu == nil, "login com sucesso apaga o erro de login anterior")
        toggleController.detail = "vmnet: falha ao subir"
        toggleController.detailIsLocal = true
        toggleController.recordLoginResult(error: nil)
        expect(toggleController.detail == "vmnet: falha ao subir",
               "login com sucesso preserva erro de outra operacao")
        toggleController.detail = nil
        toggleController.detailIsLocal = false

        // Cancelar dialogo do vmnet nao e falha.
        toggleController.finishVmnet(
            result: CLIRunResult(exitCode: 1, spawned: true, stderr: "execution error: User canceled. (-128)"),
            state: .running, vmCount: 1)
        expect(toggleController.errorItem.menu == nil,
               "cancelar vmnet sai sem linha de erro")

        // Lume com toggle brew: detected-only quando brew ausente.
        let lumeController = StatusItemController(
            cli: ContainerCLI(directories: []), runtimes: [],
            vmnet: VmnetProbe(fusionAppPath: "/no/such/Fusion.app"))
        lumeController.item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(lumeController.item) }
        lumeController.absorb(poll: (.running, nil), runtimes: ["Lume": .notInstalled], sequence: 1)
        expect(lumeController.lumeRowItem.menu == nil,
               "lume fora do menu sem deteccao")
        // Lima: bloco so aparece com limactl, linha informativa sem acao.
        expect(lumeController.limaRowItem.menu == nil, "lima fora do menu sem deteccao")
        lumeController.absorb(poll: (.running, nil), runtimes: ["Lima": .stopped],
                              info: ["Lima": "VMs Lima (limactl); instancias: default Stopped, docker Running"],
                              sequence: 2)
        let limaLines = lumeController.limaRowItem.submenu?.items ?? []
        expect(lumeController.limaRowItem.menu != nil && lumeController.limaRowItem.title == "Lima: Not Running"
               && lumeController.limaRowItem.isEnabled
               && limaLines.map(\.title) == ["VMs Lima (limactl)", "instancias: default Stopped", "docker Running"]
               && limaLines.map(\.indentationLevel) == [0, 0, 1]
               && limaLines.allSatisfy { !$0.isEnabled },
               "lima detectado abre submenu com uma instancia por linha")
        let firstLine = limaLines.first
        lumeController.absorb(poll: (.running, nil), runtimes: ["Lima": .stopped],
                              info: ["Lima": "VMs Lima (limactl); instancias: default Running, docker Running"],
                              sequence: 3)
        expect(lumeController.limaRowItem.submenu?.items.first === firstLine
               && lumeController.limaRowItem.submenu?.items[1].title == "instancias: default Running",
               "poll novo atualiza as linhas no lugar, sem recriar itens")
        lumeController.absorb(poll: (.running, nil), runtimes: ["Lima": .stopped], sequence: 4)
        expect(lumeController.limaRowItem.submenu == nil && !lumeController.limaRowItem.isEnabled,
               "lima sem informacao fica sem submenu vazio")
        lumeController.absorb(poll: (.running, nil), runtimes: ["Podman": .running], sequence: 5)
        expect(lumeController.podmanActionItem.menu != nil
               && lumeController.podmanActionItem.title == "Disable Daemon"
               && lumeController.podmanActionItem.action == #selector(runtimeToggled(_:))
               && lumeController.podmanActionItem.representedObject as? String == "Podman"
               && lumeController.menu.index(of: lumeController.podmanActionItem)
                  == lumeController.menu.index(of: lumeController.podmanRowItem) + 1,
               "podman detectado mostra a acao logo abaixo da linha")
        lumeController.absorb(poll: (.running, nil), runtimes: ["Podman": .notInstalled], sequence: 6)
        expect(lumeController.podmanActionItem.menu == nil, "podman sumido leva a acao junto")
        lumeController.absorb(poll: (.running, nil), runtimes: ["Lume": .stopped], sequence: 7)
        expect(lumeController.lumeRowItem.menu != nil
               && lumeController.lumeDetectItem.title == "Enable Daemon"
               && lumeController.lumeDetectItem.menu === lumeController.lumeRowItem.submenu
               && lumeController.lumeRowItem.isEnabled,
               "lume detectado oferece habilitar o daemon no submenu da linha")

        // Poll em voo: um segundo pedido no meio e descartado, nao enfileirado.
        // Cadencia: 15s com menu fechado, 3s aberto, um unico timer.
        lumeController.startPolling()
        expect(lumeController.pollInterval == StatusItemController.idlePollInterval, "menu fechado consulta a cada 15s")
        let firstTimer = lumeController.pollTimer
        lumeController.menuWillOpen(lumeController.menu)
        expect(lumeController.pollInterval == StatusItemController.openPollInterval
               && firstTimer?.isCancelled == true,
               "menu aberto consulta a cada 3s e cancela o timer anterior")
        lumeController.menuDidClose(lumeController.menu)
        expect(lumeController.pollInterval == StatusItemController.idlePollInterval, "fechar o menu volta a 15s")
        lumeController.pollTimer?.cancel()
        lumeController.pollTimer = nil
        // Disparo real: um timer curto precisa produzir polls aplicados, e o
        // cancelado nao pode produzir mais nenhum.
        // Sequencias manuais dos testes acima ficam acima do contador real.
        lumeController.lastAppliedSequence = -1
        let firedBefore = lumeController.lastAppliedSequence
        lumeController.startPolling(every: 0.3)
        // Duas aplicacoes distintas: um timer que dispara uma vez e congela falha.
        var applications: Set<Int> = []
        let fireDeadline = Date().addingTimeInterval(4)
        while Date() < fireDeadline && applications.count < 2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if lumeController.lastAppliedSequence > firedBefore { applications.insert(lumeController.lastAppliedSequence) }
        }
        expect(applications.count >= 2, "timer repete polls de verdade na cadencia (\(applications.count) aplicacoes)")
        lumeController.pollTimer?.cancel()
        let settle = Date().addingTimeInterval(1)
        while Date() < settle { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let afterCancel = lumeController.lastAppliedSequence
        let quiet = Date().addingTimeInterval(1)
        while Date() < quiet { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(lumeController.lastAppliedSequence == afterCancel, "timer cancelado para de disparar")
        lumeController.pollTimer = nil
        lumeController.pollInterval = 0

        // Pedidos no meio de um ciclo viram UM ciclo extra (rescan nao some),
        // nunca uma fila.
        lumeController.lastAppliedSequence = -1
        lumeController.spawnPoll(sequence: lumeController.nextSequence())
        lumeController.spawnPoll(sequence: lumeController.nextSequence())
        lumeController.spawnPoll(sequence: lumeController.nextSequence())
        expect(lumeController.pollPending, "pedido com ciclo em voo fica pendente")
        let pollDeadline = Date().addingTimeInterval(8)
        while Date() < pollDeadline && (lumeController.pollInFlight || lumeController.pollPending) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let issued = lumeController.sequenceLock.withLock { $0 }
        expect(!lumeController.pollInFlight && lumeController.lastAppliedSequence == issued,
               "pendente roda uma vez apos o ciclo em voo, sem fila")

        // Ordem: epoca e sequencia seguem descartando leituras velhas.
        let epochBefore = toggleController.mutationEpoch
        toggleController.finish(result: CLIRunResult(exitCode: 0, spawned: true),
                                poll: (.running, nil), containers: [])
        toggleController.absorb(poll: (.stopped, nil), sequence: Int.max,
                                epoch: epochBefore)
        // O poll velho so muda o estado Apple: e ele (e a sequencia) que
        // revela se o guard de epoca segurou.
        expect(toggleController.state == .running && toggleController.lastAppliedSequence != Int.max,
               "poll de epoca anterior nao sobrescreve o toggle")
    }
    // MARK: Launch at login

    private static var loginStatus: SMAppService.Status {
        SMAppService.mainApp.status
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
            recordLoginResult(error: nil)
        } catch {
            recordLoginResult(error: error)
        }
        loginStatusCache = Self.loginStatus
        apply()
    }

    /// Falha grava o erro local; sucesso apaga so um erro de login anterior
    /// (erro de outra operacao continua visivel).
    private func recordLoginResult(error: Error?) {
        if let error {
            detail = "Login: \(error.localizedDescription)"
            detailIsLocal = true
        } else if detail?.hasPrefix("Login: ") == true {
            detail = nil
            detailIsLocal = false
        }
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        menu.cancelTracking()
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
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
