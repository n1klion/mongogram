import AppKit
import MoonKit

/// Measures and draws one table card. Drawing assumes a y-down context.
enum TableRenderer {
    /// The size Moon Modeler gives the box: its stored width, and 27 + 18 per field.
    static func size(of table: Table, item: DiagramItem?) -> CGSize {
        let width = item.map(\.width).flatMap { $0 > 0 ? $0 : nil } ?? measuredWidth(table)
        let rows = item?.isCollapsed == true ? 0 : CGFloat(max(table.columns.count, 1))
        return CGSize(width: width.rounded(.up), height: Metrics.headerHeight + rows * Metrics.rowHeight)
    }

    private static func measuredWidth(_ table: Table) -> CGFloat {
        let header = (table.name as NSString).size(withAttributes: [.font: Metrics.headerFont]).width + Metrics.padding * 2
            + (table.note != nil ? 18 : 0) + (table.isEmbeddable ? 16 : 0)
        var rowWidth: CGFloat = 0
        for c in table.columns {
            let name = (c.name as NSString).size(withAttributes: [.font: c.isPrimaryKey ? Metrics.pkColumnFont : Metrics.columnFont]).width
            let type = (c.type as NSString).size(withAttributes: [.font: Metrics.typeFont]).width
            rowWidth = max(rowWidth, Metrics.iconColumn + name + (c.note != nil ? 8 : 0) + 22 + type)
        }
        return min(Metrics.maxWidth, max(Metrics.minWidth, header, rowWidth + Metrics.padding * 2))
    }

    static func isCollapsed(_ size: CGSize) -> Bool { size.height < Metrics.headerHeight + Metrics.rowHeight / 2 }

    static func rowCenterY(_ index: Int) -> CGFloat {
        Metrics.headerHeight + (CGFloat(index) + 0.5) * Metrics.rowHeight
    }

    /// Row under a point in table-local coordinates; -1 for the header.
    static func row(at y: CGFloat, in table: Table) -> Int? {
        if y < Metrics.headerHeight { return -1 }
        let i = Int((y - Metrics.headerHeight) / Metrics.rowHeight)
        return i < table.columns.count ? i : nil
    }

    static func headerTextColor(_ header: NSColor) -> NSColor {
        header.luminance > 0.62 ? NSColor(white: 0.1, alpha: 0.92) : .white
    }

    /// Embeddables get a light tint of their collection's color instead of a solid header.
    static func headerFill(_ table: Table, _ header: NSColor, _ theme: Theme) -> NSColor {
        guard table.isEmbeddable else { return header }
        return theme.tableBody.blended(withFraction: theme.isDark ? 0.30 : 0.20, of: header) ?? header
    }

    static func draw(_ table: Table, size: CGSize, header: NSColor, theme: Theme, in ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let bounds = CGRect(origin: .zero, size: size)
        let card = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Metrics.cornerRadius, cornerHeight: Metrics.cornerRadius, transform: nil)
        let fill = headerFill(table, header, theme)
        let collapsed = isCollapsed(size)

        ctx.saveGState()
        ctx.addPath(card)
        ctx.setFillColor(theme.tableBody.cgColor)
        ctx.fillPath()

