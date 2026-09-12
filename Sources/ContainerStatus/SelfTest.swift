import Foundation

/// Command-line self-test (`ContainerStatus --selftest`): verifies the pure
/// logic and the process watchdog without touching the real service. Replaces
/// the unit test target, which the Command Line Tools toolchain cannot build
/// with cross-module imports.
enum SelfTest {
    static func runAndExit() -> Never {
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

        let dirOld = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs_old_\(UUID().uuidString)", isDirectory: true)
        let dirNew = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs_new_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(atPath: dirOld.path, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: dirNew.path, withIntermediateDirectories: true)
        let oldCLI = dirOld.appendingPathComponent("container").path
        let newCLI = dirNew.appendingPathComponent("container").path
        FileManager.default.createFile(atPath: oldCLI,
                                       contents: Data("#!/bin/sh\necho \"container CLI version 1.0.0\"\n".utf8))
        FileManager.default.createFile(atPath: newCLI,
                                       contents: Data("#!/bin/sh\necho \"container CLI version 9.9.9\"\n".utf8))
        Darwin.chmod(oldCLI, 0o755)
        Darwin.chmod(newCLI, 0o755)
        let resolved = ContainerCLI.resolveNewest(inDirectories: [dirOld.path, dirNew.path])
        expect(resolved?.path == newCLI, "a CLI mais nova vence entre candidatos")
        expect(ContainerCLI.isVersionNewer("1.4.1", than: "1.3.1"), "1.4.1 > 1.3.1")
        expect(!ContainerCLI.isVersionNewer("1.3.1", than: "1.4.1"), "1.3.1 nao supera 1.4.1")
        expect(ContainerCLI.isVersionNewer("10.0", than: "9.9.9"), "dois digitos: 10.0 > 9.9.9")
        expect(!ContainerCLI.isVersionNewer(nil, than: "1.0.0"), "sem versao perde")
        expect(ContainerCLI.isVersionNewer("1.0.0", than: nil), "com versao vence sem versao")
        try? FileManager.default.removeItem(atPath: dirOld.path)
        try? FileManager.default.removeItem(atPath: dirNew.path)

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

        if failures == 0 {
            print("SELFTEST OK")
            exit(0)
        }
        print("SELFTEST FAILED (\(failures))")
        exit(1)
    }
}
