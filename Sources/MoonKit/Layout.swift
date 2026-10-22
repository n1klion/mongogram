import CoreGraphics
import Foundation

/// Layered (Sugiyama-style) layout: referenced tables go left, referencing tables right.
/// Each connected component is laid out on its own and the components are shelf-packed.
public enum LayeredLayout {
    public struct Node {
        public var id: String
        public var size: CGSize
        public init(id: String, size: CGSize) { self.id = id; self.size = size }
    }

    public struct Edge: Hashable {
        public var parent: String
        public var child: String
        public init(parent: String, child: String) { self.parent = parent; self.child = child }
    }

    public struct Spacing {
        public var horizontal: CGFloat
        public var vertical: CGFloat
        public var component: CGFloat
        public init(horizontal: CGFloat = 110, vertical: CGFloat = 36, component: CGFloat = 90) {
            self.horizontal = horizontal; self.vertical = vertical; self.component = component
        }
    }

    /// Defaults give the classic left-right layout, folded to stay roughly 16:10.
    public struct Options {
        /// Split very tall layers into several columns.
        public var splitTallLayers = true
        /// Wrap a long chain of columns into stacked bands.
        public var wrapBands = true
        public init(splitTallLayers: Bool = true, wrapBands: Bool = true) {
            self.splitTallLayers = splitTallLayers; self.wrapBands = wrapBands
        }
    }

    /// Returns the top-left origin of every node.
    public static func layout(nodes: [Node], edges: [Edge], spacing: Spacing = Spacing(), options: Options = Options()) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let index = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var edgeSet: Set<Edge> = []
        var pairs: [(Int, Int)] = []
        for e in edges where e.parent != e.child {
            guard let a = index[e.parent], let b = index[e.child], edgeSet.insert(e).inserted else { continue }
            pairs.append((a, b))
        }

        // Union-find for connected components.
        var root = Array(0..<nodes.count)
        func find(_ x: Int) -> Int {
            var x = x
            while root[x] != x { root[x] = root[root[x]]; x = root[x] }
            return x
        }
        for (a, b) in pairs { root[find(a)] = find(b) }
        var components: [Int: [Int]] = [:]
        for i in nodes.indices { components[find(i), default: []].append(i) }

        var placed: [(members: [Int], positions: [Int: CGPoint], size: CGSize)] = []
        for members in components.values {
            let memberSet = Set(members)
            let local = pairs.filter { memberSet.contains($0.0) }
            let positions = layoutComponent(members: members.sorted(), edges: local, nodes: nodes, spacing: spacing, options: options)
            var maxX: CGFloat = 0, maxY: CGFloat = 0
            for (i, p) in positions {
                maxX = max(maxX, p.x + nodes[i].size.width)
                maxY = max(maxY, p.y + nodes[i].size.height)
            }
            placed.append((members.sorted(), positions, CGSize(width: maxX, height: maxY)))
        }

        // Biggest components first, then by source order so the result is stable.
        placed.sort {
            let a = $0.members.count, b = $1.members.count
            return a != b ? a > b : $0.members[0] < $1.members[0]
        }
        let totalArea = placed.reduce(0) { $0 + ($1.size.width + spacing.component) * ($1.size.height + spacing.component) }
        let rowLimit = max(placed.map(\.size.width).max() ?? 0, (totalArea * 1.6).squareRoot())

