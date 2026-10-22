import AppKit
import MoonKit

/// Development aids driven by environment variables; inert in normal use.
/// `scripts/screenshots.sh` uses them to regenerate the README images.
enum DebugHooks {
    /// MONGOGRAM_SCREENSHOT=out.png renders the whole window to a PNG a few seconds after opening, then quits.
    /// Optional: MONGOGRAM_APPEARANCE=light|dark, MONGOGRAM_DIAGRAM=name, MONGOGRAM_SELECT_TABLE=name,
    /// MONGOGRAM_SELECT_REF=table.field (a reference or embedded document by its field).
    static func screenshotIfRequested(_ model: DocumentModel) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["MONGOGRAM_SCREENSHOT"] else { return }
        if env["MONGOGRAM_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        if env["MONGOGRAM_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            model.canvas?.window?.setContentSize(NSSize(width: 1440, height: 860))
            if let name = env["MONGOGRAM_DIAGRAM"], let d = model.file.diagrams.first(where: { $0.name == name }) { model.selectDiagram(d.id) }
            if let t = env["MONGOGRAM_SELECT_TABLE"], let table = model.schema.tables.first(where: { $0.name == t }) { model.select(table.id, focus: false) }
            if let r = env["MONGOGRAM_SELECT_REF"] {
                let parts = r.split(separator: ".", maxSplits: 1).map(String.init)
                let text = { (ref: Ref) in RelationText(ref, schema: model.schema) }
                if parts.count == 2, let i = model.schema.refs.firstIndex(where: { text($0).tableName($0.from.tableID) == parts[0] && text($0).columnName($0.from) == parts[1] }) {
                    model.selectRef(i, reveal: false)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { model.canvas?.zoomToFit(animated: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let window = model.canvas?.window, let image = render(window) {
                try? ImageExporter.writePNG(image, to: URL(fileURLWithPath: out))
            }
            NSApp.terminate(nil)
        }
    }

    /// MONGOGRAM_SELFTEST=1 drives selection, moves, nudges, auto-arrange and undo/redo through the real
    /// canvas and the window's undo manager, prints PASS/FAIL lines to stderr and quits (exit 1 on failure).
    static func selfTestIfRequested(_ model: DocumentModel) {
        guard ProcessInfo.processInfo.environment["MONGOGRAM_SELFTEST"] != nil else { return }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            FileHandle.standardError.write("\(ok ? "PASS" : "FAIL") \(what)\n".data(using: .utf8)!)
        }
        func positions(_ ids: [String]) -> [String: CGPoint] {
            Dictionary(uniqueKeysWithValues: ids.compactMap { id in model.canvas?.scene?.positions[id].map { (id, $0) } })
        }
        var undo: UndoManager? { model.canvas?.window?.undoManager }
        var ids: [String] = [], start: [String: CGPoint] = [:], moved: [String: CGPoint] = [:], all: [String: CGPoint] = [:]
        // Each step runs on its own run-loop pass, so every registration is its own undo group, as with real events.
        let steps: [() -> Void] = [
            {
                model.useFileLayoutWithoutUndo()
                ids = Array(model.schema.tables.prefix(3).map(\.id))
                model.canvas?.setSelection(Set(ids), primary: ids[0])
                check(model.selectedTables == Set(ids) && model.selection == ids[0], "canvas multi-select reaches the model")
                start = positions(ids)
                moved = start.mapValues { CGPoint(x: $0.x + 40, y: $0.y + 25) }
                model.canvas?.movePositions(moved, animated: false)
                model.tablesMoved(old: start, new: moved)
                check(model.hasMovedTables && undo?.undoActionName == "Move 3 Tables", "group move registers \"Move 3 Tables\"")
            },
            { undo?.undo() },
            {
                check(positions(ids) == start, "undo puts the 3 tables back")
                check(!model.hasMovedTables, "undo of the first move returns to the file's layout")
                undo?.redo()
            },
            {
                check(positions(ids) == moved, "redo moves them again")
                undo?.undo()
            },
            {
                // Two nudges in quick succession are one step.
                let one = ids[0]
                let a = positions([one]), b = a.mapValues { CGPoint(x: $0.x + 1, y: $0.y) }, c = b.mapValues { CGPoint(x: $0.x + 10, y: $0.y) }
                model.canvas?.select(one)
                model.canvas?.movePositions(b, animated: false); model.tablesMoved(old: a, new: b, isNudge: true)
                model.canvas?.movePositions(c, animated: false); model.tablesMoved(old: b, new: c, isNudge: true)
                check(positions([one]) == c, "nudges move the table")
                start = a
            },
            { undo?.undo() },
            {
                check(positions([ids[0]]) == start, "one undo reverts both nudges")
                all = positions(model.schema.tables.map(\.id))
                let style = model.layoutStyle
                model.arrange(style == .compact ? .pipeline : .compact)
                check(undo?.undoActionName == "Auto-Arrange", "auto-arrange is undoable")
                moved = [style.rawValue: .zero]
            },
            {
                check(positions(Array(all.keys)) != all, "auto-arrange slid the tables to new places")
                undo?.undo()
            },
            {
                check(positions(Array(all.keys)) == all, "undo of auto-arrange restores every table")
                check(model.layoutStyle.rawValue == moved.keys.first, "undo of auto-arrange restores the style")
                model.canvas?.selectAll(nil)
                check(model.selectedTables.count == model.schema.tables.count, "select all")
                model.canvas?.toggle(ids[0])
                check(!model.selectedTables.contains(ids[0]) && model.selection != ids[0], "toggle removes a table and keeps a valid primary")
                FileHandle.standardError.write("SELFTEST \(failures == 0 ? "OK" : "FAILED (\(failures))")\n".data(using: .utf8)!)
                exit(failures == 0 ? 0 : 1)
            },
        ]
        func run(_ i: Int) {
            guard i < steps.count else { return }
            steps[i]()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(i + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run(0) }
    }

    /// Renders the window's own layer tree (no screen-recording permission needed).
    /// Blur materials come out flat, which is fine for documentation.
    private static func render(_ window: NSWindow) -> CGImage? {
        guard let frameView = window.contentView?.superview, let layer = frameView.layer else { return nil }
        let scale = window.backingScaleFactor, size = frameView.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}
