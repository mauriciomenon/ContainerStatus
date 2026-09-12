import AppKit
import ServiceManagement

/// Owns the status bar item, the menu, and the idle/starting/stopping state
/// machine. All mutable state is main-actor; the CLI runs on background
/// queues and results hop back to the main actor.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let cli = ContainerCLI()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let pollQueue = DispatchQueue(label: "local.menon.containerstatus.poll", qos: .utility)

    private var state: ServiceState = .stopped
    private var detail: String?
    private var activity: ServiceActivity = .none
    private var pollTimer: DispatchSourceTimer?

    // Menu items, kept as references so state changes mutate them in place.
    private let headerItem = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    // MARK: Lifecycle

    override init() {
        super.init()
        buildMenu()
        item.menu = menu
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
        toggleItem.target = self
        toggleItem.action = #selector(toggleService(_:))
        errorItem.isEnabled = false
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
        menu.addItem(toggleItem)
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
        let icon = Self.dotImage(state: state, dimmed: activity != .none)
        item.button?.image = icon

        let busy = activity != .none
        switch activity {
        case .starting:
            item.button?.toolTip = "Apple Container: iniciando..."
        case .stopping:
            item.button?.toolTip = "Apple Container: parando..."
        case .none:
            switch state {
            case .running: item.button?.toolTip = "Apple Container: ligado"
            case .stopped: item.button?.toolTip = "Apple Container: desligado"
            case .notInstalled: item.button?.toolTip = "Apple Container: CLI indisponivel"
            }
        }

        if busy {
            headerItem.title = "Apple Container - alternando..."
            toggleItem.title = "Alternando..."
            toggleItem.state = .off
            toggleItem.isEnabled = false
        } else {
            switch state {
            case .running:
                headerItem.title = "Apple Container - ligado"
                toggleItem.title = "Servico ligado"
                toggleItem.state = .on
                toggleItem.isEnabled = true
            case .stopped:
                headerItem.title = "Apple Container - desligado"
                toggleItem.title = "Servico desligado"
                toggleItem.state = .off
                toggleItem.isEnabled = true
            case .notInstalled:
                headerItem.title = "Apple Container - indisponivel"
                toggleItem.title = "Servico indisponivel"
                toggleItem.state = .off
                toggleItem.isEnabled = false
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
        guard activity == .none else { return }
        state = poll.state
        detail = poll.detail
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

    // MARK: Toggle

    @objc private func toggleService(_ sender: NSMenuItem) {
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

    // MARK: Icon

    /// Draws the status dot: filled green/red, hollow gray when the CLI is
    /// unavailable, dimmed while a toggle is in flight.
    private static func dotImage(state: ServiceState, dimmed: Bool) -> NSImage {
        let side: CGFloat = 18
        let alpha: CGFloat = dimmed ? 0.45 : 1.0
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6))
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
