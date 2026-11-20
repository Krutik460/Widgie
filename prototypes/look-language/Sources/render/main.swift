import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func peakRSSMB() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_maxrss) / 1_048_576
}

func die(_ message: String) -> Never {
    let line = message.replacingOccurrences(of: "\n", with: " ")
    FileHandle.standardError.write("error: \(line)\n".data(using: .utf8)!)
    exit(1)
}

func pixels(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf, w, h)
}

func loadPNG(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { die("cannot read image \(path)") }
    return img
}

// Share of sampled pixels that differ from the most common color. Near zero means a blank render.
func inkShare(_ image: CGImage) -> Double {
    let (buf, w, h) = pixels(image)
    var counts: [UInt32: Int] = [:]
    var total = 0
    for y in stride(from: 0, to: h, by: 3) {
        for x in stride(from: 0, to: w, by: 3) {
            let i = (y * w + x) * 4
            if buf[i + 3] == 0 { continue }
            let key = UInt32(buf[i] >> 3) << 16 | UInt32(buf[i + 1] >> 3) << 8 | UInt32(buf[i + 2] >> 3)
            counts[key, default: 0] += 1
            total += 1
        }
    }
    guard total > 0, let top = counts.values.max() else { return 0 }
    return 1 - Double(top) / Double(total)
}

func diffShare(_ a: CGImage, _ b: CGImage) -> Double {
    let (pa, wa, ha) = pixels(a)
    let (pb, wb, hb) = pixels(b)
    guard wa == wb, ha == hb else { return 1 }
    var differing = 0
    for i in stride(from: 0, to: pa.count, by: 4) {
        let d = abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
        if d > 24 { differing += 1 }
    }
    return Double(differing) / Double(wa * ha)
}