        var result: [String: CGPoint] = [:]
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for comp in placed {
            if x > 0, x + comp.size.width > rowLimit {
                x = 0
                y += rowHeight + spacing.component
                rowHeight = 0
            }
            for (i, p) in comp.positions {
                result[nodes[i].id] = CGPoint(x: x + p.x, y: y + p.y)
            }
            x += comp.size.width + spacing.component
            rowHeight = max(rowHeight, comp.size.height)
        }
        return result
    }

    private static func layoutComponent(members: [Int], edges: [(Int, Int)], nodes: [Node], spacing: Spacing, options: Options) -> [Int: CGPoint] {
        if members.count == 1 { return [members[0]: .zero] }

        var children: [Int: [Int]] = [:]
        var parents: [Int: [Int]] = [:]
        var neighbors: [Int: [Int]] = [:]
        for (a, b) in edges {
            children[a, default: []].append(b)
            neighbors[a, default: []].append(b)
            neighbors[b, default: []].append(a)
        }

        // Break cycles: drop DFS back edges for layering purposes.
        var state: [Int: Int] = [:]  // 1 = on stack, 2 = done
        var dag: [Int: [Int]] = [:]
        func dfs(_ n: Int) {
            state[n] = 1
            for c in children[n] ?? [] {
                if state[c] == 1 { continue }
                dag[n, default: []].append(c)
                if state[c] == nil { dfs(c) }
            }
            state[n] = 2
        }
        // Start from nodes with the most children so hubs anchor the left side.
        for n in members.sorted(by: { (children[$0]?.count ?? 0) > (children[$1]?.count ?? 0) }) where state[n] == nil {
            dfs(n)
        }
        for (a, cs) in dag { for c in cs { parents[c, default: []].append(a) } }

        // Longest-path layering in topological order.
        var indegree: [Int: Int] = [:]
        for n in members { indegree[n] = parents[n]?.count ?? 0 }
        var queue = members.filter { indegree[$0] == 0 }
        var topo: [Int] = []
        var layer: [Int: Int] = [:]
        while !queue.isEmpty {
            let n = queue.removeFirst()
            topo.append(n)
            for c in dag[n] ?? [] {
                layer[c] = max(layer[c] ?? 0, (layer[n] ?? 0) + 1)
                indegree[c]! -= 1
                if indegree[c] == 0 { queue.append(c) }
            }
        }
        for n in members where layer[n] == nil { layer[n] = 0 }
        // Pull pure parents (no parents themselves) right, next to their nearest child.
        for n in topo.reversed() where (parents[n] ?? []).isEmpty {
            if let minChild = (dag[n] ?? []).compactMap({ layer[$0] }).min(), minChild - 1 > layer[n]! {
                layer[n] = minChild - 1
            }
        }

        let layerCount = (layer.values.max() ?? 0) + 1
        var layers: [[Int]] = Array(repeating: [], count: layerCount)
        for n in members { layers[layer[n]!].append(n) }

        // Crossing reduction: barycenter sweeps using normalized positions of all neighbors.
        var order: [Int: Double] = [:]
        func renumber() {
            for l in layers {
                for (k, n) in l.enumerated() { order[n] = Double(k) / Double(max(1, l.count - 1)) }
            }
        }
        renumber()
        for sweep in 0..<8 {
            let range: [Int] = sweep % 2 == 0 ? Array(0..<layerCount) : Array((0..<layerCount).reversed())
            for li in range {
                let current = layers[li]
                let keys = current.map { n -> Double in
                    let ns = (neighbors[n] ?? []).filter { sweep % 2 == 0 ? layer[$0]! < li : layer[$0]! > li }
                    let use = ns.isEmpty ? (neighbors[n] ?? []).filter { layer[$0]! != li } : ns
                    guard !use.isEmpty else { return order[n]! }
                    return use.reduce(0) { $0 + order[$1]! } / Double(use.count)
                }
                layers[li] = zip(current, keys).enumerated()
                    .sorted { $0.element.1 != $1.element.1 ? $0.element.1 < $1.element.1 : $0.offset < $1.offset }
                    .map { $0.element.0 }
                for (k, n) in layers[li].enumerated() { order[n] = Double(k) / Double(max(1, layers[li].count - 1)) }
            }
        }

        // Split very tall layers into several columns so the diagram stays roughly 16:10.
        let area = members.reduce(CGFloat(0)) { $0 + (nodes[$1].size.width + spacing.horizontal) * (nodes[$1].size.height + spacing.vertical) }
        let tallest = members.map { nodes[$0].size.height }.max() ?? 0
        // Never split a column that is only a few tables tall: its edges would cross the extra column.
        let targetHeight = max(tallest * 2.5, (area * 10 / 16).squareRoot())
        var columns: [[Int]] = []
        for l in layers {
            let height = l.reduce(CGFloat(0)) { $0 + nodes[$1].size.height + spacing.vertical }
            let parts = options.splitTallLayers ? max(1, Int((height / targetHeight).rounded(.up))) : 1
            if parts == 1 { columns.append(l); continue }
            let per = height / CGFloat(parts)
            var col: [Int] = [], acc: CGFloat = 0
            for n in l {
                let h = nodes[n].size.height + spacing.vertical
                if !col.isEmpty, acc + h / 2 > per, columns.count < Int.max {
                    columns.append(col); col = []; acc = 0
                }
                col.append(n); acc += h
            }
            if !col.isEmpty { columns.append(col) }
        }

        // X: one column after another.
        var x: [Int: CGFloat] = [:]
        var cursor: CGFloat = 0
        for col in columns {
            let width = col.map { nodes[$0].size.width }.max() ?? 0
            for n in col { x[n] = cursor }
            cursor += width + spacing.horizontal
        }

        // Y: start stacked, then repeatedly move nodes toward the mean of their neighbors
        // while keeping column order and spacing (exact least-squares via block merging).
        var y: [Int: CGFloat] = [:]
        for col in columns {
            var acc: CGFloat = 0
            for n in col { y[n] = acc; acc += nodes[n].size.height + spacing.vertical }
        }
        let columnOf = Dictionary(uniqueKeysWithValues: columns.enumerated().flatMap { ci, col in col.map { ($0, ci) } })
        for iteration in 0..<12 {
            let range: [Int] = iteration % 2 == 0 ? Array(columns.indices) : Array(columns.indices.reversed())
            for ci in range {
                let col = columns[ci]
                let desired = col.map { n -> CGFloat in
                    let ns = (neighbors[n] ?? []).filter { columnOf[$0] != ci }
                    guard !ns.isEmpty else { return y[n]! }
                    let center = ns.reduce(CGFloat(0)) { $0 + y[$1]! + nodes[$1].size.height / 2 } / CGFloat(ns.count)
                    return center - nodes[n].size.height / 2
                }
                let placed = resolveOverlaps(desired: desired, heights: col.map { nodes[$0].size.height }, gap: spacing.vertical)
                for (k, n) in col.enumerated() { y[n] = placed[k] }
            }
        }

        // Wrap a long chain of columns into stacked bands so the result isn't a thin strip.
        let colWidths = columns.map { col in col.map { nodes[$0].size.width }.max() ?? 0 }
        let totalWidth = colWidths.reduce(0) { $0 + $1 + spacing.horizontal }
        let targetWidth = (area * 16 / 10).squareRoot() * 1.3
        var bands: [[Int]] = [Array(columns.indices)]
        if options.wrapBands, totalWidth > targetWidth * 1.5 {
            bands = []
            var band: [Int] = [], w: CGFloat = 0
            for ci in columns.indices {
                if !band.isEmpty, w + colWidths[ci] > targetWidth { bands.append(band); band = []; w = 0 }
                band.append(ci); w += colWidths[ci] + spacing.horizontal
            }
            if !band.isEmpty { bands.append(band) }
        }

        var result: [Int: CGPoint] = [:]
        var bandTop: CGFloat = 0
        for band in bands {
            let bandNodes = band.flatMap { columns[$0] }
            let minY = bandNodes.map { y[$0]! }.min() ?? 0
            let minX = bandNodes.map { x[$0]! }.min() ?? 0
            var bottom: CGFloat = 0
            for n in bandNodes {
                let p = CGPoint(x: x[n]! - minX, y: (bandTop + y[n]! - minY).rounded())
                result[n] = p
                bottom = max(bottom, p.y + nodes[n].size.height)
            }
            bandTop = bottom + spacing.horizontal
        }
        return result
    }

    /// Places items in order with `gap` between them, minimizing squared distance to `desired`.
    static func resolveOverlaps(desired: [CGFloat], heights: [CGFloat], gap: CGFloat) -> [CGFloat] {
        struct Block { var first: Int; var count: Int; var sum: CGFloat; var height: CGFloat; var top: CGFloat { sum / CGFloat(count) } }
        var blocks: [Block] = []
        for i in desired.indices {
            var b = Block(first: i, count: 1, sum: desired[i], height: heights[i])
            while let prev = blocks.last, prev.top + prev.height + gap > b.top {
                blocks.removeLast()
                let shift = prev.height + gap
                b = Block(first: prev.first, count: prev.count + b.count,
                          sum: prev.sum + b.sum - shift * CGFloat(b.count), height: prev.height + gap + b.height)
            }
            blocks.append(b)
        }
        var out = Array(repeating: CGFloat(0), count: desired.count)
        for b in blocks {
            var top = b.top
            for i in b.first..<(b.first + b.count) {
                out[i] = top
                top += heights[i] + gap
            }
        }
        return out
    }
}

