import AppKit
import CryptoKit
import MoonKit
import Observation

/// State of one window: the open file, its parsed model, the diagram on screen, positions and selection.
@Observable
final class DocumentModel {
    var url: URL?
    /// Everything in the file.
    private(set) var file = Schema()
    /// The diagram on screen: only its tables and the lines between them, plus the file's diagnostics.
    private(set) var schema = Schema()
    private(set) var diagramID: String?
    /// The primary selected table (inspector, sidebar scrolling); always in `selectedTables` when set.
    var selection: String?
    var selectedTables: Set<String> = []
    /// Index into `schema.refs` of the selected line. Mutually exclusive with `selection`.
    var selectedRef: Int?
    var loadError: String?
    var isPasted = false
    /// The auto-arrange style of this file: the last one used on it, else the last one used anywhere.
    var layoutStyle = DocumentModel.defaultLayoutStyle
    /// True when tables of this diagram were moved here, so they differ from the file.
    private(set) var hasMovedTables = false
    /// Bumped on every new scene so the canvas knows to reload.
    private(set) var revision = 0
    /// Colors for the sidebar and inspector. Changes only when the scene changes.
    private(set) var style: SceneStyle?
    /// Not observed: table positions change on every drag and must not re-render SwiftUI views.
    @ObservationIgnored private(set) var scene: DiagramScene?

    @ObservationIgnored weak var canvas: DiagramCanvas?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var store: LayoutStore?
    /// Source of the model on screen, to skip reloads when the file content didn't change.
    @ObservationIgnored private var lastSource: String?
    /// Positions set in this app (dragged or auto-arranged), per diagram. They win over the file's
    /// positions; everything else follows the file, so moves made in Moon Modeler show up on reload.
    @ObservationIgnored private var overrides: [String: [String: CGPoint]] = [:]
    @ObservationIgnored private var recheck: DispatchWorkItem?
    /// Counts undo registrations, so a nudge only merges into the step registered just before it.
    @ObservationIgnored private var undoSerial = 0
    /// The undo step of the last arrow-key nudge while it can still absorb more presses.
    @ObservationIgnored private weak var lastNudge: MoveStep?

    var title: String {
        if let url { return url.lastPathComponent }
        return isPasted ? "Pasted Model" : "MongoGram"
    }

    var hasContent: Bool { url != nil || isPasted }

    var diagram: Diagram? { file.diagram(id: diagramID) }

    // MARK: loading

    func open(_ url: URL) {
        if url != self.url { undoManager?.removeAllActions(withTarget: self) }
        self.url = url
        isPasted = false
        store = LayoutStore(for: url)
        overrides = store?.positions ?? [:]
        layoutStyle = store?.style ?? Self.defaultLayoutStyle
        diagramID = nil
        lastSource = nil
        RecentFiles.add(url)
        reload(initial: true)
        watcher = FileWatcher(url: url) { [weak self] in self?.reload(initial: false) }
    }

    func loadPasted(_ source: String) {
        undoManager?.removeAllActions(withTarget: self)
        url = nil
        watcher = nil
        store = nil
        isPasted = true
        overrides = [:]
        layoutStyle = Self.defaultLayoutStyle
        diagramID = nil
        lastSource = source
        apply(DMM.parse(source), initial: true)
    }

