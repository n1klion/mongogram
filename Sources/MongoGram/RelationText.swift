import MoonKit

/// Human-readable pieces of a reference or containment line, shared by the canvas tooltip and the inspector.
struct RelationText {
    let ref: Ref
    let schema: Schema

    init(_ ref: Ref, schema: Schema) {
        self.ref = ref
        self.schema = schema
    }

    var from: String { endpoint(ref.from) }
    var to: String { endpoint(ref.to) }

    func tableName(_ id: String) -> String { schema.table(id: id)?.name ?? "?" }

    func columnName(_ e: RefEndpoint) -> String? {
        guard let id = e.columnID, let t = schema.table(id: e.tableID), let i = t.columnIndex(id: id) else { return nil }
        return t.columns[i].name
    }

    var title: String {
        if ref.kind == .embedding { return "Embedded document" }
        return ref.name ?? "Reference"
    }

    var kind: String {
        if ref.kind == .embedding { return ref.to.cardinality == .many ? "array of subdocuments" : "subdocument" }
        let base: String
        switch (ref.from.cardinality, ref.to.cardinality) {
        case (.many, .one): base = "many-to-one"
        case (.one, .many): base = "one-to-many"
        case (.one, .one): base = "one-to-one"
        case (.many, .many): base = "many-to-many"
        }
        return ref.from.isOptional || ref.to.isOptional ? base + ", optional" : base
    }

    /// "one", "many", "zero or one", "zero or many".
    static func side(_ e: RefEndpoint) -> String {
        let base = e.cardinality == .many ? "many" : "one"
        return e.isOptional ? "zero or \(base)" : base
    }

    /// A plain-language explanation of what the line means.
    var sentence: String {
        let a = tableName(ref.from.tableID), b = tableName(ref.to.tableID)
        let field = columnName(ref.from).map { "\(a).\($0)" } ?? a
        if ref.kind == .embedding {
            let what = ref.to.cardinality == .many ? "an array of \(b) subdocuments" : "a \(b) subdocument"
            let optional = ref.from.isOptional ? " The field is optional." : ""
            return "Every \(a) document stores \(what) inline in \(field), not in a separate collection.\(optional)"
        }
        let key = columnName(ref.to).map { "\(b).\($0)" } ?? b
        var s: String
        switch (ref.from.cardinality, ref.to.cardinality) {
        case (.one, .one):
            s = "Each \(a) document matches at most one \(b) document through \(field) → \(key), and the other way round."
        case (.many, .many):
            s = "Documents of \(a) and \(b) can be linked in any combination."
        default:
            s = "Each \(a) document points to one \(b) document: \(field) holds a \(key) value. A \(b) document can be referenced by many \(a) documents."
        }
        if ref.to.isOptional { s += " \(field) may be empty, so a \(a) document doesn't have to point anywhere." }
        return s
    }

    func endpoint(_ e: RefEndpoint) -> String {
        columnName(e).map { "\(tableName(e.tableID)).\($0)" } ?? tableName(e.tableID)
    }
}
