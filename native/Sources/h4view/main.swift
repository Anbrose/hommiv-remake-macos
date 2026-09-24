import AppKit
import Metal
import MetalKit
import H4Engine

// h4view <Data/heroes4.h4r> <map.h4c> [--level N] [--snapshot out.png]
let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: h4view <Data/heroes4.h4r> <map.h4c> [--level N] [--snapshot out.png]")
    exit(2)
}
var level = 0
var snapshot: String?
var center: (Int, Int)?   // --center x,y: map cell to put in the middle of the view
var zoom: Float = 1       // --zoom z: initial scale
var walk: (Int, Int)?     // --walk x,y (with --snapshot): send the hero there and render 1.5 s later
var showBlocked = false   // --blocked: mark impassable cells (debug)
var heroAt: (Int, Int)?   // --hero x,y: put the hero there instead of at the town gate (debug)
var plan: (Int, Int)?     // --plan x,y (with --snapshot): show the route there without walking
var i = 3
while i < args.count {
    if args[i] == "--level", i + 1 < args.count { level = Int(args[i + 1]) ?? 0; i += 2 }
    else if args[i] == "--zoom", i + 1 < args.count { zoom = Float(args[i + 1]) ?? 1; i += 2 }
    else if args[i] == "--blocked" { showBlocked = true; i += 1 }
    else if (args[i] == "--hero" || args[i] == "--plan"), i + 1 < args.count {
        let p = args[i + 1].split(separator: ",").compactMap { Int($0) }
        if p.count == 2 { if args[i] == "--hero" { heroAt = (p[0], p[1]) } else { plan = (p[0], p[1]) } }
        i += 2
    }
    else if args[i] == "--walk", i + 1 < args.count {
        let p = args[i + 1].split(separator: ",").compactMap { Int($0) }
        if p.count == 2 { walk = (p[0], p[1]) }
        i += 2
    }
    else if args[i] == "--snapshot", i + 1 < args.count { snapshot = args[i + 1]; i += 2 }
    else if args[i] == "--center", i + 1 < args.count {
        let p = args[i + 1].split(separator: ",").compactMap { Int($0) }
        if p.count == 2 { center = (p[0], p[1]) }
        i += 2
    } else { i += 1 }
}