        ctx.addPath(card)
        ctx.clip()
        ctx.setFillColor(fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: Metrics.headerHeight))
        if !table.isEmbeddable {
            // Soft highlight at the top of the header gives it some depth.
            ctx.setFillColor(NSColor.white.withAlphaComponent(theme.isDark ? 0.06 : 0.10).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: Metrics.headerHeight / 2))
        }

        // Rows.
        let textColor = theme.text
        for (i, c) in table.columns.enumerated() where !collapsed {
            let top = Metrics.headerHeight + CGFloat(i) * Metrics.rowHeight
            if top >= size.height { break }
            if i > 0 {
                ctx.setFillColor(theme.divider.cgColor)
                ctx.fill(CGRect(x: Metrics.padding, y: top, width: size.width - Metrics.padding * 2, height: 1))
            }
            let mid = top + Metrics.rowHeight / 2
            let icon = CGPoint(x: Metrics.padding + 5, y: mid)

            if c.isPrimaryKey {
                drawSymbol("key.fill", color: theme.pk, center: icon, pointSize: 8)
            } else if c.isForeignKey {
                drawSymbol("link", color: theme.fk, center: icon, pointSize: 8)
            } else if c.embeddedTableID != nil {
                drawSymbol(c.isList ? "square.stack.3d.up.fill" : "curlybraces", color: theme.embedded, center: icon, pointSize: 8)
            }

            let typeColor = c.embeddedTableID != nil ? theme.embedded : theme.secondaryText
            let type = NSAttributedString(string: c.type, attributes: [.font: Metrics.typeFont, .foregroundColor: typeColor])
            let typeWidth = min(type.size().width, (size.width - Metrics.padding * 2 - Metrics.iconColumn) * 0.55)
            let typeRect = CGRect(x: size.width - Metrics.padding - typeWidth, y: mid - 6.5, width: typeWidth, height: 13)
            type.draw(with: typeRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

            var nameAttrs: [NSAttributedString.Key: Any] = [.font: c.isPrimaryKey ? Metrics.pkColumnFont : Metrics.columnFont, .foregroundColor: textColor]
            if !c.isNotNull && !c.isPrimaryKey { nameAttrs[.foregroundColor] = textColor.withAlphaComponent(0.78) }
            let name = NSAttributedString(string: c.name, attributes: nameAttrs)
            let nameX = Metrics.padding + Metrics.iconColumn
            let maxName = typeRect.minX - nameX - 10 - (c.note != nil ? 8 : 0)
            let nameWidth = max(0, min(name.size().width, maxName))
            name.draw(with: CGRect(x: nameX, y: mid - 7, width: nameWidth, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

            if c.note != nil {
                ctx.setFillColor(theme.accent.withAlphaComponent(0.7).cgColor)
                ctx.fillEllipse(in: CGRect(x: nameX + nameWidth + 4, y: mid - 1.5, width: 3, height: 3))
            }
        }
        if table.columns.isEmpty && !collapsed {
            let empty = NSAttributedString(string: "no fields", attributes: [.font: Metrics.columnFont, .foregroundColor: theme.secondaryText])
            empty.draw(at: CGPoint(x: Metrics.padding + Metrics.iconColumn, y: Metrics.headerHeight + 2))
        }
        ctx.restoreGState()

        // Header text.
        let headerColor = table.isEmbeddable ? theme.text : headerTextColor(fill)
        var x = Metrics.padding
        if table.isEmbeddable {
            drawSymbol("curlybraces", color: header.blended(withFraction: theme.isDark ? 0.4 : 0, of: .white) ?? header,
                       center: CGPoint(x: x + 5, y: Metrics.headerHeight / 2), pointSize: 9)
            x += Metrics.iconColumn
        }
        let noteSpace: CGFloat = table.note != nil ? 18 : 0
        NSAttributedString(string: table.name, attributes: [.font: Metrics.headerFont, .foregroundColor: headerColor])
            .draw(with: CGRect(x: x, y: Metrics.headerHeight / 2 - 8, width: size.width - x - Metrics.padding - noteSpace, height: 16),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if table.note != nil {
            drawSymbol("text.bubble.fill", color: headerColor.withAlphaComponent(0.7),
                       center: CGPoint(x: size.width - Metrics.padding - 5, y: Metrics.headerHeight / 2), pointSize: 9.5)
        }

        ctx.addPath(card)
        if table.isEmbeddable {
            ctx.setStrokeColor(header.withAlphaComponent(0.65).cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
        } else {
            ctx.setStrokeColor(theme.tableBorder.cgColor)
        }
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private static var symbolCache: [String: NSImage] = [:]

    private static func drawSymbol(_ name: String, color: NSColor, center: CGPoint, pointSize: CGFloat) {
        let key = "\(name)|\(color.description)|\(pointSize)"
        let image: NSImage
        if let cached = symbolCache[key] {
            image = cached
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
            symbolCache[key] = img
            image = img
        }
        let s = image.size
        image.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Geometry of a line between two rows (or a row and a table header), including cardinality markers.
enum EdgeGeometry {
    enum Marker { case none, one, many }

    struct Anchor {
        var rect: CGRect
        var rowY: CGFloat
        var marker: Marker
        var isOptional = false

        /// Length of the straight piece leaving the table; optional ends need room for the circle.
        var stub: CGFloat { isOptional ? 26 : marker == .none ? 8 : 14 }
    }

    static func path(from a: Anchor, to b: Anchor, sameTable: Bool) -> CGPath {
        let path = CGMutablePath()

        if sameTable {
            let x = a.rect.maxX
            let p1 = CGPoint(x: x, y: a.rowY), p2 = CGPoint(x: x, y: b.rowY)
            let s1 = CGPoint(x: x + a.stub, y: p1.y), s2 = CGPoint(x: x + b.stub, y: p2.y)
            let reach: CGFloat = 40 + abs(p2.y - p1.y) * 0.15
            path.move(to: s1)
            path.addCurve(to: s2, control1: CGPoint(x: x + reach, y: p1.y), control2: CGPoint(x: x + reach, y: p2.y))
            addEnd(path, at: p1, direction: 1, a)
            addEnd(path, at: p2, direction: 1, b)
            return path
        }

        // Pick sides: face each other when horizontally separated, otherwise loop around one side.
        let da: CGFloat, db: CGFloat
        if a.rect.maxX + 20 < b.rect.minX { (da, db) = (1, -1) }
        else if b.rect.maxX + 20 < a.rect.minX { (da, db) = (-1, 1) }
        else if a.rect.midX <= b.rect.midX { (da, db) = (-1, -1) }
        else { (da, db) = (1, 1) }

        let p1 = CGPoint(x: da > 0 ? a.rect.maxX : a.rect.minX, y: a.rowY)
        let p2 = CGPoint(x: db > 0 ? b.rect.maxX : b.rect.minX, y: b.rowY)
        let s1 = CGPoint(x: p1.x + da * a.stub, y: p1.y)
        let s2 = CGPoint(x: p2.x + db * b.stub, y: p2.y)
        let reach: CGFloat = da == db
            ? max(40, abs(s2.x - s1.x) + 40)
            : max(30, min(abs(s2.x - s1.x) * 0.5, 220))
        path.move(to: s1)
        path.addCurve(to: s2,
                      control1: CGPoint(x: s1.x + da * reach, y: s1.y),
                      control2: CGPoint(x: s2.x + db * reach, y: s2.y))
        addEnd(path, at: p1, direction: da, a)
        addEnd(path, at: p2, direction: db, b)
        return path
    }

    /// The straight stub from the table edge `p` out to where the curve starts, with markers:
    /// "one" is a bar, "many" a crow's foot opening toward the table, and an optional end adds
    /// a hollow circle ("zero") further out, with the line broken around it.
    private static func addEnd(_ path: CGMutablePath, at p: CGPoint, direction d: CGFloat, _ end: Anchor) {
        func pt(_ dx: CGFloat, _ dy: CGFloat = 0) -> CGPoint { CGPoint(x: p.x + d * dx, y: p.y + dy) }
        let radius: CGFloat = 3.5, circleCenter: CGFloat = 18
        path.move(to: p)
        if end.isOptional {
            path.addLine(to: pt(circleCenter - radius))
            path.addEllipse(in: CGRect(x: pt(circleCenter).x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            path.move(to: pt(circleCenter + radius))
        }
        path.addLine(to: pt(end.stub))
        switch end.marker {
        case .none: break
        case .one:
            path.move(to: pt(8, -4.5)); path.addLine(to: pt(8, 4.5))
        case .many:
            path.move(to: pt(10)); path.addLine(to: pt(0, -5))
            path.move(to: pt(10)); path.addLine(to: pt(0, 5))
        }
    }
}

/// Everything needed to draw one diagram, shared by the live canvas and the PNG exporter.
/// `schema` holds only this diagram's tables and the lines between them.
struct DiagramScene {
    var schema: Schema
    var diagram: Diagram?
    var style: SceneStyle
    var sizes: [String: CGSize]
    var positions: [String: CGPoint]
    /// Where the file puts each table; nil for tables the file doesn't place in this diagram.
    var filePositions: [String: CGPoint]

    init(file: Schema, diagram: Diagram?) {
        var schema = file
        if let diagram {
            let ids = Set(diagram.tableIDs)
            schema.tables = diagram.tableIDs.compactMap { file.table(id: $0) }
            schema.refs = file.refs.filter { ids.contains($0.from.tableID) && ids.contains($0.to.tableID) }
        }
        self.schema = schema
        self.diagram = diagram
        style = SceneStyle(schema: schema, diagram: diagram)
        sizes = Dictionary(uniqueKeysWithValues: schema.tables.map { ($0.id, TableRenderer.size(of: $0, item: diagram?.items[$0.id])) })
        filePositions = diagram?.items.mapValues(\.origin) ?? [:]
        positions = [:]
    }

    var tableIDs: [String] { schema.tables.map(\.id) }

    /// Positions tables: `moved` (set in this app) first, then the file's, then an automatic spot
    /// next to a neighbor. With nothing known at all, the whole diagram is auto-arranged.
    mutating func place(moved: [String: CGPoint], style: LayoutStyle = .leftRight) {
        let ids = Set(tableIDs)
        let known = filePositions.merging(moved) { _, mine in mine }.filter { ids.contains($0.key) }
        positions = known.isEmpty
            ? SchemaLayout.compute(schema: schema, tableIDs: tableIDs, sizes: sizes, style: style)
            : SchemaLayout.placeNew(schema: schema, tableIDs: tableIDs, sizes: sizes, existing: known, style: style)
    }

    func rect(_ id: String) -> CGRect {
        CGRect(origin: positions[id] ?? .zero, size: sizes[id] ?? .zero)
    }

    func anchors(_ ref: Ref) -> (EdgeGeometry.Anchor, EdgeGeometry.Anchor)? {
        guard let ta = schema.table(id: ref.from.tableID), let tb = schema.table(id: ref.to.tableID) else { return nil }
        func anchor(_ t: Table, _ e: RefEndpoint, _ marker: EdgeGeometry.Marker) -> EdgeGeometry.Anchor {
            let r = rect(t.id)
            let row = TableRenderer.isCollapsed(r.size) ? nil : e.columnID.flatMap { t.columnIndex(id: $0) }
            let y = row.map { r.minY + TableRenderer.rowCenterY($0) } ?? (r.minY + Metrics.headerHeight / 2)
            return .init(rect: r, rowY: y, marker: marker, isOptional: e.isOptional && ref.kind == .reference)
        }
        switch ref.kind {
        case .reference:
            return (anchor(ta, ref.from, ref.from.cardinality == .many ? .many : .one),
                    anchor(tb, ref.to, ref.to.cardinality == .many ? .many : .one))
        case .embedding:
            return (anchor(ta, ref.from, .none), anchor(tb, ref.to, ref.to.cardinality == .many ? .many : .none))
        }
    }

    func edgePath(_ ref: Ref) -> CGPath? {
        guard let (a, b) = anchors(ref) else { return nil }
        return EdgeGeometry.path(from: a, to: b, sameTable: ref.from.tableID == ref.to.tableID)
    }

    var contentBounds: CGRect {
        let r = schema.tables.map { rect($0.id) }.reduce(CGRect.null) { $0.union($1) }
        return r.isNull ? .zero : r
    }
}