/// Lays out the tables of one diagram: referenced collections go left, the collections pointing
/// at them and the documents embedded in them go right.
/// The auto-arrange styles.
public enum LayoutStyle: String, CaseIterable, Sendable {
    /// Referenced collections on the left, referencing ones on the right, folded to fit the screen.
    case leftRight
    /// One long left-to-right flow along the references; each collection and its embedded documents is a stage.
    case pipeline
    /// As little empty space as possible, related collections kept close.
    case compact

    public var title: String {
        switch self {
        case .leftRight: return "Left to Right"
        case .pipeline: return "Pipeline"
        case .compact: return "Compact"
        }
    }
}

public enum SchemaLayout {
    static func edges(_ schema: Schema, _ ids: Set<String>) -> [LayeredLayout.Edge] {
        schema.refs.compactMap { r in
            ids.contains(r.parent.tableID) && ids.contains(r.child.tableID) ? LayeredLayout.Edge(parent: r.parent.tableID, child: r.child.tableID) : nil
        }
    }

    private static func size(_ id: String, _ sizes: [String: CGSize]) -> CGSize { sizes[id] ?? CGSize(width: 200, height: 100) }

    /// Lays out the given tables of `schema` (one diagram) in `style`.
    public static func compute(schema: Schema, tableIDs: [String], sizes: [String: CGSize], style: LayoutStyle = .leftRight) -> [String: CGPoint] {
        switch style {
        case .leftRight: return leftRight(schema: schema, tableIDs: tableIDs, sizes: sizes)
        case .pipeline: return pipeline(schema: schema, tableIDs: tableIDs, sizes: sizes)
        case .compact:
            // With a few big blocks the layered layout can happen to be tighter; Compact is whichever is smaller.
            let packed = compact(schema: schema, tableIDs: tableIDs, sizes: sizes)
            let layered = leftRight(schema: schema, tableIDs: tableIDs, sizes: sizes)
            return area(packed, sizes) <= area(layered, sizes) ? packed : layered
        }
    }

