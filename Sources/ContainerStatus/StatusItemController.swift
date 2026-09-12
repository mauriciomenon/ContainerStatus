import AppKit
import ServiceManagement

/// Owns the status bar item, the menu, and the idle/starting/stopping state
/// machine. All mutable state is main-actor; the CLI runs on background
/// queues and results hop back to the main actor.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let projectURL = URL(string: "https://github.com/apple/container")!
    private static let projectLinkText = "github.com/apple/container"

    private let cli = ContainerCLI()
    private let item = NSStatusBar.system.statusItem(withLength: 20)
    private let menu = NSMenu()
    private let pollQueue = DispatchQueue(label: "local.menon.containerstatus.poll", qos: .utility)

    private var state: ServiceState = .stopped
    private var detail: String?
    private var activity: ServiceActivity = .none
    private var cliVersion: String?
    private var cliVersionPath: String?
    private var pollTimer: DispatchSourceTimer?

    // Menu items, kept as references so state changes mutate them in place.
    private let headerItem = NSMenuItem()
    private let statusLineItem = NSMenuItem()
    private let actionItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let quitItem = NSMenuItem()
    private let quitRow = NSStackView()
    private let quitButton = NSButton()
    private let linkButton = NSButton()

    // MARK: Lifecycle

    override init() {
        super.init()
        buildMenu()
        item.menu = menu
        item.button?.image = Self.dotImage(state: state, dimmed: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startPolling()
        refreshNow()
        fetchVersionInBackground()
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
        loginItem.title = "Abrir no login"
        loginItem.target = self
        loginItem.action = #selector(toggleLogin(_:))

        quitButton.title = "Sair"
        quitButton.isBordered = false
        quitButton.font = .menuFont(ofSize: 0)
        quitButton.target = self
        quitButton.action = #selector(quitApp)

        linkButton.title = "link"
        linkButton.isBordered = false
        linkButton.font = .menuFont(ofSize: 10)
        linkButton.contentTintColor = .linkColor
        linkButton.target = self
        linkButton.action = #selector(openProjectPage)

        quitRow.orientation = .horizontal
        quitRow.alignment = .centerY
        quitRow.spacing = 8
        quitRow.edgeInsets = NSEdgeInsets(top: 3, left: 14, bottom: 3, right: 12)
        quitRow.addView(quitButton, in: .leading)
        quitRow.addView(linkButton, in: .trailing)
        quitRow.setFrameSize(NSSize(width: 240, height: 24))
        quitItem.view = quitRow

        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(headerItem)
        menu.addItem(statusLineItem)
        menu.addItem(actionItem)
        if let detail, !detail.isEmpty {
            errorItem.title = detail
            menu.addItem(errorItem)
        }
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        apply()
    }

    /// Refreshes menu text and the status icon from the current state.
    private func apply() {
        item.button?.image = Self.dotImage(state: state, dimmed: activity != .none)

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

        loginItem.state = Self.loginServiceEnabled ? .on : .off
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

    /// Applies a poll result. Polls never overwrite a toggle in flight;
    /// only the toggle completion advances out of the transitioning state.
    private func absorb(poll: (state: ServiceState, detail: String?)) {
        if activity == .none {
            state = poll.state
            detail = poll.detail
        }
        // Refresh the header version whenever the resolved CLI changes
        // (first find, install, upgrade or removal).
        let currentPath = cli.currentBinaryPath()
        if currentPath != cliVersionPath {
            if currentPath != nil {
                fetchVersionInBackground()
            } else {
                cliVersion = nil
                cliVersionPath = nil
            }
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
        refreshNow()
        if activity == .none { apply() }
    }

    private func fetchVersionInBackground() {
        let cli = self.cli
        Task.detached(priority: .utility) {
            let version = cli.fetchVersion()
            await MainActor.run { [weak self] in
                self?.cliVersion = version
                self?.cliVersionPath = cli.currentBinaryPath()
                self?.apply()
            }
        }
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
        detail = result.succeeded ? poll.detail : (ContainerCLI.firstLine(result.stderr).isEmpty ? "Operacao falhou" : ContainerCLI.firstLine(result.stderr))
        apply()
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
        }
        apply()
    }

    @objc private func openProjectPage() {
        menu.cancelTracking()
        NSWorkspace.shared.open(Self.projectURL)
    }

    @objc private func quitApp() {
        menu.cancelTracking()
        NSApp.terminate(nil)
    }

    // MARK: Icon

    /// Draws the status dot: filled green/red, hollow gray when the CLI is
    /// unavailable, dimmed while a toggle is in flight. The image is compact
    /// (16 px) inside a narrow status item so it takes little menu bar width,
    /// while the dot itself stays large and readable.
    private static func dotImage(state: ServiceState, dimmed: Bool) -> NSImage {
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
}
