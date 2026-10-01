import AppKit
import Foundation

@main
struct AppMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--probe-runtimes") {
            Self.probeRuntimesAndExit()
        }
        let includeUI = CommandLine.arguments.contains("--selftest-ui")
        if includeUI || CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit(includeUI: includeUI)
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let controller = StatusItemController()
            app.delegate = controller
            app.run()
        }
    }

    /// Diagnostico read-only das sondas contra as CLIs reais da maquina
    /// (validacao de planta do passo 1 do roadmap); nao altera nada.
    @MainActor
    static func probeRuntimesAndExit() -> Never {
        for probe in RuntimeProbeConfig.standard.map({ RuntimeProbe(config: $0) }) {
            let (runtimeState, path) = probe.currentStatus()
            let label: String
            switch runtimeState {
            case .notInstalled: label = "nao instalado"
            case .running: label = "ligado"
            case .stopped: label = "desligado"
            }
            var line = "\(probe.label): \(label)\(path.map { " (\($0))" } ?? "")"
            if runtimeState != .notInstalled, let info = probe.currentInfo() {
                line += " [\(info)]"
            }
            print(line)
        }
        exit(0)
    }
}