    private static func area(_ positions: [String: CGPoint], _ sizes: [String: CGSize]) -> CGFloat {
        let r = positions.reduce(CGRect.null) { $0.union(CGRect(origin: $1.value, size: size($1.key, sizes))) }
        return r.isNull ? 0 : r.width * r.height
    }

    private static func leftRight(schema: Schema, tableIDs: [String], sizes: [String: CGSize]) -> [String: CGPoint] {
        let nodes = tableIDs.map { LayeredLayout.Node(id: $0, size: size($0, sizes)) }
        return LayeredLayout.layout(nodes: nodes, edges: edges(schema, Set(tableIDs)),
                                    spacing: .init(horizontal: 90, vertical: 28, component: 80))
    }

    /// The collection each embedded document belongs to (following nested embeddings up),
    /// when that collection is among `ids`.
    static func owners(_ schema: Schema, _ ids: Set<String>) -> [String: String] {
        var parentOf: [String: String] = [:]
        for r in schema.refs where r.kind == .embedding && r.from.tableID != r.to.tableID { parentOf[r.to.tableID] = r.from.tableID }
        var result: [String: String] = [:]
        for id in ids {
            var cur = id, seen: Set<String> = [id]
            while let p = parentOf[cur], ids.contains(p), seen.insert(p).inserted { cur = p }
            result[id] = cur
        }
        return result
    }

