import Foundation

/// Ultima release publicada do apple/container no GitHub. A CLI so conhece
/// a versao instalada; sem esta consulta o app nunca sabe que saiu outra.
struct UpstreamRelease: Equatable, Sendable {
    var version: String
    var url: URL

    /// `releases/latest` ja exclui rascunhos e pre-releases.
    static let endpoint = URL(string: "https://api.github.com/repos/apple/container/releases/latest")!
    /// Sem token: 60 requisicoes/hora por IP; a cada 6h sobra folga.
    static let checkInterval: TimeInterval = 6 * 3600

    /// Le so tag_name ("1.5.0" ou "v1.5.0") do JSON da API. A URL que o menu
    /// abre e montada aqui (pagina da tag no apple/container), nunca vem da
    /// resposta: um html_url adulterado poderia apontar para qualquer download
    /// no github.com. Tag nao numerica, com mais de 4 partes ou 32 caracteres = nil.
    static func parse(_ data: Data) -> UpstreamRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, tag.count <= 32 else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard ContainerCLI.parseVersion("version \(version)") == version,
              version.split(separator: ".").count <= 4,
              let link = URL(string: "https://github.com/apple/container/releases/tag/\(tag)") else { return nil }
        return UpstreamRelease(version: version, url: link)
    }

    /// Sessao efemera: sem cache em disco que outro processo do usuario
    /// pudesse adulterar entre consultas.
    private static let session = URLSession(configuration: .ephemeral)

    /// Release mais nova que a instalada, ou nil (sem CLI, sem consulta ou
    /// ja atualizado).
    static func update(_ release: UpstreamRelease?, installed: String?) -> UpstreamRelease? {
        guard let release, let installed,
              ContainerCLI.isVersionNewer(release.version, than: installed) else { return nil }
        return release
    }

    /// Falha de rede ou de API = nil; a proxima rodada tenta de novo.
    static func fetchLatest() async -> UpstreamRelease? {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}
