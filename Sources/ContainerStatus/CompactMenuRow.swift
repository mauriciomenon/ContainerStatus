import AppKit

/// Linha de menu compacta: no macOS 26 a linha nativa tem altura minima de
/// ~24pt (fonte menor nao reduz). A view desenha o item que a contem -
/// titulo, indentacao, check, seta de submenu e realce - lendo o proprio
/// NSMenuItem, entao o estado continua todo no item e o apply() segue
/// mexendo so em titulos. Submenu e tracking ficam com o AppKit.
final class CompactMenuRow: NSView {
    static let rowHeight: CGFloat = 19
    private static let leading: CGFloat = 18   // coluna do check
    private static let trailing: CGFloat = 18  // coluna da seta
    private static let indentStep: CGFloat = 10

    /// Garante a view compacta em todos os itens (submenus inclusos) e
    /// reajusta tamanho e desenho ao estado atual de cada um.
    static func install(in menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            let row = item.view as? CompactMenuRow ?? {
                let created = CompactMenuRow(frame: NSRect(x: 0, y: 0, width: 100, height: rowHeight))
                created.autoresizingMask = [.width]
                item.view = created
                return created
            }()
            row.refresh()
            if let submenu = item.submenu { install(in: submenu) }
        }
    }

    /// Texto como sera desenhado. Cinza so para acao desabilitada (ex.:
    /// "Working..."); linha informativa (sem acao) fica na cor normal.
    var title: NSAttributedString {
        guard let item = enclosingMenuItem else { return NSAttributedString() }
        let base = NSMutableAttributedString(
            attributedString: item.attributedTitle
                ?? NSAttributedString(string: item.title,
                                      attributes: [.font: StatusItemController.compactFont]))
        let whole = NSRange(location: 0, length: base.length)
        if base.length > 0 && base.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil {
            let dimmed = !item.isEnabled && item.action != nil
            base.addAttribute(.foregroundColor,
                              value: dimmed ? NSColor.disabledControlTextColor : NSColor.labelColor,
                              range: whole)
        }
        if base.length > 0 && base.attribute(.font, at: 0, effectiveRange: nil) == nil {
            base.addAttribute(.font, value: StatusItemController.compactFont, range: whole)
        }
        if isLit {
            base.addAttribute(.foregroundColor, value: NSColor.selectedMenuItemTextColor, range: whole)
        }
        return base
    }

    private var isLit: Bool {
        guard let item = enclosingMenuItem else { return false }
        return item.isHighlighted && item.isEnabled
    }

    private var textOrigin: CGFloat {
        Self.leading + CGFloat(enclosingMenuItem?.indentationLevel ?? 0) * Self.indentStep
    }

    /// Largura pedida pelo conteudo; a altura cresce so para titulo em duas
    /// linhas (caminho "via symlink").
    func refresh() {
        let size = title.boundingRect(with: NSSize(width: 1000, height: 200),
                                      options: [.usesLineFragmentOrigin]).size
        let height = max(Self.rowHeight, ceil(size.height) + 4)
        let width = ceil(textOrigin + size.width + Self.trailing + 6)
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(enclosingMenuItem?.title)
        setAccessibilityEnabled(enclosingMenuItem?.isEnabled ?? false)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item = enclosingMenuItem else { return }
        if isLit {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let text = title
        let textHeight = ceil(text.boundingRect(with: NSSize(width: 1000, height: 200),
                                                options: [.usesLineFragmentOrigin]).height)
        let y = (bounds.height - textHeight) / 2
        text.draw(with: NSRect(x: textOrigin, y: y, width: bounds.width - textOrigin - Self.trailing,
                               height: textHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let markColor = isLit ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor
        let markAttributes: [NSAttributedString.Key: Any] = [
            .font: StatusItemController.compactFont, .foregroundColor: markColor,
        ]
        if item.state == .on {
            NSAttributedString(string: "\u{2713}", attributes: markAttributes)
                .draw(at: NSPoint(x: 6, y: y))
        }
        if item.submenu != nil {
            NSAttributedString(string: "\u{203A}", attributes: markAttributes)
                .draw(at: NSPoint(x: bounds.width - Self.trailing + 2, y: y))
        }
    }

    // Com view, o AppKit nao dispara a acao do item: o clique dispara aqui.
    override func mouseUp(with event: NSEvent) {
        perform()
    }

    override func accessibilityPerformPress() -> Bool {
        perform()
        return true
    }

    /// Selftest: clique dispara a acao do item habilitado; desabilitado e
    /// linha com submenu nao disparam.
    static func checkClick(expect: (Bool, String) -> Void) {
        final class Target: NSObject {
            var hits = 0
            @objc func hit(_ sender: Any) { hits += 1 }
        }
        let target = Target()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Acao", action: #selector(Target.hit(_:)), keyEquivalent: "")
        item.target = target
        let parent = NSMenuItem(title: "Pai", action: #selector(Target.hit(_:)), keyEquivalent: "")
        parent.target = target
        parent.submenu = NSMenu()
        menu.addItem(item)
        menu.addItem(parent)
        install(in: menu)
        let row = item.view as? CompactMenuRow
        expect(row?.perform() == true && target.hits == 1, "clique na linha compacta dispara a acao")
        item.isEnabled = false
        expect(row?.perform() == false && target.hits == 1, "linha desabilitada nao dispara")
        expect((parent.view as? CompactMenuRow)?.perform() == false && target.hits == 1,
               "linha com submenu abre o submenu, nao dispara acao")
    }

    @discardableResult
    func perform() -> Bool {
        guard let item = enclosingMenuItem, let menu = item.menu, item.isEnabled,
              item.submenu == nil, item.action != nil else { return false }
        var root = menu
        while let parent = root.supermenu { root = parent }
        root.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }
}