    /// A collection with the documents embedded in it (or a table on its own), laid out as one block:
    /// the collection on the left, nested documents to its right. Positions are relative to the block.
    private struct Stage {
        var id: String
        var local: [String: CGPoint]
        var size: CGSize
    }

    private static func stages(schema: Schema, tableIDs: [String], sizes: [String: CGSize], edges: [LayeredLayout.Edge],
                               owner: [String: String]) -> [Stage] {
        var members: [String: [String]] = [:]
        var order: [String] = []
        for id in tableIDs {
            let o = owner[id] ?? id
            if members[o] == nil { order.append(o) }
            members[o, default: []].append(id)
        }
        return order.map { o in
            let m = members[o]!
            let set = Set(m)
            let inner = m.count == 1 ? [m[0]: CGPoint.zero] : LayeredLayout.layout(
                nodes: m.map { LayeredLayout.Node(id: $0, size: size($0, sizes)) },
                edges: edges.filter { set.contains($0.parent) && set.contains($0.child) },
                spacing: .init(horizontal: 50, vertical: 20, component: 40),
                options: .init(splitTallLayers: false, wrapBands: false))
            var w: CGFloat = 0, h: CGFloat = 0
            for (id, p) in inner { w = max(w, p.x + size(id, sizes).width); h = max(h, p.y + size(id, sizes).height) }
            return Stage(id: o, local: inner, size: CGSize(width: w, height: h))
        }
    }