@MainActor
func runMain() {
    var args = CommandLine.arguments
    var assetArgs: [String] = []
    while let i = args.firstIndex(of: "--asset") {
        guard i + 1 < args.count else { die("--asset needs id=path") }
        assetArgs.append(args[i + 1])
        args.removeSubrange(i...i + 1)
    }
    if args.count == 3, args[1] == "fonts" {
        let (view, report) = fontSpecimen()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { die("cannot render the font specimen") }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        let out = try! JSONSerialization.data(withJSONObject: ["fonts": report, "pixel_width": image.width, "pixel_height": image.height], options: [.sortedKeys, .prettyPrinted])
        print(String(data: out, encoding: .utf8)!)
        exit(0)
    }
    if args.count == 4, args[1] == "diff" {
        print(String(format: "{\"diff_share\": %.4f}", diffShare(loadPNG(args[2]), loadPNG(args[3]))))
        exit(0)
    }
    if args.count > 4, args[1] == "montage", let cols = Int(args[3]) {
        // montage <out.png> <images per row> <png...>: review sheet at half pixel size.
        let images = args[4...].map { loadPNG($0) }
        let gap = 16
        var rows: [[CGImage]] = []
        for (i, img) in images.enumerated() {
            if i % cols == 0 { rows.append([]) }
            rows[rows.count - 1].append(img)
        }
        let rowWidths = rows.map { $0.reduce(gap) { $0 + $1.width / 2 + gap } }
        let rowHeights = rows.map { ($0.map { $0.height / 2 }.max() ?? 0) + gap }
        let w = rowWidths.max() ?? gap, h = rowHeights.reduce(gap, +)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.35, green: 0.35, blue: 0.38, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var y = h - gap
        for (r, row) in rows.enumerated() {
            var x = gap
            for img in row {
                ctx.draw(img, in: CGRect(x: x, y: y - img.height / 2, width: img.width / 2, height: img.height / 2))
                x += img.width / 2 + gap
            }
            y -= rowHeights[r]
        }
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        exit(0)
    }
    guard args.count == 6 else {
        die("usage: render <template|js> <look file> <data fixture json> <small|medium> <out png> [--asset id=path]...   or   render diff <a.png> <b.png>   or   render fonts <out png>")
    }
    let variant = args[1]
    let families: [String: CGSize] = ["small": CGSize(width: 158, height: 158), "medium": CGSize(width: 338, height: 158)]
    guard variant == "template" || variant == "js" else { die("variant must be template or js") }
    guard let size = families[args[4]] else { die("family must be small or medium") }
    guard let lookData = FileManager.default.contents(atPath: args[2]) else { die("cannot read look file \(args[2])") }
    guard let fixtureData = FileManager.default.contents(atPath: args[3]) else { die("cannot read fixture \(args[3])") }

    var stats: [String: Any] = ["ok": true, "variant": variant, "family": args[4]]

    do {
        var assetStats: [String: Any] = [:]
        for spec in assetArgs {
            guard let eq = spec.firstIndex(of: "="), eq != spec.startIndex else { die("--asset expects id=path, got \(spec)") }
            let id = String(spec[..<eq])
            let asset = try loadAsset(String(spec[spec.index(after: eq)...]))
            assetRegistry[id] = asset
            assetStats[id] = ["source": [asset.sourceWidth, asset.sourceHeight], "decoded": [asset.image.width, asset.image.height],
                              "decoded_pixels": asset.image.width * asset.image.height]
        }
        stats["assets"] = assetStats
        let data = try JSON.parse(fixtureData, what: "the data fixture")
        let footprintBefore = footprintMB()
        let t0 = nowMs()
        let tree: JSON
        if variant == "template" {
            let scope = Scope(vars: ["data": data, "family": .str(args[4]), "width": .num(size.width), "height": .num(size.height)])
            tree = try expandTemplate(source: lookData, scope: scope)
        } else {
            guard let source = String(data: lookData, encoding: .utf8) else { throw LookError("the script is not valid UTF-8") }
            let fixtureText = String(data: fixtureData, encoding: .utf8)!
            let ctxJson = "{\"data\": \(fixtureText), \"family\": \"\(args[4])\", \"width\": \(Int(size.width)), \"height\": \(Int(size.height))}"
            let run = try runJS(source: source, ctxJson: ctxJson, limitMs: 250)
            tree = run.tree
            stats["js_setup_ms"] = run.setupMs
            stats["js_eval_ms"] = run.evalMs
        }
        stats["tree_ms"] = nowMs() - t0
        stats["tree_footprint_mb"] = footprintMB() - footprintBefore

        // Measurement only: repeat the look evaluation in this warm process.
        if let n = ProcessInfo.processInfo.environment["LOOK_WARM_RUNS"].flatMap({ Int($0) }), n > 0 {
            var warm: [Double] = []
            for _ in 0..<n {
                let w0 = nowMs()
                if variant == "template" {
                    let scope = Scope(vars: ["data": data, "family": .str(args[4]), "width": .num(size.width), "height": .num(size.height)])
                    _ = try expandTemplate(source: lookData, scope: scope)
                } else {
                    let fixtureText = String(data: fixtureData, encoding: .utf8)!
                    let ctxJson = "{\"data\": \(fixtureText), \"family\": \"\(args[4])\", \"width\": \(Int(size.width)), \"height\": \(Int(size.height))}"
                    _ = try runJS(source: String(data: lookData, encoding: .utf8)!, ctxJson: ctxJson, limitMs: 250)
                }
                warm.append(nowMs() - w0)
            }
            warm.sort()
            stats["tree_ms_warm_median"] = warm[warm.count / 2]
            stats["tree_ms_warm_max"] = warm.last!
            stats["tree_footprint_mb_after_warm"] = footprintMB() - footprintBefore
        }

        let t1 = nowMs()
        let builder = Builder()
        let root = try builder.build(tree, "root", isRoot: true)
        var background = AnyView(Color.white)
        if case .obj(let d) = tree, let bg = d["widgetBackground"], !({ if case .null = bg { return true } else { return false } }()) {
            if case .obj(let bd) = bg, bd["type"] != nil {
                background = try builder.build(bg, "root.widgetBackground")
            } else {
                background = AnyView(Rectangle().fill(try parsePaint(bg, "root.widgetBackground")))
            }
        }
        let widget = ZStack {
            background.frame(width: size.width, height: size.height)
            root
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "widget")
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: widget)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(size)
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { throw LookError("the renderer produced no image") }
        stats["render_ms"] = nowMs() - t1
        builder.fit.enabled = false
        stats["fit"] = fitReport(builder.fit, widget: size)
        stats["assets_used"] = builder.assetsUsed.sorted()
        stats["fonts_used"] = builder.fontsUsed.sorted()

        let outURL = URL(fileURLWithPath: args[5])
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LookError("cannot write \(args[5])")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw LookError("cannot write \(args[5])") }

        // The size the root asks for when offered the widget size. Larger than the widget means clipped content.
        let probe = ImageRenderer(content: root.environment(\.colorScheme, .light))
        probe.scale = 1
        probe.proposedSize = ProposedViewSize(size)
        if let p = probe.cgImage {
            stats["content_width"] = p.width
            stats["content_height"] = p.height
            stats["overflow"] = CGFloat(p.width) > size.width + 0.5 || CGFloat(p.height) > size.height + 0.5
        }
        stats["ink_share"] = inkShare(image)
        stats["pixel_width"] = image.width
        stats["pixel_height"] = image.height
        stats["nodes"] = builder.nodeCount
        stats["actions"] = builder.actions.map { ["action": $0.action, "rowId": $0.rowId ?? NSNull()] as [String: Any] }
        stats["peak_rss_mb"] = peakRSSMB()
        stats["footprint_mb"] = footprintMB()
        let out = try JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys])
        print(String(data: out, encoding: .utf8)!)
    } catch let e as LookError {
        die(e.message)
    } catch {
        die("\(error)")
    }
}

MainActor.assumeIsolated { runMain() }
