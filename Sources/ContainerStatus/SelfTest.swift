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
    }
}
