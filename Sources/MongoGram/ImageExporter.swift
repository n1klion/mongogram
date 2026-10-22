import AppKit
import MoonKit
import UniformTypeIdentifiers

/// Renders a whole diagram into a bitmap, using the same drawing code as the canvas.
enum ImageExporter {
    static func render(_ scene: DiagramScene, theme: Theme, scale: CGFloat = 2) -> CGImage? {
        let margin: CGFloat = 48
        let bounds = scene.contentBounds.insetBy(dx: -margin, dy: -margin)
        // Keep huge diagrams under a sane bitmap size.
        let maxPixels: CGFloat = 16384
        let s = min(scale, maxPixels / max(bounds.width, 1), maxPixels / max(bounds.height, 1))
        let w = Int((bounds.width * s).rounded(.up)), h = Int((bounds.height * s).rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }

        // Flip to a y-down coordinate system matching the canvas.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)

        ctx.setFillColor(theme.background.cgColor)
        ctx.fill(bounds)

        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for ref in scene.schema.refs {
            guard let path = scene.edgePath(ref) else { continue }
            ctx.addPath(path)
            if ref.kind == .embedding {
                ctx.setStrokeColor(theme.embedded.withAlphaComponent(0.75).cgColor)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
            } else {
                ctx.setStrokeColor(theme.edge.cgColor)
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        for t in scene.schema.tables {
            let r = scene.rect(t.id)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(CGFloat(theme.shadowOpacity)).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: Metrics.cornerRadius, cornerHeight: Metrics.cornerRadius, transform: nil))
            ctx.setFillColor(theme.tableBody.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY)
            TableRenderer.draw(t, size: r.size, header: scene.style.headerColors[t.id] ?? Palette.neutral, theme: theme, in: ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// `MongoGram --render input.dmm output.png [--diagram name] [--auto | --style name] [--dark] [--scale N]`
    /// Without `--diagram`, renders the main diagram; `--diagram all` writes one PNG per diagram.
    /// `--auto` ignores the file's positions (Left to Right); `--style` picks another auto-arrange style.
    static func runCommandLine(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--render"), args.count > i + 2 else {
            FileHandle.standardError.write("usage: MongoGram --render input.dmm output.png [--diagram name|all] [--auto | --style leftRight|pipeline|compact] [--dark] [--scale N]\n".data(using: .utf8)!)
            return 2
        }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
        let input = URL(fileURLWithPath: args[i + 1]), output = URL(fileURLWithPath: args[i + 2])
        let scale = value("--scale").flatMap(Double.init) ?? 2
        let styleArg = value("--style")
        guard let style = styleArg.map({ LayoutStyle(rawValue: $0) }) ?? .leftRight else {
            FileHandle.standardError.write("error: unknown style; use one of: \(LayoutStyle.allCases.map(\.rawValue).joined(separator: ", "))\n".data(using: .utf8)!)
            return 2
        }
        do {
            let t0 = Date()
            let source = try String(contentsOf: input, encoding: .utf8)
            let schema = DMM.parse(source)
            let t1 = Date()
            for d in schema.diagnostics { print("\(d.severity == .error ? "error" : "warning"): \(d)") }
            if schema.isUnreadable { return 1 }
            let wanted = value("--diagram")
            let diagrams: [Diagram?]
            if wanted == "all" { diagrams = schema.diagrams }
            else if let wanted {
                guard let d = schema.diagrams.first(where: { $0.name == wanted || $0.id == wanted }) else {
                    FileHandle.standardError.write("error: no diagram named \(wanted). Diagrams: \(schema.diagrams.map(\.name).joined(separator: ", "))\n".data(using: .utf8)!)
                    return 1
                }
                diagrams = [d]
            } else { diagrams = [schema.mainDiagram] }

            for d in diagrams {
                let t2 = Date()
                var scene = DiagramScene(file: schema, diagram: d)
                if args.contains("--auto") || styleArg != nil {
                    scene.positions = SchemaLayout.compute(schema: scene.schema, tableIDs: scene.tableIDs, sizes: scene.sizes, style: style)
                } else {
                    scene.place(moved: [:])
                }
                let t3 = Date()
                guard let image = render(scene, theme: args.contains("--dark") ? .dark : .light, scale: CGFloat(scale)) else { return 1 }
                var dest = output
                if diagrams.count > 1, let d {
                    let safe = d.name.replacingOccurrences(of: "/", with: "-")
                    dest = output.deletingPathExtension().appendingPathExtension(safe).appendingPathExtension("png")
                }
                try writePNG(image, to: dest)
                let t4 = Date()
                print(String(format: "%@: %d tables, %d lines | parse %.1fms, measure+layout %.1fms, render %.1fms -> %@",
                             d?.name ?? "diagram", scene.schema.tables.count, scene.schema.refs.count,
                             t1.timeIntervalSince(t0) * 1000, t3.timeIntervalSince(t2) * 1000, t4.timeIntervalSince(t3) * 1000, dest.lastPathComponent))
            }
            return 0
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }
}