    private static func place(_ stages: [Stage], at origins: [String: CGPoint]) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        for st in stages {
            let o = origins[st.id] ?? .zero
            for (id, p) in st.local { result[id] = CGPoint(x: o.x + p.x, y: o.y + p.y) }
        }
        return result
    }

    /// Left to right along the references. Each collection, together with the documents embedded in it,
    /// is a stage; a stage sits right of every stage it references (except along cycles), and stages
    /// at the same depth share a column.
    private static func pipeline(schema: Schema, tableIDs: [String], sizes: [String: CGSize]) -> [String: CGPoint] {
        let ids = Set(tableIDs)
        let edges = edges(schema, ids)
        let owner = owners(schema, ids)
        let stages = stages(schema: schema, tableIDs: tableIDs, sizes: sizes, edges: edges, owner: owner)
        let stageEdges = edges.compactMap { e -> LayeredLayout.Edge? in
            guard let a = owner[e.parent], let b = owner[e.child], a != b else { return nil }
            return LayeredLayout.Edge(parent: a, child: b)
        }
        let origins = LayeredLayout.layout(
            nodes: stages.map { .init(id: $0.id, size: $0.size) }, edges: stageEdges,
            spacing: .init(horizontal: 150, vertical: 40, component: 100),
            options: .init(splitTallLayers: false, wrapBands: false))
        return place(stages, at: origins)
    }

    /// As little empty space as possible. Each collection keeps its embedded documents beside it;
    /// those blocks are packed with referencing collections next to each other, one cluster of
    /// connected collections at a time, and then the clusters are packed.
    private static func compact(schema: Schema, tableIDs: [String], sizes: [String: CGSize]) -> [String: CGPoint] {
        let ids = Set(tableIDs)
        let edges = edges(schema, ids)
        let owner = owners(schema, ids)
        let stages = stages(schema: schema, tableIDs: tableIDs, sizes: sizes, edges: edges, owner: owner)
        let stageSize = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0.size) })
        var neighbors: [String: [String]] = [:]
        for e in edges {
            guard let a = owner[e.parent], let b = owner[e.child], a != b else { continue }
            neighbors[a, default: []].append(b)
            neighbors[b, default: []].append(a)
        }
        // Connected components, in sidebar order.
        let order = stages.map(\.id)
        var componentOf: [String: Int] = [:]
        var components: [[String]] = []
        for id in order where componentOf[id] == nil {
            var stack = [id], comp: Set<String> = []
            componentOf[id] = components.count
            while let n = stack.popLast() {
                comp.insert(n)
                for m in neighbors[n] ?? [] where componentOf[m] == nil { componentOf[m] = components.count; stack.append(m) }
            }
            components.append(order.filter(comp.contains))
        }
        var local: [[String: CGPoint]] = []
        var boxes: [(id: String, size: CGSize)] = []
        for (i, c) in components.enumerated() {
            let packed = shelfPack(relatedOrder(c, neighbors: neighbors).map { ($0, stageSize[$0]!) }, gapX: 40, gapY: 24)
            local.append(packed)
            var w: CGFloat = 0, h: CGFloat = 0
            for (id, p) in packed { w = max(w, p.x + stageSize[id]!.width); h = max(h, p.y + stageSize[id]!.height) }
            boxes.append(("\(i)", CGSize(width: w, height: h)))
        }
        // Big clusters first; ties keep the sidebar order.
        let ordered = boxes.enumerated().sorted {
            let a = $0.element.size.width * $0.element.size.height, b = $1.element.size.width * $1.element.size.height
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        let clusterOrigins = shelfPack(ordered, gapX: 60, gapY: 50)
        var origins: [String: CGPoint] = [:]
        for (i, packed) in local.enumerated() {
            let o = clusterOrigins["\(i)"] ?? .zero
            for (id, p) in packed { origins[id] = CGPoint(x: o.x + p.x, y: o.y + p.y) }
        }
        return place(stages, at: origins)
    }

    /// Breadth-first from the most connected table, so related tables end up next to each other.
    static func relatedOrder(_ members: [String], neighbors: [String: [String]]) -> [String] {
        let set = Set(members)
        let degree = Dictionary(members.map { ($0, neighbors[$0]?.filter(set.contains).count ?? 0) }, uniquingKeysWith: { a, _ in a })
        let byDegree = members.enumerated().sorted { degree[$0.element]! != degree[$1.element]! ? degree[$0.element]! > degree[$1.element]! : $0.offset < $1.offset }.map(\.element)
        var seen: Set<String> = [], order: [String] = []
        for start in byDegree where !seen.contains(start) {
            var queue = [start], head = 0
            seen.insert(start)
            while head < queue.count {
                let n = queue[head]
                head += 1
                order.append(n)
                let next = (neighbors[n] ?? []).filter { set.contains($0) && !seen.contains($0) }
                for m in next.sorted(by: { degree[$0]! > degree[$1]! }) where seen.insert(m).inserted { queue.append(m) }
            }
        }
        return order
    }

    /// Rows (or columns) of items in the given order. Tries every row width (column height) at which the
    /// wrapping changes, in both directions, and keeps the smallest bounding box, penalizing shapes far
    /// from 16:10. Columns suit collections, which are about as wide as each other but differ a lot in height.
    static func shelfPack(_ items: [(id: String, size: CGSize)], gapX: CGFloat, gapY: CGFloat) -> [String: CGPoint] {
        /// Packs along x (rows) or, with `columns`, along y.
        func pack(_ limit: CGFloat, columns: Bool) -> (positions: [String: CGPoint], size: CGSize) {
            var result: [String: CGPoint] = [:]
            var main: CGFloat = 0, cross: CGFloat = 0, shelf: CGFloat = 0, extent: CGFloat = 0
            let gapMain = columns ? gapY : gapX, gapCross = columns ? gapX : gapY
            for item in items {
                let len = columns ? item.size.height : item.size.width
                let depth = columns ? item.size.width : item.size.height
                if main > 0, main + len > limit {
                    main = 0; cross += shelf + gapCross; shelf = 0
                }
                result[item.id] = columns ? CGPoint(x: cross, y: main) : CGPoint(x: main, y: cross)
                extent = max(extent, main + len)
                main += len + gapMain
                shelf = max(shelf, depth)
            }
            let size = CGSize(width: extent, height: cross + shelf)
            return (result, columns ? CGSize(width: size.height, height: size.width) : size)
        }
        func score(_ s: CGSize) -> CGFloat {
            guard s.width > 0, s.height > 0 else { return 0 }
            let ratio = s.width / s.height
            return s.width * s.height * max(ratio / 1.6, 1.6 / ratio)
        }
        var best = pack(.infinity, columns: false)
        var bestScore = score(best.size)
        for columns in [false, true] {
            // Candidate limits: the end of each prefix of items laid out in one shelf.
            var candidates: [CGFloat] = []
            var acc: CGFloat = 0
            for item in items {
                acc += columns ? item.size.height : item.size.width
                candidates.append(acc)
                acc += columns ? gapY : gapX
            }
            // Big inputs: a sample of limits is plenty and keeps this linear-ish.
            let stride = max(1, candidates.count / 200)
            for i in Swift.stride(from: 0, to: candidates.count, by: stride) {
                let p = pack(candidates[i], columns: columns)
                let sc = score(p.size)
                if sc < bestScore { best = p; bestScore = sc }
            }
        }
        return best.positions
    }

    /// Places tables that have no position yet next to an already placed neighbor,
    /// or to the right of everything, without moving existing tables.
    public static func placeNew(schema: Schema, tableIDs: [String], sizes: [String: CGSize], existing: [String: CGPoint], style: LayoutStyle = .leftRight) -> [String: CGPoint] {
        let ids = Set(tableIDs)
        var result = existing.filter { ids.contains($0.key) }
        let missing = tableIDs.filter { result[$0] == nil }
        guard !missing.isEmpty else { return result }
        if result.isEmpty { return compute(schema: schema, tableIDs: tableIDs, sizes: sizes, style: style) }

        func rect(_ id: String) -> CGRect { CGRect(origin: result[id]!, size: sizes[id] ?? .zero) }
        func free(_ r: CGRect) -> Bool { !result.keys.contains { rect($0).insetBy(dx: -20, dy: -20).intersects(r) } }
        let bounds = result.keys.map(rect).reduce(CGRect.null) { $0.union($1) }
        var fallbackX = bounds.maxX + 140
        for id in missing {
            let size = sizes[id] ?? CGSize(width: 200, height: 100)
            let neighbor = schema.refs.lazy.compactMap { r -> String? in
                if r.from.tableID == id, result[r.to.tableID] != nil { return r.to.tableID }
                if r.to.tableID == id, result[r.from.tableID] != nil { return r.from.tableID }
                return nil
            }.first
            if let n = neighbor {
                let nr = rect(n)
                var candidate = CGRect(origin: CGPoint(x: nr.maxX + 90, y: nr.minY), size: size)
                for _ in 0..<200 where !free(candidate) { candidate.origin.y += 30 }
                result[id] = candidate.origin
            } else {
                result[id] = CGPoint(x: fallbackX, y: bounds.minY)
                fallbackX += size.width + 60
            }
        }
        return result
    }
}