var t0 = Date()
func lap(_ what: String) { print("\(what): \(Int(Date().timeIntervalSince(t0) * 1000)) ms"); t0 = Date() }
let archive = try H4Archive(url: URL(fileURLWithPath: args[1]))
func writePNG(_ bm: Bitmap, to path: String) {
    // straight (non-premultiplied) RGBA: CGImage accepts it, CGContext would not
    guard let provider = CGDataProvider(data: Data(bm.pixels) as CFData),
          let img = CGImage(width: bm.width, height: bm.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bm.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else {
        print("  could not write \(path)"); return
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

if args[2] == "--dump" {   // h4view <h4r> --dump <entry>...: describe sprite entries, write each image as PNG (debugging aid)
    for name in args.dropFirst(3) {
        guard let e = archive.byName[name] else { print("\(name): not in archive"); continue }
        print("\(name): size \(e.size) unpacked \(e.unpackedSize) type \(e.type) alias '\(e.alias)'")
        if let s = try? Sprite(data: archive.payload(name)) {
            print("  \(s.images.count) images \(s.images.prefix(4).map { "\($0.name) \($0.box)" }) origin \(s.origin) footprint \(s.footprint)")
            if let dir = ProcessInfo.processInfo.environment["H4DUMP_DIR"] {
                for img in s.images { writePNG(img.bitmap, to: "\(dir)/\(name).\(img.name).png") }
            }
        } else { print("  sprite decode failed") }
    }
    exit(0)
}
let objNames = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
let map = try MapFile(data: Data(contentsOf: URL(fileURLWithPath: args[2])), objectNames: objNames)
let masks = try TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
lap("loaded '\(map.name)'")
let scene = try MapScene(map: map, level: min(level, map.levels - 1), archive: archive, masks: masks)
lap("scene built: \(scene.chunks.count) terrain chunks, \(scene.placed.count) objects")
let device = MTLCreateSystemDefaultDevice()!

// A scenario in progress: one hero of the leftmost town's alignment standing at its gate.
let resolver = RandomResolver(archive: archive)
let game = GameState(map: map, level: scene.level, scene: scene)
let alignments = ["haven": "life", "academy": "order", "asylum": "chaos", "necropolis": "death", "preserve": "nature", "stronghold": "might"]
if let town = scene.placed.filter({ $0.category == "castle" }).min(by: { ($0.cellY - $0.cellX) < ($1.cellY - $1.cellX) }) {
    let faction = alignments.first { town.name.lowercased().contains($0.key) }?.value ?? "life"
    // the gate is in the middle of the lower-right wall of right-facing (" R") towns, lower-left otherwise
    let right = town.name.lowercased().hasSuffix(" r.h4d")
    if let cell = heroAt ?? game.freeCell(near: town.cellX + (right ? 3 : 6), town.cellY + (right ? 6 : 3)) {
        game.heroes.append(Hero(actor: "hero.\(faction)_might_male", x: cell.0, y: cell.1))
        lap("hero at \(cell) by \(town.name)")
    }
}

if let out = snapshot {
    // Render one 1280x800 frame centred on the map into a texture and save it as PNG.
    let renderer = try Renderer(device: device, scene: scene, pixelFormat: .rgba8Unorm)
    renderer.game = game
    renderer.resolver = resolver
    renderer.showBlocked = showBlocked
    lap("textures uploaded")
    var snapTime = 0.0
    if let target = walk, let hero = game.heroes.first {
        if let p = scene.placed.first(where: { $0.cellX == target.0 && $0.cellY == target.1 && game.isPickup($0) }) {
            game.click(hero: hero, pickup: p)
            print("path to pickup \(p.name): \(hero.plan.map { "(\($0.x),\($0.y))" }.joined(separator: " "))")
            game.click(hero: hero, pickup: p)
        } else {
            game.click(hero: hero, x: target.0, y: target.1)
            print("path: \(hero.plan.map { "(\($0.x),\($0.y))" }.joined(separator: " "))")
            game.click(hero: hero, x: target.0, y: target.1)
        }
        for _ in 0..<90 { game.update(dt: 1.0 / 60) }   // 1.5 s of walking
        snapTime = 1.5
        for line in game.log { print(line) }
        game.log.removeAll()
        print("hero now at (\(hero.x),\(hero.y)) facing \(hero.facing), movement \(hero.movement), still walking: \(hero.isWalking)")
        let near = scene.placed.filter { game.isPickup($0) && abs($0.cellX - hero.x) <= 6 && abs($0.cellY - hero.y) <= 6 }
        print("pickups nearby: \(near.map { "\($0.name.dropFirst(11).dropLast(4))@(\($0.cellX),\($0.cellY))" }.joined(separator: ", "))")
    }
    if let target = plan, let hero = game.heroes.first {
        game.click(hero: hero, x: target.0, y: target.1)
        print("plan: \(game.arrows(for: hero).map { "\($0.name)@(\($0.x),\($0.y))" }.joined(separator: " "))")
    }
    let w = 1280, h = 800
    renderer.viewSize = SIMD2(Float(w), Float(h))
    renderer.zoom = zoom
    let c = center ?? game.heroes.first.map { ($0.x, $0.y) } ?? (map.size / 2, map.size / 2)
    let (sx, sy) = scene.screen(x: c.0, y: c.1)
    renderer.pan = SIMD2(Float(sx) - Float(w) / 2 / zoom, Float(sy) - Float(h) / 2 / zoom)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]
    let target = device.makeTexture(descriptor: td)!
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = target
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    renderer.encode(rpd: rpd, present: nil, time: snapTime)
    lap("frame rendered")
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    target.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(out)")
    exit(0)
}

final class MapView: MTKView {
    var renderer: Renderer!
    var dragged: Float = 0
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with e: NSEvent) { dragged = 0 }
    override func mouseDragged(with e: NSEvent) {
        dragged += abs(Float(e.deltaX)) + abs(Float(e.deltaY))
        renderer.pan -= SIMD2(Float(e.deltaX), Float(e.deltaY)) / renderer.zoom
    }
    override func mouseUp(with e: NSEvent) {
        guard dragged < 4, let g = renderer.game, let hero = g.heroes.first else { return }
        // window point -> map pixel -> cell (rounding x and y separately picks the diamond under the cursor)
        let p = convert(e.locationInWindow, from: nil)
        let scale = Float(window?.backingScaleFactor ?? 1)
        let mouse = SIMD2(Float(p.x) * scale, Float(bounds.height - p.y) * scale)
        let m = renderer.pan + mouse / renderer.zoom
        let u = (m.x - Float(g.map.size * 32 + 32)) / 32, v = (m.y - 32) / 16   // u = y - x, v = x + y
        var x = Int(((v - u) / 2).rounded()), y = Int(((v + u) / 2).rounded())
        // a pickup under the cursor (topmost drawn wins): walk next to it and take it
        if let p = renderer.scene.placed.last(where: { p in
            guard Float(p.x) <= m.x, m.x < Float(p.x + p.image.bitmap.width), Float(p.y) <= m.y, m.y < Float(p.y + p.image.bitmap.height) else { return false }
            let bm = p.image.bitmap
            return bm.pixels[((Int(m.y) - p.y) * bm.width + Int(m.x) - p.x) * 4 + 3] > 0 && g.isPickup(p)
        }) {
            g.click(hero: hero, pickup: p)
            return
        }
        if !g.passability.isFree(x, y) {
            // Clicked on something you cannot stand on. If an object's picture is under the cursor
            // (a bridge deck is drawn well above its cells), go to the nearest free cell of its
            // footprint; otherwise to the nearest free cell around the click.
            var best: (Int, Int)?
            var bestD = Float.infinity
            for p in renderer.scene.placed where Float(p.x) <= m.x && m.x < Float(p.x + p.image.bitmap.width) && Float(p.y) <= m.y && m.y < Float(p.y + p.image.bitmap.height) {
                let bm = p.image.bitmap
                let px = Int(m.x) - p.x, py = Int(m.y) - p.y
                guard bm.pixels[(py * bm.width + px) * 4 + 3] > 0 else { continue }
                for i in 0..<p.sprite.footprint.w {
                    for j in 0..<p.sprite.footprint.h where g.passability.isFree(p.cellX + i, p.cellY + j) {
                        let (cx, cy) = renderer.screen(Float(p.cellX + i), Float(p.cellY + j))
                        let d = (cx - m.x) * (cx - m.x) + (cy - m.y) * (cy - m.y)
                        if d < bestD { bestD = d; best = (p.cellX + i, p.cellY + j) }
                    }
                }
            }
            if best == nil, let c = g.freeCell(near: x, y), max(abs(c.0 - x), abs(c.1 - y)) <= 2 { best = c }
            guard let b = best else { return }
            (x, y) = b
        }
        g.click(hero: hero, x: x, y: y)
    }
    override func scrollWheel(with e: NSEvent) {
        renderer.pan -= SIMD2(Float(e.scrollingDeltaX), Float(e.scrollingDeltaY)) / renderer.zoom
    }
    override func magnify(with e: NSEvent) {
        let z = max(0.25, min(4, renderer.zoom * Float(1 + e.magnification)))
        let p = convert(e.locationInWindow, from: nil)
        let scale = Float(window?.backingScaleFactor ?? 1)
        let mouse = SIMD2(Float(p.x) * scale, Float(bounds.height - p.y) * scale)
        renderer.pan += mouse / renderer.zoom - mouse / z
        renderer.zoom = z
    }
    override func keyDown(with e: NSEvent) {
        let step: Float = 64 / renderer.zoom
        switch e.keyCode {
        case 123: renderer.pan.x -= step
        case 124: renderer.pan.x += step
        case 125: renderer.pan.y += step
        case 126: renderer.pan.y -= step
        case 36, 76: renderer.game?.endTurn()   // Return / Enter
        case 14: renderer.game?.endTurn()       // E
        default: break
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let view = MapView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        let renderer = try! Renderer(device: device, scene: scene, pixelFormat: .bgra8Unorm)
        renderer.game = game
        renderer.resolver = resolver
        renderer.showBlocked = showBlocked
        renderer.onTitle = { [weak self] t in if self?.window.title != t { self?.window.title = t } }
        view.renderer = renderer
        view.delegate = renderer
        renderer.viewSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        renderer.zoom = zoom
        let c = center ?? game.heroes.first.map { ($0.x, $0.y) } ?? (map.size / 2, map.size / 2)
        let (sx, sy) = scene.screen(x: c.0, y: c.1)
        renderer.pan = SIMD2(Float(sx) - renderer.viewSize.x / 2 / zoom, Float(sy) - renderer.viewSize.y / 2 / zoom)
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Heroes IV — \(map.name)"
        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        lap("window up")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
