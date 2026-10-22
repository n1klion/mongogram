import CoreGraphics
import Foundation
import Testing
@testable import MoonKit

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized

/// The samples, plus the local `examples/` models when they are there (they aren't in the repo).
private func models() throws -> [(name: String, schema: Schema)] {
    var result: [(String, Schema)] = []
    for dir in ["samples", "examples"] {
        let url = root.appendingPathComponent(dir)
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "dmm" {
            result.append((f.lastPathComponent, DMM.parse(try String(contentsOf: f, encoding: .utf8))))
        }
    }
    return result
}

/// Each diagram's tables, sized like the canvas sizes them.
private func diagrams(_ s: Schema) -> [(name: String, ids: [String], sizes: [String: CGSize])] {
    s.diagrams.map { d in
        let ids = d.tableIDs.filter { s.table(id: $0) != nil }
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, CGSize(width: d.items[id]?.width ?? 220, height: 27 + 18 * CGFloat(s.table(id: id)!.columns.count)))
        })
        return (d.name, ids, sizes)
    }
}

@Test(arguments: LayoutStyle.allCases)
func stylesPlaceEveryTableWithoutOverlaps(_ style: LayoutStyle) throws {
    let all = try models()
    #expect(all.count >= 2)
    for (name, s) in all {
        for d in diagrams(s) {
            let pos = SchemaLayout.compute(schema: s, tableIDs: d.ids, sizes: d.sizes, style: style)
            #expect(Set(pos.keys) == Set(d.ids), "\(name) / \(d.name) \(style): \(pos.count) of \(d.ids.count) placed")
            let rects = d.ids.map { CGRect(origin: pos[$0] ?? .zero, size: d.sizes[$0]!) }
            var overlaps = 0
            for i in rects.indices { for j in rects.indices where j > i && rects[i].intersects(rects[j]) { overlaps += 1 } }
            #expect(overlaps == 0, "\(name) / \(d.name) \(style): \(overlaps) overlapping tables")
        }
    }
}

@Test func pipelineFollowsReferences() throws {
    for (name, s) in try models() {
        for d in diagrams(s) {
            let ids = Set(d.ids)
            let pos = SchemaLayout.compute(schema: s, tableIDs: d.ids, sizes: d.sizes, style: .pipeline)
            let owner = SchemaLayout.owners(s, ids)
            let refs = s.refs.filter { $0.kind == .reference && ids.contains($0.from.tableID) && ids.contains($0.to.tableID) }
            var next: [String: Set<String>] = [:]
            for r in refs { let a = owner[r.parent.tableID]!, b = owner[r.child.tableID]!; if a != b { next[a, default: []].insert(b) } }
            func reaches(_ from: String, _ to: String) -> Bool {
                var stack = [from], seen: Set<String> = [from]
                while let n = stack.popLast() {
                    if n == to { return true }
                    for m in next[n] ?? [] where seen.insert(m).inserted { stack.append(m) }
                }
                return false
            }
            for r in refs {
                let a = owner[r.parent.tableID]!, b = owner[r.child.tableID]!
                guard a != b, !reaches(b, a) else { continue }  // same stage, or part of a cycle
                #expect(pos[a]!.x < pos[b]!.x, "\(name) / \(d.name): \(s.table(id: a)!.name) should be left of \(s.table(id: b)!.name)")
            }
            // Embedded documents sit right of the collection they belong to.
            for (id, o) in owner where id != o {
                #expect(pos[id]!.x > pos[o]!.x, "\(name) / \(d.name): \(s.table(id: id)!.name) should be right of \(s.table(id: o)!.name)")
            }
        }
    }
}

@Test func compactIsSmallerThanLeftRight() throws {
    for (name, s) in try models() {
        for d in diagrams(s) where d.ids.count >= 20 {
            func area(_ style: LayoutStyle) -> CGFloat {
                let pos = SchemaLayout.compute(schema: s, tableIDs: d.ids, sizes: d.sizes, style: style)
                let r = d.ids.map { CGRect(origin: pos[$0]!, size: d.sizes[$0]!) }.reduce(CGRect.null) { $0.union($1) }
                return r.width * r.height
            }
            #expect(area(.compact) < area(.leftRight), "\(name) / \(d.name)")
            #expect(area(.compact) <= area(.pipeline), "\(name) / \(d.name)")
        }
    }
}

@Test func leftRightIsTheDefault() throws {
    let (_, s) = try models()[0]
    let d = diagrams(s)[0]
    #expect(SchemaLayout.compute(schema: s, tableIDs: d.ids, sizes: d.sizes)
        == SchemaLayout.compute(schema: s, tableIDs: d.ids, sizes: d.sizes, style: .leftRight))
}

@Test func shelfPackKeepsOrderAndAvoidsOverlaps() {
    let items = (0..<30).map { (id: "t\($0)", size: CGSize(width: 100 + CGFloat($0 % 4) * 40, height: 60 + CGFloat($0 % 5) * 30)) }
    let pos = SchemaLayout.shelfPack(items, gapX: 10, gapY: 10)
    let rects = items.map { CGRect(origin: pos[$0.id]!, size: $0.size) }
    for i in rects.indices { for j in rects.indices where j > i { #expect(!rects[i].intersects(rects[j])) } }
    // Reading order: each item follows the previous one on its shelf, or starts the next shelf.
    let byRows = (1..<items.count).allSatisfy { i in
        let a = pos[items[i - 1].id]!, b = pos[items[i].id]!
        return b.y > a.y || (b.y == a.y && b.x > a.x)
    }
    let byColumns = (1..<items.count).allSatisfy { i in
        let a = pos[items[i - 1].id]!, b = pos[items[i].id]!
        return b.x > a.x || (b.x == a.x && b.y > a.y)
    }
    #expect(byRows || byColumns)
}