    static func debugLog(_ s: String) {
        guard ProcessInfo.processInfo.environment["MONGOGRAM_DEBUG"] != nil else { return }
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    /// Reads the file and shows it. Keeps the current diagram when the file is missing, unchanged,
    /// or briefly broken (empty or half-written JSON while an app saves), so a hot reload never
    /// flashes or loses the picture.
    func reload(initial: Bool, confirm: Bool = false) {
        guard let url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = "\(url.lastPathComponent) was moved or deleted. Waiting for it to come back…"
            return
        }
        let t0 = CACurrentMediaTime()
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = "Can't read \(url.lastPathComponent) as UTF-8 text"
            return
        }
        if !initial, source == lastSource { loadError = nil; return }
        let parsed = DMM.parse(source)
        let haveGood = !file.tables.isEmpty
        if !initial, haveGood, parsed.isUnreadable {
            if !confirm {
                // Probably mid-save; look again shortly before believing it.
                recheck?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.reload(initial: false, confirm: true) }
                recheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
                return
            }
            let d = parsed.diagnostics.first { $0.severity == .error }
            loadError = "\(d.map { "Line \($0.line): \($0.message)" } ?? "Can't read the file"). Showing the last version that loaded."
            return
        }
        loadError = nil
        lastSource = source
        apply(parsed, initial: initial)
        Self.debugLog(String(format: "reload %@ tables=%d: %.1fms", url.lastPathComponent, file.tables.count, (CACurrentMediaTime() - t0) * 1000))
    }

    private func apply(_ parsed: Schema, initial: Bool) {
        file = parsed
        if file.diagram(id: diagramID) == nil {
            diagramID = file.diagram(id: store?.lastDiagram)?.id ?? file.mainDiagram?.id
        }
        rebuild(fit: initial)
    }

    /// Builds the scene for the current diagram: positions from this app, then from the file,
    /// and an automatic spot for anything left.
    private func rebuild(fit: Bool) {
        var scene = DiagramScene(file: file, diagram: diagram)
        let ids = Set(scene.tableIDs)
        let moved = (overrides[diagramID ?? ""] ?? [:]).filter { ids.contains($0.key) }
        scene.place(moved: moved, style: layoutStyle)
        hasMovedTables = !moved.isEmpty
        var visible = scene.schema
        visible.diagnostics = file.diagnostics
        let oldRef = selectedRef.flatMap { $0 < schema.refs.count ? schema.refs[$0].id : nil }
        schema = visible
        self.scene = scene
        style = scene.style
        selectedTables = selectedTables.filter { schema.table(id: $0) != nil }
        if let s = selection, schema.table(id: s) == nil { selection = nil }
        selectedRef = oldRef.flatMap { id in schema.refs.firstIndex { $0.id == id } }
        revision += 1
        if let canvas { push(to: canvas, fit: fit) }
    }

    func selectDiagram(_ id: String) {
        guard id != diagramID, file.diagram(id: id) != nil else { return }
        if let canvas { viewportChanged(zoom: canvas.zoom, offset: canvas.offset) }
        diagramID = id
        store?.lastDiagram = id
        selection = nil
        selectedTables = []
        selectedRef = nil
        rebuild(fit: true)
    }

    func selectDiagram(offset: Int) {
        guard let i = file.diagrams.firstIndex(where: { $0.id == diagramID }), !file.diagrams.isEmpty else { return }
        selectDiagram(file.diagrams[(i + offset + file.diagrams.count) % file.diagrams.count].id)
    }

    /// Called by the canvas wrapper when it appears, and after every new scene.
    func push(to canvas: DiagramCanvas, fit: Bool) {
        guard let scene else { return }
        let t0 = CACurrentMediaTime()
        // Set the viewport first so new table layers rasterize once, at the right resolution.
        var fitLater = false
        if fit {
            if let v = store?.viewport(for: diagramID ?? "") {
                canvas.setViewport(zoom: v.zoom, offset: CGPoint(x: v.x, y: v.y))
            } else if canvas.bounds.width > 0 {
                canvas.fit(scene.contentBounds, maxZoom: 1.2, animated: false)
            } else {
                fitLater = true
            }
        }
        canvas.load(scene)
        Self.debugLog(String(format: "canvas load: %.1fms (%d tables)", (CACurrentMediaTime() - t0) * 1000, scene.schema.tables.count))
        if fitLater {
            // The view has no size yet; fit once it's laid out.
            DispatchQueue.main.async { canvas.zoomToFit(animated: false) }
        }
        if let path = ProcessInfo.processInfo.environment["MONGOGRAM_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak canvas] in canvas?.snapshot(to: URL(fileURLWithPath: path)) }
        }
        if ProcessInfo.processInfo.environment["MONGOGRAM_BENCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak canvas] in
                guard let canvas else { return }
                Self.debugLog(String(format: "hover: %.2fms per change", canvas.benchmarkHover(count: 30)))
            }
        }
    }

    /// Re-arranges every table of this diagram in `style` (default: this file's style) and remembers the choice.
    /// The result is kept in this app only; ⌘Z brings back the previous layout.
    func arrange(_ style: LayoutStyle? = nil) {
        guard let scene, let canvas else { return }
        let style = style ?? layoutStyle
        let oldStyle = layoutStyle
        let new = SchemaLayout.compute(schema: scene.schema, tableIDs: scene.tableIDs, sizes: scene.sizes, style: style)
        let step = MoveStep(name: "Auto-Arrange", diagram: diagramID ?? "", old: placements(scene.tableIDs),
                            new: new.mapValues { Placement(position: $0, isMoved: true) })
        step.viewport = (canvas.zoom, canvas.offset)
        step.style = oldStyle
        setStyle(style)
        apply(step.new, animated: true)
        // Fit to where the tables end up, not where the slide starts.
        if let arranged = self.scene { canvas.fit(arranged.contentBounds, maxZoom: 1.2, animated: true) }
        // Arranging again in the same style changes nothing: an undo step for it would look like ⌘Z doing nothing.
        if step.new != step.old || style != oldStyle { registerUndo(step) }
    }

    /// Drops positions set in this app and goes back to where the file puts each table. Undoable.
    func useFileLayout() {
        guard var scene else { return }
        let old = placements(scene.tableIDs)
        scene.place(moved: [:], style: layoutStyle)
        let step = MoveStep(name: "Use Layout from File", diagram: diagramID ?? "", old: old,
                            new: scene.positions.mapValues { Placement(position: $0, isMoved: false) })
        apply(step.new, animated: true)
        canvas?.zoomToFit()
        if step.new != step.old { registerUndo(step) }
    }

    /// Debug self-test: start from the file's layout without leaving an undo step.
    func useFileLayoutWithoutUndo() {
        overrides[diagramID ?? ""] = nil
        rebuild(fit: false)
    }

    private static let defaultStyleKey = "DefaultLayoutStyle"
    private static var defaultLayoutStyle: LayoutStyle {
        UserDefaults.standard.string(forKey: defaultStyleKey).flatMap(LayoutStyle.init(rawValue:)) ?? .leftRight
    }

    private func setStyle(_ style: LayoutStyle) {
        layoutStyle = style
        store?.style = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.defaultStyleKey)
    }

    // MARK: moving tables & undo

    /// Where a table is in one diagram, and whether that position was set in this app (else it follows the file).
    struct Placement: Equatable {
        var position: CGPoint
        var isMoved: Bool
    }

    /// One undo step: the placements before and after, in one diagram. A class so a merged nudge
    /// can update `new` after it was registered.
    private final class MoveStep {
        let name: String
        let diagram: String
        let old: [String: Placement]
        var new: [String: Placement]
        /// Arrange only: the zoom/scroll and style to bring back with `old`.
        var viewport: (CGFloat, CGPoint)?
        var style: LayoutStyle?
        var time = CACurrentMediaTime()
        var serial = 0
        init(name: String, diagram: String, old: [String: Placement], new: [String: Placement]) {
            self.name = name; self.diagram = diagram; self.old = old; self.new = new
        }
    }

    /// The window's undo manager, so Edit → Undo / Redo (⌘Z / ⌘⇧Z) reach it.
    private var undoManager: UndoManager? { canvas?.window?.undoManager }

    private func placements(_ ids: some Sequence<String>) -> [String: Placement] {
        let moved = overrides[diagramID ?? ""] ?? [:]
        var result: [String: Placement] = [:]
        for id in ids { if let p = scene?.positions[id] { result[id] = Placement(position: p, isMoved: moved[id] != nil) } }
        return result
    }

    /// Dragged or nudged on the canvas (already moved there). Arrow-key presses less than a second
    /// apart, on the same tables, are one undo step.
    func tablesMoved(old: [String: CGPoint], new: [String: CGPoint], isNudge: Bool = false) {
        let moved = overrides[diagramID ?? ""] ?? [:]
        let before = Dictionary(uniqueKeysWithValues: old.map { ($0.key, Placement(position: $0.value, isMoved: moved[$0.key] != nil)) })
        let after = new.mapValues { Placement(position: $0, isMoved: true) }
        apply(after, animated: false)
        if isNudge, let last = lastNudge, last.serial == undoSerial, last.diagram == (diagramID ?? ""),
           Set(last.new.keys) == Set(after.keys), CACurrentMediaTime() - last.time < 1 {
            last.new = after
            last.time = CACurrentMediaTime()
            return
        }
        let step = MoveStep(name: new.count == 1 ? "Move Table" : "Move \(new.count) Tables", diagram: diagramID ?? "", old: before, new: after)
        registerUndo(step)
        lastNudge = isNudge ? step : nil
    }

    /// Applies placements of the current diagram to the overrides, the saved layout and the canvas.
    /// Tables that aren't on the diagram right now (removed by an edit) only update the overrides.
    private func apply(_ placements: [String: Placement], animated: Bool) {
        let key = diagramID ?? ""
        var moved = overrides[key] ?? [:]
        for (id, p) in placements { moved[id] = p.isMoved ? p.position : nil }
        overrides[key] = moved.isEmpty ? nil : moved
        hasMovedTables = !moved.isEmpty
        store?.save(positions: overrides)
        guard var scene else { return }
        let positions = placements.mapValues(\.position)
        for (id, p) in positions where scene.positions[id] != nil { scene.positions[id] = p }
        self.scene = scene
        canvas?.movePositions(positions, animated: animated)
    }

    /// Undo brings back `step.old` (switching to its diagram first) and registers the reverse as redo.
    private func registerUndo(_ step: MoveStep) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            if model.diagramID ?? "" != step.diagram {
                guard model.file.diagram(id: step.diagram) != nil else { return }
                model.selectDiagram(step.diagram)
            }
            let reverse = MoveStep(name: step.name, diagram: step.diagram, old: step.new, new: step.old)
            if step.viewport != nil, let canvas = model.canvas { reverse.viewport = (canvas.zoom, canvas.offset) }
            if step.style != nil { reverse.style = model.layoutStyle }
            if let style = step.style { model.setStyle(style) }
            model.apply(step.old, animated: true)
            if let v = step.viewport { model.canvas?.setViewport(zoom: v.0, offset: v.1, animated: true) }
            model.registerUndo(reverse)
        }
        undoManager.setActionName(step.name)
        undoSerial += 1
        step.serial = undoSerial
    }

    func viewportChanged(zoom: CGFloat, offset: CGPoint) {
        store?.save(viewport: .init(zoom: zoom, x: offset.x, y: offset.y), for: diagramID ?? "")
    }

    func selectRef(_ i: Int?, reveal: Bool) {
        selectedRef = i
        if i != nil { selection = nil; selectedTables = [] }
        canvas?.selectRef(i, reveal: reveal)
    }

    func select(_ id: String?, focus: Bool) {
        selection = id
        selectedTables = id.map { [$0] } ?? []
        if id != nil { selectedRef = nil }
        guard let canvas else { return }
        if let id, focus { canvas.focus(table: id) } else { canvas.select(id) }
    }

    /// ⌘-click in the sidebar: add or remove a table without losing the rest of the selection.
    func toggle(_ id: String) {
        canvas?.toggle(id)
    }

    // MARK: export

    func exportPNG() {
        guard let scene, let window = canvas?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        var name = url?.deletingPathExtension().lastPathComponent ?? "model"
        if file.diagrams.count > 1, let d = diagram { name += " - " + d.name }
        panel.nameFieldStringValue = name + ".png"
        let theme = Theme.current(window.effectiveAppearance)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let dest = panel.url, let image = ImageExporter.render(scene, theme: theme) else { return }
            try? ImageExporter.writePNG(image, to: dest)
        }
    }

    /// The whole file, not just the diagram on screen, so embedded types and reference targets are all there.
    func exportMongoose() {
        guard hasContent, !file.tables.isEmpty, let window = canvas?.window else { return }
        MongooseExporter.save(file, name: url?.deletingPathExtension().lastPathComponent ?? "models", sourceName: url?.lastPathComponent, window: window)
    }

    func copyMongoose() {
        guard hasContent, !file.tables.isEmpty else { return }
        MongooseExporter.copy(file, sourceName: url?.lastPathComponent)
    }
}

