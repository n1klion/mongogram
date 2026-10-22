import CoreGraphics
import Foundation

/// Reads Moon Modeler `.dmm` files (JSON). Tolerant: missing or oddly typed fields fall back to
/// defaults, broken references become diagnostics, and everything else still renders.
public enum DMM {
    public static let containmentLine = "containment-line"

    public static func parse(_ source: String) -> Schema {
        var schema = Schema()
        let data = Data(source.utf8)
        let root: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                schema.diagnostics.append(.init(severity: .error, line: 1, message: "Not a Moon Modeler file: the top level is not a JSON object"))
                return schema
            }
            root = obj
        } catch {
            schema.diagnostics.append(.init(severity: .error, line: jsonErrorLine(error) ?? 1, message: "Invalid JSON: \(jsonErrorMessage(error))"))
            return schema
        }
        guard let rawTables = root["tables"] as? [String: Any] else {
            schema.diagnostics.append(.init(severity: .error, line: 1, message: "Not a Moon Modeler file: no \"tables\" object"))
            return schema
        }
        var ctx = Context(source: source)
        ctx.parse(root, rawTables, into: &schema)
        return schema
    }

    private struct Context {
        let lines: LineIndex
        var diagnostics: [Diagnostic] = []

        init(source: String) { lines = LineIndex(source) }

        mutating func warn(_ id: String?, _ message: String) {
            diagnostics.append(.init(severity: .warning, line: id.flatMap { lines.line(ofID: $0) } ?? 1, message: message))
        }

        mutating func parse(_ root: [String: Any], _ rawTables: [String: Any], into schema: inout Schema) {
            let model = root["model"] as? [String: Any] ?? [:]
            schema.name = string(model["name"]) ?? ""
            schema.databaseType = string(model["type"])
            schema.note = string(model["desc"])

            // Tables in sidebar order, then any the order list misses.
            let raw = rawTables.compactMapValues { $0 as? [String: Any] }
            var listed: Set<String> = []
            var ids = (root["order"] as? [Any] ?? []).compactMap { $0 as? String }.filter { raw[$0] != nil && listed.insert($0).inserted }
            ids += raw.keys.filter { !listed.contains($0) }.sorted { (lines.line(ofID: $0) ?? 0) < (lines.line(ofID: $1) ?? 0) }
            let visible = ids.filter { raw[$0]?["visible"] as? Bool ?? true }
            let names = raw.mapValues { string($0["name"]) ?? "?" }

            var tables: [Table] = []
            for id in visible {
                let t = raw[id]!
                var table = Table(id: id, name: names[id]!, line: lines.line(ofID: id) ?? 1)
                table.isEmbeddable = t["embeddable"] as? Bool ?? false
                table.note = string(t["desc"])
                var seen: Set<String> = []
                for case let c as [String: Any] in t["cols"] as? [Any] ?? [] {
                    let colID = string(c["id"]) ?? UUID().uuidString
                    let name = string(c["name"]) ?? "?"
                    if !seen.insert(name).inserted { warn(colID, "\(table.name): duplicate field \(name)") }
                    let datatype = string(c["datatype"]) ?? "?"
                    var col = Column(id: colID, name: name, datatype: datatype, type: datatype)
                    col.param = string(c["param"])
                    col.isPrimaryKey = c["pk"] as? Bool ?? false
                    col.isNotNull = c["nn"] as? Bool ?? false
                    col.isList = c["list"] as? Bool ?? false
                    col.isForeignKey = c["fk"] as? Bool ?? false
                    col.note = string(c["comment"])
                    col.sample = string(c["data"])
                    col.options = string(c["options"])
                    var base = datatype
                    if let embedded = names[datatype] {
                        col.embeddedTableID = datatype
                        base = embedded
                    } else if DMM.looksLikeUUID(datatype) {
                        warn(colID, "\(table.name).\(name): its type \(datatype) is not a table in this file")
                    } else if let p = col.param {
                        base += "(\(p))"
                    }
                    col.type = col.isList ? "[\(base)]" : base
                    table.columns.append(col)
                }
                for case let k as [String: Any] in t["indexes"] as? [Any] ?? [] {
                    let colIDs = (k["cols"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap { string($0["colid"]) } }
                    let cols = colIDs.map { cid in table.columns.first { $0.id == cid }?.name ?? cid }
                    table.indexes.append(Index(name: string(k["name"]), columns: cols, isUnique: k["unique"] as? Bool ?? false))
                }
                tables.append(table)
            }
            let index = Dictionary(uniqueKeysWithValues: tables.enumerated().map { ($1.id, $0) })

            // Relations.
            var refs: [Ref] = []
            let rawRelations = (root["relations"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
            for (id, r) in rawRelations.sorted(by: { (lines.line(ofID: $0.key) ?? 0) < (lines.line(ofID: $1.key) ?? 0) }) {
                let label = string(r["name"]) ?? "relation"
                guard let pid = string(r["parent"]), let cid = string(r["child"]) else { warn(id, "\(label): missing parent or child"); continue }
                guard let pi = index[pid], let ci = index[cid] else {
                    if raw[pid] == nil || raw[cid] == nil { warn(id, "\(label): points to a table that doesn't exist") }
                    continue  // Hidden table: not an error.
                }
                let pair = (r["cols"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.first
                let pcol = pair.flatMap { string($0["parentcol"]) }.flatMap { tables[pi].columnIndex(id: $0) }
                let ccol = pair.flatMap { string($0["childcol"]) }.flatMap { tables[ci].columnIndex(id: $0) }
                if pair != nil, pcol == nil || ccol == nil { warn(id, "\(label): a column of this relation doesn't exist") }

                // Which side holds the key being referenced? Decided by the columns, not by the
                // field names, since files disagree on what "parent" and "child" mean.
                let parentKeyID = string(r["parent_key"])
                let parentOwnsKey = (raw[pid]?["keys"] as? [Any] ?? []).contains { ($0 as? [String: Any]).flatMap { string($0["id"]) } == parentKeyID }
                let keyIsChild: Bool
                if let ccol, tables[ci].columns[ccol].isPrimaryKey { keyIsChild = true }
                else if let pcol, tables[pi].columns[pcol].isPrimaryKey { keyIsChild = false }
                else { keyIsChild = !parentOwnsKey }
                let (fkT, fkC, keyT, keyC) = keyIsChild ? (pi, pcol, ci, ccol) : (ci, ccol, pi, pcol)

                let keyCard = string(r["c_p"]) ?? "one", fkCard = string(r["c_ch"]) ?? "many"
                let fkColumn = fkC.map { tables[fkT].columns[$0] }
                if let fkC { tables[fkT].columns[fkC].isForeignKey = true }
                let from = RefEndpoint(tableID: tables[fkT].id, columnID: fkColumn?.id,
                                       cardinality: fkCard.lowercased().contains("many") ? .many : .one,
                                       isOptional: fkCard.lowercased().hasPrefix("zero"))
                let to = RefEndpoint(tableID: tables[keyT].id, columnID: keyC.map { tables[keyT].columns[$0].id },
                                     cardinality: keyCard.lowercased().contains("many") ? .many : .one,
                                     isOptional: keyCard.lowercased().hasPrefix("zero") || fkColumn.map { !$0.isNotNull && !$0.isPrimaryKey } ?? false)
                refs.append(Ref(id: id, kind: .reference, name: string(r["name"]), from: from, to: to, line: lines.line(ofID: id) ?? 1))
                for t in [pid, cid] where !(raw[t]?["relations"] as? [Any] ?? []).contains(where: { $0 as? String == id }) {
                    warn(id, "\(label): not listed in \(names[t]!).relations")
                }
            }

            // Containment lines: a field of one table holding an embedded document type.
            let rawLines = (root["lines"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
            var contained: Set<String> = []  // "tableID#columnID"
            var parentsOf: [String: [String]] = [:]
            for (id, l) in rawLines.sorted(by: { (lines.line(ofID: $0.key) ?? 0) < (lines.line(ofID: $1.key) ?? 0) }) {
                guard let pid = string(l["parent"]), let cid = string(l["child"]) else { continue }
                let colID = string(l["parentTableColId"])
                guard string(l["name"]) == DMM.containmentLine || colID != nil else { continue }
                guard let pi = index[pid], let ci = index[cid] else {
                    if raw[pid] == nil || raw[cid] == nil { warn(id, "containment line \(id.prefix(8)): points to a table that doesn't exist") }
                    continue
                }
                let col = colID.flatMap { tables[pi].columnIndex(id: $0) }
                if colID != nil, col == nil { warn(id, "containment line from \(tables[pi].name): its field doesn't exist") }
                if let col, tables[pi].columns[col].embeddedTableID != cid {
                    warn(id, "containment line \(tables[pi].name).\(tables[pi].columns[col].name) → \(tables[ci].name): the field's type is \(tables[pi].columns[col].type)")
                }
                if !tables[ci].isEmbeddable { warn(id, "\(tables[ci].name) is contained in \(tables[pi].name) but isn't marked embeddable") }
                for t in [pid, cid] where !(raw[t]?["lines"] as? [Any] ?? []).contains(where: { $0 as? String == id }) {
                    warn(id, "containment line \(tables[pi].name) → \(tables[ci].name): not listed in \(names[t]!).lines")
                }
                let column = col.map { tables[pi].columns[$0] }
                if let column { contained.insert("\(pid)#\(column.id)") }
                parentsOf[cid, default: []].append(column.map { "\(tables[pi].name).\($0.name)" } ?? tables[pi].name)
                refs.append(embedding(id: id, parent: tables[pi], column: column, child: cid, line: lines.line(ofID: id) ?? 1))
            }
            // A field typed as an embeddable without a line still shows its link.
            for t in tables {
                for c in t.columns {
                    guard let e = c.embeddedTableID, index[e] != nil, !contained.contains("\(t.id)#\(c.id)") else { continue }
                    warn(c.id, "\(t.name).\(c.name): no containment line to \(names[e]!)")
                    parentsOf[e, default: []].append("\(t.name).\(c.name)")
                    refs.append(embedding(id: "synthetic:\(t.id)#\(c.id)", parent: t, column: c, child: e, line: lines.line(ofID: c.id) ?? t.line))
                }
            }
            for (e, parents) in parentsOf where parents.count > 1 {
                warn(e, "\(names[e]!) is embedded in several places (\(parents.joined(separator: ", "))); each parent should have its own copy")
            }
            for t in tables where t.isEmbeddable && parentsOf[t.id] == nil {
                warn(t.id, "\(t.name) is embeddable but no field uses it")
            }

            // Diagrams.
            let rawDiagrams = (root["diagrams"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
            var ordered: Set<String> = []
            var order = (root["diagramsOrder"] as? [Any] ?? []).compactMap { $0 as? String }.filter { rawDiagrams[$0] != nil && ordered.insert($0).inserted }
            order += rawDiagrams.keys.filter { !ordered.contains($0) }.sorted { (lines.line(ofID: $0) ?? 0) < (lines.line(ofID: $1) ?? 0) }
            let otherIDs = Set(((root["notes"] as? [String: Any]) ?? [:]).keys).union(((root["otherObjects"] as? [String: Any]) ?? [:]).keys)
            var diagrams: [Diagram] = []
            for did in order {
                let d = rawDiagrams[did]!
                var diagram = Diagram(id: did, name: string(d["name"]) ?? "Diagram", isMain: d["main"] as? Bool ?? false, description: string(d["description"]))
                for (key, value) in d["diagramItems"] as? [String: Any] ?? [:] {
                    guard let item = value as? [String: Any] else { continue }
                    let tid = string(item["referencedItemId"]) ?? key
                    guard let ti = index[tid] else {
                        if raw[tid] == nil && !otherIDs.contains(tid) { warn(did, "\(diagram.name): shows an item that doesn't exist (\(tid.prefix(8)))") }
                        continue
                    }
                    var di = DiagramItem(origin: CGPoint(x: number(item["x"]) ?? 0, y: number(item["y"]) ?? 0),
                                         width: number(item["gWidth"]) ?? 0, height: number(item["gHeight"]) ?? 0)
                    di.background = string(item["background"]).flatMap { $0.lowercased() == "transparent" ? nil : $0 }
                    di.textColor = string(item["color"])
                    di.isCollapsed = item["collapsed"] as? Bool ?? false
                    di.isResized = item["resized"] as? Bool ?? false
                    let expected = 27 + 18 * CGFloat(tables[ti].columns.count)
                    if !di.isCollapsed, !di.isResized, di.height != 0, di.height != expected {
                        warn(tid, "\(tables[ti].name): gHeight is \(Int(di.height)) in \"\(diagram.name)\", expected \(Int(expected)) (27 + \(tables[ti].columns.count) × 18)")
                    }
                    diagram.items[tid] = di
                }
                diagram.tableIDs = tables.map(\.id).filter { diagram.items[$0] != nil }
                diagrams.append(diagram)
            }
            if diagrams.isEmpty { diagrams = [Diagram(id: "main", name: "Main Diagram", isMain: true)] }
            // Tables no diagram shows go on the main one, placed automatically.
            let shown = Set(diagrams.flatMap(\.tableIDs))
            let mainIndex = diagrams.firstIndex(where: \.isMain) ?? 0
            let unshown = tables.map(\.id).filter { !shown.contains($0) }
            if !unshown.isEmpty {
                diagrams[mainIndex].tableIDs = tables.map(\.id).filter { diagrams[mainIndex].items[$0] != nil || !shown.contains($0) }
            }

            schema.tables = tables
            schema.refs = refs
            schema.diagrams = diagrams
            schema.diagnostics = diagnostics
        }

        private func embedding(id: String, parent: Table, column: Column?, child: String, line: Int) -> Ref {
            Ref(id: id, kind: .embedding, name: column.map { "\(parent.name).\($0.name)" },
                from: RefEndpoint(tableID: parent.id, columnID: column?.id, cardinality: .one, isOptional: column.map { !$0.isNotNull } ?? false),
                to: RefEndpoint(tableID: child, columnID: nil, cardinality: column?.isList == true ? .many : .one),
                line: line)
        }
    }

    static func looksLikeUUID(_ s: String) -> Bool {
        s.count == 36 && s.filter { $0 == "-" }.count == 4 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private static func jsonErrorLine(_ error: Error) -> Int? {
        let text = ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
        guard let r = text.range(of: #"line (\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[r].dropFirst(5))
    }

    private static func jsonErrorMessage(_ error: Error) -> String {
        ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
    }
}

/// A non-empty, trimmed string, or nil.
private func string(_ v: Any?) -> String? {
    switch v {
    case let s as String:
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    case let n as NSNumber: return n.stringValue
    default: return nil
    }
}

private func number(_ v: Any?) -> CGFloat? {
    switch v {
    case let n as NSNumber: return CGFloat(n.doubleValue)
    case let s as String: return Double(s).map { CGFloat($0) }
    default: return nil
    }
}

/// Line numbers of objects in the source, found by their `"id": "…"` member, so diagnostics
/// and the inspector can point at the right spot in the JSON.
struct LineIndex {
    private var lines: [String: Int] = [:]

    init(_ source: String) {
        var line = 1
        let bytes = Array(source.utf8)
        let key = Array(#""id""#.utf8)
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b == UInt8(ascii: "\n") { line += 1; i += 1; continue }
            if b == UInt8(ascii: "\""), i + key.count <= n, bytes[i..<(i + key.count)].elementsEqual(key) {
                // Skip `: "` and read the value.
                var j = i + key.count
                while j < n, bytes[j] == UInt8(ascii: " ") || bytes[j] == UInt8(ascii: ":") || bytes[j] == UInt8(ascii: "\t") { j += 1 }
                if j < n, bytes[j] == UInt8(ascii: "\"") {
                    let start = j + 1
                    var end = start
                    while end < n, bytes[end] != UInt8(ascii: "\""), bytes[end] != UInt8(ascii: "\n") { end += 1 }
                    if let value = String(bytes: bytes[start..<end], encoding: .utf8), lines[value] == nil { lines[value] = line }
                    i = end
                    continue
                }
                i = j
                continue
            }
            i += 1
        }
    }

    func line(ofID id: String) -> Int? { lines[id] }
}
