import AppKit
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
    private let item = NSStatusBar.system.statusItem(withLength: 20)
    private let menu = NSMenu()
    private let pollQueue = DispatchQueue(label: "local.containerstatus.poll", qos: .utility)

    private var state: ServiceState = .stopped
    private var detail: String?
    /// Erro gravado pelo proprio app (toggle/login) sobrevive a polls saudaveis
    /// ate um novo toggle ou um poll que traga detalhe proprio.
    private var detailIsLocal = false
    private var activity: ServiceActivity = .none
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
    private let actionItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let aboutAppleItem = NSMenuItem()
    private let aboutItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    // MARK: Lifecycle

    init(cli: ContainerCLI = ContainerCLI()) {
        self.cli = cli
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
                menu.insertItem(errorItem, at: menu.index(of: loginItem))
            }
        } else if errorItem.menu != nil {
            menu.removeItem(errorItem)
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

        if activity != .none {
            statusLineItem.title = state == .running ? "Status: Ligado" : "Status: Desligado"
            actionItem.title = "Alternando..."
            actionItem.isEnabled = false
            actionItem.state = .off
        } else {
            switch state {
            case .running:
                statusLineItem.title = "Status: Ligado"
                actionItem.title = "Desligar daemon"
                actionItem.isEnabled = true
                actionItem.state = .off
            case .stopped:
                statusLineItem.title = "Status: Desligado"
                actionItem.title = "Ligar daemon"
                actionItem.isEnabled = true
                actionItem.state = .off
            case .notInstalled:
                statusLineItem.title = "Status: Não instalado"
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
        timer.setEventHandler { [cli, weak self] in
            let result = cli.checkStatus()
            Task { @MainActor [weak self] in
                self?.absorb(poll: result)
            }
        }
        timer.resume()
        pollTimer = timer
    }

    private func absorb(poll: (state: ServiceState, detail: String?)) {
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

    /// One-shot background check (used when the menu opens).
    func refreshNow() {
        pollQueue.async { [cli, weak self] in
            let result = cli.checkStatus()
            Task { @MainActor [weak self] in
                self?.absorb(poll: result)
            }
        }
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
            await MainActor.run { [weak self] in
                self?.finish(result: result, poll: poll)
            }
        }
    }

    private func finish(result: CLIRunResult, poll: (state: ServiceState, detail: String?)) {
        activity = .none
        state = poll.state
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

    // Regressao opcional de AppKit, sem iniciar polling ou executar a CLI real.
    static func checkMenuErrors(expect: (Bool, String) -> Void) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = StatusItemController(cli: ContainerCLI(directories: []))
        controller.item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(controller.item) }

        let initialCount = controller.menu.numberOfItems
        expect(controller.errorItem.menu == nil, "menu inicia sem linha de erro")

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

        controller.absorb(poll: (.running, nil))
        expect(controller.errorItem.title == "Falha ao parar" && controller.errorItem.menu === controller.menu,
               "erro local de toggle sobrevive a poll saudavel")

        controller.absorb(poll: (.stopped, "CLI retornou detalhe"))
        expect(controller.errorItem.title == "CLI retornou detalhe",
               "poll com detalhe proprio substitui erro local")

        controller.finish(result: CLIRunResult(exitCode: 0, spawned: true), poll: (.running, nil))
        expect(controller.errorItem.menu == nil && controller.menu.numberOfItems == initialCount,
               "operacao bem-sucedida remove erro anterior")

        controller.absorb(poll: (.notInstalled, "CLI indisponivel"))
        expect(controller.errorItem.title == "CLI indisponivel" && controller.errorItem.menu === controller.menu,
               "polling com falha exibe erro")

        controller.absorb(poll: (.running, nil))
        expect(controller.errorItem.menu == nil && controller.menu.numberOfItems == initialCount,
               "recuperacao no polling remove erro")
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
