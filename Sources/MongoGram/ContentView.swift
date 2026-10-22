import AppKit
import MoonKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Binding var fileURL: URL?
    var initialPaste: String? = nil
    @State private var model = DocumentModel()
    @State private var search = ""
    @State private var showInspector = true
    @State private var showIssues = false
    @State private var windowID = UUID()
    @State private var actions = WindowActions()
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            ZStack(alignment: .bottomLeading) {
                CanvasRepresentable(model: model)
                    .ignoresSafeArea()
                if !model.hasContent { EmptyStateView(open: openPanel, paste: pasteFromClipboard, openRecent: open) }
                if let error = model.loadError { banner(error, systemImage: "exclamationmark.triangle.fill", color: .red) }
                else if !model.schema.diagnostics.isEmpty { issuesButton }
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 290, max: 420)
        }
        .navigationTitle(model.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onAppear {
            Opener.register(openWindow)
            configureActions()
            DebugHooks.screenshotIfRequested(model)
            DebugHooks.selfTestIfRequested(model)
            if let url = fileURL { DispatchQueue.main.async { model.open(url) } }
            else if let text = initialPaste { model.loadPasted(text) }
            else if let url = Opener.takePending() { fileURL = url }
            else { Opener.registerEmpty(windowID) { url in fileURL = url } }
        }
        .onDisappear { Opener.unregisterEmpty(windowID) }
        .onChange(of: fileURL) { _, url in
            if let url { Opener.unregisterEmpty(windowID); model.open(url) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { open(url) } }
            }
            return true
        }
        .focusedSceneValue(\.windowActions, actions)
    }

    // MARK: sidebar

    private var subtitle: String {
        guard model.hasContent else { return "" }
        let tables = model.schema.tables
        let embedded = tables.filter(\.isEmbeddable).count
        var parts = ["\(tables.count - embedded) collections"]
        if embedded > 0 { parts.append("\(embedded) embedded") }
        parts.append("\(model.schema.refs.filter { $0.kind == .reference }.count) refs")
        if model.file.diagrams.count > 1, let d = model.diagram { parts.insert(d.name, at: 0) }
        return parts.joined(separator: " · ")
    }

    private var filteredGroups: [(name: String, tables: [MoonKit.Table])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matches: (MoonKit.Table) -> Bool = { t in
            q.isEmpty || t.displayName.lowercased().contains(q) || t.columns.contains { $0.name.lowercased().contains(q) }
        }
        let shown = model.schema.tables.filter(matches)
        let collections = shown.filter { !$0.isEmbeddable }, embedded = shown.filter(\.isEmbeddable)
        return [("Collections", collections), ("Embedded Documents", embedded)].filter { !$0.1.isEmpty }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find table or column", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filteredGroups.first?.tables.first { model.select(first.id, focus: true) }
                    }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            .padding(.horizontal, 10).padding(.vertical, 8)

            // A lazy stack instead of List: stays smooth with thousands of tables.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(filteredGroups, id: \.name) { group in
                            Section {
                                ForEach(group.tables) { t in
                                    SidebarRow(table: t, color: model.style?.headerColors[t.id] ?? Palette.neutral,
                                               selected: model.selectedTables.contains(t.id)) {
                                        // ⌘/⇧-click adds to the selection, like on the canvas.
                                        if !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty { model.toggle(t.id) }
                                        else { model.select(t.id, focus: true) }
                                    }
                                    .id(t.id)
                                }
                            } header: {
                                HStack(spacing: 6) {
                                    Text(group.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                                .background(.bar)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .onChange(of: model.selection) { _, id in
                    if let id { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    // MARK: toolbar & banners

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if model.file.diagrams.count > 1 {
                Picker("Diagram", selection: Binding(get: { model.diagramID ?? "" }, set: { model.selectDiagram($0) })) {
                    ForEach(model.file.diagrams) { d in
                        Text("\(d.name)  (\(d.tableIDs.count))").tag(d.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 160)
                .help("Diagram (⌘[ and ⌘] switch)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.canvas?.zoom(by: 0.8, animated: true) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
            Button { model.canvas?.zoom(by: 1.25, animated: true) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
            Button { model.canvas?.zoomToFit() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Zoom to fit (⌘0)")
            Menu {
                Picker("Style", selection: Binding(get: { model.layoutStyle }, set: { model.arrange($0) })) {
                    ForEach(LayoutStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Arrange", systemImage: "rectangle.3.group")
            } primaryAction: {
                model.arrange()
            }
            // The toolbar keeps its menu once built; a new identity rebuilds it with the right checkmark.
            .id(model.layoutStyle)
            .help("Auto-arrange tables (\(model.layoutStyle.title), ⌘⇧L). Use the arrow to pick a style.")
            Menu {
                Button("Open…", action: openPanel)
                Button("Paste Model from Clipboard", action: pasteFromClipboard)
                Divider()
                Button("Use Layout from File", action: model.useFileLayout).disabled(!model.hasMovedTables)
                Button("Export PNG…", action: model.exportPNG)
                Button("Export Mongoose Schema…", action: model.exportMongoose)
                Button("Copy Mongoose Schema", action: model.copyMongoose)
            } label: { Label("More", systemImage: "ellipsis.circle") }
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
    }

    private var issuesButton: some View {
        Button { showIssues.toggle() } label: {
            Label("\(model.schema.diagnostics.count) issue\(model.schema.diagnostics.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .padding(14)
        .popover(isPresented: $showIssues) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.schema.diagnostics.enumerated()), id: \.offset) { _, d in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(d.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                            Text(d.message).font(.callout).foregroundStyle(d.severity == .error ? .red : .primary)
                        }
                    }
                }
                .padding(12)
            }
            .frame(width: 420, height: min(300, CGFloat(model.schema.diagnostics.count) * 24 + 30))
        }
    }

    private func banner(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .foregroundStyle(color)
            .padding(14)
    }

    // MARK: actions

    private func configureActions() {
        let model = model
        actions.open = openPanel
        actions.paste = pasteFromClipboard
        actions.export = { model.exportPNG() }
        actions.exportMongoose = { model.exportMongoose() }
        actions.copyMongoose = { model.copyMongoose() }
        actions.arrange = { model.arrange($0) }
        actions.useFileLayout = { model.useFileLayout() }
        actions.nextDiagram = { model.selectDiagram(offset: 1) }
        actions.previousDiagram = { model.selectDiagram(offset: -1) }
        actions.find = { searchFocused = true }
        actions.zoomIn = { model.canvas?.zoom(by: 1.25, animated: true) }
        actions.zoomOut = { model.canvas?.zoom(by: 0.8, animated: true) }
        actions.zoomFit = { model.canvas?.zoomToFit() }
        actions.zoomActual = { model.canvas?.zoom(by: 1 / (model.canvas?.zoom ?? 1), animated: true) }
        actions.toggleInspector = { showInspector.toggle() }
    }

    private func open(_ url: URL) {
        if fileURL == nil && !model.isPasted { fileURL = url } else { openWindow(value: url) }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dmm") ?? .json, .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        if model.hasContent {
            Opener.pendingPaste = text
            openWindow(id: "paste")
        } else {
            Opener.unregisterEmpty(windowID)
            model.loadPasted(text)
        }
    }
}

/// Window for a model pasted from the clipboard.
struct PasteWindowView: View {
    @State private var url: URL?
    @State private var text = Opener.takePaste()
    var body: some View {
        ContentView(fileURL: $url, initialPaste: text)
    }
}

private struct SidebarRow: View {
    let table: MoonKit.Table
    let color: NSColor
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            TableSwatch(table: table, color: color, size: 10)
            Text(table.displayName).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(table.columns.count)").font(.caption).monospacedDigit()
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let model: DocumentModel

    func makeNSView(context: Context) -> DiagramCanvas {
        let canvas = DiagramCanvas(frame: .zero)
        canvas.onSelect = { [weak model] id, tables in
            if model?.selection != id { model?.selection = id }
            if model?.selectedTables != tables { model?.selectedTables = tables }
        }
        canvas.onSelectRef = { [weak model] i in
            if model?.selectedRef != i { model?.selectedRef = i }
        }
        canvas.onTablesMoved = { [weak model] old, new, isNudge in model?.tablesMoved(old: old, new: new, isNudge: isNudge) }
        canvas.onViewportChanged = { [weak model] z, o in model?.viewportChanged(zoom: z, offset: o) }
        model.canvas = canvas
        model.push(to: canvas, fit: true)
        return canvas
    }

    func updateNSView(_ canvas: DiagramCanvas, context: Context) {}
}

struct EmptyStateView: View {
    let open: () -> Void
    let paste: () -> Void
    let openRecent: (URL) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "curlybraces.square")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Open a Moon Modeler model").font(.title2.weight(.semibold))
                Text("Drop a .dmm file here, open one, or paste its JSON from the clipboard.\nThe diagram reloads automatically when the file changes.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Open File…", action: open).keyboardShortcut("o").controlSize(.large).buttonStyle(.borderedProminent)
                Button("Paste Model", action: paste).controlSize(.large)
            }
            let recents = RecentFiles.all
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 8)
                    ForEach(recents.prefix(6), id: \.self) { url in
                        Button {
                            openRecent(url)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 440)
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

