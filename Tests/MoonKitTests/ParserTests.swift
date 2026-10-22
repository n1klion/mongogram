import CoreGraphics
import Foundation
import Testing
@testable import MoonKit

/// A small model in the shape Moon Modeler writes: a relation whose `parent` holds the foreign key,
/// an embedded document with its containment line, a sub-diagram and a hidden table.
private let fixture = #"""
{
  "tables": {
    "T-USERS": {
      "id": "T-USERS", "visible": true, "name": "users", "desc": "people",
      "cols": [
        { "id": "C-U-ID", "name": "_id", "datatype": "ObjectId", "param": "", "pk": true, "nn": true, "list": false, "fk": false, "comment": "" },
        { "id": "C-U-PROFILE", "name": "profile", "datatype": "T-PROFILE", "param": "", "pk": false, "nn": true, "list": false, "fk": false, "comment": "" },
        { "id": "C-U-TAGS", "name": "tags", "datatype": "String", "param": "", "pk": false, "nn": false, "list": true, "fk": false, "comment": "free text" }
      ],
      "relations": ["R-1"], "lines": ["L-1"], "keys": [{ "id": "K-USERS", "name": "Primary", "isPk": true, "cols": [{ "id": "x", "colid": "C-U-ID" }] }],
      "indexes": [], "embeddable": false
    },
    "T-PROFILE": {
      "id": "T-PROFILE", "visible": true, "name": "users_profile", "desc": "",
      "cols": [ { "id": "C-P-BIO", "name": "bio", "datatype": "String", "pk": false, "nn": false, "list": false, "fk": false } ],
      "relations": [], "lines": ["L-1"], "keys": [], "indexes": [], "embeddable": true
    },
    "T-POSTS": {
      "id": "T-POSTS", "visible": true, "name": "posts", "desc": "",
      "cols": [
        { "id": "C-P-ID", "name": "_id", "datatype": "ObjectId", "pk": true, "nn": true, "list": false, "fk": false },
        { "id": "C-P-AUTHOR", "name": "authorId", "datatype": "ObjectId", "pk": false, "nn": false, "list": false, "fk": true }
      ],
      "relations": ["R-1"], "lines": [], "keys": [], "indexes": [], "embeddable": false
    },
    "T-HIDDEN": { "id": "T-HIDDEN", "visible": false, "name": "hidden", "cols": [], "relations": [], "lines": [], "keys": [], "embeddable": false }
  },
  "relations": {
    "R-1": {
      "id": "R-1", "name": "posts_users", "type": "identifying", "parent": "T-POSTS", "child": "T-USERS", "parent_key": "K-USERS",
      "cols": [{ "id": "RC-1", "parentcol": "C-P-AUTHOR", "childcol": "C-U-ID" }], "c_p": "one", "c_ch": "many"
    }
  },
  "notes": {},
  "lines": {
    "L-1": { "id": "L-1", "name": "containment-line", "parent": "T-USERS", "child": "T-PROFILE", "parentTableColId": "C-U-PROFILE", "childTableColId": "" }
  },
  "model": { "name": "Fixture", "type": "MONGOOSE" },
  "otherObjects": {},
  "diagrams": {
    "D-MAIN": {
      "id": "D-MAIN", "name": "Main Diagram", "main": true,
      "diagramItems": {
        "T-USERS": { "referencedItemId": "T-USERS", "x": 40, "y": 60, "gHeight": 81, "gWidth": 220, "color": "#ffffff", "background": "#03a9f4", "collapsed": false, "resized": false },
        "T-PROFILE": { "referencedItemId": "T-PROFILE", "x": 300, "y": 60, "gHeight": 45, "gWidth": 220, "background": "transparent", "collapsed": false },
        "T-POSTS": { "referencedItemId": "T-POSTS", "x": 40, "y": 300, "gHeight": 99, "gWidth": 220, "background": "#e91e63", "collapsed": false }
      }
    },
    "D-SUB": {
      "id": "D-SUB", "name": "Posts only", "main": false,
      "diagramItems": { "T-POSTS": { "referencedItemId": "T-POSTS", "x": 0, "y": 0, "gHeight": 63, "gWidth": 200 } }
    }
  },
  "diagramsOrder": ["D-MAIN", "D-SUB"],
  "order": ["T-USERS", "T-PROFILE", "T-POSTS", "T-HIDDEN"]
}
"""#

@Test func parsesTablesAndColumns() {
    let s = DMM.parse(fixture)
    #expect(s.name == "Fixture")
    #expect(s.databaseType == "MONGOOSE")
    #expect(s.tables.map(\.name) == ["users", "users_profile", "posts"])  // hidden table left out, sidebar order kept
    let users = s.table(id: "T-USERS")!
    #expect(users.note == "people")
    #expect(users.columns[0].isPrimaryKey)
    #expect(users.columns[1].embeddedTableID == "T-PROFILE")
    #expect(users.columns[1].type == "users_profile")
    #expect(users.columns[2].type == "[String]")
    #expect(users.columns[2].note == "free text")
    #expect(s.table(id: "T-PROFILE")!.isEmbeddable)
}

@Test func relationPointsFromForeignKeyToKey() {
    let s = DMM.parse(fixture)
    let r = s.refs.first { $0.kind == .reference }!
    #expect(r.from.tableID == "T-POSTS")
    #expect(r.from.columnID == "C-P-AUTHOR")
    #expect(r.from.cardinality == .many)
    #expect(r.to.tableID == "T-USERS")
    #expect(r.to.columnID == "C-U-ID")
    #expect(r.to.cardinality == .one)
    #expect(r.to.isOptional)  // authorId is not required
    #expect(r.parent.tableID == "T-USERS")
    #expect(s.table(id: "T-POSTS")!.columns[1].isForeignKey)
}

@Test func relationDirectionIsFoundEvenWhenParentAndChildAreSwapped() {
    // Moon Modeler's own relations may name the referenced table "parent".
    let swapped = fixture
        .replacingOccurrences(of: #""parent": "T-POSTS", "child": "T-USERS""#, with: #""parent": "T-USERS", "child": "T-POSTS""#)
        .replacingOccurrences(of: #""parentcol": "C-P-AUTHOR", "childcol": "C-U-ID""#, with: #""parentcol": "C-U-ID", "childcol": "C-P-AUTHOR""#)
    let r = DMM.parse(swapped).refs.first { $0.kind == .reference }!
    #expect(r.from.tableID == "T-POSTS")
    #expect(r.to.tableID == "T-USERS")
}

@Test func containmentLineBecomesEmbedding() {
    let s = DMM.parse(fixture)
    let e = s.refs.first { $0.kind == .embedding }!
    #expect(e.from.tableID == "T-USERS")
    #expect(e.from.columnID == "C-U-PROFILE")
    #expect(e.to.tableID == "T-PROFILE")
    #expect(e.to.columnID == nil)
    #expect(e.to.cardinality == .one)
    #expect(e.parent.tableID == "T-USERS")
}

@Test func diagramsKeepOrderPositionsAndColors() {
    let s = DMM.parse(fixture)
    #expect(s.diagrams.map(\.name) == ["Main Diagram", "Posts only"])
    #expect(s.mainDiagram?.id == "D-MAIN")
    let main = s.diagrams[0]
    #expect(main.tableIDs == ["T-USERS", "T-PROFILE", "T-POSTS"])
    #expect(main.items["T-USERS"]?.origin == CGPoint(x: 40, y: 60))
    #expect(main.items["T-USERS"]?.width == 220)
    #expect(main.items["T-USERS"]?.background == "#03a9f4")
    #expect(main.items["T-PROFILE"]?.background == nil)
    #expect(s.diagrams[1].tableIDs == ["T-POSTS"])
}

@Test func validFixtureHasOnlyTheExpectedWarning() {
    // The main diagram's posts box is too tall on purpose: 99 instead of 27 + 2 × 18 = 63.
    let s = DMM.parse(fixture)
    #expect(s.diagnostics.count == 1)
    #expect(s.diagnostics.first?.message.contains("gHeight is 99") == true)
}

@Test func reportsBrokenReferencesWithLineNumbers() {
    var broken = fixture.replacingOccurrences(of: #""datatype": "T-PROFILE""#, with: #""datatype": "00000000-0000-0000-0000-000000000000""#)
    broken = broken.replacingOccurrences(of: #""childcol": "C-U-ID""#, with: #""childcol": "C-NOPE""#)
    let s = DMM.parse(broken)
    let messages = s.diagnostics.map(\.message)
    #expect(messages.contains { $0.contains("is not a table in this file") })
    #expect(messages.contains { $0.contains("a column of this relation doesn't exist") })
    let typeIssue = s.diagnostics.first { $0.message.contains("is not a table") }!
    #expect(typeIssue.line == 7)  // the line of C-U-PROFILE
}

@Test func fieldWithoutContainmentLineStillLinks() {
    let noLine = fixture.replacingOccurrences(of: #""L-1": { "id": "L-1", "name": "containment-line", "parent": "T-USERS", "child": "T-PROFILE", "parentTableColId": "C-U-PROFILE", "childTableColId": "" }"#, with: "")
    let s = DMM.parse(noLine)
    #expect(s.refs.contains { $0.kind == .embedding && $0.to.tableID == "T-PROFILE" })
    #expect(s.diagnostics.contains { $0.message.contains("no containment line") })
}

@Test func invalidJSONIsAnErrorWithALine() {
    let s = DMM.parse("{\n  \"tables\": {\n    \"a\": ,\n  }\n}")
    #expect(s.isUnreadable)
    #expect(s.diagnostics.first?.line == 3)
    #expect(DMM.parse("[1, 2]").isUnreadable)
    #expect(DMM.parse("").isUnreadable)
}

@Test func filesWithoutDiagramsGetOne() {
    let s = DMM.parse(#"{ "tables": { "A": { "id": "A", "name": "a", "cols": [] } } }"#)
    #expect(s.diagrams.count == 1)
    #expect(s.diagrams[0].tableIDs == ["A"])
    #expect(s.diagrams[0].items.isEmpty)
}

@Test func layoutPlacesEmbeddedDocumentsRightOfTheirParent() {
    let s = DMM.parse(fixture)
    let sizes = Dictionary(uniqueKeysWithValues: s.tables.map { ($0.id, CGSize(width: 200, height: 100)) })
    let p = SchemaLayout.compute(schema: s, tableIDs: s.tables.map(\.id), sizes: sizes)
    #expect(p.count == 3)
    #expect(p["T-PROFILE"]!.x > p["T-USERS"]!.x)
    #expect(p["T-POSTS"]!.x > p["T-USERS"]!.x)
}

@Test func samplesParseCleanly() throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../samples").standardized
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "dmm" }
    #expect(files.count >= 2)
    for f in files {
        let s = DMM.parse(try String(contentsOf: f, encoding: .utf8))
        #expect(s.diagnostics.isEmpty, "\(f.lastPathComponent): \(s.diagnostics)")
        #expect(!s.tables.isEmpty)
        #expect(s.diagrams.allSatisfy { !$0.tableIDs.isEmpty })
    }
}

@Test func duplicatesInOrderListsAreIgnored() {
    let dup = fixture
        .replacingOccurrences(of: #""order": ["T-USERS","#, with: #""order": ["T-USERS", "T-USERS", "T-POSTS","#)
        .replacingOccurrences(of: #""diagramsOrder": ["D-MAIN", "D-SUB"]"#, with: #""diagramsOrder": ["D-MAIN", "D-SUB", "D-MAIN"]"#)
    let s = DMM.parse(dup)
    #expect(s.tables.map(\.name) == ["users", "posts", "users_profile"])
    #expect(s.diagrams.count == 2)
}

@Test func mongooseExportMapsFieldsEmbeddingsAndRefs() {
    let code = MongooseExport.generate(DMM.parse(fixture), format: .commonJS)
    let profile = code.range(of: "const users_profileSchema = new Schema({")!
    let users = code.range(of: "const usersSchema = new Schema({")!
    #expect(profile.lowerBound < users.lowerBound)  // embedded types come before the schemas that use them
    #expect(code.contains("  bio: { type: String },\n}, { _id: false });"))
    #expect(!code.contains("_id: { type"))  // Mongoose adds _id itself
    #expect(code.contains("  profile: { type: users_profileSchema, required: true },"))
    #expect(code.contains("  tags: { type: [String] }, // free text"))
    #expect(code.contains("  authorId: { type: Schema.Types.ObjectId, ref: 'users' },"))
    #expect(code.contains("}, { collection: 'posts' });"))
    #expect(!code.contains("mongoose.model("))
    #expect(!code.contains("module.exports"))
    #expect(code.contains("/**\n * people\n */\nconst usersSchema"))
}

@Test func mongooseExportSkipsDuplicatesAndEscapes() {
    let odd = fixture
        .replacingOccurrences(of: #""name": "tags""#, with: #""name": "bio""#)
        .replacingOccurrences(of: #""name": "bio", "datatype": "String", "pk""#, with: #""name": "my-bio", "datatype": "Thing", "pk""#)
        .replacingOccurrences(of: #""desc": "people""#, with: #""desc": "a */ b""#)
    var s = DMM.parse(odd)
    s.tables[0].columns.append(s.tables[0].columns[2])
    let code = MongooseExport.generate(s, format: .typeScript)
    #expect(code.contains("  // bio: skipped, the field appears twice in users."))
    #expect(MongooseExport.generate(DMM.parse(fixture.replacingOccurrences(of: #""name": "tags""#, with: #""name": "isNew""#))).contains("// free text; isNew is reserved by Mongoose"))
    #expect(code.contains("  'my-bio': { type: Schema.Types.Mixed }, // Moon Modeler type Thing"))
    #expect(code.contains(" * a *\\/ b"))
    #expect(code.contains("export type Users = InferSchemaType<typeof usersSchema>;"))
}
