import AppKit
import Foundation
import ServiceManagement

@main
struct AppMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--probe-runtimes") {
            Self.probeRuntimesAndExit()
        }
        if CommandLine.arguments.contains("--unregister-login") {
            // Manutencao: remove o registro de login DESTE bundle (identidade
            // do proprio app). Serve para limpar cadaveres do BTM: reencarne
            // o bundle antigo no caminho memorizado e rode esta flag.
            exit(Self.setLogin(register: false))
        }
        if CommandLine.arguments.contains("--register-login") {
            exit(Self.setLogin(register: true))
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
            if runtimeState != .notInstalled, let tooltip = probe.tooltipInfo(state: runtimeState) {
                line += " [\(tooltip)]"
            }
            print(line)
        }
        let vmnet = VmnetProbe()
        if vmnet.fusionInstalled {
            let (vmnetState, vmCount) = vmnet.currentStatus()
            let text = vmnetState == .running ? "ativo" : "parado"
            print("VMware vmnet: \(text)\(vmCount > 0 ? " (\(vmCount) VM)" : "")")
        } else {
            print("VMware vmnet: Fusion nao instalado")
        }
        exit(0)
    }

    /// Registro/desregistro do login item DESTE bundle, para manutencao.
    /// Retorna codigo de saida: 0 ok, 1 falhou, 2 exige aprovacao do usuario.
    @MainActor
    static func setLogin(register: Bool) -> Int32 {
        let service = SMAppService.mainApp
        do {
            if register {
                try service.register()
            } else {
                try service.unregister()
            }
            print("ok: status agora e \(describeLogin(service.status))")
            return 0
        } catch {
            print("falha (\(register ? "registrar" : "desregistrar")): \(error.localizedDescription)")
            return 1
        }
    }

    private static func describeLogin(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "habilitado"
        case .requiresApproval: return "exige aprovacao no painel"
        case .notRegistered: return "nao registrado"
        case .notFound: return "nao encontrado"
        @unknown default: return "desconhecido (\(status.rawValue))"
        }
    }
}
