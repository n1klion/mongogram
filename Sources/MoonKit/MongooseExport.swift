import Foundation

/// Turns a Moon Modeler model into Mongoose schema code: one schema per collection and embedded
/// document type, no models. Pass the whole file, not a diagram, so every
/// embedded type and reference target is there.
public enum MongooseExport {
    public enum Format: String, CaseIterable, Sendable {
        case commonJS, esModule, typeScript

        public var title: String {
            switch self {
            case .commonJS: "JavaScript (CommonJS)"
            case .esModule: "JavaScript (ES Module)"
            case .typeScript: "TypeScript"
            }
        }

        public var fileExtension: String {
            switch self {
            case .commonJS: "js"
            case .esModule: "mjs"
            case .typeScript: "ts"
            }
        }
    }

    public static func generate(_ schema: Schema, format: Format = .commonJS, sourceName: String? = nil) -> String {
        var g = Generator(schema: schema, format: format)
        return g.run(sourceName: sourceName)
    }

    /// Mongoose types by lowercased Moon Modeler datatype; JS globals where Mongoose accepts them.
    static let types: [String: String] = [
        "string": "String", "number": "Number", "boolean": "Boolean", "bool": "Boolean", "date": "Date",
        "buffer": "Buffer", "array": "Array", "map": "Map",
        "objectid": "Schema.Types.ObjectId", "mixed": "Schema.Types.Mixed", "object": "Schema.Types.Mixed",
        "decimal128": "Schema.Types.Decimal128", "uuid": "Schema.Types.UUID", "bigint": "Schema.Types.BigInt",
        "double": "Schema.Types.Double", "int32": "Schema.Types.Int32",
    ]

