import AppKit
import MoonKit
import UniformTypeIdentifiers

/// Save panel, clipboard and command line for Mongoose schema code.
enum MongooseExporter {
    private static let formatKey = "MongooseExportFormat"

    static var lastFormat: MongooseExport.Format {
        get { UserDefaults.standard.string(forKey: formatKey).flatMap(MongooseExport.Format.init(rawValue:)) ?? .commonJS }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: formatKey) }
    }

    static func contentType(_ format: MongooseExport.Format) -> UTType {
        UTType(filenameExtension: format.fileExtension) ?? .sourceCode
    }

    static func save(_ schema: Schema, name: String, sourceName: String?, window: NSWindow) {
        let panel = NSSavePanel()
        var format = lastFormat
        panel.allowedContentTypes = [contentType(format)]
        panel.nameFieldStringValue = "\(name).\(format.fileExtension)"

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: MongooseExport.Format.allCases.map(\.title))
        popup.selectItem(at: MongooseExport.Format.allCases.firstIndex(of: format) ?? 0)
        let handler = PopupHandler { i in
            format = MongooseExport.Format.allCases[i]
            panel.allowedContentTypes = [contentType(format)]
        }
        popup.target = handler
        popup.action = #selector(PopupHandler.changed(_:))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = row

        panel.beginSheetModal(for: window) { response in
            _ = handler
            guard response == .OK, let dest = panel.url else { return }
            lastFormat = format
            let code = MongooseExport.generate(schema, format: format, sourceName: sourceName)
            do {
                try code.write(to: dest, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    static func copy(_ schema: Schema, sourceName: String?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MongooseExport.generate(schema, format: lastFormat, sourceName: sourceName), forType: .string)
    }

    private final class PopupHandler: NSObject {
        let onChange: (Int) -> Void
        init(_ onChange: @escaping (Int) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSPopUpButton) { onChange(sender.indexOfSelectedItem) }
    }

    /// `MongoGram --mongoose input.dmm [output.js|.mjs|.ts] [--format cjs|esm|ts]`. Without an output, prints the code.
    static func runCommandLine(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--mongoose"), args.count > i + 1 else {
            FileHandle.standardError.write("usage: MongoGram --mongoose input.dmm [output.js|.mjs|.ts] [--format cjs|esm|ts]\n".data(using: .utf8)!)
            return 2
        }
        let input = URL(fileURLWithPath: args[i + 1])
        let output = args.count > i + 2 && !args[i + 2].hasPrefix("--") ? URL(fileURLWithPath: args[i + 2]) : nil
        let flag = args.firstIndex(of: "--format").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        let format: MongooseExport.Format
        switch flag ?? output?.pathExtension {
        case "esm", "mjs": format = .esModule
        case "ts": format = .typeScript
        case nil, "cjs", "js", "": format = .commonJS
        case let other?:
            FileHandle.standardError.write("error: unknown format \(other); use cjs, esm or ts\n".data(using: .utf8)!)
            return 2
        }
        do {
            let schema = DMM.parse(try String(contentsOf: input, encoding: .utf8))
            for d in schema.diagnostics {
                FileHandle.standardError.write("\(d.severity == .error ? "error" : "warning"): \(d)\n".data(using: .utf8)!)
            }
            if schema.isUnreadable { return 1 }
            let code = MongooseExport.generate(schema, format: format, sourceName: input.lastPathComponent)
            if let output {
                try code.write(to: output, atomically: true, encoding: .utf8)
            } else {
                FileHandle.standardOutput.write(code.data(using: .utf8)!)
            }
            return 0
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }
}
