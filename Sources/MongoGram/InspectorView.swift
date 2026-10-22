import AppKit
import MoonKit
import SwiftUI

struct InspectorView: View {
    let model: DocumentModel

    var body: some View {
        if let i = model.selectedRef, i < model.schema.refs.count {
            RelationInspector(model: model, index: i, ref: model.schema.refs[i])
        } else if model.selectedTables.count > 1 {
            MultiTableInspector(model: model)
        } else if let id = model.selection, let table = model.schema.table(id: id) {
            TableInspector(model: model, table: table)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.hasContent {
                        Text(model.file.name.isEmpty ? "Model" : model.file.name).font(.title3.weight(.semibold))
                        if let db = model.file.databaseType { Label(db, systemImage: "cylinder.split.1x2").foregroundStyle(.secondary) }
                        if let note = model.file.note { Text(note).textSelection(.enabled).font(.callout) }
                        if model.file.diagrams.count > 1 {
                            section("Diagrams")
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(model.file.diagrams) { d in
                                    Button { model.selectDiagram(d.id) } label: {
                                        HStack {
                                            Image(systemName: d.isMain ? "square.grid.2x2.fill" : "square.grid.2x2").foregroundStyle(.secondary)
                                            Text(d.name).fontWeight(d.id == model.diagramID ? .semibold : .regular)
                                            Spacer()
                                            Text("\(d.tableIDs.count)").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, 6).padding(.vertical, 4)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(d.id == model.diagramID ? Color.accentColor.opacity(0.15) : .clear))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if let desc = model.diagram?.description { Text(desc).font(.callout).foregroundStyle(.secondary) }
                        Divider()
                    }
                    Text("Select a collection to see its fields, notes and references.")
                        .foregroundStyle(.secondary).font(.callout)
                    VStack(alignment: .leading, spacing: 6) {
                        shortcut("Pan", "two-finger scroll / space + drag / right-drag")
                        shortcut("Zoom", "pinch / ⌘ + scroll / mouse wheel")
                        shortcut("Fit", "⌘0 or F")
                        shortcut("Find", "⌘F")
                        shortcut("Focus table", "double-click")
                        shortcut("Select", "drag a rectangle; ⌘/⇧-click; ⌘A")
                        shortcut("Move", "drag, or arrow keys (⇧ = 10 pt); ⌘Z undoes")
                        shortcut("Line", "click it; double-click to show both ends")
                        shortcut("Diagram", "⌘[ / ⌘]")
                    }
                    .font(.caption)
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func shortcut(_ a: String, _ b: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(a).fontWeight(.medium).frame(width: 74, alignment: .leading)
            Text(b).foregroundStyle(.secondary)
        }
    }
}

private func section(_ title: String) -> some View {
    Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
}

/// Several tables selected: their names and the lines between them.
private struct MultiTableInspector: View {
    let model: DocumentModel

    var body: some View {
        let tables = model.schema.tables.filter { model.selectedTables.contains($0.id) }
        let refs = model.schema.refs.enumerated().filter {
            model.selectedTables.contains($0.element.from.tableID) && model.selectedTables.contains($0.element.to.tableID)
        }
        let embedded = tables.filter(\.isEmbeddable).count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(tables.count) selected").font(.title3.weight(.semibold))
                Text([tables.count - embedded > 0 ? "\(tables.count - embedded) collection\(tables.count - embedded == 1 ? "" : "s")" : nil,
                      embedded > 0 ? "\(embedded) embedded document\(embedded == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
                Text("Drag any of them to move them together, or use the arrow keys. ⌘Z undoes a move.")
                    .font(.callout).foregroundStyle(.secondary)

                section("Selected")
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tables) { t in
                        Button { model.canvas?.center(on: t.id) } label: {
                            HStack(spacing: 8) {
                                TableSwatch(table: t, color: model.style?.headerColors[t.id] ?? Palette.neutral, size: 10)
                                Text(t.displayName).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(t.columns.count)").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show \(t.displayName)")
                    }
                }

                if !refs.isEmpty {
                    section("Lines between them")
                    ForEach(refs, id: \.offset) { index, r in
                        let text = RelationText(r, schema: model.schema)
                        Button { model.selectRef(index, reveal: true) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(text.from) → \(text.to)").font(.system(.callout, design: .monospaced))
                                Text(text.kind).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TableInspector: View {
    let model: DocumentModel
    let table: MoonKit.Table

    var body: some View {
        let all = model.schema.refs.enumerated().filter { $0.element.from.tableID == table.id || $0.element.to.tableID == table.id }
        let refs = all.filter { $0.element.kind == .reference }
        let containers = all.filter { $0.element.kind == .embedding && $0.element.to.tableID == table.id }
        let embeds = all.filter { $0.element.kind == .embedding && $0.element.from.tableID == table.id }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    TableSwatch(table: table, color: model.style?.headerColors[table.id] ?? Palette.neutral, size: 14)
                    Text(table.displayName).font(.title3.weight(.semibold)).textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Badge(text: table.isEmbeddable ? "embedded document" : "collection")
                    Spacer()
                    Text("line \(table.line)").font(.caption).foregroundStyle(.tertiary)
                }
                if let note = table.note {
                    Text(note).font(.callout).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                }

                if !containers.isEmpty {
                    section("Embedded in")
                    ForEach(containers, id: \.offset) { index, r in
                        lineButton(index, RelationText(r, schema: model.schema).from, r.to.cardinality == .many ? "array" : nil)
                    }
                }

                section("Fields")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, c in
                        ColumnRow(model: model, column: c)
                        Divider().opacity(0.5)
                    }
                }

                if !table.indexes.isEmpty {
                    section("Indexes")
                    ForEach(Array(table.indexes.enumerated()), id: \.offset) { _, idx in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("(\(idx.columns.joined(separator: ", ")))").font(.system(.callout, design: .monospaced))
                            if idx.isUnique { Badge(text: "unique") }
                            Spacer()
                        }
                        if let n = idx.name { Text(n).font(.caption).foregroundStyle(.secondary) }
                    }
                }

                if !embeds.isEmpty {
                    section("Embedded Documents")
                    ForEach(embeds, id: \.offset) { index, r in
                        let text = RelationText(r, schema: model.schema)
                        lineButton(index, "\(text.columnName(r.from) ?? "?") → \(text.tableName(r.to.tableID))", r.to.cardinality == .many ? "array" : nil)
                    }
                }

                if !refs.isEmpty {
                    section("References")
                    ForEach(refs, id: \.offset) { index, r in
                        let text = RelationText(r, schema: model.schema)
                        let outgoing = r.from.tableID == table.id
                        let mine = outgoing ? r.from : r.to, other = outgoing ? r.to : r.from
                        Button { model.selectRef(index, reveal: true) } label: {
                            HStack(spacing: 6) {
                                Text(text.columnName(mine) ?? "?").font(.system(.callout, design: .monospaced))
                                Text(outgoing ? "→" : "←").foregroundStyle(.secondary)
                                Text(text.endpoint(other))
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    private func lineButton(_ index: Int, _ label: String, _ badge: String?) -> some View {
        Button { model.selectRef(index, reveal: true) } label: {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces").font(.caption).foregroundStyle(.secondary)
                Text(label).font(.system(.callout, design: .monospaced)).foregroundStyle(Color.accentColor)
                if let badge { Badge(text: badge) }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RelationInspector: View {
    let model: DocumentModel
    let index: Int
    let ref: Ref

    var body: some View {
        let text = RelationText(ref, schema: model.schema)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: ref.kind == .embedding ? "curlybraces" : "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                    Text(text.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Badge(text: text.kind)
                    Spacer()
                    if !ref.id.hasPrefix("synthetic:") { Text("line \(ref.line)").font(.caption).foregroundStyle(.tertiary) }
                }
                Text(text.sentence).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                EndpointCard(model: model, end: ref.from, caption: ref.kind == .embedding ? "contains" : RelationText.side(ref.from))
                HStack {
                    Spacer()
                    Image(systemName: "arrow.down").foregroundStyle(.secondary)
                    Spacer()
                }
                EndpointCard(model: model, end: ref.to, caption: ref.kind == .embedding ? (ref.to.cardinality == .many ? "array" : "subdocument") : RelationText.side(ref.to))

                Button { model.selectRef(index, reveal: true) } label: {
                    Label("Show Both Tables", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
    }
}

/// One side of a line: its table (click to jump there), cardinality and field details.
private struct EndpointCard: View {
    let model: DocumentModel
    let end: RefEndpoint
    let caption: String

    var body: some View {
        let table = model.schema.table(id: end.tableID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let table { TableSwatch(table: table, color: model.style?.headerColors[end.tableID] ?? Palette.neutral, size: 10) }
                Button { model.select(end.tableID, focus: true) } label: {
                    Text(table?.displayName ?? "?").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Go to table")
                Spacer()
                Text(caption).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if let id = end.columnID {
                let column = table?.columnIndex(id: id).map { table!.columns[$0] }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let column { FieldIcon(column: column) }
                        Text(column?.name ?? "missing field").font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text(column?.type ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if let c = column {
                        Text(c.isNotNull || c.isPrimaryKey ? "required" : "optional").font(.caption).foregroundStyle(.tertiary)
                        if let note = c.note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

private struct ColumnRow: View {
    let model: DocumentModel
    let column: Column

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                FieldIcon(column: column)
                Text(column.name).fontWeight(column.isPrimaryKey ? .semibold : .regular).textSelection(.enabled)
                Spacer()
                if let e = column.embeddedTableID {
                    Button { model.select(e, focus: true) } label: {
                        Text(column.type).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Go to the embedded document")
                } else {
                    Text(column.type).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            let flags = [column.isPrimaryKey ? "primary key" : nil, column.isNotNull ? "required" : nil, column.isList ? "array" : nil,
                         column.options, column.sample.map { "e.g. \($0)" }].compactMap { $0 }
            if !flags.isEmpty {
                Text(flags.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
            }
            if let note = column.note {
                Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
    }
}

struct FieldIcon: View {
    let column: Column

    var body: some View {
        if column.isPrimaryKey { Image(systemName: "key.fill").font(.caption2).foregroundStyle(.orange) }
        else if column.isForeignKey { Image(systemName: "link").font(.caption2).foregroundStyle(.blue) }
        else if column.embeddedTableID != nil { Image(systemName: column.isList ? "square.stack.3d.up.fill" : "curlybraces").font(.caption2).foregroundStyle(.teal) }
    }
}

/// Header color of a table: a filled square for collections, braces for embedded documents.
struct TableSwatch: View {
    let table: MoonKit.Table
    let color: NSColor
    let size: CGFloat

    var body: some View {
        if table.isEmbeddable {
            Image(systemName: "curlybraces").font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(Color(nsColor: color)).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.28).fill(Color(nsColor: color)).frame(width: size, height: size)
        }
    }
}

/// Small pill label. A struct, not a `badge(_:)` function: inside a View that name resolves to
/// SwiftUI's `.badge` modifier on `self`, which nests the view in itself until the stack overflows.
struct Badge: View {
    let text: String

    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }
}