    static let reserved: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
        "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof",
        "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void",
        "while", "with", "yield", "let", "static", "implements", "interface", "package", "private", "protected",
        "public", "await", "arguments", "eval", "undefined", "mongoose", "Schema", "model", "InferSchemaType",
    ]

    /// `Schema.reserved` in Mongoose: allowed as field names, but they shadow document methods.
    static let reservedPaths: Set<String> = [
        "validate", "toObject", "save", "remove", "populated", "isNew", "isModified", "init", "get", "errors",
        "collection", "removeListener", "listeners", "emit", "prototype", "on", "schema", "db",
    ]

    static func isIdentifier(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
    }

    static func quoted(_ s: String) -> String {
        var out = "'"
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "'"
    }

    static func key(_ s: String) -> String { isIdentifier(s) ? s : quoted(s) }

    /// One line, safe after `//`.
    static func lineComment(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private struct Generator {
    let schema: Schema
    let format: MongooseExport.Format
    var out: [String] = []
    var used: Set<String> = []
    var schemaVar: [String: String] = [:]
    /// "table#column" -> referenced collection, from relations.
    var refTarget: [String: [Ref]] = [:]
    /// Embedding fields that would close a cycle; they fall back to Mixed.
    var cyclic: Set<String> = []

    init(schema: Schema, format: MongooseExport.Format) {
        self.schema = schema
        self.format = format
        for r in schema.refs where r.kind == .reference {
            guard let c = r.from.columnID else { continue }
            refTarget["\(r.from.tableID)#\(c)", default: []].append(r)
        }
    }

    mutating func identifier(_ base: String) -> String {
        var s = String(base.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" ? $0 : "_" })
        if s.isEmpty || s.first!.isNumber { s = "_" + s }
        if MongooseExport.reserved.contains(s) { s += "_" }
        var candidate = s, n = 2
        while !used.insert(candidate).inserted {
            candidate = "\(s)\(n)"
            n += 1
        }
        return candidate
    }

    /// Tables in sidebar order, each after the embedded types its fields use.
    mutating func ordered() -> [Table] {
        var result: [Table] = [], state: [String: Bool] = [:]  // false = in progress, true = done
        func visit(_ t: Table, _ g: inout Generator) {
            if state[t.id] != nil { return }
            state[t.id] = false
            for c in t.columns {
                guard let e = c.embeddedTableID, let target = g.schema.table(id: e) else { continue }
                if state[e] == false { g.cyclic.insert("\(t.id)#\(c.id)"); continue }
                visit(target, &g)
            }
            state[t.id] = true
            result.append(t)
        }
        // Embedded types first so they read as building blocks, then collections.
        for t in schema.tables where t.isEmbeddable { visit(t, &self) }
        for t in schema.tables { visit(t, &self) }
        return result
    }

    mutating func run(sourceName: String?) -> String {
        let tables = ordered()
        for t in tables { schemaVar[t.id] = identifier(t.name + "Schema") }

        let title = [schema.name.isEmpty ? nil : "\"\(schema.name)\"", sourceName.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        out.append("// Mongoose schemas generated by MongoGram\(title.isEmpty ? "" : " from " + title).")
        out.append("// Moon Modeler descriptions and comments are kept as comments.")
        switch format {
        case .commonJS:
            out += ["'use strict';", "", "const mongoose = require('mongoose');", "", "const { Schema } = mongoose;"]
        case .esModule:
            out += ["", "import mongoose from 'mongoose';", "", "const { Schema } = mongoose;"]
        case .typeScript:
            out += ["", "import { Schema, type InferSchemaType } from 'mongoose';"]
        }

        for t in tables { emitSchema(t) }

        if format == .typeScript {
            var typeNames: Set<String> = []
            out.append("")
            for t in tables {
                var name = schemaVar[t.id]!.dropLast("Schema".count)
                name = name.prefix(1).uppercased() + name.dropFirst()
                var candidate = String(name), n = 2
                while !typeNames.insert(candidate).inserted { candidate = "\(name)\(n)"; n += 1 }
                out.append("export type \(candidate) = InferSchemaType<typeof \(schemaVar[t.id]!)>;")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    mutating func emitSchema(_ t: Table) {
        let export = format == .commonJS ? "" : "export "
        out.append("")
        if let note = t.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            out.append("/**")
            for line in note.components(separatedBy: .newlines) {
                let safe = line.replacingOccurrences(of: "*/", with: "*\\/")
                out.append(safe.isEmpty ? " *" : " * " + safe)
            }
            out.append(" */")
        }
        out.append("\(export)const \(schemaVar[t.id]!) = new Schema({")
        var seen: Set<String> = []
        for c in t.columns {
            if !seen.insert(c.name).inserted {
                out.append("  // \(MongooseExport.key(c.name)): skipped, the field appears twice in \(t.name).")
                continue
            }
            // Mongoose adds an ObjectId _id to every document; declaring it would stop that.
            if c.name == "_id" && c.datatype.lowercased() == "objectid" && c.embeddedTableID == nil { continue }
            out.append(field(c, in: t))
        }
        let hasID = t.columns.contains { $0.name == "_id" }
        var options: [String] = []
        if t.isEmbeddable && !hasID { options.append("_id: false") }
        if !t.isEmbeddable { options.append("collection: \(MongooseExport.quoted(t.name))") }
        out.append(options.isEmpty ? "});" : "}, { \(options.joined(separator: ", ")) });")
        for index in t.indexes where !index.columns.isEmpty {
            let fields = index.columns.map { "\(MongooseExport.key($0)): 1" }.joined(separator: ", ")
            var opts: [String] = []
            if index.isUnique { opts.append("unique: true") }
            if let n = index.name, !n.isEmpty { opts.append("name: \(MongooseExport.quoted(n))") }
            out.append("\(schemaVar[t.id]!).index({ \(fields) }\(opts.isEmpty ? "" : ", { \(opts.joined(separator: ", ")) }"));")
        }
    }

    func field(_ c: Column, in t: Table) -> String {
        var notes: [String] = []
        var type: String
        if let e = c.embeddedTableID, let target = schema.table(id: e), !cyclic.contains("\(t.id)#\(c.id)") {
            type = schemaVar[target.id]!
        } else if c.embeddedTableID != nil {
            type = "Schema.Types.Mixed"
            notes.append("embeds \(schema.table(id: c.embeddedTableID!)?.name ?? "?") recursively")
        } else if let known = MongooseExport.types[c.datatype.lowercased()] {
            type = known
        } else {
            type = "Schema.Types.Mixed"
            notes.append(DMM.looksLikeUUID(c.datatype) ? "type \(c.datatype) is not in this model" : "Moon Modeler type \(c.datatype)")
        }
        if c.isList { type = "[\(type)]" }

        var parts = ["type: \(type)"]
        if c.isNotNull { parts.append("required: true") }
        let refs = refTarget["\(t.id)#\(c.id)"] ?? []
        for (i, r) in refs.enumerated() {
            guard let target = schema.table(id: r.to.tableID) else { continue }
            let key = r.to.columnID.flatMap { id in target.columns.first { $0.id == id }?.name }
            if target.isEmbeddable {
                notes.append("references embedded type \(target.name)")
            } else if i > 0 {
                notes.append("also references \(target.name)")
            } else {
                parts.append("ref: \(MongooseExport.quoted(target.name))")
                if let key, key != "_id" { notes.append("matches \(target.name).\(key), not _id") }
            }
        }
        if let o = c.options?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))), !o.isEmpty {
            parts.append(o)
        }
        if MongooseExport.reservedPaths.contains(c.name) { notes.append("\(c.name) is reserved by Mongoose and shadows a document method") }
        if let note = c.note.map(MongooseExport.lineComment), !note.isEmpty { notes.insert(note, at: 0) }
        let line = "  \(MongooseExport.key(c.name)): { \(parts.joined(separator: ", ")) },"
        return notes.isEmpty ? line : line + " // " + notes.joined(separator: "; ")
    }
}
