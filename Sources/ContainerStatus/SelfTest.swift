import Foundation

/// Command-line self-test (`ContainerStatus --selftest`): verifies the pure
/// logic and the process watchdog without touching the real service. Replaces
/// the unit test target, which the Command Line Tools toolchain cannot build
/// with cross-module imports.
enum SelfTest {
    @MainActor
    static func runAndExit(includeUI: Bool = false) -> Never {
        var failures = 0

        func expect(_ condition: Bool, _ label: String) {
            if condition {
                print("ok: \(label)")
            } else {
                failures += 1
                print("FAIL: \(label)")
            }
        }

        // State mapping.
        expect(ServiceState.from(exitCode: 0, timedOut: false) == .running, "exit 0 = running")
        expect(ServiceState.from(exitCode: 1, timedOut: false) == .stopped, "exit 1 = stopped")
        expect(ServiceState.from(exitCode: 2, timedOut: false) == .stopped, "exit 2 = stopped")
        expect(ServiceState.from(exitCode: 127, timedOut: false) == .stopped, "exit 127 = stopped")
        expect(ServiceState.from(exitCode: 0, timedOut: true) == .notInstalled, "timeout = not installed")
        expect(ServiceState.from(exitCode: 1, timedOut: true) == .notInstalled, "timeout beats exit code")

        // Text helpers.
        expect(ContainerCLI.firstLine("a\nb\nc") == "a", "firstLine multiline")
        expect(ContainerCLI.firstLine("") == "", "firstLine empty")
        expect(ContainerCLI.firstLine("unico") == "unico", "firstLine single")

        // Path resolution: found on this machine, newest version wins among
        // candidates, nil when nothing exists.
        expect(ContainerCLI.existingCandidates(inDirectories: ["/no/such/dir"]).isEmpty,
               "diretorio sem CLI = nenhum candidato")
        expect(ContainerCLI.resolveNewest(inDirectories: ["/no/such/dir"]) == nil,
               "nada instalado = nil")

        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs_selftest_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer {
                do {
                    try FileManager.default.removeItem(at: temporary)
                } catch {
                    expect(false, "limpeza dos testes: \(error.localizedDescription)")
                }
            }
            try checkResolution(in: temporary, expect: expect)
        } catch {
            expect(false, "teste de resolucao da CLI: \(error.localizedDescription)")
        }
        expect(ContainerCLI.isVersionNewer("1.4.1", than: "1.3.1"), "1.4.1 > 1.3.1")
        expect(!ContainerCLI.isVersionNewer("1.3.1", than: "1.4.1"), "1.3.1 nao supera 1.4.1")
        expect(ContainerCLI.isVersionNewer("10.0", than: "9.9.9"), "dois digitos: 10.0 > 9.9.9")
        expect(!ContainerCLI.isVersionNewer(nil, than: "1.0.0"), "sem versao perde")
        expect(ContainerCLI.isVersionNewer("1.0.0", than: nil), "com versao vence sem versao")

        // Version parsing (single and double digit groups).
        expect(ContainerCLI.parseVersion("container CLI version 1.3.1 (build: release)") == "1.3.1", "parse 1.3.1")
        expect(ContainerCLI.parseVersion("container CLI version 1.4.1 (build: release)") == "1.4.1", "parse 1.4.1")
        expect(ContainerCLI.parseVersion("container CLI version 10.22.33") == "10.22.33", "parse dois digitos")
        expect(ContainerCLI.parseVersion("sem versao aqui") == nil, "parse de texto sem versao")

        // Spawn plumbing against foreign binaries: exit codes, success flag
        // and the watchdog killing a process that exceeds its budget.
        expect(ContainerCLI.runBinary("/usr/bin/true", arguments: [], timeout: 2).succeeded, "/usr/bin/true = sucesso")
        expect(ContainerCLI.runBinary("/usr/bin/false", arguments: [], timeout: 2).exitCode == 1, "/usr/bin/false = exit 1")
        let hung = ContainerCLI.runBinary("/bin/sleep", arguments: ["5"], timeout: 0.3)
        expect(hung.timedOut && !hung.succeeded, "watchdog mata processo estourado")