/// Positions moved in this app, viewports and the last diagram, stored per file in
/// Application Support so the .dmm file is never touched.
final class LayoutStore {
    struct Viewport: Codable { var zoom: CGFloat; var x: CGFloat; var y: CGFloat }
    struct Data: Codable {
        /// Diagram id -> table id -> [x, y].
        var positions: [String: [String: [CGFloat]]] = [:]
        var viewports: [String: Viewport] = [:]
        var lastDiagram: String?
        /// A `LayoutStyle` raw value. A plain string so an unknown value never fails decoding
        /// (which would lose the saved positions).
        var style: String?
    }

    private let file: URL
    private var data: Data
    private var saveWork: DispatchWorkItem?

    init?(for document: URL) {
        // The debug self-test moves and arranges tables; it must never touch a real saved layout.
        if ProcessInfo.processInfo.environment["MONGOGRAM_SELFTEST"] != nil { return nil }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("MongoGram/Layouts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Foundation.Data(document.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        file = dir.appendingPathComponent("\(hash).json")
        data = (try? JSONDecoder().decode(Data.self, from: Foundation.Data(contentsOf: file))) ?? Data()
    }

    var positions: [String: [String: CGPoint]] {
        data.positions.mapValues { $0.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
    }

    var lastDiagram: String? {
        get { data.lastDiagram }
        set { data.lastDiagram = newValue; scheduleWrite() }
    }

    var style: LayoutStyle? {
        get { data.style.flatMap(LayoutStyle.init(rawValue:)) }
        set { data.style = newValue?.rawValue; scheduleWrite() }
    }

    func viewport(for diagram: String) -> Viewport? { data.viewports[diagram] }

    func save(positions: [String: [String: CGPoint]]) {
        data.positions = positions.mapValues { $0.mapValues { [$0.x, $0.y] } }
        scheduleWrite()
    }

    func save(viewport: Viewport, for diagram: String) {
        data.viewports[diagram] = viewport
        scheduleWrite()
    }

    private func scheduleWrite() {
        saveWork?.cancel()
        let snapshot = data, file = file
        let work = DispatchWorkItem {
            if let encoded = try? JSONEncoder().encode(snapshot) { try? encoded.write(to: file, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// Watches a file for changes. Kernel file events give instant reloads; a once-a-second check of the
/// file's identity, size and modification time re-attaches after the file is replaced or recreated
/// (however late) and catches changes the events miss, e.g. on network or synced folders.
final class FileWatcher {
    private struct Stamp: Equatable {
        var inode: UInt64
        var size: Int64
        var modified: timespec

        static func == (a: Stamp, b: Stamp) -> Bool {
            a.inode == b.inode && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var watchedInode: UInt64?
    private var lastStamp: Stamp?
    private var timer: Timer?
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        lastStamp = stamp()
        attach()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 0.3
        // .common so it keeps running while the user drags or scrolls.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        source?.cancel()
    }

    private func stamp() -> Stamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Stamp(inode: UInt64(st.st_ino), size: Int64(st.st_size), modified: st.st_mtimespec)
    }

    private func attach() {
        source?.cancel()
        source = nil
        watchedInode = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }  // Missing for now; check() attaches when it reappears.
        var st = stat()
        if fstat(fd, &st) == 0 { watchedInode = UInt64(st.st_ino) }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.intersection([.delete, .rename]).isEmpty {
                // Replaced by an atomic save: watch the new file once it is in place.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.attach() }
            }
            self.fire()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func check() {
        let current = stamp()
        if let current, source == nil || current.inode != watchedInode { attach() }
        if current != lastStamp { fire() }
    }

    private func fire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastStamp = self.stamp()
            self.onChange()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}

enum RecentFiles {
    private static let key = "recentFiles"

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: key)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}
