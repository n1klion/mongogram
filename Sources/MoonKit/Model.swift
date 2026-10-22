import CoreGraphics
import Foundation

/// A Moon Modeler model: collections, embedded document types, references between them and diagrams.
public struct Schema: Sendable, Equatable {
    public var name: String = ""
    public var databaseType: String?
    public var note: String?
    /// Visible tables in the order of the Moon Modeler sidebar.
    public var tables: [Table] = [] { didSet { reindex() } }
    private var tableIndex: [String: Int] = [:]
    /// References (foreign keys) first, then containment lines of embedded documents.
    public var refs: [Ref] = []
    public var diagrams: [Diagram] = []
    public var diagnostics: [Diagnostic] = []

    public init() {}

    public func table(id: String) -> Table? { tableIndex[id].map { tables[$0] } }

    public func diagram(id: String?) -> Diagram? {
        guard let id else { return nil }
        return diagrams.first { $0.id == id }
    }

    /// The diagram to show first: the one marked main, else the first.
    public var mainDiagram: Diagram? { diagrams.first(where: \.isMain) ?? diagrams.first }

    /// True when the file couldn't be read at all, as opposed to a model with some problems.
    public var isUnreadable: Bool { tables.isEmpty && diagnostics.contains { $0.severity == .error } }

    private mutating func reindex() {
        tableIndex = Dictionary(tables.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// A collection, or an embeddable (nested document type) when `isEmbeddable` is set.
public struct Table: Sendable, Equatable, Identifiable {
    /// Moon Modeler UUID; positions and selection are keyed by it, so renames keep their place.
    public var id: String
    public var name: String
    public var columns: [Column] = []
    public var indexes: [Index] = []
    public var isEmbeddable = false
    public var note: String?
    public var line: Int

    public var displayName: String { name }

    public func columnIndex(id: String) -> Int? { columns.firstIndex { $0.id == id } }
}

public struct Column: Sendable, Equatable {
    public var id: String
    public var name: String
    /// Raw datatype: a type name like `String`, or the UUID of an embeddable table.
    public var datatype: String
    /// The type as shown: `String`, `[Number]`, or the embedded table's name.
    public var type: String
    /// Set when the column holds an embedded document (or an array of them).
    public var embeddedTableID: String?
    public var param: String?
    public var isPrimaryKey = false
    public var isNotNull = false
    public var isList = false
    public var isForeignKey = false
    public var note: String?
    /// Moon Modeler's sample data.
    public var sample: String?
    public var options: String?
}

public struct Index: Sendable, Equatable {
    public var name: String?
    public var columns: [String]
    public var isUnique = false
}

public enum Cardinality: Sendable, Equatable {
    case one, many
}

public struct RefEndpoint: Sendable, Equatable {
    public var tableID: String
    /// Nil for the embedded side of a containment line, which attaches to the table header.
    public var columnID: String?
    public var cardinality: Cardinality
    /// Rows on the other side don't have to have a match here.
    public var isOptional = false

    public var columns: [String] { columnID.map { [$0] } ?? [] }
}

public struct Ref: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A relation: `from` holds the foreign key, `to` the referenced key.
        case reference
        /// A containment line: `from` is the field, `to` the embedded document type.
        case embedding
    }

    public var id: String
    public var kind: Kind
    public var name: String?
    public var from: RefEndpoint
    public var to: RefEndpoint
    public var line: Int

    /// The side that owns the key being pointed at, or the containing document; used for layout direction.
    public var parent: RefEndpoint { kind == .reference ? to : from }
    public var child: RefEndpoint { kind == .reference ? from : to }
}

/// One Moon Modeler diagram (the main one or a sub-diagram) with the tables it shows.
public struct Diagram: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var isMain = false
    public var description: String?
    /// Table id -> how the table is drawn in this diagram.
    public var items: [String: DiagramItem] = [:]
    /// Ids of shown tables in sidebar order.
    public var tableIDs: [String] = []
}

public struct DiagramItem: Sendable, Equatable {
    public var origin: CGPoint
    public var width: CGFloat
    public var height: CGFloat
    /// Header color; nil when transparent (embeddables).
    public var background: String?
    public var textColor: String?
    public var isCollapsed = false
    public var isResized = false
}

public struct Diagnostic: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: Sendable { case error, warning }
    public var severity: Severity
    public var line: Int
    public var message: String

    public var description: String { "line \(line): \(message)" }
}