        if includeUI {
            StatusItemController.checkMenuErrors(expect: expect)
        }

        if failures == 0 {
            print("SELFTEST OK")
            exit(0)
        }
        print("SELFTEST FAILED (\(failures))")
        exit(1)
    }

    private static func writeCLI(at url: URL, version: String,
                                 versionDelay: TimeInterval = 0, stopDelay: TimeInterval = 0) throws {
        let script = """
        #!/bin/sh
        case "$1" in
          --version)
            printf 'probe\\n' >> "$0.probes"
            printf 'container CLI version \(version)\\n'
            \(versionDelay > 0 ? "/bin/sleep \(versionDelay)" : ":")
            ;;
          system)
            if [ "$2" = stop ]; then /bin/sleep \(stopDelay); fi
            ;;
        esac
        """
        try script.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func probeCount(for url: URL) throws -> Int {
        try String(contentsOfFile: url.path + ".probes", encoding: .utf8).split(separator: "\n").count
    }

    private static func checkResolution(in temporary: URL, expect: (Bool, String) -> Void) throws {
        let oldDirectory = temporary.appendingPathComponent("old", isDirectory: true)
        let newDirectory = temporary.appendingPathComponent("new", isDirectory: true)
        let linkDirectory = temporary.appendingPathComponent("link", isDirectory: true)
        for directory in [oldDirectory, newDirectory, linkDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let oldCLI = oldDirectory.appendingPathComponent("container")
        let newCLI = newDirectory.appendingPathComponent("container")
        let linkCLI = linkDirectory.appendingPathComponent("container")
        try writeCLI(at: oldCLI, version: "1.0.0")
        try writeCLI(at: newCLI, version: "2.0.0")

        let cli = ContainerCLI(directories: [oldDirectory.path, newDirectory.path])
        expect(cli.checkStatus().state == .running, "CLI simulada responde status")
        expect(cli.currentBinaryPath() == newCLI.path && cli.currentVersion() == "2.0.0",
               "a CLI mais nova vence entre candidatos")
        for _ in 0..<3 { _ = cli.checkStatus() }
        let oldProbes = try probeCount(for: oldCLI)
        let newProbes = try probeCount(for: newCLI)
        expect(oldProbes == 1 && newProbes == 1, "cache evita probes repetidos durante polling")

        try writeCLI(at: newCLI, version: "3.0.0")
        _ = cli.checkStatus()
        expect(cli.currentBinaryPath() == newCLI.path && cli.currentVersion() == "3.0.0",
               "upgrade no mesmo caminho e tamanho atualiza versao")
        try writeCLI(at: oldCLI, version: "4.0.0")
        _ = cli.checkStatus()
        expect(cli.currentBinaryPath() == oldCLI.path && cli.currentVersion() == "4.0.0",
               "upgrade de outro candidato atualiza selecao")

        try FileManager.default.createSymbolicLink(at: linkCLI, withDestinationURL: newCLI)
        let linked = ContainerCLI(directories: [linkDirectory.path])
        _ = linked.checkStatus()
        expect(linked.currentBinaryPath() == linkCLI.path && linked.currentVersion() == "3.0.0",
               "resolucao aceita symlink")
        try FileManager.default.removeItem(at: linkCLI)
        try FileManager.default.createSymbolicLink(at: linkCLI, withDestinationURL: oldCLI)
        _ = linked.checkStatus()
        expect(linked.currentBinaryPath() == linkCLI.path && linked.currentVersion() == "4.0.0",
               "troca do destino do symlink invalida cache")
        expect(linked.resolvedPathInfo()?.contains(oldCLI.resolvingSymlinksInPath().path) == true,
               "informacao do caminho acompanha symlink")
        try writeCLI(at: oldCLI, version: "5.0.0")
        _ = linked.checkStatus()
        expect(linked.currentVersion() == "5.0.0", "upgrade do destino do symlink invalida cache")

        let concurrent = ContainerCLI(directories: [newDirectory.path])
        _ = concurrent.checkStatus()
        let beforeSlowProbe = try probeCount(for: newCLI)
        try writeCLI(at: newCLI, version: "6.0.0", versionDelay: 1)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = concurrent.checkStatus()
            completed.signal()
        }
        let deadline = Date().addingTimeInterval(2)
        while try probeCount(for: newCLI) == beforeSlowProbe && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        expect(try probeCount(for: newCLI) > beforeSlowProbe, "probe concorrente iniciou")
        try writeCLI(at: newCLI, version: "7.0.0")
        _ = concurrent.checkStatus()
        expect(completed.wait(timeout: .now() + 3) == .success, "resolucao concorrente terminou")
        expect(concurrent.currentVersion() == "7.0.0", "probe antigo nao sobrescreve resolucao recente")

        try FileManager.default.removeItem(at: oldCLI)
        _ = cli.checkStatus()
        expect(cli.currentBinaryPath() == newCLI.path, "remocao seleciona candidato restante")
        try FileManager.default.removeItem(at: newCLI)
        expect(cli.checkStatus().state == .notInstalled && cli.currentVersion() == nil,
               "remocao de todos os candidatos limpa versao")

        try writeCLI(at: newCLI, version: "7.0.0", stopDelay: 11)
        let simulated = ContainerCLI(binaryPath: newCLI.path, directories: [])
        let started = Date()
        let stopped = simulated.stop()
        expect(stopped.succeeded && Date().timeIntervalSince(started) >= 10,
               "parada simulada superior a 10s conclui sem watchdog")

        // Contagem de containers rodando (ls --format json): parse do array,
        // vazio = 0, falha = nil.
        let countDirectory = temporary.appendingPathComponent("count", isDirectory: true)
        try FileManager.default.createDirectory(at: countDirectory, withIntermediateDirectories: false)
        func writeContainerStub(_ stdout: String, exitCode: Int) throws {
            let script = """
            #!/bin/sh
            if [ "$1" = "ls" ] && [ "$2" = "--format" ]; then
              cat <<'EOF'
            \(stdout)
            EOF
              exit \(exitCode)
            fi
            exit 0
            """
            let path = countDirectory.appendingPathComponent("container").path
            try script.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        let countingCLI = ContainerCLI(directories: [countDirectory.path])
        try writeContainerStub("[{\"id\":\"a\",\"configuration\":{\"resources\":{\"memoryInBytes\":2147483648}}},{\"id\":\"b\"}]", exitCode: 0)
        expect(countingCLI.containerCount() == 2, "ls com dois containers = 2")
        let summary = countingCLI.runningContainers() ?? []
        expect(summary.count == 2 && summary[0].id == "a"
               && summary[0].memoryBytes == 2_147_483_648
               && summary[1].id == "b" && summary[1].memoryBytes == nil,
               "ls parseia id e memoria por container")
        try writeContainerStub("[]", exitCode: 0)
        expect(countingCLI.containerCount() == 0, "ls vazio = 0")
        try writeContainerStub("erro", exitCode: 1)
        expect(countingCLI.containerCount() == nil, "ls falho = nil")

        try checkColima(in: temporary, expect: expect)
        try checkRuntimeRecipes(in: temporary, expect: expect)
        try checkVmnet(in: temporary, expect: expect)
    }

    /// Sonda vmnet com Fusion e pgrep simulados; script de subida com escape
    /// de caminho com espaco ("VMware Fusion.app").
    private static func checkVmnet(in temporary: URL, expect: (Bool, String) -> Void) throws {
        expect(VmnetProbe(fusionAppPath: "/no/such/Fusion.app").currentStatus().state == .notInstalled,
               "sem Fusion = secao vmnet escondida")

        let fusion = temporary.appendingPathComponent("VMware Fusion.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fusion.appendingPathComponent("Contents/Library"),
            withIntermediateDirectories: true)
        let vmnetCli = fusion.appendingPathComponent("Contents/Library/vmnet-cli")
        try "#!/bin/sh\nexit 0".write(toFile: vmnetCli.path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vmnetCli.path)

        let pgrepDirectory = temporary.appendingPathComponent("pgrep-running", isDirectory: true)
        try FileManager.default.createDirectory(at: pgrepDirectory, withIntermediateDirectories: false)
        let pgrep = pgrepDirectory.appendingPathComponent("pgrep")
        try "#!/bin/sh\necho 101\necho 102\nexit 0".write(toFile: pgrep.path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pgrep.path)
        let running = VmnetProbe(fusionAppPath: fusion.path, pgrepPath: pgrep.path)
        let (state, vmCount) = running.currentStatus()
        expect(state == .running && vmCount == 2,
               "vmnet com daemons = ativo e conta VMs")

        let pgrepIdleDirectory = temporary.appendingPathComponent("pgrep-idle", isDirectory: true)
        try FileManager.default.createDirectory(at: pgrepIdleDirectory, withIntermediateDirectories: false)
        let pgrepIdle = pgrepIdleDirectory.appendingPathComponent("pgrep")
        try "#!/bin/sh\nexit 1".write(toFile: pgrepIdle.path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pgrepIdle.path)
        let stopped = VmnetProbe(fusionAppPath: fusion.path, pgrepPath: pgrepIdle.path)
        expect(stopped.currentStatus().state == .stopped,
               "vmnet sem daemon = parado")

        let script = running.startScript()
        expect(script.contains("vmnet-cli") && script.contains("with administrator privileges")
               && script.contains("--start") && !script.contains("--stop \""),
               "script de subida pede admin e so sobe")
    }

    /// Receitas dos demais runtimes do roadmap, com binarios simulados que
    /// reproduzem a saida real de cada CLI (docker info, podman machine
    /// list, lume ls, orbctl status).
    private static func checkRuntimeRecipes(in temporary: URL, expect: (Bool, String) -> Void) throws {
        func stub(_ name: String, _ directory: URL, stdout: String, exitCode: Int) throws -> String {
            let path = directory.appendingPathComponent(name).path
            let script = """
            #!/bin/sh
            cat <<'EOF'
            \(stdout)
            EOF
            exit \(exitCode)
            """
            try script.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        func bare(_ name: String, _ directory: URL, exitCode: Int) throws -> String {
            let path = directory.appendingPathComponent(name).path
            let script = "#!/bin/sh\nexit \(exitCode)\n"
            try script.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }

        // Docker: exit 0 = daemon responde; erro = CLI sem daemon.
        let dockerDirectory = temporary.appendingPathComponent("docker", isDirectory: true)
        try FileManager.default.createDirectory(at: dockerDirectory, withIntermediateDirectories: false)
        _ = try bare("docker", dockerDirectory, exitCode: 0)
        expect(RuntimeProbe(config: .docker, directories: [dockerDirectory.path])
            .currentStatus().state == .running, "docker com daemon = ligado")
        _ = try bare("docker", dockerDirectory, exitCode: 1)
        expect(RuntimeProbe(config: .docker, directories: [dockerDirectory.path])
            .currentStatus().state == .stopped, "docker sem daemon = desligado")

        // Informacao de planta (passo 3 parcial): contexto do docker via
        // sonda read-only; falha de comando = nil.
        _ = try stub("docker", dockerDirectory, stdout: "orbstack", exitCode: 0)
        expect(RuntimeProbe(config: .docker, directories: [dockerDirectory.path])
            .currentInfo() == "contexto: orbstack",
               "sonda informativa le o contexto do docker")
        _ = try bare("docker", dockerDirectory, exitCode: 1)
        expect(RuntimeProbe(config: .docker, directories: [dockerDirectory.path])
            .currentInfo() == nil,
               "sonda informativa falha sem exit 0")

        // Podman: JSON de machine list com maquina Running.
        let podmanDirectory = temporary.appendingPathComponent("podman", isDirectory: true)
        try FileManager.default.createDirectory(at: podmanDirectory, withIntermediateDirectories: false)
        _ = try stub("podman", podmanDirectory,
                 stdout: "[{\"Name\":\"pm\",\"State\":\"Running\"}]", exitCode: 0)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path])
            .currentStatus().state == .running, "podman com maquina running = ligado")
        _ = try stub("podman", podmanDirectory, stdout: "[]", exitCode: 0)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path])
            .currentStatus().state == .stopped, "podman sem maquina = desligado")

        // Lume: JSON de ls com VM running (exit 0 mesmo sem VMs).
        let lumeDirectory = temporary.appendingPathComponent("lume", isDirectory: true)
        try FileManager.default.createDirectory(at: lumeDirectory, withIntermediateDirectories: false)
        _ = try stub("lume", lumeDirectory,
                 stdout: "[{\"name\":\"macos\",\"status\":\"running\"}]", exitCode: 0)
        expect(RuntimeProbe(config: .lume, directories: [lumeDirectory.path])
            .currentStatus().state == .running, "lume com VM running = ligado")
        _ = try stub("lume", lumeDirectory, stdout: "[\n\n]", exitCode: 0)
        expect(RuntimeProbe(config: .lume, directories: [lumeDirectory.path])
            .currentStatus().state == .stopped, "lume sem VMs = desligado")

        // Auto-start (passo 3): LaunchAgent presente marca o runtime; ausente
        // = nil. Diretorio injetavel para teste deterministico.
        let agentsDirectory = temporary.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: false)
        try "dict".write(toFile: agentsDirectory.appendingPathComponent("homebrew.mxcl.lume.plist").path,
                         atomically: true, encoding: .utf8)
        let lumeProbe = RuntimeProbe(config: .lume, directories: [lumeDirectory.path],
                                     launchAgentsDirectories: [agentsDirectory.path])
        expect(lumeProbe.autoStartLabel() == "homebrew.mxcl.lume",
               "auto-start do lume aparece pelo LaunchAgent")
        let colimaProbe = RuntimeProbe(config: .colima, directories: [],
                                       launchAgentsDirectories: [agentsDirectory.path])
        expect(colimaProbe.autoStartLabel() == nil,
               "runtime sem LaunchAgent nao marca auto-start")

        // Contagem por runtime (ps -q = uma linha por container): docker com
        // receita de contagem; colima sem receita nunca conta.
        let dockerCountProbe = RuntimeProbe(config: .docker, directories: [dockerDirectory.path])
        _ = try stub("docker", dockerDirectory, stdout: "id1\nid2\nid3", exitCode: 0)
        expect(dockerCountProbe.runningCount() == 3,
               "docker ps -q com tres ids = 3 containers")
        _ = try stub("docker", dockerDirectory, stdout: "", exitCode: 0)
        expect(dockerCountProbe.runningCount() == 0,
               "docker ps -q vazio = 0 containers")
        _ = try bare("docker", dockerDirectory, exitCode: 1)
        expect(dockerCountProbe.runningCount() == nil,
               "docker ps falho = nil")
        let noCountProbe = RuntimeProbe(config: .colima, directories: [lumeDirectory.path])
        expect(noCountProbe.runningCount() == nil,
               "runtime sem receita de contagem nao conta")

        // OrbStack: orbctl status "Running" exit 0; erro = parado.
        let orbstackDirectory = temporary.appendingPathComponent("orbstack", isDirectory: true)
        try FileManager.default.createDirectory(at: orbstackDirectory, withIntermediateDirectories: false)
        _ = try stub("orbctl", orbstackDirectory, stdout: "Running", exitCode: 0)
        expect(RuntimeProbe(config: .orbstack, directories: [orbstackDirectory.path])
            .currentStatus().state == .running, "orbstack running = ligado")
        _ = try bare("orbctl", orbstackDirectory, exitCode: 1)
        expect(RuntimeProbe(config: .orbstack, directories: [orbstackDirectory.path])
            .currentStatus().state == .stopped, "orbstack parado = desligado")
    }

    /// Sonda read-only de runtime com binarios simulados (passo 1 do roadmap).
    private static func writeColima(at url: URL, exitCode: Int, delay: TimeInterval = 0) throws {
        let script = """
        #!/bin/sh
        if [ "$1" = status ]; then
          \(delay > 0 ? "/bin/sleep \(delay)" : ":")
          exit \(exitCode)
        fi
        exit 0
        """
        try script.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func checkColima(in temporary: URL, expect: (Bool, String) -> Void) throws {
        let runningDirectory = temporary.appendingPathComponent("colima-running", isDirectory: true)
        let stoppedDirectory = temporary.appendingPathComponent("colima-stopped", isDirectory: true)
        for directory in [runningDirectory, stoppedDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try writeColima(at: runningDirectory.appendingPathComponent("colima"), exitCode: 0)
        try writeColima(at: stoppedDirectory.appendingPathComponent("colima"), exitCode: 1)

        let missing = RuntimeProbe(config: .colima, directories: ["/no/such/dir"])
        expect(missing.currentStatus().state == .notInstalled,
               "colima ausente = nao instalado")
        expect(RuntimeProbe(config: .colima, directories: [runningDirectory.path])
            .currentStatus().state == .running, "colima simulado ativo = ligado")
        expect(RuntimeProbe(config: .colima, directories: [stoppedDirectory.path])
            .currentStatus().state == .stopped, "colima simulado parado = desligado")
        try writeColima(at: runningDirectory.appendingPathComponent("colima"), exitCode: 0, delay: 5)
        expect(RuntimeProbe(config: .colima, directories: [runningDirectory.path])
            .currentStatus().state == .stopped, "colima travado cai no watchdog e mostra desligado")
        try writeColima(at: runningDirectory.appendingPathComponent("colima"), exitCode: 0)
        expect(RuntimeProbe(config: .colima, directories: [stoppedDirectory.path]).resolvedPath() != nil,
               "caminho do colima acompanha candidato")

        // Controle (passo 2): start/stop da sonda mutam o estado simulado e o
        // status acompanha. Deterministico, sem UI.
        let controllable = RuntimeProbe(config: .colima, directories: [stoppedDirectory.path])
        try writeColima(at: stoppedDirectory.appendingPathComponent("colima"), exitCode: 1)
        let controlScript = """
        #!/bin/sh
        case "$1" in
          start) touch "$0.state"; exit 0 ;;
          stop) rm -f "$0.state"; exit 0 ;;
          status) [ -f "$0.state" ] && exit 0 || exit 1 ;;
        esac
        """
        let controlPath = stoppedDirectory.appendingPathComponent("colima").path
        try controlScript.write(toFile: controlPath, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: controlPath)
        expect(controllable.isControllable, "receita de controle habilita toggle")
        expect(controllable.currentStatus().state == .stopped, "antes do start = desligado")
        expect(controllable.start().succeeded, "start do runtime tem exit 0")
        expect(controllable.currentStatus().state == .running, "apos start = ligado")
        expect(controllable.stop().succeeded, "stop do runtime tem exit 0")
        expect(controllable.currentStatus().state == .stopped, "apos stop = desligado")

        // Sem receita (docker read-only): start/stop nao executam nada.
        let readOnly = RuntimeProbe(config: .docker, directories: [stoppedDirectory.path])
        expect(!readOnly.isControllable, "docker read-only nao tem controle")
        expect(!readOnly.start().succeeded, "start de runtime read-only nao executa")
    }
}
