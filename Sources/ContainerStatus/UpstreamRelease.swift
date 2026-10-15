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

    /// Le tag_name ("1.5.0" ou "v1.5.0") e html_url do JSON da API. Tag nao
    /// numerica ou link fora de github.com = nil: o item do menu abre a URL.
    static func parse(_ data: Data) -> UpstreamRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let link = (object["html_url"] as? String).flatMap(URL.init(string:)),
              link.scheme == "https", link.host == "github.com" else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard ContainerCLI.parseVersion("version \(version)") == version else { return nil }
        return UpstreamRelease(version: version, url: link)
    }

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
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}
