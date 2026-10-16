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

        // Release do GitHub: parse do JSON da API e comparacao com a instalada.
        func release(_ json: String) -> UpstreamRelease? { UpstreamRelease.parse(Data(json.utf8)) }
        let link = "https://github.com/apple/container/releases/tag/1.6.0"
        expect(release("{\"tag_name\":\"1.6.0\",\"html_url\":\"\(link)\"}")?.version == "1.6.0",
               "release do GitHub: tag numerica")
        expect(release("{\"tag_name\":\"v1.6.0\",\"html_url\":\"\(link)\"}")?.version == "1.6.0",
               "release do GitHub: prefixo v removido")
        expect(release("{\"tag_name\":\"1.6.0-rc1\",\"html_url\":\"\(link)\"}") == nil,
               "release do GitHub: tag nao numerica ignorada")
        expect(release("{\"tag_name\":\"1.6.0\",\"html_url\":\"https://evil.example/x\"}") == nil,
               "release do GitHub: link fora de github.com ignorado")
        expect(release("{\"message\":\"API rate limit exceeded\"}") == nil && release("lixo") == nil,
               "release do GitHub: resposta de erro = nil")
        let latest = release("{\"tag_name\":\"1.6.0\",\"html_url\":\"\(link)\"}")
        expect(UpstreamRelease.update(latest, installed: "1.5.0") == latest,
               "release mais nova que a instalada = aviso")
        expect(UpstreamRelease.update(latest, installed: "1.6.0") == nil
               && UpstreamRelease.update(latest, installed: "1.10.0") == nil,
               "instalada igual ou mais nova = sem aviso")
        expect(UpstreamRelease.update(latest, installed: nil) == nil,
               "sem CLI instalada = sem aviso de atualizacao")

        // Spawn plumbing against foreign binaries: exit codes, success flag
        // and the watchdog killing a process that exceeds its budget.
        expect(ContainerCLI.runBinary("/usr/bin/true", arguments: [], timeout: 2).succeeded, "/usr/bin/true = sucesso")
        expect(ContainerCLI.runBinary("/usr/bin/false", arguments: [], timeout: 2).exitCode == 1, "/usr/bin/false = exit 1")
        let hung = ContainerCLI.runBinary("/bin/sleep", arguments: ["5"], timeout: 0.3)
        expect(hung.timedOut && !hung.succeeded, "watchdog mata processo estourado")
        let stubborn = ContainerCLI.runBinary("/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"],
                                              timeout: 0.3)
        expect(stubborn.timedOut && !stubborn.succeeded && stubborn.exitCode == SIGKILL,
               "filho que ignora SIGTERM morre de fato pelo SIGKILL")
        // Neto segurando o pipe: retorna no teto de IO sem prender threads e
        // sem perder o exit do filho; a saida e dada como indisponivel.
        let heldStart = Date()
        let held = ContainerCLI.runBinary("/bin/sh", arguments: ["-c", "/bin/sleep 4 & echo ok"], timeout: 2)
        expect(!held.timedOut && held.exitCode == 0 && held.stderr.contains("pipe mantido aberto")
               && Date().timeIntervalSince(heldStart) < 3.5,
               "neto segurando o pipe nao trava a chamada")
        expect(held.exitedCleanly && !held.succeeded,
               "pipe preso: exit vale para mutacao, stdout nao vale para parser")
        let flood = ContainerCLI.runBinary("/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' y"],
                                           timeout: 5)
        expect(!flood.succeeded && flood.truncated && flood.stdout.utf8.count == 1 << 20,
               "saida acima de 1MB e truncada e nao conta como sucesso")
        // Corte no meio de um caractere UTF-8 (offset impar com 'e' agudo de 2 bytes).
        let accented = ContainerCLI.runBinary(
            "/bin/sh", arguments: ["-c", "printf x; yes \"$(printf '\\303\\251')\" | tr -d '\\n' | head -c 1100000"],
            timeout: 5)
        expect(accented.truncated && accented.stdout.hasPrefix("x\u{00E9}"),
               "corte no meio de um caractere UTF-8 nao descarta a saida")
        // Neto segurando o pipe repetidas vezes: descritores nao vazam (com os
        // leitores bloqueantes antigos, cada chamada deixava dois abertos).
        func openDescriptors() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }
        // autoreleasepool: o selftest roda sem run loop, e os FileHandle so
        // morrem quando o pool drena (no app o run loop drena a cada evento).
        let descriptorsBefore = openDescriptors()
        for _ in 0..<3 {
            autoreleasepool {
                _ = ContainerCLI.runBinary("/bin/sh", arguments: ["-c", "/bin/sleep 20 & echo ok"], timeout: 2)
            }
        }
        let descriptorsAfter = openDescriptors()
        expect(descriptorsAfter <= descriptorsBefore,
               "neto segurando o pipe nao vaza descritores (\(descriptorsBefore) -> \(descriptorsAfter))")
        // stderr acima do buffer do pipe (64KB) com stdout ainda aberto: com
        // leitura serial o filho travava no write ate o watchdog.
        let noisy = ContainerCLI.runBinary("/bin/sh",
                                           arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo ok"],
                                           timeout: 3)
        expect(noisy.succeeded && noisy.stdout == "ok" && noisy.stderr.count == 200_000,
               "stderr grande nao trava a leitura do stdout")

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

    private static func probeCount(for url: URL, suffix: String = ".probes") throws -> Int {
        try String(contentsOfFile: url.path + suffix, encoding: .utf8).split(separator: "\n").count
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

        // Upgrade cuja primeira consulta de versao falha (binario novo lento
        // na primeira execucao): o poll seguinte tem de consultar de novo,
        // senao o app fica preso no binario e na versao antigos.
        let flakyDirectory = temporary.appendingPathComponent("flaky", isDirectory: true)
        try FileManager.default.createDirectory(at: flakyDirectory, withIntermediateDirectories: false)
        let flakyOld = flakyDirectory.appendingPathComponent("old/container")
        let flakyNew = flakyDirectory.appendingPathComponent("new/container")
        for url in [flakyOld, flakyNew] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: false)
        }
        try writeCLI(at: flakyOld, version: "1.0.0")
        let flakyScript = """
        #!/bin/sh
        if [ "$1" = --version ]; then
          if [ -f "$0.ready" ]; then printf 'container CLI version 9.0.0\\n'; else touch "$0.ready"; exit 1; fi
        fi
        """
        try flakyScript.write(to: flakyNew, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flakyNew.path)
        let flaky = ContainerCLI(directories: [flakyOld.deletingLastPathComponent().path,
                                               flakyNew.deletingLastPathComponent().path])
        _ = flaky.checkStatus()
        expect(flaky.currentVersion() == "1.0.0", "probe falho do candidato novo cai no antigo")
        _ = flaky.checkStatus()
        expect(flaky.currentBinaryPath() == flakyNew.path && flaky.currentVersion() == "9.0.0",
               "probe falho e repetido no poll seguinte e o upgrade aparece")
        _ = flaky.checkStatus()
        expect(try probeCount(for: flakyOld) == 2,
               "com todos os probes ok o cache volta a valer")

        // Binario plantado em prefixo do usuario: so vale sem CLI do sistema,
        // e versao declarada maior nao rouba a selecao.
        let plantedDirectory = temporary.appendingPathComponent("planted", isDirectory: true)
        try FileManager.default.createDirectory(at: plantedDirectory, withIntermediateDirectories: false)
        try writeCLI(at: plantedDirectory.appendingPathComponent("container"), version: "99.0.0")
        let guarded = ContainerCLI(directories: [newDirectory.path],
                                   fallbackDirectories: [plantedDirectory.path])
        _ = guarded.checkStatus()
        expect(guarded.currentBinaryPath() == newCLI.path,
               "CLI do sistema vence binario de prefixo do usuario com versao maior")
        let onlyFallback = ContainerCLI(directories: ["/no/such/dir"],
                                        fallbackDirectories: [plantedDirectory.path])
        _ = onlyFallback.checkStatus()
        expect(onlyFallback.currentVersion() == "99.0.0",
               "sem CLI do sistema o prefixo do usuario ainda e encontrado")
        let writableDirectory = temporary.appendingPathComponent("writable", isDirectory: true)
        try FileManager.default.createDirectory(at: writableDirectory, withIntermediateDirectories: false)
        let writable = writableDirectory.appendingPathComponent("container")
        try writeCLI(at: writable, version: "1.0.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writable.path)
        expect(ContainerCLI.existingCandidates(inDirectories: [writableDirectory.path]).isEmpty,
               "binario gravavel por outros usuarios e ignorado")
        expect(!ContainerCLI.fallbackDirectories().contains("/usr/local/bin"),
               "fallback nao repete diretorios do sistema")

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

        // Fallback do start so apos falha explicita: exit 0 com saida acima
        // do teto ja e start feito e nao pode rodar --disable-kernel-install.
        let startDirectory = temporary.appendingPathComponent("start", isDirectory: true)
        try FileManager.default.createDirectory(at: startDirectory, withIntermediateDirectories: false)
        let startCLI = startDirectory.appendingPathComponent("container")
        func writeStartCLI(exitCode: Int) throws {
            let script = """
            #!/bin/sh
            if [ "$1" = system ] && [ "$2" = start ]; then
              printf 's\\n' >> "$0.starts"
              head -c 1200000 /dev/zero | tr '\\0' z
              exit \(exitCode)
            fi
            """
            try script.write(to: startCLI, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: startCLI.path)
            try? FileManager.default.removeItem(atPath: startCLI.path + ".starts")
        }
        try writeStartCLI(exitCode: 0)
        let starter = ContainerCLI(binaryPath: startCLI.path, directories: [])
        let bigStart = starter.start()
        let startsAfterSuccess = try probeCount(for: startCLI, suffix: ".starts")
        expect(bigStart.exitedCleanly && bigStart.truncated && startsAfterSuccess == 1,
               "start com exit 0 e saida truncada nao dispara o fallback")
        try writeStartCLI(exitCode: 1)
        _ = starter.start()
        let startsAfterFailure = try probeCount(for: startCLI, suffix: ".starts")
        expect(startsAfterFailure == 2, "start com exit 1 dispara o fallback")

        // Versao do servico (apiserver) x CLI: tabela de system version.
        let table = """
        COMPONENT            VERSION  BUILD    COMMIT
        container            1.6.0    release  aaa
        container-apiserver  1.5.0    release  bbb
        """
        expect(ContainerCLI.parseServiceVersion(table) == "1.5.0", "parse da versao do apiserver")
        expect(ContainerCLI.parseServiceVersion("COMPONENT  VERSION\ncontainer  1.5.0") == nil,
               "servico parado = sem versao do apiserver")
        let serviceDirectory = temporary.appendingPathComponent("service", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceDirectory, withIntermediateDirectories: false)
        let serviceCLI = serviceDirectory.appendingPathComponent("container")
        func writeServiceCLI(apiserver: String) throws {
            let script = """
            #!/bin/sh
            case "$1" in
              --version) printf 'container CLI version 1.6.0\\n' ;;
              system) [ "$2" = version ] && printf 'COMPONENT VERSION\\ncontainer-apiserver \(apiserver) release x\\n' ;;
            esac
            exit 0
            """
            try script.write(to: serviceCLI, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serviceCLI.path)
        }
        try writeServiceCLI(apiserver: "1.5.0")
        let service = ContainerCLI(directories: [serviceDirectory.path])
        _ = service.checkStatus()
        service.refreshServiceVersion(running: true)
        expect(service.currentServiceVersion() == "1.5.0", "servico antigo de pe apos upgrade da CLI")
        service.refreshServiceVersion(running: false)
        expect(service.currentServiceVersion() == nil, "servico parado limpa a versao")
        // Falha transitoria do system version: tenta de novo apos o intervalo.
        let start = Date()
        try writeServiceCLI(apiserver: "x")
        service.refreshServiceVersion(running: true, now: start)
        expect(service.currentServiceVersion() == nil, "system version sem versao valida = nil")
        try writeServiceCLI(apiserver: "1.5.0")
        service.refreshServiceVersion(running: true, now: start.addingTimeInterval(1))
        expect(service.currentServiceVersion() == nil, "falha recente nao repete a cada poll")
        service.refreshServiceVersion(running: true,
                                      now: start.addingTimeInterval(ContainerCLI.serviceRetryInterval + 1))
        expect(service.currentServiceVersion() == "1.5.0", "falha antiga e consultada de novo")

        // --version com exit != 0 nao conta como versao, mesmo com stdout.
        let failingVersion = serviceDirectory.appendingPathComponent("failing")
        try "#!/bin/sh\nprintf 'container CLI version 9.0.0\\n'\nexit 1\n"
            .write(to: failingVersion, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingVersion.path)
        expect(ContainerCLI.probeVersion(failingVersion.path) == nil, "--version com exit 1 e ignorado")

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
        expect(countingCLI.runningContainers()?.count == 2, "ls com dois containers = 2")
        let summary = countingCLI.runningContainers() ?? []
        expect(summary.count == 2 && summary[0].id == "a"
               && summary[0].memoryBytes == 2_147_483_648
               && summary[1].id == "b" && summary[1].memoryBytes == nil,
               "ls parseia id e memoria por container")
        try writeContainerStub("[{\"id\":\"web\\nStatus: Running\\tx\"}]", exitCode: 0)
        expect(countingCLI.runningContainers()?.first?.id == "web Status: Running x",
               "id com quebra de linha nao forja linhas no menu")
        expect(ContainerCLI.menuSafe(String(repeating: "a", count: 100)).count == 64,
               "id enorme e truncado")
        expect(ContainerCLI.menuSafe("a\u{2028}b\u{2029}c") == "a b c",
               "separadores de linha Unicode tambem viram espaco")
        try writeContainerStub("[]", exitCode: 0)
        expect(countingCLI.runningContainers()?.count == 0, "ls vazio = 0")
        try writeContainerStub("erro", exitCode: 1)
        expect(countingCLI.runningContainers()?.count == nil, "ls falho = nil")

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
               && script.contains("--start")
               && script.contains("/usr/bin/codesign --verify") && script.contains(VmnetProbe.vmwareTeamID),
               "script de subida confere a assinatura VMware como root antes de subir")
        // Verificacao do shell elevado, rodada sem root: stub do usuario cai;
        // o Fusion real (root:wheel, assinado pela VMware) passa.
        let stubCheck = ContainerCLI.runBinary("/bin/sh", arguments: ["-c", running.verificationShell() + "; echo OK"],
                                               timeout: 10)
        expect(!stubCheck.stdout.contains("OK"), "shell elevado recusa vmnet-cli que nao e do root")
        let realCli = "/Applications/VMware Fusion.app/Contents/Library/vmnet-cli"
        if FileManager.default.fileExists(atPath: realCli) {
            let realCheck = ContainerCLI.runBinary("/bin/sh", arguments: ["-c", VmnetProbe().verificationShell() + "; echo OK"],
                                                   timeout: 10)
            expect(realCheck.stdout == "OK", "shell elevado aceita o vmnet-cli real da VMware")
            let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(VmnetProbe.vmwareTeamID)\""
            expect(ContainerCLI.runBinary("/usr/bin/codesign", arguments: ["--verify", "-R=\(requirement)", realCli],
                                          timeout: 10).succeeded,
                   "vmnet-cli instalado passa no requisito de assinatura")
        }
        // Compila sem executar: aspas cruas no literal quebravam a sintaxe.
        let compiled = temporary.appendingPathComponent("vmnet.scpt").path
        expect(ContainerCLI.runBinary("/usr/bin/osacompile", arguments: ["-o", compiled, "-e", script],
                                      timeout: 10).succeeded,
               "script de subida do vmnet compila no AppleScript")
        // Elevacao so com vmnet-cli do root: o stub do usuario e recusado
        // antes de qualquer dialogo de senha.
        let refused = running.start()
        expect(!refused.succeeded && refused.stderr.contains("elevacao recusada"),
               "vmnet-cli do usuario nao e elevado a root")
        expect(VmnetProbe.isRootOwned("/usr/bin/true"), "binario do sistema passa na checagem de dono")
        expect(!VmnetProbe.isRootOwned(vmnetCli.path), "binario do usuario falha na checagem de dono")
        let tricky = VmnetProbe(fusionAppPath: "/tmp/it's \"odd\" \\ $(x).app").startScript()
        expect(ContainerCLI.runBinary("/usr/bin/osacompile", arguments: ["-o", compiled, "-e", tricky],
                                      timeout: 10).succeeded,
               "escape do vmnet resiste a aspas, barra e $()")
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

        // Podman: formato oficial de machine list (booleano "Running").
        let podmanDirectory = temporary.appendingPathComponent("podman", isDirectory: true)
        try FileManager.default.createDirectory(at: podmanDirectory, withIntermediateDirectories: false)
        _ = try stub("podman", podmanDirectory,
                 stdout: "[{\"Name\":\"podman-machine-default\",\"Default\":true,\"Running\":true,\"Starting\":false}]", exitCode: 0)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path])
            .currentStatus().state == .running, "podman com maquina running = ligado")
        _ = try stub("podman", podmanDirectory,
                 stdout: "[{\"Name\":\"podman-machine-default\",\"Default\":true,\"Running\":false,\"Starting\":false}]", exitCode: 0)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path])
            .currentStatus().state == .stopped, "podman com maquina parada = desligado")
        _ = try stub("podman", podmanDirectory,
                 stdout: "[{\"Name\":\"Running\",\"Running\":false}]", exitCode: 0)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path])
            .currentStatus().state == .stopped, "maquina chamada Running nao engana o estado")
        // Conexao padrao ("Default") apontando para "dev" ligada, mas start/stop
        // sem nome agem em podman-machine-default, parada: vale a parada.
        _ = try stub("podman", podmanDirectory,
                     stdout: "[{\"Name\":\"dev*\",\"Default\":true,\"Running\":true},"
                        + "{\"Name\":\"podman-machine-default\",\"Default\":false,\"Running\":false}]", exitCode: 0)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path])
            .currentStatus().state == .stopped,
               "podman segue podman-machine-default, o alvo de start/stop sem nome")
        _ = try stub("podman", podmanDirectory,
                     stdout: "[{\"Name\":\"podman-machine-default*\",\"Default\":true,\"Running\":true}]", exitCode: 0)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path])
            .currentStatus().state == .running, "podman-machine-default marcada com * e reconhecida")
        _ = try stub("podman", podmanDirectory,
                     stdout: "[{\"Name\":\"podman-machine-default2\",\"Running\":true},"
                        + "{\"Name\":\"podman-machine-default\",\"Running\":false}]", exitCode: 0)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path])
            .currentStatus().state == .stopped, "nome parecido (prefixo) nao conta como o alvo")
        _ = try stub("podman", podmanDirectory, stdout: "[{\"Name\":\"dev\",\"Running\":true}]", exitCode: 0)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path])
            .currentStatus().state == .stopped, "sem a maquina alvo, outra VM nao decide o estado")
        let writablePodman = try stub("podman", podmanDirectory, stdout: "[]", exitCode: 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writablePodman)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path]).resolvedPath() == nil,
               "sonda ignora binario gravavel por outros usuarios")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: writablePodman)
        _ = try stub("podman", podmanDirectory, stdout: "[]", exitCode: 0)
        expect(RuntimeProbe(config: .podman, directories: [podmanDirectory.path])
            .currentStatus().state == .stopped, "podman sem maquina = desligado")

        // Lume: estado do servidor no launchd (launchctl print), nao das VMs.
        let lumeDirectory = temporary.appendingPathComponent("lume", isDirectory: true)
        try FileManager.default.createDirectory(at: lumeDirectory, withIntermediateDirectories: false)
        _ = try bare("lume", lumeDirectory, exitCode: 0)
        let launchctlDirectory = temporary.appendingPathComponent("launchctl", isDirectory: true)
        try FileManager.default.createDirectory(at: launchctlDirectory, withIntermediateDirectories: false)
        let launchctl = try stub("launchctl", launchctlDirectory,
                                 stdout: "gui/501/homebrew.mxcl.lume = {\n\tstate = running\n}", exitCode: 0)
        let lumeConfig = RuntimeProbeConfig.makeLume(launchctl: launchctl)
        expect(RuntimeProbe(config: lumeConfig, directories: [lumeDirectory.path])
            .currentStatus().state == .running, "lume com servidor de pe = ligado")
        _ = try stub("launchctl", launchctlDirectory,
                     stdout: "gui/501/homebrew.mxcl.lume = {\n\tstate = not running\n}", exitCode: 0)
        expect(RuntimeProbe(config: lumeConfig, directories: [lumeDirectory.path])
            .currentStatus().state == .stopped, "lume com servico carregado e parado = desligado")
        _ = try stub("launchctl", launchctlDirectory, stdout: "Could not find service", exitCode: 113)
        expect(RuntimeProbe(config: lumeConfig, directories: [lumeDirectory.path])
            .currentStatus().state == .stopped, "lume sem servico no launchd = desligado")
        expect(RuntimeProbe(config: lumeConfig, directories: ["/no/such/dir"])
            .currentStatus().state == .notInstalled, "lume sem binario = nao instalado")
        expect(RuntimeProbeConfig.lume.control?.startArguments == ["services", "start", "lume"]
               && RuntimeProbeConfig.lume.control?.stopArguments == ["services", "stop", "lume"],
               "brew services recebe o nome da formula lume")

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

        // Toda a familia docker precisa estar nas sondas de producao.
        let probed = Set(RuntimeProbeConfig.standard.map(\.label))
        expect(RuntimeProbeConfig.dockerFamily.allSatisfy { probed.contains($0.label) },
               "familia docker inteira entra nas sondas padrao")

        // Finch: vm status imprime Running / Stopped / Nonexistent.
        let finchDirectory = temporary.appendingPathComponent("finch", isDirectory: true)
        try FileManager.default.createDirectory(at: finchDirectory, withIntermediateDirectories: false)
        _ = try stub("finch", finchDirectory, stdout: "Running", exitCode: 0)
        expect(RuntimeProbe(config: .finch, directories: [finchDirectory.path])
            .currentStatus().state == .running, "finch vm Running = ligado")
        _ = try stub("finch", finchDirectory, stdout: "Nonexistent", exitCode: 0)
        expect(RuntimeProbe(config: .finch, directories: [finchDirectory.path])
            .currentStatus().state == .stopped, "finch sem VM = desligado")

        // Docker Desktop e Rancher: processo de dentro do bundle, com o
        // padrao ancorado no caminho (testado contra o pgrep real).
        expect(ContainerCLI.runBinary("/usr/bin/pgrep", arguments: ["-f", "^/no/such/App.app/Contents/MacOS/"],
                                      timeout: 2).exitCode == 1,
               "pgrep ancorado sem processo = desligado")

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
