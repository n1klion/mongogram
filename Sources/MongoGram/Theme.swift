import AppKit
import MoonKit

struct Theme: Equatable {
    var isDark: Bool
    var background: NSColor
    var tableBody: NSColor
    var tableBorder: NSColor
    var text: NSColor
    var secondaryText: NSColor
    var divider: NSColor
    var edge: NSColor
    var accent: NSColor
    var pk: NSColor
    var fk: NSColor
    /// Fields holding embedded documents, and their containment lines.
    var embedded: NSColor
    var shadowOpacity: Float

    static let light = Theme(
        isDark: false,
        background: NSColor(hex: "#F4F5F7")!,
        tableBody: .white,
        tableBorder: NSColor(hex: "#DDE1E6")!,
        text: NSColor(hex: "#1D2129")!,
        secondaryText: NSColor(hex: "#7A828E")!,
        divider: NSColor(hex: "#EEF0F3")!,
        edge: NSColor(hex: "#A3ABB7")!,
        accent: NSColor(hex: "#2F6FEB")!,
        pk: NSColor(hex: "#D99A0B")!,
        fk: NSColor(hex: "#5B8DEF")!,
        embedded: NSColor(hex: "#0E8F7E")!,
        shadowOpacity: 0.10)

    static let dark = Theme(
        isDark: true,
        background: NSColor(hex: "#15171C")!,
        tableBody: NSColor(hex: "#1F2229")!,
        tableBorder: NSColor(hex: "#30343D")!,
        text: NSColor(hex: "#E7E9EE")!,
        secondaryText: NSColor(hex: "#8A92A0")!,
        divider: NSColor(hex: "#292D35")!,
        edge: NSColor(hex: "#58606E")!,
        accent: NSColor(hex: "#5B9BFF")!,
        pk: NSColor(hex: "#F2B84B")!,
        fk: NSColor(hex: "#7EA6F5")!,
        embedded: NSColor(hex: "#3CC8B4")!,
        shadowOpacity: 0.45)

    static func current(_ appearance: NSAppearance) -> Theme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

/// Moon Modeler's own box geometry (header 27, rows 18), so positions from the file line up exactly.
enum Metrics {
    static let headerHeight: CGFloat = 27
    static let rowHeight: CGFloat = 18
    static let padding: CGFloat = 8
    static let iconColumn: CGFloat = 15
    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 420
    static let cornerRadius: CGFloat = 6

    static let headerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let columnFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let pkColumnFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let typeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
}

/// Header colors when the schema doesn't specify one: pleasant, distinguishable, readable with white text.
enum Palette {
    static let colors = ["#3E63DD", "#0E9F8E", "#D6409F", "#E5484D", "#8E4EC6", "#F76B15", "#12A594", "#5B5BD6", "#AB4ABA", "#0090FF"]
        .compactMap { NSColor(hex: $0) }
    static let neutral = NSColor(hex: "#5E6B7D")!

    static func color(_ i: Int) -> NSColor { colors[i % colors.count] }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

/// Resolved, render-ready view of a diagram: header colors per table.
struct SceneStyle {
    var headerColors: [String: NSColor] = [:]
    /// Embeddables: the color of the collection they live in, used as a tint.
    var embeddedIn: [String: String] = [:]

    init(schema: Schema, diagram: Diagram?) {
        for t in schema.tables {
            headerColors[t.id] = diagram?.items[t.id]?.background.flatMap(NSColor.init(hex:))
        }
        // Each embeddable takes the color of its nearest colored ancestor.
        var parentOf: [String: String] = [:]
        for r in schema.refs where r.kind == .embedding { parentOf[r.to.tableID] = r.from.tableID }
        for t in schema.tables where t.isEmbeddable {
            var p = parentOf[t.id], seen: Set<String> = [t.id]
            while let id = p, seen.insert(id).inserted {
                if let table = schema.table(id: id), !table.isEmbeddable || headerColors[id] != nil {
                    embeddedIn[t.id] = id
                    break
                }
                p = parentOf[id]
            }
        }
        for t in schema.tables where headerColors[t.id] == nil && !t.isEmbeddable { headerColors[t.id] = Palette.color(0) }
        for t in schema.tables where headerColors[t.id] == nil {
            headerColors[t.id] = embeddedIn[t.id].flatMap { headerColors[$0] } ?? Palette.neutral
        }
    }
}
