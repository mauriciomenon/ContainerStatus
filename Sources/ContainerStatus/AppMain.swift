import AppKit
import Foundation
import os
import ServiceManagement

@main
struct AppMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--dump-menu") {
            StatusItemController.dumpMenuAndExit()
        }
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
            let controller = StatusItemController(persistPosition: true)
            app.delegate = controller
            app.run()
        }
    }

    /// Diagnostico read-only das sondas contra as CLIs reais da maquina
    /// (validacao de planta do passo 1 do roadmap); nao altera nada.
    @MainActor
    static func probeRuntimesAndExit() -> Never {
        for probe in RuntimeProbeConfig.standard.map({ RuntimeProbe(config: $0) }) {
            let status = probe.statusWithResult()
            let (runtimeState, path) = (status.state, status.path)
            let label: String
            switch runtimeState {
            case .notInstalled: label = "nao instalado"
            case .running: label = "ligado"
            case .stopped: label = "desligado"
            }
            var line = "\(probe.label): \(label)\(path.map { " (\($0))" } ?? "")"
            if runtimeState != .notInstalled,
               let tooltip = probe.tooltipInfo(state: runtimeState, statusResult: status.result) {
                line += " [\(tooltip)]"
            }
            print(line)
        }
        let vmnet = VmnetProbe()
        if vmnet.fusionInstalled {
            let (vmnetState, vmCount) = vmnet.currentStatus()
            let text = vmnetState == .running ? "ativo" : "parado"
            let elevation = VmnetProbe.isRootOwned(vmnet.vmnetCliPath) ? "elevacao permitida" : "elevacao recusada"
            print("VMware vmnet: \(text)\(vmCount > 0 ? " (\(vmCount) VM)" : "") [\(elevation)]")
        } else {
            print("VMware vmnet: Fusion nao instalado")
        }
        // Release do GitHub contra a CLI instalada: o mesmo caminho do menu.
        let fetched = OSAllocatedUnfairLock<UpstreamRelease?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let release = await UpstreamRelease.fetchLatest()
            fetched.withLock { $0 = release }
            done.signal()
        }
        done.wait()
        let cli = ContainerCLI.installed()
        _ = cli.checkStatus()
        let installed = cli.currentVersion()
        if let release = fetched.withLock({ $0 }) {
            let pending = UpstreamRelease.update(release, installed: installed) != nil
            print("apple/container no GitHub: \(release.version) (instalada: \(installed ?? "nenhuma"))"
                  + (pending ? " - atualizacao disponivel" : ""))
        } else {
            print("apple/container no GitHub: consulta falhou")
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
