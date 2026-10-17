import AppKit

/// Linha informativa compacta: no macOS 26 a linha nativa tem altura minima
/// de ~24pt (fonte menor nao reduz). So linhas INERTES (sem acao e sem
/// submenu: titulo, status, info) recebem esta view. Linhas clicaveis ficam
/// nativas: com view o AppKit nao entrega teclado (Return), o VoiceOver nao
/// abre submenu e cancelar arrastando para fora exigiria reimplementar o
/// tracking - o nativo ja faz tudo isso certo.
final class CompactMenuRow: NSView {
    static let rowHeight: CGFloat = 19
    private static let leading: CGFloat = 18     // alinha com o texto nativo
    private static let trailing: CGFloat = 12
    private static let indentStep: CGFloat = 10
    /// Teto de largura: um caminho de CLI longo nao alarga o menu ate a
    /// borda da tela; o excedente quebra em linhas (altura cresce).
    static let maxTextWidth: CGFloat = 380

    /// Natural size da ultima medicao: so reajusta o frame quando o conteudo
    /// muda (o autoresize estica a linha ate a largura do menu, e encolher a
    /// cada poll brigaria com ele).
    private var naturalSize = NSSize.zero

    static func isInert(_ item: NSMenuItem) -> Bool {
        !item.isSeparatorItem && item.action == nil && item.submenu == nil
    }

    /// Linha inerte ganha (ou mantem) a view compacta; clicavel volta a ser
    /// nativa. Submenus inclusos.
    static func install(in menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            if isInert(item) {
                let row = item.view as? CompactMenuRow ?? {
                    let created = CompactMenuRow(frame: NSRect(x: 0, y: 0, width: 100, height: rowHeight))
                    created.autoresizingMask = [.width]
                    item.view = created
                    return created
                }()
                row.refresh()
            } else {
                if item.view is CompactMenuRow { item.view = nil }
                if let submenu = item.submenu { install(in: submenu) }
            }
        }
    }

    /// Texto como sera desenhado: cor do proprio titulo atribuido (ex.:
    /// caminho secundario) ou a cor normal de texto.
    var title: NSAttributedString {
        guard let item = enclosingMenuItem else { return NSAttributedString() }
        let base = NSMutableAttributedString(
            attributedString: item.attributedTitle
                ?? NSAttributedString(string: item.title,
                                      attributes: [.font: StatusItemController.compactFont]))
        let whole = NSRange(location: 0, length: base.length)
        guard base.length > 0 else { return base }
        if base.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil {
            base.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        }
        if base.attribute(.font, at: 0, effectiveRange: nil) == nil {
            base.addAttribute(.font, value: StatusItemController.compactFont, range: whole)
        }
        return base
    }

    private var textOrigin: CGFloat {
        Self.leading + CGFloat(enclosingMenuItem?.indentationLevel ?? 0) * Self.indentStep
    }

    private func measure(_ text: NSAttributedString) -> NSSize {
        let rect = text.boundingRect(with: NSSize(width: Self.maxTextWidth, height: 400),
                                     options: [.usesLineFragmentOrigin])
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// Reajusta tamanho, tooltip e acessibilidade ao estado atual do item.
    func refresh() {
        let text = title
        let size = measure(text)
        let natural = NSSize(width: textOrigin + size.width + Self.trailing,
                             height: max(Self.rowHeight, size.height + 4))
        if natural != naturalSize {
            naturalSize = natural
            setFrameSize(natural)
        }
        // Com view, o tooltip do item nao aparece sozinho.
        toolTip = enclosingMenuItem?.toolTip
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text.string.replacingOccurrences(of: "\n", with: " "))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = title
        let size = measure(text)
        text.draw(with: NSRect(x: textOrigin, y: (bounds.height - size.height) / 2,
                               width: min(Self.maxTextWidth, bounds.width - textOrigin), height: size.height),
                  options: [.usesLineFragmentOrigin])
    }
}
