import Foundation

/// Estado de um runtime externo observado somente-leitura (passo 1 do
/// roadmap multi-runtime: deteccao sem controle e sem tocar na maquina).
enum ExternalRuntimeState: Equatable, Sendable {
    case notInstalled
    case running
    case stopped
}

/// Sonda do colima: `colima status` responde exit 0 com a VM de pe e
/// nao-zero quando parada. Reaproveita o watchdog e o ambiente fixo do
/// wrapper da CLI. Nenhum toggle aqui - controle e o passo 2 do roadmap.
final class ColimaProbe: Sendable {
    private static let statusTimeout: TimeInterval = 2

    private let directories: [String]

    init(directories: [String] = ContainerCLI.searchDirectories()) {
        self.directories = directories
    }

    /// Binario colima com maior prioridade (ordem dos diretorios), ou nil
    /// quando o colima nao esta instalado.
    func resolvedPath() -> String? {
        directories.compactMap { directory in
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("colima").path
            return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
        }.first
    }

    func currentStatus() -> (state: ExternalRuntimeState, path: String?) {
        guard let path = resolvedPath() else {
            return (.notInstalled, nil)
        }
        let result = ContainerCLI.runBinary(path, arguments: ["status"], timeout: Self.statusTimeout)
        // Timeout: conservador, mostra desligado e o poll seguinte corrige -
        // a linha e informativa e read-only, nunca dispara alarme.
        if result.timedOut || !result.spawned {
            return (.stopped, path)
        }
        return (result.exitCode == 0 ? .running : .stopped, path)
    }
}
