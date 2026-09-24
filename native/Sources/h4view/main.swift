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
var openTown = false      // --town (with --snapshot): render the town screen
var openBuildList = false // --build: the town screen with its build list open
var openRecruit = false   // --recruit: the town screen with the first dwelling's recruit dialog open
var openHeroScreen = false // --heroscreen: the hero screen open
var openChest = false      // --chest: the treasure chest dialog open
var battleAt: (Int, Int)?  // --battle x,y (with --snapshot): open the combat screen against the monster on that cell
var battleSteps = 0        // --steps n: let the battle play n automatic actions first
var battleResults = false  // --results: show the results dialog (after --steps ran the battle to its end)
var heroAt: (Int, Int)?   // --hero x,y: put the hero there instead of at the town gate (debug)
var plan: (Int, Int)?     // --plan x,y (with --snapshot): show the route there without walking
var inspectAt: (Int, Int)? // --inspect x,y (with --snapshot): the right-click box for that cell
var movementLeft: Float?  // --movement n: the hero starts with n points left (debug)
var i = 3
while i < args.count {
    if args[i] == "--level", i + 1 < args.count { level = Int(args[i + 1]) ?? 0; i += 2 }
    else if args[i] == "--zoom", i + 1 < args.count { zoom = Float(args[i + 1]) ?? 1; i += 2 }
    else if args[i] == "--blocked" { showBlocked = true; i += 1 }
    else if args[i] == "--movement", i + 1 < args.count { movementLeft = Float(args[i + 1]); i += 2 }
    else if args[i] == "--town" { openTown = true; i += 1 }
    else if args[i] == "--build" { openTown = true; openBuildList = true; i += 1 }
    else if args[i] == "--recruit" { openTown = true; openRecruit = true; i += 1 }
    else if args[i] == "--heroscreen" { openHeroScreen = true; i += 1 }
    else if args[i] == "--battle", i + 1 < args.count { let p = args[i + 1].split(separator: ",").compactMap { Int($0) }; if p.count == 2 { battleAt = (p[0], p[1]) }; i += 2 }
    else if args[i] == "--steps", i + 1 < args.count { battleSteps = Int(args[i + 1]) ?? 0; i += 2 }
    else if args[i] == "--results" { battleResults = true; i += 1 }
    else if args[i] == "--chest" { openChest = true; i += 1 }
    else if (args[i] == "--hero" || args[i] == "--plan" || args[i] == "--inspect"), i + 1 < args.count {
        let p = args[i + 1].split(separator: ",").compactMap { Int($0) }
        if p.count == 2 { if args[i] == "--hero" { heroAt = (p[0], p[1]) } else if args[i] == "--plan" { plan = (p[0], p[1]) } else { inspectAt = (p[0], p[1]) } }
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

if args[2] == "--text", args.count >= 6 {   // h4view <h4r> --text <font entry> <text> <out.png>: render text with a game font (debugging aid)
    let font = try H4Font(data: archive.payload(args[3]))
    writePNG(font.render(args[4], colour: (40, 24, 8)), to: args[5])
    print("size \(font.size) line \(font.lineHeight) ascent \(font.ascent) glyphs \(font.glyphs.count); '\(args[4])' measures \(font.measure(args[4])) -> \(args[5])")
    exit(0)
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

// A scenario in progress: one hero of the first player's town (the map's owner 0, else the
// leftmost town) standing at its gate.
let resolver = RandomResolver(archive: archive)
let game = GameState(map: map, level: scene.level, scene: scene)
let textURL = URL(fileURLWithPath: args[1]).deletingLastPathComponent().appendingPathComponent("text.h4r")
if let text = try? H4Archive(url: textURL), let tables = try? RuleTables(archive: text) { game.tables = tables; lap("rules: \(tables.creatures.count) creatures, \(tables.heroes.count) heroes") }
let alignments = ["haven": "life", "academy": "order", "asylum": "chaos", "necropolis": "death", "preserve": "nature", "stronghold": "might"]
func faction(of name: String) -> String { alignments.first { name.lowercased().contains($0.key) }?.value ?? "life" }
game.registerObjects(townFactions: Dictionary(uniqueKeysWithValues: scene.placed.filter { $0.category == "castle" }.map { ($0.name, faction(of: $0.name)) }))
let ownedByFirst = map.objects.first { ($0.type == "town" || $0.type == "random_town") && $0.owner == 0 && $0.level == scene.level }
if let town = scene.placed.first(where: { p in ownedByFirst.map { p.category == "castle" && p.cellX == $0.x && p.cellY == $0.y } ?? false })
    ?? scene.placed.filter({ $0.category == "castle" }).min(by: { ($0.cellY - $0.cellX) < ($1.cellY - $1.cellX) }) {
    let align = faction(of: town.name)
    if let i = game.towns.firstIndex(where: { $0.x == town.cellX && $0.y == town.cellY }) { game.towns[i].owned = true }
    // the gate is in the middle of the lower-right wall of right-facing (" R") towns, lower-left otherwise
    let right = town.name.lowercased().hasSuffix(" r.h4d")
    if let cell = heroAt ?? game.freeCell(near: town.cellX + (right ? 3 : 6), town.cellY + (right ? 6 : 3)) {
        // a might hero of the town's alignment, picked from the heroes table (the male model exists for every class)
        let cls = RuleTables.classes[align]?.might ?? "knight"
        let candidates = game.tables?.heroes(ofClass: cls).filter { $0.sex == "male" } ?? []
        let def = candidates.isEmpty ? nil : candidates[(town.cellX + town.cellY) % candidates.count]
        let hero = Hero(actor: "hero.\(align)_might_male", x: cell.0, y: cell.1, movement: Hero.baseMovement)
        hero.name = def?.name ?? "Hero"; hero.keyword = def?.keyword ?? ""; hero.alignment = align
        hero.home = (cell.0, cell.1)
        game.giveStartingArmy(hero)
        if let m = movementLeft { hero.movement = m }
        game.heroes.append(hero)
        lap("\(hero.name) the \(cls) at \(cell) by \(game.towns.first { $0.owned }?.name ?? town.name)")
    }
}

// The adventure screen chrome (frame, panel, fonts); the map alone if the UI files are missing.
var ui: AdventureUI? = nil
var townScreen: TownScreen? = nil
var combatScreen: CombatScreen? = nil
do { ui = try AdventureUI(archive: archive, index: resolver); townScreen = try TownScreen(archive: archive); combatScreen = try CombatScreen(archive: archive); lap("ui loaded") } catch { print("no UI: \(error)") }

/// Camera setup shared by the window and the snapshot: 1 map pixel per canvas pixel times
/// the requested zoom, the requested cell in the middle of the map viewport.
func aim(_ renderer: Renderer, at c: (Int, Int)) {
    renderer.zoom = zoom * (ui == nil ? 1 : renderer.uiScale)
    let viewportW = ui == nil ? renderer.viewSize.x : Float(AdventureUI.mapViewportWidth) * renderer.uiScale
    let (sx, sy) = scene.screen(x: c.0, y: c.1)
    renderer.pan = SIMD2(Float(sx) - viewportW / 2 / renderer.zoom, Float(sy) - renderer.viewSize.y / 2 / renderer.zoom)
}

if let out = snapshot {
    // Render one 1024x768 frame centred on the map into a texture and save it as PNG.
    let renderer = try Renderer(device: device, scene: scene, pixelFormat: .rgba8Unorm)
    renderer.game = game
    renderer.resolver = resolver
    renderer.showBlocked = showBlocked
    renderer.ui = ui
    renderer.town = townScreen
    renderer.combat = combatScreen
    if walk != nil { game.quickCombatOnly = true }   // --walk snapshots resolve fights at once
    if let target = battleAt, let hero = game.heroes.first, let cs = combatScreen,
       let p = scene.placed.first(where: { $0.cellX == target.0 && $0.cellY == target.1 }), let mi = game.monster(for: p) {
        cs.start(game: game, hero: hero, monsterAt: mi, p, terrain: 1)
        if let b = cs.battle { for _ in 0..<battleSteps { b.autoAct() }; _ = b.takeEvents(); cs.pump(); if b.finished != nil { cs.result = (b.finished!, b.round); cs.showResults = battleResults } }
        print("battle: round \(cs.battle?.round ?? 0), units \(cs.battle?.units.map { "\($0.stats.name)x\($0.stats.count)@(\($0.x),\($0.y))" }.joined(separator: " ") ?? "")")
    }
    if openHeroScreen { renderer.adventureDialog = .hero(0) }
    if openChest, let h = game.heroes.first { game.chestOffer = (h, 1500, 1000); renderer.adventureDialog = .chest; renderer.chestChoice = true }
    if openTown {
        renderer.townOpen = game.towns.firstIndex { $0.owned }
        if openBuildList { renderer.townDialog = .buildList }
        if openRecruit, let i = renderer.townOpen, let slot = townScreen?.hotspot("dwelling_1") { _ = i; renderer.townClick(x: Float(slot.x + 5), y: Float(slot.y + 5)) }
    }
    lap("textures uploaded")
    var snapTime = 0.0
    if let target = walk, let hero = game.heroes.first {
        if let p = scene.placed.first(where: { $0.cellX == target.0 && $0.cellY == target.1 && game.isVisitable($0) }) {
            game.click(hero: hero, pickup: p)
            print("path to pickup \(p.name): \(hero.plan.map { "(\($0.x),\($0.y))" }.joined(separator: " "))")
            game.click(hero: hero, pickup: p)
        } else {
            game.click(hero: hero, x: target.0, y: target.1)
            print("path: \(hero.plan.map { "(\($0.x),\($0.y))" }.joined(separator: " "))")
            game.click(hero: hero, x: target.0, y: target.1)
        }
        var frames = 0
        while frames < 600, game.heroes.first?.isWalking == true || frames < 90 { game.update(dt: 1.0 / 60); frames += 1 }   // walk until arrival (at least 1.5 s)
        snapTime = Double(frames) / 60
        for line in game.log { print(line) }
        game.log.removeAll()
        print("hero now at (\(hero.x),\(hero.y)) facing \(hero.facing), movement \(hero.movement), still walking: \(hero.isWalking)")
        let near = scene.placed.filter { game.isPickup($0) && abs($0.cellX - hero.x) <= 6 && abs($0.cellY - hero.y) <= 6 }
        print("pickups nearby: \(near.map { "\($0.name.dropFirst(11).dropLast(4))@(\($0.cellX),\($0.cellY))" }.joined(separator: ", "))")
    }
    if let target = plan, let hero = game.heroes.first {   // a click on that cell's centre, as the mouse would do it
        let (sx, sy) = scene.screen(x: target.0, y: target.1)
        renderer.click(mapPoint: SIMD2(Float(sx), Float(sy)))
        print("plan: \(game.arrows(for: hero).map { "\($0.name)@(\($0.x),\($0.y))" }.joined(separator: " "))")
    }
    let w = ui == nil ? 1280 : AdventureUI.width, h = ui == nil ? 800 : AdventureUI.height
    renderer.viewSize = SIMD2(Float(w), Float(h))
    aim(renderer, at: center ?? game.heroes.first.map { ($0.x, $0.y) } ?? (map.size / 2, map.size / 2))
    if let target = inspectAt {   // the status line, then a right click on that cell's centre
        let (sx, sy) = scene.screen(x: target.0, y: target.1)
        let m = SIMD2(Float(sx), Float(sy))
        let canvas = (m - renderer.pan) * renderer.zoom / renderer.uiScale
        if let text = renderer.statusText(mapPoint: m) { renderer.hover = (text, Int(canvas.x), Int(canvas.y)); print("status: \(text)") }
    }
    if let target = inspectAt {   // a right click on that cell's centre
        let (sx, sy) = scene.screen(x: target.0, y: target.1)
        let m = SIMD2(Float(sx), Float(sy))
        let canvas = (m - renderer.pan) * renderer.zoom / renderer.uiScale
        renderer.inspect(mapPoint: m, canvas: (canvas.x, canvas.y))
        print("inspect (\(target.0),\(target.1)): \(renderer.popup.map { "\($0.title) | " + $0.lines.joined(separator: " / ") } ?? renderer.creatureDialog.map { "dialog: \($0.count) \($0.creature.plural)" } ?? "nothing")")
    }
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

/// The game's animated mouse pointers (layers.cursor.<name>: frames "1".."4" and a hot_spot
/// layer whose rectangle marks the hot spot; single-frame files hold "Layer 1").
final class GameCursors {
    struct Set { let frames: [NSCursor] }
    var sets: [String: Set] = [:]
    let archive: H4Archive

    init(archive: H4Archive) { self.archive = archive }

    static func image(_ bm: Bitmap) -> NSImage? {
        guard let provider = CGDataProvider(data: Data(bm.pixels) as CFData),
              let img = CGImage(width: bm.width, height: bm.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bm.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: bm.width, height: bm.height))
    }

    func set(_ name: String) -> Set? {
        if let s = sets[name] { return s }
        let file = name == "normal" ? "layers.cursor.combat.normal.h4d" : "layers.cursor.\(name).h4d"
        if name == "combat.normal" { return set("normal") }
        guard let d = try? archive.payload(file), let f = try? LayerFile(data: d) else { return nil }
        let hot = f.layers.first { $0.name.lowercased() == "hot_spot" }.map { NSPoint(x: $0.x, y: $0.y) } ?? NSPoint(x: 0, y: 0)
        var frames: [NSCursor] = []
        for l in f.layers where l.name.lowercased() != "hot_spot" && l.width > 0 {
            if let img = GameCursors.image(l.bitmap) { frames.append(NSCursor(image: img, hotSpot: hot)) }
        }
        guard !frames.isEmpty else { return nil }
        let s = Set(frames: frames)
        sets[name] = s
        return s
    }
}

final class MapView: MTKView {
    var renderer: Renderer!
    var dragged: Float = 0
    var cursors: GameCursors?
    var cursorName = "normal"
    var cursorFrame = 0
    var cursorTimer: Timer?
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
        if cursorTimer == nil {
            cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tickCursor() }
        }
    }
    func tickCursor() {
        tickHover()
        guard let s = cursors?.set(cursorName) else { return }
        cursorFrame = (cursorFrame + 1) % s.frames.count
        s.frames[cursorFrame].set()
    }
    /// Pick the pointer for what is under the mouse: the plain arrow over the panel, the
    /// town screen and open boxes; on the map, what a click there would do.
    override func mouseMoved(with e: NSEvent) {
        guard let g = renderer.game, g.heroes.first != nil else { return }
        let p = convert(e.locationInWindow, from: nil)
        let scale = Float(window?.backingScaleFactor ?? 1)
        let mouse = SIMD2(Float(p.x) * scale, Float(bounds.height - p.y) * scale)
        let cx = mouse.x / renderer.uiScale
        var name = "normal"
        if renderer.inCombat { name = renderer.combatCursor(x: cx, y: mouse.y / renderer.uiScale) }
        else if renderer.townOpen == nil, renderer.popup == nil, renderer.creatureDialog == nil, renderer.adventureDialog == nil, renderer.ui == nil || cx < Float(AdventureUI.mapViewportWidth) {
            name = renderer.cursorKind(mapPoint: renderer.pan + mouse / renderer.zoom)
        }
        if name != cursorName { cursorName = name; cursorFrame = 0; cursors?.set(name)?.frames.first?.set() }
        // the status line appears once the pointer rests on the map for a moment
        renderer.hover = nil
        hoverPending = (name == "normal" && (renderer.ui == nil || cx >= Float(AdventureUI.mapViewportWidth))) || (renderer.inCombat && !name.hasPrefix("combat.melee") && name != "combat.shoot") ? nil : (mouse, Date())
    }
    var hoverPending: (mouse: SIMD2<Float>, since: Date)?
    func tickHover() {
        guard let p = hoverPending, Date().timeIntervalSince(p.since) > 0.4, renderer.hover == nil, renderer.townOpen == nil else { return }
        if renderer.inCombat {
            if let text = renderer.combatStatusText(x: p.mouse.x / renderer.uiScale, y: p.mouse.y / renderer.uiScale) {
                renderer.hover = (text, Int(p.mouse.x / renderer.uiScale), Int(p.mouse.y / renderer.uiScale))
            }
            return
        }
        if let text = renderer.statusText(mapPoint: renderer.pan + p.mouse / renderer.zoom) {
            renderer.hover = (text, Int(p.mouse.x / renderer.uiScale), Int(p.mouse.y / renderer.uiScale))
        }
    }
    override func mouseExited(with e: NSEvent) { NSCursor.arrow.set(); cursorName = ""; renderer.hover = nil; hoverPending = nil }
    override func mouseDown(with e: NSEvent) { dragged = 0; renderer.hover = nil; hoverPending = nil }
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
        if renderer.inCombat {
            renderer.combatClick(x: mouse.x / renderer.uiScale, y: mouse.y / renderer.uiScale)
            return
        }
        if renderer.popup != nil {   // an open right-click box: a left click outside it closes it, and does nothing else
            let cx = mouse.x / renderer.uiScale, cy = mouse.y / renderer.uiScale
            if !renderer.onPopup(cx, cy) { renderer.popup = nil }
            return
        }
        if renderer.adventureDialog != nil {
            let cx = mouse.x / renderer.uiScale, cy = mouse.y / renderer.uiScale
            _ = renderer.adventureDialogClick(x: cx, y: cy)
            return
        }
        if renderer.creatureDialog != nil {   // the creature dialog: Close, or a click outside it
            let cx = mouse.x / renderer.uiScale, cy = mouse.y / renderer.uiScale
            let hit = renderer.onDialog(cx, cy)
            if hit.close || !hit.inside { renderer.creatureDialog = nil }
            return
        }
        if let ui = renderer.ui {   // the panel: only its buttons react
            let cx = mouse.x / renderer.uiScale, cy = mouse.y / renderer.uiScale
            if renderer.townOpen != nil { renderer.townClick(x: cx, y: cy); return }
            if cx >= Float(AdventureUI.mapViewportWidth) {
                if ui.hit("end_turn", x: cx, y: cy) { g.endTurn() }
                else if ui.hit("Town_list", x: cx, y: cy), let i = g.towns.firstIndex(where: { $0.owned }) { renderer.townOpen = i }
                else if ui.hit("Hero_List", x: cx, y: cy) {   // a portrait opens the hero screen
                    for (i, (hx, hy)) in AdventureUI.heroSlots.enumerated() where i < g.heroes.count && abs(cx - Float(hx)) < 30 && abs(cy - Float(hy)) < 30 { renderer.adventureDialog = .hero(i) }
                }
                return
            }
        }
        renderer.click(mapPoint: renderer.pan + mouse / renderer.zoom)
    }
    /// Right click: opens a box describing what is under the cursor; it stays until a left
    /// click lands outside it (as in the game).
    override func rightMouseDown(with e: NSEvent) {
        guard renderer.townOpen == nil else { return }
        let p = convert(e.locationInWindow, from: nil)
        let scale = Float(window?.backingScaleFactor ?? 1)
        let mouse = SIMD2(Float(p.x) * scale, Float(bounds.height - p.y) * scale)
        let cx = mouse.x / renderer.uiScale, cy = mouse.y / renderer.uiScale
        if renderer.onPopup(cx, cy) || renderer.onDialog(cx, cy).inside { return }
        if renderer.ui != nil, cx >= Float(AdventureUI.mapViewportWidth) { renderer.popup = nil; renderer.creatureDialog = nil; return }
        renderer.inspect(mapPoint: renderer.pan + mouse / renderer.zoom, canvas: (cx, cy))
    }
    override func scrollWheel(with e: NSEvent) {
        if renderer.townOpen != nil {   // the build list pages with the wheel
            if case .buildList? = renderer.townDialog, abs(e.scrollingDeltaY) > 2 { renderer.buildPage = max(0, renderer.buildPage + (e.scrollingDeltaY < 0 ? 1 : -1)) }
            return
        }
        if renderer.adventureDialog != nil { return }
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
        case 123, 124:   // arrows pan the map, or page the build list
            if case .buildList? = renderer.townDialog { renderer.buildPage = max(0, renderer.buildPage + (e.keyCode == 124 ? 1 : -1)) }
            else { renderer.pan.x += e.keyCode == 124 ? step : -step }
        case 125: renderer.pan.y += step
        case 126: renderer.pan.y -= step
        case 36, 76: if renderer.townOpen == nil, !renderer.inCombat { renderer.game?.endTurn() }   // Return / Enter
        case 14: if renderer.townOpen == nil, !renderer.inCombat { renderer.game?.endTurn() }       // E
        case 1: if renderer.inCombat, let b = renderer.combat?.battle, !(renderer.combat?.busy ?? true), b.finished == nil { b.wait(); renderer.combat?.pump() }   // S = wait
        case 2: if renderer.inCombat, let b = renderer.combat?.battle, !(renderer.combat?.busy ?? true), b.finished == nil { b.defend(); renderer.combat?.pump() } // D = defend
        case 53:   // Escape closes a dialog, then leaves the town
            if renderer.townDialog != nil { renderer.townDialog = nil }
            else if renderer.townOpen != nil { renderer.townOpen = nil }
            else if case .hero? = renderer.adventureDialog { renderer.adventureDialog = nil }
        default: break
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let size = ui == nil ? NSSize(width: 1280, height: 800) : NSSize(width: AdventureUI.width, height: AdventureUI.height)
        let view = MapView(frame: NSRect(origin: .zero, size: size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        let renderer = try! Renderer(device: device, scene: scene, pixelFormat: .bgra8Unorm)
        renderer.game = game
        renderer.resolver = resolver
        renderer.showBlocked = showBlocked
        renderer.ui = ui
        renderer.town = townScreen
        renderer.combat = combatScreen
        renderer.onTitle = { [weak self] t in if self?.window.title != t { self?.window.title = t } }
        view.renderer = renderer
        view.cursors = GameCursors(archive: archive)
        view.delegate = renderer
        renderer.viewSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        aim(renderer, at: center ?? game.heroes.first.map { ($0.x, $0.y) } ?? (map.size / 2, map.size / 2))
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.contentAspectRatio = size
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
