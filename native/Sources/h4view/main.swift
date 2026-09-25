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
var loadFile: String?     // --load <file.h4s>: start from a saved game
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
    else if args[i] == "--load", i + 1 < args.count { loadFile = args[i + 1]; i += 2 }
    else if args[i] == "--center", i + 1 < args.count {
        let p = args[i + 1].split(separator: ",").compactMap { Int($0) }
        if p.count == 2 { center = (p[0], p[1]) }
        i += 2
    } else { i += 1 }
}

var t0 = Date()
func lap(_ what: String) { print("\(what): \(Int(Date().timeIntervalSince(t0) * 1000)) ms"); t0 = Date() }
let archive = try H4Archive(url: URL(fileURLWithPath: args[1]))
let movies = Movies(dataDirectory: URL(fileURLWithPath: args[1]).deletingLastPathComponent())
let gameSound = GameSound(dataDirectory: URL(fileURLWithPath: args[1]).deletingLastPathComponent())
if let names = ProcessInfo.processInfo.environment["H4SOUNDCHECK"] {   // debugging aid: which sounds exist and decode
    for n in names.split(separator: ",") { print("\(n): \(gameSound.data(String(n)).map { "\($0.count) bytes" } ?? "missing")") }
    exit(0)
}
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
if args[2] == "--raw", args.count >= 5 {   // h4view <h4r> --raw <entry> <out>: write an entry's unpacked bytes (debugging aid)
    try archive.payload(args[3]).write(to: URL(fileURLWithPath: args[4]))
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
if ProcessInfo.processInfo.environment["H4DEBUG"] != nil {
    print("scenario: teams \(map.teams.sorted { $0.key < $1.key }) standard victory \(map.standardVictory) win '\(map.victoryText ?? "-")' loss '\(map.lossText ?? "-")' players \(map.playerSpecs.map { "\($0.colour):\($0.canBeHuman ? "h" : "ai"):\(String($0.alignments, radix: 2))" })")
}
// the rule tables first: random monsters are drawn from the creature table
let textURL = URL(fileURLWithPath: args[1]).deletingLastPathComponent().appendingPathComponent("text.h4r")
let ruleTables = (try? H4Archive(url: textURL)).flatMap { try? RuleTables(archive: $0) }
if let t = ruleTables {
    let expansion = max(0, min(2, map.version - 27))
    let sea: Set<String> = ["mermaid", "sea monster", "pirate"]
    RandomResolver.creaturePool = (1...4).map { lv in t.creatures.filter { $0.level == lv && $0.expansion <= expansion && !sea.contains($0.keyword) }.map { $0.keyword } }
}
RandomResolver.playerAlignments = Dictionary(map.playerSpecs.map { ($0.colour, $0.alignments) }, uniquingKeysWith: { a, _ in a })
// every level of the map (the surface and, on most maps, the underground)
let scenes = try (0..<max(1, map.levels)).map { try MapScene(map: map, level: $0, archive: archive, masks: masks) }
let scene = scenes[min(level, scenes.count - 1)]
lap("scenes built: \(scenes.map { "\($0.chunks.count) terrain chunks, \($0.placed.count) objects" }.joined(separator: "; "))")
let device = MTLCreateSystemDefaultDevice()!

// A scenario in progress: one hero of the first player's town (the map's owner 0, else the
// leftmost town) standing at its gate.
let resolver = RandomResolver(archive: archive)
let game = GameState(map: map, level: scene.level, scenes: scenes)
if let tables = ruleTables { game.tables = tables; lap("rules: \(tables.creatures.count) creatures, \(tables.heroes.count) heroes") }
let alignments = ["haven": "life", "academy": "order", "asylum": "chaos", "necropolis": "death", "preserve": "nature", "stronghold": "might"]
func faction(of name: String) -> String { alignments.first { name.lowercased().contains($0.key) }?.value ?? "life" }
game.registerObjects(townFactions: Dictionary(scenes.flatMap { $0.placed }.filter { $0.category == "castle" }.map { ($0.name, faction(of: $0.name)) }, uniquingKeysWith: { a, _ in a }))
game.setupObjects()   // chests, piles, generators: their contents are rolled as the game starts
let ownedByFirst = map.objects.first { ($0.type == "town" || $0.type == "random_town") && $0.owner == map.humanColour && $0.level == scene.level }
if let town = scene.placed.first(where: { p in ownedByFirst.map { p.category == "castle" && p.cellX == $0.x && p.cellY == $0.y } ?? false })
    ?? scene.placed.filter({ $0.category == "castle" }).min(by: { ($0.cellY - $0.cellX) < ($1.cellY - $1.cellX) }) {
    let align = faction(of: town.name)
    if let i = game.towns.firstIndex(where: { $0.x == town.cellX && $0.y == town.cellY }) { game.towns[i].owned = true; game.towns[i].owner = map.humanColour }
    // the gate is in the middle of the lower-right wall of right-facing (" R") towns, lower-left otherwise
    let right = town.name.lowercased().hasSuffix(" r.h4d")
    // the heroes the map places for the player (armies with heroes: "Beyond the Lake" starts a
    // level 15 and a level 10 hero together); a hero at the town gate when it has none
    let placed = map.objects.filter { $0.type == "hero_army" && $0.owner == map.humanColour && $0.level == scene.level && !$0.heroes.isEmpty }
    for o in placed {
        var all = o.heroes.map { Hero.fromMap($0, alignment: align, x: o.x, y: o.y, tables: game.tables, random: &game.random) }
        let hero = all.removeFirst()
        hero.companions = all
        hero.home = (o.x, o.y); hero.z = o.level
        hero.army = (o.army ?? []).compactMap { $0 }.compactMap { s in
            s.creature < RuleTables.creatureIds.count ? Hero.Stack(creature: RuleTables.creatureIds[s.creature], count: s.count) : nil }
        hero.maxMovement = game.armyMovement(hero); hero.movement = hero.maxMovement
        if let m = movementLeft { hero.movement = m }
        game.heroes.append(hero)
        lap("\(hero.name) level \(hero.level) \(hero.classKeyword) at (\(o.x),\(o.y)) skills \(hero.skills) with \(all.map { "\($0.name) level \($0.level) \($0.classKeyword) \($0.skills)" })")
    }
    if placed.isEmpty, let cell = heroAt ?? game.freeCell(near: town.cellX + (right ? 3 : 6), town.cellY + (right ? 6 : 3)) {
        // a might hero of the town's alignment, picked from the heroes table (the male model exists for every class)
        let cls = RuleTables.classes[align]?.might ?? "knight"
        let candidates = game.tables?.heroes(ofClass: cls).filter { $0.sex == "male" } ?? []
        let def = candidates.isEmpty ? nil : candidates[(town.cellX + town.cellY) % candidates.count]
        let hero = Hero(actor: "hero.\(align)_might_male", x: cell.0, y: cell.1, movement: Hero.baseMovement)
        hero.name = def?.name ?? "Hero"; hero.keyword = def?.keyword ?? ""; hero.alignment = align
        if let c = RuleTables.heroClasses.firstIndex(where: { $0.keyword == cls }) {
            hero.heroClass = c
            for s in RuleTables.heroClasses[c].skills { hero.learn(s, level: 0) }
        }
        hero.home = (cell.0, cell.1); hero.z = scene.level
        game.giveStartingArmy(hero)
        if let m = movementLeft { hero.movement = m }
        game.heroes.append(hero)
        lap("\(hero.name) the \(cls) at \(cell) by \(game.towns.first { $0.owned }?.name ?? town.name)")
    }
}
if let f = ProcessInfo.processInfo.environment["H4HEROAT"] {   // debugging aid: parse a hero record at file:offset of a raw map dump
    let parts = f.split(separator: ":")
    if parts.count == 2, let d = try? Data(contentsOf: URL(fileURLWithPath: String(parts[0]))), let off = Int(parts[1]) {
        if let (h, end) = MapFile.parseHero(d, at: off) { print("hero lv\(h.level) end \(end) events \(h.events.count)") } else { print("hero parse failed") }
        if let ev = ProcessInfo.processInfo.environment["H4EVAT"].flatMap({ Int($0) }) {
            var sr = ScriptReader(d, at: ev)
            do { _ = try sr.builtinEvent(slot: 0); print("builtin ok at \(sr.position)")
                 let t = try sr.list({ try $0.timedEvent() }); print("timed \(t.count) at \(sr.position)")
                 let g = try sr.list({ try $0.triggerableEvent() }); print("trig \(g.count) at \(sr.position)")
                 let c = try sr.list({ try $0.continuousEvent() }); print("cont \(c.count) at \(sr.position)") }
            catch { print("event error \(error) at \(sr.position)") }
        }
    }
    exit(0)
}
if ProcessInfo.processInfo.environment["H4DEBUG"] != nil {
    for o in game.map.objects where o.type == "hero_army" {
        print("hero army of player \(o.owner ?? -1) at (\(o.x),\(o.y)): stacks \(o.army?.compactMap { $0 }.map { "\($0.count)x\($0.creature)" } ?? []) heroes \(o.heroes.map { "lv\($0.level) class \($0.heroClass) portrait \($0.portrait) '\($0.name)' skills \($0.skills.map { "\($0)" } ?? "random") equipped \($0.equipped) backpack \($0.backpack)" })")
    }
}
if ProcessInfo.processInfo.environment["H4AMBIENT"] != nil {   // debugging aid: the objects that have an ambient sound
    let snd = GameSound(dataDirectory: URL(fileURLWithPath: args[1]).deletingLastPathComponent())
    var found: [String: Int] = [:], missing: [String: Int] = [:]
    for p in scene.placed where !p.type.isEmpty {
        let full = "adv_object.\(p.type).\(p.subtype)", short = "adv_object.\(p.type)"
        if let n = [full, short].first(where: { snd.has($0) }) { found[n, default: 0] += 1 } else { missing[full, default: 0] += 1 }
    }
    print("ambient found \(found)\nnone for \(missing)")
    exit(0)
}
if ProcessInfo.processInfo.environment["H4VISITALL"] != nil, let h = game.heroes.first {   // debugging aid: every object's visit, once
    var seen: Set<String> = []
    for p in scene.placed where game.hasVisit(p) && !seen.contains("\(p.type).\(p.subtype)") {
        seen.insert("\(p.type).\(p.subtype)")
        let before = game.resources, lv = h.level
        game.scripts.messages = []; game.floaters = []
        _ = game.debugVisit(hero: h, p)
        let diff = game.resources.filter { $0.value != before[$0.key] }.map { "\($0.key) \($0.value - (before[$0.key] ?? 0))" }
        print("== \(p.type).\(p.subtype) at (\(p.cellX),\(p.cellY)): \(diff) floaters \(game.floaters.map { $0.text }) level \(lv)->\(h.level) q \(game.question?.text.prefix(60) ?? "-") chest \(game.chestOffer.map { "\($0.gold)/\($0.experience)" } ?? "-")")
        for m in game.scripts.messages { print("   \(m.prefix(150))") }
        if let c = game.choice { print("   choice: \(c.text.prefix(80)) -> \(c.options)") }
        game.question = nil; game.chestOffer = nil; game.choice = nil
    }
    print("resources now \(game.resources)")
    print("hero: atk+\(h.attackBonus) def+\(h.defenseBonus) spd+\(h.speedBonus) sp+\(h.spellPointBonus) exp \(h.experience) luck \(h.armyLuck) morale \(h.armyMorale) temple \(h.templeAlignment ?? "-") backpack \(h.backpack.map { game.artifactName($0) })")
    exit(0)
}
// the map's scripts: loaded, then day 1's events (the opening story, ...)
game.loadScripts()
// a saved game: its state over the freshly started scenario (day events already ran then)
if let f = loadFile, let save = try? SaveGame.read(URL(fileURLWithPath: f)) {
    game.restore(save); lap("loaded \(f)")
    if let h = game.heroes.first { print("loaded: day \(game.day), hero at (\(h.x),\(h.y)), movement \(h.movement), gold \(game.resources["Gold"] ?? 0), monsters \(game.monsters.count), objects \(scene.placed.count)") }
}
else { game.runDayEvents() }
for m in game.scripts.messages { print("script text: \(m.prefix(100))") }

// The adventure screen chrome (frame, panel, fonts); the map alone if the UI files are missing.
var ui: AdventureUI? = nil
var townScreen: TownScreen? = nil
var combatScreen: CombatScreen? = nil
do { ui = try AdventureUI(archive: archive, index: resolver); townScreen = try TownScreen(archive: archive); combatScreen = try CombatScreen(archive: archive); lap("ui loaded") } catch { print("no UI: \(error)") }
if let cs = combatScreen, let updates = try? H4Archive(url: URL(fileURLWithPath: args[1]).deletingLastPathComponent().appendingPathComponent("updates.h4r")),
   let d = try? updates.payload("table.combat_grid_colors.h4d") { cs.gridColors = GridColors(data: d) }

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
    let renderer = try Renderer(device: device, scenes: scenes, pixelFormat: .rgba8Unorm)
    renderer.game = game
    renderer.resolver = resolver
    renderer.showBlocked = showBlocked
    renderer.ui = ui
    renderer.town = townScreen
    renderer.combat = combatScreen
    renderer.movies = movies
    if let m = ProcessInfo.processInfo.environment["H4SAVEDIALOG"] { renderer.openSaveDialog(m == "load" ? .load : .save) }   // snapshot the save / load dialog
    if ProcessInfo.processInfo.environment["H4MENU"] != nil { renderer.openSystemMenu() }   // snapshot the system menu
    if walk != nil { game.quickCombatOnly = true }   // --walk snapshots resolve fights at once
    if let target = battleAt, let hero = game.heroes.first, let cs = combatScreen,
       let p = scene.placed.first(where: { $0.cellX == target.0 && $0.cellY == target.1 }), let mi = game.monster(for: p) {
        cs.start(game: game, hero: hero, monsterAt: mi, p, terrain: 1)
        if let b = cs.battle { for _ in 0..<battleSteps { b.autoAct() }
            if ProcessInfo.processInfo.environment["H4DEBUG"] != nil { print("battle: round \(b.round) finished \(String(describing: b.finished)) units \(b.units.map { "\($0.keyword):\($0.stats.count)@\($0.x),\($0.y)" })") }
            _ = b.takeEvents(); cs.pump(); if b.finished != nil { cs.result = (b.finished!, b.round); cs.showResults = battleResults }
            if let n = ProcessInfo.processInfo.environment["H4INFO"].flatMap({ Int($0) }), b.units.indices.contains(n) { cs.info = b.units[n].id }
            if ProcessInfo.processInfo.environment["H4RETREAT"] != nil { renderer.askRetreat() } }   // snapshot: the retreat question   // snapshot: open a unit's creature window
        print("battle: round \(cs.battle?.round ?? 0), units \(cs.battle?.units.map { "\($0.stats.name)x\($0.stats.count) morale \($0.stats.morale)@(\($0.x),\($0.y))" }.joined(separator: " ") ?? "")")
    }
    if openHeroScreen { renderer.adventureDialog = .hero(0) }
    if let n = ProcessInfo.processInfo.environment["H4LEVELUP"].flatMap({ Int($0) }), let h = game.heroes.first {   // snapshot: the level-up dialog
        game.giveExperience(n, to: h); renderer.levelUpChoice = 0
    }
    if ProcessInfo.processInfo.environment["H4MARKET"] != nil { renderer.market = MarketState(k: 3, sell: 1, buy: 0, lots: 5) }   // snapshot: the marketplace
    if let m = ProcessInfo.processInfo.environment["H4OVERVIEW"] { renderer.overview = KingdomOverview(mode: m == "heroes" ? .heroes : .towns) }   // snapshot: the kingdom overview
    if let k = ProcessInfo.processInfo.environment["H4ARMYPOPUP"].flatMap({ Int($0) }) { renderer.armyPopup = ArmyPopup(hero: 0, selected: k) }   // snapshot: the right-click window
    if openChest, let h = game.heroes.first { game.chestOffer = (h, 1500, 1000); renderer.adventureDialog = .chest; renderer.chestChoice = true }
    if openTown {
        renderer.townOpen = game.towns.firstIndex { $0.owned }
        renderer.townHover = ProcessInfo.processInfo.environment["H4HOVER"]   // --town snapshot: pretend the pointer is over this building
        if openBuildList { renderer.townDialog = .buildList }
        if openRecruit, let i = renderer.townOpen, let slot = townScreen?.hotspot("dwelling_1") { _ = i; renderer.townClick(x: Float(slot.x + 5), y: Float(slot.y + 5)) }
    }
    lap("textures uploaded")
    var snapTime = 0.0
    if ProcessInfo.processInfo.environment["H4FAR"] != nil, let hero = game.heroes.first {   // debugging aid: cells 2-3 days away
        var found = 0
        for x in stride(from: 0, to: game.map.size, by: 3) { for y in stride(from: 0, to: game.map.size, by: 3) where found < 5 {
            if let d = game.daysToReach(hero, (x, y)), d >= 2, d <= 3 { print("far cell (\(x),\(y)) \(d) days"); found += 1 }
        } }
    }
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
        while frames < 600, game.heroes.first?.isWalking == true || game.charge != nil || frames < 90 { game.update(dt: 1.0 / 60); frames += 1 }   // walk until arrival (at least 1.5 s)
        snapTime = Double(frames) / 60
        for line in game.log { print(line) }
        game.log.removeAll()
        print("hero now at (\(hero.x),\(hero.y)) facing \(hero.facing), movement \(hero.movement), still walking: \(hero.isWalking), route left \(hero.plan.count) cells")
        if let out = ProcessInfo.processInfo.environment["H4SAVETO"] { try? game.snapshot(mapPath: args[2]).write(to: URL(fileURLWithPath: out)); print("saved \(out)") }   // debugging aid
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
        guard renderer.cursorFrameIndex == nil, let s = cursors?.set(cursorName) else { return }   // a days / turns pointer does not animate
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
        renderer.cursorFrameIndex = nil
        if renderer.inCombat {
            name = renderer.combatCursor(x: cx, y: mouse.y / renderer.uiScale)
            if let cs = renderer.combat, let b = cs.battle { cs.hover(renderer.unitUnder(b, x: cx, y: mouse.y / renderer.uiScale)?.id, now: Date()) }
        }
        else if renderer.townOpen == nil, renderer.popup == nil, renderer.creatureDialog == nil, renderer.adventureDialog == nil, renderer.ui == nil || cx < Float(AdventureUI.mapViewportWidth) {
            name = renderer.cursorKind(mapPoint: renderer.pan + mouse / renderer.zoom)
        }
        renderer.townHover = renderer.townOpen != nil && renderer.townDialog == nil ? renderer.townBuilding(at: cx, mouse.y / renderer.uiScale)?.name : nil
        if let i = renderer.cursorFrameIndex, let s = cursors?.set(name) {
            cursorName = name; cursorFrame = min(i, s.frames.count - 1); s.frames[cursorFrame].set()
        } else if name != cursorName { cursorName = name; cursorFrame = 0; cursors?.set(name)?.frames.first?.set() }
        // the status line appears once the pointer rests on the map for a moment
        renderer.hover = nil
        hoverPending = (name == "normal" && (renderer.ui == nil || cx >= Float(AdventureUI.mapViewportWidth))) || (renderer.inCombat && renderer.combat?.info == nil && !name.hasPrefix("combat.melee") && name != "combat.shoot") ? nil : (mouse, Date())
    }
    var hoverPending: (mouse: SIMD2<Float>, since: Date)?
    func tickHover() {
        guard let p = hoverPending, Date().timeIntervalSince(p.since) > 0.4, renderer.hover == nil, renderer.townOpen == nil else { return }
        if renderer.inCombat {
            if renderer.combat?.info != nil {
                if let tip = renderer.combatInfoTip(x: p.mouse.x / renderer.uiScale, y: p.mouse.y / renderer.uiScale) {
                    renderer.hover = (tip, Int(p.mouse.x / renderer.uiScale), Int(p.mouse.y / renderer.uiScale))
                }
                return
            }
            if let text = renderer.combatStatusText(x: p.mouse.x / renderer.uiScale, y: p.mouse.y / renderer.uiScale) {
                renderer.hover = (text, Int(p.mouse.x / renderer.uiScale), Int(p.mouse.y / renderer.uiScale))
            }
            return
        }
        if renderer.game?.levelUp != nil {
            if let tip = renderer.levelUpTip(x: p.mouse.x / renderer.uiScale, y: p.mouse.y / renderer.uiScale) {
                renderer.hover = (tip, Int(p.mouse.x / renderer.uiScale), Int(p.mouse.y / renderer.uiScale))
            }
            return
        }
        if renderer.adventureDialog != nil || renderer.armyPopup != nil {   // skills and artifacts on the hero windows
            if let tip = renderer.heroWindowTip(x: p.mouse.x / renderer.uiScale, y: p.mouse.y / renderer.uiScale) {
                renderer.hover = (tip, Int(p.mouse.x / renderer.uiScale), Int(p.mouse.y / renderer.uiScale))
            }
            return
        }
        if let text = renderer.statusText(mapPoint: renderer.pan + p.mouse / renderer.zoom) {
            renderer.hover = (text, Int(p.mouse.x / renderer.uiScale), Int(p.mouse.y / renderer.uiScale))
        }
    }
    override func mouseExited(with e: NSEvent) { NSCursor.arrow.set(); cursorName = ""; renderer.hover = nil; hoverPending = nil }
    override func mouseDown(with e: NSEvent) {
        dragged = 0; renderer.hover = nil; hoverPending = nil
        let p = convert(e.locationInWindow, from: nil)
        let scale = Float(window?.backingScaleFactor ?? 1)
        renderer.pressSound(x: Float(p.x) * scale / renderer.uiScale, y: Float(bounds.height - p.y) * scale / renderer.uiScale)
    }
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
        if renderer.menuClick(x: mouse.x / renderer.uiScale, y: mouse.y / renderer.uiScale) { return }
        if renderer.saveDialogClick(x: mouse.x / renderer.uiScale, y: mouse.y / renderer.uiScale, double: e.clickCount >= 2) { return }
        if renderer.messageBoxClick(x: mouse.x / renderer.uiScale, y: mouse.y / renderer.uiScale) { return }   // a script message: only OK
        if renderer.choiceClick(x: mouse.x / renderer.uiScale, y: mouse.y / renderer.uiScale, double: e.clickCount >= 2) { return }
        if renderer.levelUpClick(x: mouse.x / renderer.uiScale, y: mouse.y / renderer.uiScale, double: e.clickCount >= 2) { return }
        if renderer.market != nil { renderer.marketClick(x: mouse.x / renderer.uiScale, y: mouse.y / renderer.uiScale); return }
        if renderer.overview != nil { renderer.overviewClick(x: mouse.x / renderer.uiScale, y: mouse.y / renderer.uiScale); return }
        if renderer.armyPopup != nil { renderer.armyPopupClick(x: mouse.x / renderer.uiScale, y: mouse.y / renderer.uiScale); return }
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
                else if ui.hit("System_menu_button", x: cx, y: cy) { renderer.openSystemMenu() }
                else if ui.hit("Game_menu_button", x: cx, y: cy) { renderer.openGameMenu() }
                else if ui.hit("move_army_button", x: cx, y: cy) { g.continueMoving(hero) }   // the horse: go on along the kept route
                else if ui.hit("overview_button", x: cx, y: cy) { renderer.overview = KingdomOverview() }
                else if ui.hit("Marketplace_button", x: cx, y: cy) { renderer.market = MarketState(k: 3) }
                else if (ui.hit("underground_button", x: cx, y: cy) || ui.hit("surface_button", x: cx, y: cy)), g.map.levels > 1 {
                    g.level = 1 - g.level   // look at the other level (the hero stays where he is)
                }
                else if ui.hit("mini_map", x: cx, y: cy), let mm = ui.hotspot("mini_map") {   // the minimap: bring the view there
                    let n = Float(g.map.size)
                    let col = (cx - Float(mm.x)) / Float(mm.width) * n - n / 2, row = (cy - Float(mm.y)) / Float(mm.height) * n + n / 2
                    renderer.centre(onCell: (Int(((row - col) / 2).rounded()), Int(((row + col) / 2).rounded())))
                }
                else if ui.hit("Town_list", x: cx, y: cy), let list = ui.hotspot("Town_list") {
                    // a town card: one click brings the map to the town, a double click opens it
                    let owned = g.towns.indices.filter { g.towns[$0].owned }
                    let row = Int((cy - Float(list.y) - 8) / 72)
                    if row >= 0, row < min(3, owned.count) {
                        let i = owned[row]
                        if e.clickCount >= 2 { renderer.townOpen = i } else { renderer.centre(onTown: i) }
                    }
                }
                else if ui.hit("Hero_List", x: cx, y: cy) {   // a portrait: one click centres the map on the hero, a double click opens the hero screen
                    for (i, (hx, hy)) in AdventureUI.heroSlots.enumerated() where i < g.heroes.count && abs(cx - Float(hx)) < 30 && abs(cy - Float(hy)) < 30 {
                        if e.clickCount >= 2 { renderer.adventureDialog = .hero(i) }
                        else { g.level = g.heroes[i].z; renderer.centre(onCell: (Int(g.heroes[i].position.x.rounded()), Int(g.heroes[i].position.y.rounded()))) }
                    }
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
        if renderer.inCombat { renderer.combatInspect(x: cx, y: cy); return }
        if renderer.onPopup(cx, cy) || renderer.onDialog(cx, cy).inside { return }
        if renderer.armyPopup != nil { renderer.armyPopup = nil; return }
        if renderer.ui != nil, cx >= Float(AdventureUI.mapViewportWidth) {
            renderer.popup = nil; renderer.creatureDialog = nil
            // a hero in the list: the army's right-click window
            if let g = renderer.game, renderer.adventureDialog == nil {
                for (i, (hx, hy)) in AdventureUI.heroSlots.enumerated() where i < g.heroes.count && abs(cx - Float(hx)) < 30 && abs(cy - Float(hy)) < 30 {
                    renderer.armyPopup = ArmyPopup(hero: i)
                }
            }
            return
        }
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
        if renderer.saveDialogKey(e) { return }
        let step: Float = 64 / renderer.zoom
        // the original's hot keys on the map: S save, L load
        if !renderer.inCombat, renderer.townOpen == nil, renderer.prompt == nil {
            if e.keyCode == 1 { renderer.openSaveDialog(.save); return }
            if e.keyCode == 37 { renderer.openSaveDialog(.load); return }
        }
        switch e.keyCode {
        case 123, 124:   // arrows pan the map, or page the build list
            if case .buildList? = renderer.townDialog { renderer.buildPage = max(0, renderer.buildPage + (e.keyCode == 124 ? 1 : -1)) }
            else { renderer.pan.x += e.keyCode == 124 ? step : -step }
        case 125: renderer.pan.y += step
        case 126: renderer.pan.y -= step
        case 36, 76: if renderer.townOpen == nil, !renderer.inCombat { renderer.game?.endTurn() }   // Return / Enter
        case 14: if renderer.townOpen == nil, !renderer.inCombat { renderer.game?.endTurn() }       // E
        case 46: renderer.showReach.toggle()   // M = movement shadow
        case 1: if renderer.inCombat, renderer.prompt == nil, let b = renderer.combat?.battle, !(renderer.combat?.busy ?? true), b.finished == nil { b.wait(); renderer.combat?.pump() }   // S = wait
        case 2: if renderer.inCombat, renderer.prompt == nil, let b = renderer.combat?.battle, !(renderer.combat?.busy ?? true), b.finished == nil { b.defend(); renderer.combat?.pump() } // D = defend
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
        let renderer = try! Renderer(device: device, scenes: scenes, pixelFormat: .bgra8Unorm)
        renderer.archivePath = args[1]; renderer.mapPath = args.count > 2 ? args[2] : nil
        renderer.game = game
        renderer.resolver = resolver
        renderer.showBlocked = showBlocked
        renderer.ui = ui
        renderer.town = townScreen
        renderer.combat = combatScreen
    renderer.movies = movies
    renderer.sound = gameSound
    combatScreen?.sound = gameSound
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
