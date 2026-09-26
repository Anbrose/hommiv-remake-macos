import Foundation
import Metal
import MetalKit
import H4Engine

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct V { float2 pos; float2 uv; };
struct Out { float4 pos [[position]]; float2 uv; };
struct Camera { float2 view; float2 pan; float zoom; float pad; };
vertex Out vmain(const device V* v [[buffer(0)]], constant Camera& cam [[buffer(1)]], uint id [[vertex_id]]) {
    Out o;
    float2 p = (v[id].pos - cam.pan) * cam.zoom;
    o.pos = float4(p.x / cam.view.x * 2.0 - 1.0, 1.0 - p.y / cam.view.y * 2.0, 0.0, 1.0);
    o.uv = v[id].uv;
    return o;
}
fragment float4 fmain(Out i [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, mip_filter::linear);
    float4 c = tex.sample(s, i.uv);
    return float4(c.rgb * c.a, c.a);
}
"""

struct Vertex { var x: Float, y: Float, u: Float, v: Float }
struct Camera { var vw: Float, vh: Float, px: Float, py: Float, zoom: Float, pad: Float }

/// One textured quad on the map canvas.
struct Quad {
    var texture: MTLTexture
    var x: Int, y: Int, w: Int, h: Int
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    /// Every map level's scene; `scene` is the one in play (the game's level).
    let scenes: [MapScene]
    var scene: MapScene { game.map { scenes[min($0.level, scenes.count - 1)] } ?? scenes[0] }
    var terrainByLevel: [[Quad]] = []
    var terrain: [Quad] { terrainByLevel[min(game?.level ?? 0, terrainByLevel.count - 1)] }
    var textures: [String: MTLTexture] = [:]
    var pan = SIMD2<Float>(0, 0)
    var zoom: Float = 1
    var viewSize = SIMD2<Float>(1, 1)
    var vertexBuffer: MTLBuffer
    let start = Date()
    var lastFrame = Date()
    var frameTimes: [Double] = []
    var game: GameState?
    var resolver: RandomResolver?
    var actorSprites: [String: Sprite] = [:]
    lazy var dot: MTLTexture = {   // path marker
        var bm = Bitmap(width: 8, height: 8)
        for y in 0..<8 { for x in 0..<8 where (x - 4) * (x - 4) + (y - 4) * (y - 4) <= 9 {
            let p = (y * 8 + x) * 4; bm.pixels[p] = 255; bm.pixels[p + 1] = 240; bm.pixels[p + 2] = 160; bm.pixels[p + 3] = 220 } }
        return makeTexture(bm)
    }()
    var onTitle: ((String) -> Void)?
    var ui: AdventureUI?
    var town: TownScreen?
    var townOpen: Int? = nil      // index into game.towns while the town screen is up
    var townDialog: TownDialog? = nil
    var adventureDialog: AdventureDialog? = nil
    var combat: CombatScreen?
    /// The game's movies (movies.h4r), decoded on demand.
    var movies: Movies?
    var sound: GameSound?
    var saveDialog: SaveDialog?
    var menu: PopupMenu?
    /// The game's archive and scenario files (for saving and for starting again from a save).
    var archivePath: String?, mapPath: String?
    var lastAutosaveDay: Int?
    var buttonTextures: Set<ObjectIdentifier> = []
    var buttonRects: [(x: Int, y: Int, w: Int, h: Int)] = []
    /// A press on one of the buttons drawn last frame plays the game's click (sound.miscellaneous.button).
    func pressSound(x: Float, y: Float) {
        if buttonRects.contains(where: { x >= Float($0.x) && x < Float($0.x + $0.w) && y >= Float($0.y) && y < Float($0.y + $0.h) }) {
            sound?.play("miscellaneous.button")
        }
    }

    /// The music for where the player is: the town's alignment in a town, else the terrain under
    /// the hero (terrain.<Terrain>); combat music is started by the battle itself.
    func updateMusic() {
        guard let s = sound, let g = game, !inCombat else { return }
        if let t = townOpen, t < g.towns.count { s.playMusic("town.\(g.towns[t].alignment)"); return }
        guard let h = g.heroes.first, let c = g.map.cells[g.level][h.x * g.map.size + h.y] else { return }
        let names: [UInt8: String] = [0: "Water", 1: "grass", 2: "Rough", 3: "Swamp", 4: "Volcanic", 5: "Snow", 6: "Sand", 7: "Dirt", 8: "Subterranean"]
        let name = g.level > 0 ? "Subterranean" : names[c.type] ?? "grass"
        s.playMusic("terrain.\(name)")
    }
    /// The sounds of the objects near the middle of the view (sound.adv_object.<type>[.<subtype>]:
    /// windmills, water wheels, stables, creature banks, ...), louder the nearer, four at most.
    func updateAmbient(_ now: Date) {
        guard let s = sound, let g = game else { return }
        if inCombat || townOpen != nil { s.setAmbient([:]); return }
        guard now.timeIntervalSince(lastAmbientCheck) > 0.5 else { return }
        lastAmbientCheck = now
        let centre = cell(at: pan + SIMD2(Float(AdventureUI.mapViewportWidth), Float(AdventureUI.height)) * uiScale / 2 / zoom)
        var near: [(key: String, name: String, d: Float)] = []
        for p in scene.placed {
            let dx = Float(p.cellX - centre.0), dy = Float(p.cellY - centre.1)
            let d = (dx * dx + dy * dy).squareRoot()
            guard d < 10 else { continue }
            // scenery and working buildings loop; chests, gems, piles and fountains sound when visited
            guard Renderer.ambientTypes.contains(p.type) else { continue }
            let full = "adv_object.\(p.type).\(p.subtype)", short = "adv_object.\(p.type)"
            guard let name = [full, short].first(where: { !p.type.isEmpty && s.has($0) }) else { continue }
            near.append(("ambient|\(p.cellX),\(p.cellY)", name, d))
        }
        _ = g
        var wanted: [String: (name: String, volume: Float)] = [:]
        for n in near.sorted(by: { $0.d < $1.d }).prefix(4) { wanted[n.key] = (n.name, max(0.1, 1 - n.d / 10) * 0.6) }
        s.setAmbient(wanted)
    }
    var lastAmbientCheck = Date.distantPast
    static let ambientTypes: Set<String> = ["decorative", "windmill", "weekly_material_generator", "mine", "abandoned_mine", "creature_bank",
                                            "creature_dwelling", "campfire", "buoy", "arena", "academy", "blacksmith", "movement_booster"]
    var combatMeleeMode = false
    /// The frame the pointer shows, when its frames are not an animation: the move / attack /
    /// activate and combat walk / fly pointers have one frame per 1, 2, 3 and 4+ days or turns.
    var cursorFrameIndex: Int?
    /// The creature the combat pointer is over (for its red target shadow).
    var combatTarget: Int?
    var dayCache: (cell: Int, days: Int?)?
    var showReach = false      // the game's "Show Movement Shadow" option (off by default, as in the original)
    var inCombat: Bool { combat?.battle != nil }
    var chestChoice: Bool? = nil          // true = gold, false = experience
    var armyPopup: ArmyPopup? = nil        // the right-click window of an army
    var levelUpChoice: Int? = nil          // the offer picked in the level-up dialog
    var overview: KingdomOverview? = nil  // the kingdom overview, when open
    var choicePicked: Int? = nil          // the option chosen in an object's choice
    var market: MarketState? = nil         // the marketplace, when open
    var spellBook: SpellBookState? = nil   // the spell book, when open
    var casting: Int? = nil               // a combat spell being aimed
    var optionsOpen: GameSettings? = nil   // the options dialog, while open (the values being edited)
    var settings = GameSettings.load()
    var hire: HireOffer? = nil             // the tavern's dialog
    var shop: ShopState? = nil             // a blacksmith's or conservatory's shop
    var sanctuary: SanctuaryOffer? = nil   // a sanctuary's dialog
    var puzzle: String? = nil              // the puzzle map shown (an obelisk colour)
    var heroShown = 0                     // which of the army's heroes the hero screen shows
    var floaters: [(text: String, x: Int, y: Int, since: Date)] = []
    var buildPage = 0
    var buildCells: [(rect: (Int, Int, Int, Int), building: RuleTables.BuildingDef)] = []
    /// The town's army display (hotspot Army_Display, 500,583 - 967,717): heroes4.exe
    /// (t_creature_array_window, 0x644855) tiles the creature_rings pieces edge to edge, each
    /// advancing by its own width (Top_Left 70, Top 59, Top_Right 70), the second row one piece
    /// height (72) lower; the portrait hole is at (15,15)-(67,67) of a piece's frame. Returns the
    /// frame origins of the 7 pieces of a row; the row is centred in the hotspot.
    func townRingOrigins(row: Int, ui: AdventureUI) -> [(piece: String, x: Int, y: Int)] {
        let name = row == 0 ? "Top" : "Bottom"
        let pieces = (0..<7).map { $0 == 0 ? "\(name)_Left" : $0 == 6 ? "\(name)_Right" : name }
        let widths = pieces.map { ui.creatureRing($0).map { $0.width } ?? 60 }
        let total = widths.reduce(0, +)
        var cursor = 500 + (467 - total) / 2
        let top = ui.creatureRing("Top"), piece0 = ui.creatureRing(pieces[0])
        let cursorY = 583 + (row == 0 ? 0 : (top?.height ?? 72))
        var out: [(piece: String, x: Int, y: Int)] = []
        for (k, p) in pieces.enumerated() {
            let l = ui.creatureRing(p)
            out.append((p, cursor - (l?.x ?? 0), cursorY - (piece0?.y ?? 0)))
            cursor += widths[k]
        }
        return out
    }

    /// The label under a stack's portrait, as the game's rings draw it: the "inset" scroll with
    /// the count centred in "inset_text", or for a hero the health and mana bars. (cx, cy) is
    /// the portrait hole's centre (the piece frame's (41, 41)).
    func ringLabel(_ out: inout [Quad], ui: AdventureUI, cx: Int, cy: Int, count: String?, hero: Bool) {
        let ox = cx - 41, oy = cy - 41
        guard let inset = ui.creatureRing("inset") else { return }
        out.append(Quad(texture: uiTexture("cring|inset", { inset.bitmap }), x: ox + inset.x, y: oy + inset.y, w: inset.width, h: inset.height))
        if hero {
            for (bar, border) in [("health_bar", "health_bar_border"), ("mana_bar", "mana_bar_border")] {
                if let b = ui.creatureRing(border) {
                    out.append(Quad(texture: uiTexture("black", { var bm = Bitmap(width: 1, height: 1); bm.pixels = [0, 0, 0, 255]; return bm }), x: ox + b.x, y: oy + b.y, w: b.width, h: b.height))
                }
                if let l = ui.creatureRing(bar) { out.append(Quad(texture: uiTexture("cring|\(bar)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height)) }
            }
        } else if let c = count, let box = ui.creatureRing("inset_text") {
            let f = ui.ringFont, w = f.measure(c)
            out.append(Quad(texture: uiTexture("ringcount|\(c)", { f.render(c, colour: (16, 12, 8)) }), x: ox + box.x + (box.width - w) / 2, y: oy + box.y + (box.height - f.size) / 2, w: w, h: f.size))
        }
    }
    var uiTextures: [String: MTLTexture] = [:]
    /// The town building under the pointer (its layout layer name).
    var townHover: String?

    /// Quads of the town screen (replaces the map and the adventure chrome).
    /// Buildings with levels show only their highest built level (the halls, the walls, the guilds).
    static let levelChains = [["village hall", "town hall", "city hall"], ["fort", "citadel", "castle"],
                              ["mage guild 1", "mage guild 2", "mage guild 3", "mage guild 4", "mage guild 5"]]
    static func shown(_ built: Set<String>) -> Set<String> {
        var s = built
        for chain in levelChains {
            if let top = chain.lastIndex(where: { built.contains($0) }) { for k in 0..<top { s.remove(chain[k]) } }
        }
        return s
    }

    /// The built building under a canvas point: the front-most whose picture is opaque there.
    func townBuilding(at x: Float, _ y: Float) -> UILayer? {
        guard let ts = town, let g = game, let i = townOpen, i < g.towns.count, y < 546 else { return nil }
        let t = g.towns[i]
        guard let lay = ts.layout(t.alignment) else { return nil }
        let hits = lay.layers.filter { l in
            guard Renderer.shown(t.buildings).contains(l.name.lowercased()), l.width > 0 else { return false }
            let r = TownScreen.place(l)
            guard x >= Float(r.x), x < Float(r.x + r.w), y >= Float(r.y), y < Float(r.y + r.h) else { return false }
            let px = Int((x - Float(r.x)) * Float(l.width) / Float(r.w)), py = Int((y - Float(r.y)) * Float(l.height) / Float(r.h))
            return l.bitmap.pixels[(py * l.bitmap.width + px) * 4 + 3] > 40
        }
        return hits.max { $0.y + $0.height < $1.y + $1.height }
    }
    /// A building's glow: its opaque pixels brightened and a warm 2 px rim along its edge.
    static func glow(_ b: Bitmap) -> Bitmap {
        var out = Bitmap(width: b.width, height: b.height)
        let w = b.width, h = b.height
        func a(_ x: Int, _ y: Int) -> UInt8 { x < 0 || y < 0 || x >= w || y >= h ? 0 : b.pixels[(y * w + x) * 4 + 3] }
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            if a(x, y) > 40 {
                var edge = false
                for dy in -2...2 { for dx in -2...2 where abs(dx) + abs(dy) <= 2 && a(x + dx, y + dy) <= 40 { edge = true } }
                if edge { out.pixels[i] = 255; out.pixels[i + 1] = 226; out.pixels[i + 2] = 120; out.pixels[i + 3] = 255 }
                else { for k in 0..<3 { out.pixels[i + k] = UInt8(min(255, Int(b.pixels[i + k]) + 36)) }; out.pixels[i + 3] = b.pixels[i + 3] }
            }
        } }
        return out
    }

    func townQuads() -> [Quad] {
        guard let ts = town, let g = game, let i = townOpen, i < g.towns.count, let ui = ui else { return [] }
        let t = g.towns[i]
        var out: [Quad] = []
        // the view: background, the built buildings (shadow then image, back to front), the foreground bits
        if let v = ts.view(t.alignment, t.terrain) {
            if let bg = v["background"] {
                let r = TownScreen.place(bg); out.append(Quad(texture: uiTexture("town|\(t.alignment)|\(t.terrain)|bg", { bg.bitmap }), x: r.x, y: r.y, w: r.w, h: r.h))
            }
            if let lay = ts.layout(t.alignment) {
                let built = lay.layers.filter { Renderer.shown(t.buildings).contains($0.name.lowercased()) && $0.width > 0 }.sorted { $0.y + $0.height < $1.y + $1.height }
                for b in built {
                    if let sh = lay.layers.first(where: { $0.name.lowercased() == b.name.lowercased() + " shadow" }), sh.width > 0 {
                        let r = TownScreen.place(sh); out.append(Quad(texture: uiTexture("town|\(t.alignment)|\(sh.name)", { sh.bitmap }), x: r.x, y: r.y, w: r.w, h: r.h))
                    }
                    let r = TownScreen.place(b); out.append(Quad(texture: uiTexture("town|\(t.alignment)|\(b.name)", { b.bitmap }), x: r.x, y: r.y, w: r.w, h: r.h))
                    // its animation: the frames over the building, looping (frame time = speed / 60 s)
                    if let anim = ts.animation(t.alignment, b.name) {
                        let frames = anim.images.filter { $0.name.hasPrefix("frame") }
                        if !frames.isEmpty {
                            let period = frames[0].speed > 0 ? Double(frames[0].speed) / 60.0 : 0.125
                            let f = frames[Int(Date().timeIntervalSince1970 / period) % frames.count]
                            // frame boxes are measured from the 1x1 "animation_position" marker,
                            // which sits where the building's picture starts
                            let anchor = anim.images.first { $0.name == "animation_position" }?.box ?? (left: 0, top: 0, right: 0, bottom: 0)
                            if f.bitmap.width > 1 {
                                let l = UILayer(name: f.name, kind: 4, x: b.x + f.box.left - anchor.left, y: b.y + f.box.top - anchor.top, width: f.bitmap.width, height: f.bitmap.height, bitmap: f.bitmap)
                                let fr = TownScreen.place(l)
                                out.append(Quad(texture: texture(for: f, of: "townanim.\(t.alignment).\(b.name)"), x: fr.x, y: fr.y, w: fr.w, h: fr.h))
                            }
                        }
                    }
                    // the building under the pointer glows (an outline along its edge, brightened)
                    if townHover == b.name {
                        out.append(Quad(texture: uiTexture("townglow|\(t.alignment)|\(b.name)", { Renderer.glow(b.bitmap) }), x: r.x, y: r.y, w: r.w, h: r.h))
                    }
                }
            }
            for f in v.layers where f.name.hasPrefix("foreground") {
                let r = TownScreen.place(f); out.append(Quad(texture: uiTexture("town|\(t.alignment)|\(t.terrain)|\(f.name)", { f.bitmap }), x: r.x, y: r.y, w: r.w, h: r.h))
            }
        }
        // the frame: opaque images, then the rest except the pressed/highlighted button states
        for l in ts.frame.layers where l.isImage && !l.name.hasSuffix("_Pressed") && !l.name.hasSuffix("_Highlighted") {
            out.append(Quad(texture: uiTexture("townframe|\(l.name)", { l.bitmap }), x: l.x, y: l.y, w: l.width, h: l.height))
        }
        if let slot = ts.hotspot("Lord_Portrait"), let h = g.heroes.first, let p = ui.portrait(keyword: h.keyword, alignment: h.alignment) {
            out.append(Quad(texture: uiTexture("portrait|\(h.alignment)|\(h.keyword)", { p.bitmap }), x: slot.x + (slot.width - p.width) / 2, y: slot.y + (slot.height - p.height) / 2, w: p.width, h: p.height))
        }
        if let f = ts.hotspot("Town_Name") {
            let text = t.name
            let w = ui.dateFont.measure(text)
            out.append(Quad(texture: uiTexture("date|\(text)", { ui.dateFont.render(text, colour: (40, 24, 8)) }), x: f.x + (f.width - w) / 2, y: f.y + (f.height - ui.dateFont.size) / 2, w: w, h: ui.dateFont.size))
        }
        for name in ui.resourceNames {
            guard let f = ts.hotspot("\(name)_Number") ?? ts.hotspot("\(name)_number") else { continue }
            let text = String(g.resources[name] ?? 0)
            let w = ui.numberFont.measure(text)
            out.append(Quad(texture: uiTexture("num|\(text)", { ui.numberFont.render(text, colour: (40, 24, 8)) }), x: f.x + (f.width - w) / 2, y: f.y, w: w, h: ui.numberFont.size))
        }
        // a count in a small dark box, centred at (cx, cy)
        func countBox(_ count: String, _ cx: Int, _ cy: Int) {
            let w = ui.numberFont.measure(count)
            out.append(Quad(texture: shade, x: cx - w / 2 - 4, y: cy - 1, w: w + 8, h: ui.numberFont.size + 2))
            out.append(Quad(texture: uiTexture("count|\(count)", { ui.numberFont.render(count, colour: (255, 236, 200)) }), x: cx - w / 2, y: cy, w: w, h: ui.numberFont.size))
        }
        // the dwellings: one slot per built dwelling, creature icon and how many wait
        if let tables = g.tables {
            let dwellings = tables.buildings(for: t.alignment).filter { $0.creature != nil && t.buildings.contains($0.keyword) }
            for (k, b) in dwellings.prefix(6).enumerated() {
                guard let slot = ts.hotspot("dwelling_\(k + 1)"), let c = b.creature, let icon = ui.creatureIcon(c) else { continue }
                out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: slot.x, y: slot.y, w: slot.width, h: slot.height))
                countBox(String(t.available[c] ?? 0), slot.x + slot.width / 2, slot.y + slot.height - ui.numberFont.size - 2)
            }
        }
        // the town list: this town's card and a piece of the minimap
        if let list = ts.hotspot("Town_list") {
            let cx = list.x + 6, cy = list.y + 4
            if let card = ui.tinyCard(t.alignment) {
                let terrain = TownScreen.terrainNames[t.terrain] ?? "grass"
                if let bg = card.layers.first(where: { $0.name.lowercased() == terrain }) ?? card["grass"] {
                    out.append(Quad(texture: uiTexture("tiny|\(t.alignment)|\(bg.name)", { bg.bitmap }), x: cx + bg.x, y: cy + bg.y, w: bg.width, h: bg.height))
                }
                let walls = t.buildings.contains("castle") ? "Castle" : t.buildings.contains("citadel") ? "Citadel" : t.buildings.contains("fort") ? "Fort" : "Village"
                if let w = card[walls] { out.append(Quad(texture: uiTexture("tiny|\(t.alignment)|\(walls)", { w.bitmap }), x: cx + w.x, y: cy + w.y, w: w.width, h: w.height)) }
            }
            if let hs = ui.hotspot("mini_map") {
                let tex = uiTexture("townmap|\(t.x),\(t.y)|\(minimapStamp)", {
                    let full = AdventureUI.minimap(game: g, size: hs.width)
                    let n = Float(g.map.size)
                    let px = Int((Float(t.y - t.x) + n / 2) / n * Float(hs.width)), py = Int((Float(t.x + t.y + 6) - n / 2) / n * Float(hs.width))
                    var b = Bitmap(width: 48, height: 48)
                    for y in 0..<48 { for x in 0..<48 {
                        let sx = px - 24 + x, sy = py - 24 + y
                        guard sx >= 0, sx < full.width, sy >= 0, sy < full.height else { continue }
                        for k in 0..<4 { b.pixels[(y * 48 + x) * 4 + k] = full.pixels[(sy * full.width + sx) * 4 + k] }
                    } }
                    return b
                })
                out.append(Quad(texture: black, x: cx + 94, y: cy, w: 50, h: 50))
                out.append(Quad(texture: tex, x: cx + 95, y: cy + 1, w: 48, h: 48))
            }
        }
        // the army display: two rows of seven rings (garrison above, the visiting army below)
        let rows = [townRingOrigins(row: 0, ui: ui), townRingOrigins(row: 1, ui: ui)]
        for row in rows {
            for o in row {
                guard let ring = ui.creatureRing(o.piece) else { continue }
                out.append(Quad(texture: uiTexture("cring|\(o.piece)", { ring.bitmap }), x: o.x + ring.x, y: o.y + ring.y, w: ring.width, h: ring.height))
            }
        }
        if let h = g.heroes.first {
            var slots: [(UILayer?, String?)] = [(ui.portrait(keyword: h.keyword, alignment: h.alignment), nil)]
            slots += h.army.map { (ui.creatureIcon($0.creature), String($0.count)) }
            for (k, (icon, _)) in slots.prefix(7).enumerated() {
                let cx = rows[1][k].x + 41, cy = rows[1][k].y + 41
                if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height)) }
            }
            for (k, (_, count)) in slots.prefix(7).enumerated() {
                ringLabel(&out, ui: ui, cx: rows[1][k].x + 41, cy: rows[1][k].y + 41, count: count, hero: k == 0)
            }
        }
        out += townDialogQuads()
        out += shopQuads()
        out += hireQuads()
        return out
    }

    /// A click on the town screen (canvas coordinates).
    func townClick(x: Float, y: Float) {
        guard let ts = town, let g = game, let i = townOpen else { return }
        if townDialog != nil { _ = townDialogClick(x: x, y: y); return }
        if ts.hit(ts.hotspot("OK_Button"), x, y) { townOpen = nil; return }
        let t = g.towns[i]
        if let tables = g.tables {
            let dwellings = tables.buildings(for: t.alignment).filter { $0.creature != nil && t.buildings.contains($0.keyword) }
            for (k, b) in dwellings.prefix(6).enumerated() where ts.hit(ts.hotspot("dwelling_\(k + 1)"), x, y) {
                if let c = b.creature, let def = tables.creature(c) {
                    let most = min(t.available[c] ?? 0, def.gold > 0 ? g.resources["Gold", default: 0] / def.gold : 99)
                    townDialog = .recruit(creature: c, count: most)
                }
                return
            }
            // a built building in the view: a dwelling recruits, the hall (or anything else) builds
            if y < 546, let lay = ts.layout(t.alignment) {
                if let top = townBuilding(at: x, y) {
                    if top.name.lowercased().hasPrefix("mage guild") { townDialog = .mageGuild(page: 0); return }
                    if top.name.lowercased() == "blacksmith", let hero = g.heroes.first {   // the town's blacksmith: its alignment's wares
                        let o = ShopOffer(key: "town|\(i)", title: text("blacksmith", "Blacksmith"), panel: t.alignment.capitalized, items: [], potions: [], hero: hero)
                        shop = ShopState(offer: o, panel: ui?.dialog("Blacksmith.\(o.panel)")); sound?.play("dialogue.marketplace")
                        return
                    }
                    if top.name.lowercased().contains("tavern") {   // the town's tavern: hire a hero (one a week)
                        if let r = g.tavernRefusal(town: i) { prompt = (r, false, nil) } else { hire = g.hireOffer(town: i) }
                        return
                    }
                    if let b = tables.buildings(for: t.alignment).first(where: { $0.keyword == top.name.lowercased() }), let c = b.creature, let def = tables.creature(c) {
                        let most = min(t.available[c] ?? 0, def.gold > 0 ? g.resources["Gold", default: 0] / def.gold : 99)
                        townDialog = .recruit(creature: c, count: most)
                    } else { townDialog = .buildList }
                    return
                }
                townDialog = .buildList
            }
        }
    }
    /// Messages shown over the map for a few seconds.
    var toasts: [(text: String, until: Date)] = []
    lazy var shade: MTLTexture = {
        var bm = Bitmap(width: 2, height: 2)
        for i in 0..<4 { bm.pixels[i * 4] = 30; bm.pixels[i * 4 + 1] = 20; bm.pixels[i * 4 + 2] = 10; bm.pixels[i * 4 + 3] = 190 }
        return makeTexture(bm)
    }()
    var minimapTexture: MTLTexture?
    var minimapStamp = -1
    /// The status line shown when the mouse rests on the map: text and canvas position.
    var hover: (text: String, x: Int, y: Int)?
    var iconSheets: [String: [String: UILayer]] = [:]

    /// Bring a map cell to the middle of the map viewport (as a click in the hero or town list does).
    func centre(onCell c: (Int, Int)) {
        let viewportW = ui == nil ? viewSize.x : Float(AdventureUI.mapViewportWidth) * uiScale
        let (sx, sy) = scene.screen(x: c.0, y: c.1)
        pan = SIMD2(Float(sx) - viewportW / 2 / zoom, Float(sy) - viewSize.y / 2 / zoom)
    }
    func centre(onTown i: Int) {
        guard let g = game, i < g.towns.count else { return }
        let t = g.towns[i]
        g.level = t.z
        if let p = scene.placed.first(where: { g.town(for: $0) == i }) {
            centre(onCell: (p.cellX + p.sprite.footprint.w / 2, p.cellY + p.sprite.footprint.h / 2))
        } else { centre(onCell: (t.x, t.y)) }
    }
    /// A question or notice of the game's own (retreat, surrender): the text, whether it has
    /// Cancel beside OK, and what OK does.
    var prompt: (text: String, cancel: Bool, ok: (() -> Void)?)?
    lazy var cream: MTLTexture = {
        var bm = Bitmap(width: 2, height: 2)
        for i in 0..<4 { bm.pixels[i * 4] = 255; bm.pixels[i * 4 + 1] = 255; bm.pixels[i * 4 + 2] = 224; bm.pixels[i * 4 + 3] = 255 }
        return makeTexture(bm)
    }()
    lazy var black: MTLTexture = {
        var bm = Bitmap(width: 2, height: 2)
        for i in 0..<4 { bm.pixels[i * 4 + 3] = 255 }
        return makeTexture(bm)
    }()
    func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> MTLTexture {
        uiTexture("solid|\(r),\(g),\(b)", { var bm = Bitmap(width: 2, height: 2); for i in 0..<4 { bm.pixels[i * 4] = r; bm.pixels[i * 4 + 1] = g; bm.pixels[i * 4 + 2] = b; bm.pixels[i * 4 + 3] = 255 }; return bm })
    }

    /// "Adventure Map [x,y]: <what is there>" for a map point, as the game's status line says it.
    func statusText(mapPoint m: SIMD2<Float>) -> String? {
        guard let g = game else { return nil }
        let c = cell(at: m)
        guard c.0 >= 0, c.0 < g.map.size, c.1 >= 0, c.1 < g.map.size, let cellData = g.map.cells[g.level][c.0 * g.map.size + c.1] else { return nil }
        var what: String
        if let h = g.heroes.first(where: { $0.z == g.level && $0.x == c.0 && $0.y == c.1 }) { what = h.name }
        else if let p = scene.placed.last(where: { underCursor($0, m) || onFootprint($0, c) }), p.type != "decorative" || true { what = g.describe(p).title }
        else if let t = g.describe(cellX: c.0, cellY: c.1) { what = t.title }
        else { what = ui?.terrainName(cellData, tables: g.tables) ?? "" }
        return "Adventure Map [\(c.0),\(c.1)]: \(what)"
    }

    /// The status line box: cream, black border, black text, to the right of the pointer.
    func hoverQuads() -> [Quad] {
        guard let h = hover, let ui = ui else { return [] }
        // long texts (ability help) wrap at 300 px
        let lines = ui.numberFont.measure(h.text) > 300 ? AdventureUI.wrap(h.text, font: ui.numberFont, width: 300) : [h.text]
        let w = (lines.map { ui.numberFont.measure($0) }.max() ?? 0) + 8, lh = ui.numberFont.size + 2, ht = lh * lines.count + 2
        var x = h.x + 18, y = h.y - 4
        let right = inCombat ? AdventureUI.width : AdventureUI.mapViewportWidth
        if x + w > right { x = max(0, h.x - w - 4) }
        if y + ht > AdventureUI.height { y = AdventureUI.height - ht }
        var out = [Quad(texture: black, x: x, y: y, w: w, h: ht), Quad(texture: cream, x: x + 1, y: y + 1, w: w - 2, h: ht - 2)]
        for (k, line) in lines.enumerated() {
            out.append(Quad(texture: uiTexture("num|\(line)", { ui.numberFont.render(line, colour: (0, 0, 0)) }), x: x + 4, y: y + 2 + k * lh, w: ui.numberFont.measure(line), h: ui.numberFont.size))
        }
        return out
    }
    /// Device pixels per canvas pixel of the 1024x768 UI.
    var uiScale: Float { viewSize.y / Float(AdventureUI.height) }
    lazy var white: MTLTexture = {
        var bm = Bitmap(width: 2, height: 2)
        for i in 0..<4 { bm.pixels[i * 4] = 255; bm.pixels[i * 4 + 1] = 255; bm.pixels[i * 4 + 2] = 255; bm.pixels[i * 4 + 3] = 255 }
        return makeTexture(bm)
    }()

    func uiTexture(_ key: String, _ make: () -> Bitmap) -> MTLTexture {
        if let t = uiTextures[key] { return t }
        let t = makeTexture(make())
        uiTextures[key] = t
        if key.hasPrefix("button|") { buttonTextures.insert(ObjectIdentifier(t)) }
        return t
    }

    /// Quads of the screen chrome on the 1024x768 canvas.
    func uiQuads() -> [Quad] {
        guard let ui = ui, let g = game else { return [] }
        var out: [Quad] = []
        for l in ui.frameImages {
            out.append(Quad(texture: uiTexture("frame|\(l.name)|\(l.x),\(l.y)", { l.bitmap }), x: l.x, y: l.y, w: l.width, h: l.height))
        }
        // minimap: the map squashed into the panel's frame, with the visible area outlined
        if let mm = ui.hotspot("mini_map") {
            let stamp = g.level * 7_000_001 + g.day * 1000 + g.enemyHeroes.reduce(0) { $0 + $1.x * 13 + $1.y * 3 } + g.heroes.reduce(0) { $0 + $1.x * 7 + $1.y } + g.towns.filter { $0.owned }.count * 31 + g.mines.filter { $0.owned }.count * 17
            if minimapTexture == nil || minimapStamp != stamp { minimapTexture = makeTexture(AdventureUI.minimap(game: g, size: mm.width)); minimapStamp = stamp }
            out.append(Quad(texture: minimapTexture!, x: mm.x, y: mm.y, w: mm.width, h: mm.height))
            let n = Float(scene.map.size)
            // the playable rectangle on the map canvas: columns -n/2..n/2 (x 16n+32...48n+32), rows n/2..3n/2
            let mapW = n * 32, mapH = n * 16
            let originX: Float = n * 16 + 32, originY: Float = n * 8 + 32
            let vx0 = (pan.x - originX) / mapW, vy0 = (pan.y - originY) / mapH
            let vx1 = vx0 + Float(AdventureUI.mapViewportWidth) * uiScale / zoom / mapW, vy1 = vy0 + viewSize.y / zoom / mapH
            let rx0 = mm.x + Int(max(0, min(1, vx0)) * Float(mm.width)), rx1 = mm.x + Int(max(0, min(1, vx1)) * Float(mm.width))
            let ry0 = mm.y + Int(max(0, min(1, vy0)) * Float(mm.height)), ry1 = mm.y + Int(max(0, min(1, vy1)) * Float(mm.height))
            if rx1 > rx0, ry1 > ry0 {
                out.append(Quad(texture: white, x: rx0, y: ry0, w: rx1 - rx0, h: 1)); out.append(Quad(texture: white, x: rx0, y: ry1 - 1, w: rx1 - rx0, h: 1))
                out.append(Quad(texture: white, x: rx0, y: ry0, w: 1, h: ry1 - ry0)); out.append(Quad(texture: white, x: rx1 - 1, y: ry0, w: 1, h: ry1 - ry0))
            }
        }
        // resource numbers, right-aligned in their fields
        for name in ui.resourceNames {
            guard let field = ui.hotspot("\(name)_Number") else { continue }
            let text = String(g.resources[name] ?? 0)
            let t = uiTexture("num|\(text)", { ui.numberFont.render(text, colour: (40, 24, 8)) })
            let w = ui.numberFont.measure(text)
            out.append(Quad(texture: t, x: field.x + field.width - w - 2, y: field.y + (field.height - ui.numberFont.size) / 2, w: w, h: ui.numberFont.size))
        }
        // the day scroll and its two text lines
        if let slot = ui.hotspot("day_scroll") {
            if let bg = ui.dayScroll["Background"] { out.append(Quad(texture: uiTexture("scroll|bg", { bg.bitmap }), x: slot.x + bg.x, y: slot.y + bg.y, w: bg.width, h: bg.height)) }
            if let rt = ui.dayScroll["Right"] { out.append(Quad(texture: uiTexture("scroll|right", { rt.bitmap }), x: slot.x + rt.x, y: slot.y + rt.y, w: rt.width, h: rt.height)) }
            if let field = ui.dayScroll["text"] {
                let lines = ["Day \(g.dayOfWeek) of Week \(g.week)", "Month \(g.month)"]
                for (i, line) in lines.enumerated() {
                    let w = ui.dateFont.measure(line)
                    let t = uiTexture("date|\(line)", { ui.dateFont.render(line, colour: (40, 24, 8)) })
                    out.append(Quad(texture: t, x: slot.x + field.x + (field.width - w) / 2, y: slot.y + field.y + i * ui.dateFont.lineHeight - 2, w: w, h: ui.dateFont.size))
                }
            }
        }
        // hero portraits (in their rings) in the hero list, with the movement bar (left, green)
        // and the mana bar (right, purple) filling from the bottom
        for (i, h) in g.heroes.prefix(AdventureUI.heroSlots.count).enumerated() {
            if let p = ui.portrait(keyword: h.keyword, alignment: h.alignment) {
                let (cx, cy) = AdventureUI.heroSlots[i]
                let px = cx - p.width / 2, py = cy - p.height / 2
                if let ring = ui.heroRing() {
                    let ox = px - ring.portraitAt.0, oy = py - ring.portraitAt.1
                    out.append(Quad(texture: uiTexture("ring|frame", { ring.frame.bitmap }), x: ox + ring.frame.x, y: oy + ring.frame.y, w: ring.frame.width, h: ring.frame.height))
                    if let bar = ui.armyRings?["Move_Bar"], h.maxMovement > 0 {
                        let f = max(0, min(1, h.movement / h.maxMovement))
                        let filled = Int(Float(bar.height) * f)
                        if filled > 0 {   // the bar's lower `filled` rows
                            let tex = uiTexture("ring|move|\(filled)", { var b = Bitmap(width: bar.width, height: filled); let src = bar.bitmap
                                for y in 0..<filled { for x in 0..<bar.width { for k in 0..<4 { b.pixels[(y * bar.width + x) * 4 + k] = src.pixels[((bar.height - filled + y) * bar.width + x) * 4 + k] } } }; return b })
                            out.append(Quad(texture: tex, x: ox + bar.x, y: oy + bar.y + bar.height - filled, w: bar.width, h: filled))
                        }
                    }
                    if let mana = ui.armyRings?["Mana_Bar"] {   // no spell points yet: an empty purple sliver
                        out.append(Quad(texture: solid(120, 40, 160), x: ox + mana.x + 4, y: oy + mana.y + mana.height - 4, w: mana.width - 8, h: 3))
                    }
                }
                out.append(Quad(texture: uiTexture("portrait|\(h.alignment)|\(h.keyword)", { p.bitmap }), x: px, y: py, w: p.width, h: p.height))
            }
        }
        // the selected hero's army: the hero, then his stacks; the labels last, over the next row
        if let h = g.heroes.first {
            let heroes = [h] + h.companions
            var slots: [(UILayer?, String?)] = heroes.map { (ui.portrait(keyword: $0.keyword, alignment: $0.alignment), nil) }
            slots += h.army.map { (ui.creatureIcon($0.creature), String($0.count)) }
            let shown = Array(slots.prefix(AdventureUI.armySlots.count).enumerated())
            for (i, (icon, _)) in shown {
                let (cx, cy) = AdventureUI.armySlots[i]
                if let icon = icon {
                    out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height))
                }
            }
            for (i, (_, count)) in shown {
                let (cx, cy) = AdventureUI.armySlots[i]
                ringLabel(&out, ui: ui, cx: cx, cy: cy, count: count, hero: i < heroes.count)
            }
        }
        // the town list: each owned town as its card (terrain, walls, three bars) and a piece of the minimap around it
        if let list = ui.hotspot("Town_list") {
            for (i, t) in g.towns.filter({ $0.owned }).prefix(3).enumerated() {
                let cx = list.x + 4, cy = list.y + 8 + i * 72
                if let card = ui.tinyCard(t.alignment) {
                    let terrain = TownScreen.terrainNames[t.terrain] ?? "grass"
                    if let bg = card.layers.first(where: { $0.name.lowercased() == terrain }) ?? card["grass"] {
                        out.append(Quad(texture: uiTexture("tiny|\(t.alignment)|\(bg.name)", { bg.bitmap }), x: cx + bg.x, y: cy + bg.y, w: bg.width, h: bg.height))
                    }
                    let walls = t.buildings.contains("castle") ? "Castle" : t.buildings.contains("citadel") ? "Citadel" : t.buildings.contains("fort") ? "Fort" : "Village"
                    if let w = card[walls] { out.append(Quad(texture: uiTexture("tiny|\(t.alignment)|\(walls)", { w.bitmap }), x: cx + w.x, y: cy + w.y, w: w.width, h: w.height)) }
                    // bars: creatures waiting to be recruited, mage guild level, buildings built
                    let waiting = t.available.values.reduce(0, +)
                    let guild = (1...5).filter { t.buildings.contains("mage guild \($0)") }.count
                    let built = g.tables.map { tb in Float(t.buildings.count) / Float(max(1, tb.buildings(for: t.alignment).count)) } ?? 0
                    for (slot, frac, rgb) in [("creatures", min(1, Float(waiting) / 60), (40, 200, 40)), ("magic", Float(guild) / 5, (40, 80, 220)), ("misc", built, (220, 40, 40))] as [(String, Float, (UInt8, UInt8, UInt8))] {
                        guard let hs = card[slot] else { continue }
                        out.append(Quad(texture: solid(20, 20, 20), x: cx + hs.x, y: cy + hs.y, w: hs.width, h: hs.height))
                        let w = Int(Float(hs.width) * max(0, min(1, frac)))
                        if w > 0 { out.append(Quad(texture: solid(rgb.0, rgb.1, rgb.2), x: cx + hs.x, y: cy + hs.y, w: w, h: hs.height)) }
                    }
                }
                // the minimap around the town, 48 px of it
                if let mm = minimapTexture, let hs = ui.hotspot("mini_map") {
                    _ = mm
                    let tex = uiTexture("townmap|\(t.x),\(t.y)|\(minimapStamp)", {
                        let full = AdventureUI.minimap(game: g, size: hs.width)
                        let n = Float(g.map.size)
                        let px = Int((Float(t.y - t.x + 3 - 3) + n / 2) / n * Float(hs.width)), py = Int((Float(t.x + t.y + 6) - n / 2) / n * Float(hs.width))
                        var b = Bitmap(width: 48, height: 48)
                        for y in 0..<48 { for x in 0..<48 {
                            let sx = px - 24 + x, sy = py - 24 + y
                            guard sx >= 0, sx < full.width, sy >= 0, sy < full.height else { continue }
                            for k in 0..<4 { b.pixels[(y * 48 + x) * 4 + k] = full.pixels[(sy * full.width + sx) * 4 + k] }
                        } }
                        return b
                    })
                    out.append(Quad(texture: black, x: cx + 92, y: cy, w: 50, h: 50))
                    out.append(Quad(texture: tex, x: cx + 93, y: cy + 1, w: 48, h: 48))
                }
            }
        }
        // messages, newest at the bottom, over the top of the map
        for (i, t) in toasts.suffix(4).enumerated() {
            let w = ui.dateFont.measure(t.text)
            let x = (AdventureUI.mapViewportWidth - w) / 2, y = 90 + i * (ui.dateFont.lineHeight + 8)
            out.append(Quad(texture: shade, x: x - 10, y: y - 4, w: w + 20, h: ui.dateFont.lineHeight + 6))
            out.append(Quad(texture: uiTexture("toast|\(t.text)", { ui.dateFont.render(t.text, colour: (255, 236, 200)) }), x: x, y: y, w: w, h: ui.dateFont.size))
        }
        // End Turn button (released state) in its hotspot
        if let slot = ui.hotspot("end_turn"), let b = ui.endTurnButton["Released"] {
            out.append(Quad(texture: uiTexture("button|end_turn", { b.bitmap }), x: slot.x, y: slot.y, w: b.width, h: b.height))
        }
        out += panelButtonQuads()
        out += floaterQuads()
        out += hoverQuads()
        out += popupQuads()
        out += creatureDialogQuads()
        out += adventureDialogQuads()
        out += armyPopupQuads()
        out += overviewQuads()
        out += marketQuads()
        out += spellBookQuads()
        out += optionsQuads()
        out += hireQuads()
        out += puzzleQuads()
        out += shopQuads()
        out += sanctuaryQuads()
        out += levelUpQuads()
        out += choiceQuads()
        out += messageBoxQuads()
        out += saveDialogQuads()
        out += menuQuads()
        return out
    }
    var showBlocked = false   // debug: mark every cell a hero cannot enter
    lazy var flag: MTLTexture = {   // the player's colour (blue) with a dark edge
        var bm = Bitmap(width: 10, height: 14)
        for y in 0..<14 { for x in 0..<10 {
            let edge = x == 0 || y == 0 || y == 13 || x == 9
            let p = (y * 10 + x) * 4
            bm.pixels[p] = edge ? 20 : 40; bm.pixels[p + 1] = edge ? 20 : 80; bm.pixels[p + 2] = edge ? 40 : 220; bm.pixels[p + 3] = 255
        } }
        return makeTexture(bm)
    }()
    lazy var redDot: MTLTexture = {
        var bm = Bitmap(width: 6, height: 6)
        for i in 0..<36 { bm.pixels[i * 4] = 255; bm.pixels[i * 4 + 3] = 200 }
        return makeTexture(bm)
    }()

    init(device: MTLDevice, scenes: [MapScene], pixelFormat: MTLPixelFormat) throws {
        self.device = device
        self.scenes = scenes
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        vertexBuffer = device.makeBuffer(length: 1 << 20, options: .storageModeShared)!
        super.init()
        for sc in scenes {
            terrainByLevel.append(sc.chunks.map { c in Quad(texture: makeTexture(c.bitmap), x: c.x, y: c.y, w: c.bitmap.width, h: c.bitmap.height) })
            for p in sc.placed {   // upload every frame of every object up front
                for img in p.sprite.images { _ = texture(for: img, of: p.name) }
            }
        }
        pan = SIMD2(Float(scenes[0].width) / 2 - 640, Float(scenes[0].height) / 2 - 400)
    }

    func texture(for img: SpriteImage, of name: String) -> MTLTexture {
        let key = name + "|" + img.name
        if let t = textures[key] { return t }
        let t = makeTexture(img.bitmap)
        textures[key] = t
        return t
    }

    func makeTexture(_ bm: Bitmap) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: bm.width, height: bm.height, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        bm.pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, bm.width, bm.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bm.width * 4) }
        return t
    }

    var timelines: [String: [(frame: SpriteImage, shadow: SpriteImage?)]] = [:]

    /// The object's current frame (and shadow) at time t.
    func frame(of p: MapScene.Placed, at t: Double) -> (SpriteImage, SpriteImage?) {
        if timelines[p.name] == nil { timelines[p.name] = p.sprite.timeline }
        let tl = timelines[p.name]!
        guard !tl.isEmpty else { return (p.image, p.shadow) }
        let speed = tl[0].frame.speed
        let period = speed > 0 ? Double(speed) / 60.0 : 0.125
        let e = tl[Int(t / period) % tl.count]
        return (e.frame, e.shadow ?? p.shadow)
    }

    /// The map cell under a map-canvas point (rounding x and y separately picks the diamond).
    func cell(at m: SIMD2<Float>) -> (Int, Int) {
        let u = (m.x - Float(scene.map.size * 32 + 32)) / 32, v = (m.y - 32) / 16   // u = y - x, v = x + y
        return (Int(((v - u) / 2).rounded()), Int(((v + u) / 2).rounded()))
    }

    /// Is the point on an opaque pixel of the object's picture?
    func underCursor(_ p: MapScene.Placed, _ m: SIMD2<Float>) -> Bool {
        guard Float(p.x) <= m.x, m.x < Float(p.x + p.image.bitmap.width), Float(p.y) <= m.y, m.y < Float(p.y + p.image.bitmap.height) else { return false }
        let bm = p.image.bitmap
        return bm.pixels[((Int(m.y) - p.y) * bm.width + Int(m.x) - p.x) * 4 + 3] > 0
    }

    /// Is the cell inside the object's footprint?
    func onFootprint(_ p: MapScene.Placed, _ c: (Int, Int)) -> Bool {
        c.0 >= p.cellX && c.0 < p.cellX + p.sprite.footprint.w && c.1 >= p.cellY && c.1 < p.cellY + p.sprite.footprint.h
    }

    /// The creature dialog (layers.dialog.army_right_click) opened by a right click on a
    /// wandering stack; drawn centred on the canvas.
    var creatureDialog: (creature: CreatureDef, count: Int, extra: [(creature: CreatureDef, count: Int)])?
    static let dialogOrigin = ((AdventureUI.width - 464) / 2, (AdventureUI.height - 494) / 2)

    /// Is a canvas point on the open creature dialog (and on its Close button)?
    func onDialog(_ x: Float, _ y: Float) -> (inside: Bool, close: Bool) {
        guard creatureDialog != nil, let ui = ui, let d = ui.dialog("army_right_click"), let bg = d["Background"] else { return (false, false) }
        let (ox, oy) = Renderer.dialogOrigin
        let inside = x >= Float(ox) && x < Float(ox + bg.width) && y >= Float(oy) && y < Float(oy + bg.height)
        var close = false
        if let c = d["Close_Button"] { close = x >= Float(ox + c.x) && x < Float(ox + c.x + c.width) && y >= Float(oy + c.y) && y < Float(oy + c.y + c.height) }
        return (inside, close)
    }

    /// The quads of the creature dialog: the layout's images, the stack's portrait in the first
    /// circle with its size below, name, level, alignment, abilities and the stat values under
    /// their icons.
    func creatureDialogQuads() -> [Quad] {
        guard let cd = creatureDialog, let ui = ui, let d = ui.dialog("army_right_click") else { return [] }
        let (ox, oy) = Renderer.dialogOrigin
        var out: [Quad] = []
        func image(_ name: String) {
            guard let l = d[name] else { return }
            out.append(Quad(texture: uiTexture("dlg|armyrc|\(name)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height))
        }
        func text(_ s: String, in name: String, font: H4Font, colour: (UInt8, UInt8, UInt8) = (40, 24, 8)) {
            guard let l = d[name], !s.isEmpty else { return }
            let w = font.measure(s)
            out.append(Quad(texture: uiTexture("dlgtext|\(font.size)|\(s)", { font.render(s, colour: colour) }), x: ox + l.x + (l.width - w) / 2, y: oy + l.y + (l.height - font.size) / 2, w: w, h: font.size))
        }
        image("Background")
        image("creature_circles")
        image("Skills_Frame")
        for n in ["Damage", "Melee_Attack", "Melee_Defense", "Hit_Points", "Speed", "Movement", "Shots", "Ranged_Attack", "Ranged_Defense", "Spell_Points", "Experience"] { image(n) }
        image("Army_Released")
        if let slot = d["Close_Button"], let b = ui.button("close") {   // the button picture lives in layers.button.close
            out.append(Quad(texture: uiTexture("button|close", { b.bitmap }), x: ox + slot.x + (slot.width - b.width) / 2, y: oy + slot.y + (slot.height - b.height) / 2, w: b.width, h: b.height))
        }
        let c = cd.creature
        func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        text("\(cd.count) \(cd.count == 1 ? cap(c.name) : cap(c.plural))", in: "Title", font: ui.font(16))
        // the army in the seven columns of the background (dividers every 60 px from x = 22):
        // the stack and, when it has one, the cheaper escort that fights with it
        var stacks = [(c, cd.count)]
        for e in cd.extra { stacks.append((e.creature, e.count)) }
        for (k, (def, n)) in stacks.prefix(7).enumerated() {
            let cx = ox + 52 + 60 * k
            if let p = ui.creatureIcon(def.keyword) {
                out.append(Quad(texture: uiTexture("cicon|\(def.keyword)", { p.bitmap }), x: cx - p.width / 2, y: oy + 62, w: p.width, h: p.height))
            }
            let s = "\(n)", w = ui.numberFont.measure(s)
            out.append(Quad(texture: uiTexture("num|\(s)", { ui.numberFont.render(s, colour: (40, 24, 8)) }), x: cx - w / 2, y: oy + 124, w: w, h: ui.numberFont.size))
        }
        text("Level \(c.level)", in: "Level", font: ui.dateFont)
        text(cap(c.alignment), in: "Alignment", font: ui.dateFont)
        text(c.shortHelp, in: "Stealth", font: ui.numberFont)
        let ranged = c.shots > 0
        // the stack's morale from its army's alignments (heroes4.exe 0x640310); none for mechanical or undead
        var army = [(alignment: c.alignment, undead: Combatant(creature: c, count: 1).has("undead"))]
        for e in cd.extra { army.append((e.creature.alignment, Combatant(creature: e.creature, count: 1).has("undead"))) }
        let noMorale = Combatant(creature: c, count: 1).has("mechanical") || army[0].undead
        let m = noMorale ? 0 : Battle.armyMorale(own: c.alignment, army: army)
        let moraleText = m > 0 ? "+\(m)" : "\(m)"
        let values: [(String, String)] = [("Damage_Text", "\(c.damageLow)-\(c.damageHigh)"), ("Melee_Attack_Text", "\(c.attack)"), ("Melee_Defense_Text", "\(c.defense)"),
                                          ("Hit_Points_Text", "\(c.hitPoints)"), ("Morale_Text", moraleText), ("Speed_Text", "\(c.speed)"), ("Movement_Text", "\(c.move)"),
                                          ("Shots_Text", "\(c.shots)"), ("Ranged_Attack_Text", ranged ? "\(c.attack)" : "0"), ("Ranged_Defense_Text", "\(c.defense)"),
                                          ("Spell_Points_Text", "\(c.spellPoints)"), ("Luck_Text", "0"), ("Experience_Text", "\(c.experience)")]
        for (slot, v) in values { text(v, in: slot, font: ui.numberFont) }
        return out
    }

    /// Which of the game's cursors fits what is under a map point: attack over a wandering
    /// stack, activate over something to visit, move over walkable ground, blocked elsewhere.
    func cursorKind(mapPoint m: SIMD2<Float>) -> String {
        cursorFrameIndex = nil
        var kind = pointerKind(mapPoint: m)
        if let g = game, g.enemyAt(cell(at: m).0, cell(at: m).1) != nil { kind = "attack" }   // an enemy army
        // a free cell where a wandering stack would fall on the hero: the danger pointer
        if kind == "move", let g = game, let h = g.heroes.first {
            let c = cell(at: m)
            if g.threat(to: h, at: c.0, c.1) != nil { kind = "Danger_Zone" }
        }
        guard ["move", "attack", "activate", "Danger_Zone"].contains(kind), let g = game, let h = g.heroes.first else { return kind }
        guard h.z == g.level else { return "normal" }
        // the days to get there pick the frame; an object is reached from the cell before it
        var c = cell(at: m)
        if kind != "move", kind != "Danger_Zone", let p = scene.placed.last(where: { g.isVisitable($0) && (underCursor($0, m) || onFootprint($0, c)) }) {
            c = kind == "attack" || g.town(for: p) == nil ? (p.cellX, p.cellY) : g.gateCells(p)[0]
        }
        let key = c.0 * g.map.size + c.1 + h.x * 1_000_003 + h.y * 7919 + Int(h.movement * 10) * 104729
        if dayCache?.cell != key {
            var days = g.daysToReach(h, c)
            if days == nil, kind != "move", kind != "Danger_Zone" {   // an object: the cheapest free neighbour
                for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                    if let d = g.daysToReach(h, (c.0 + dx, c.1 + dy)) { days = min(days ?? d, d) }
                } }
            }
            dayCache = (key, days)
        }
        cursorFrameIndex = min(4, max(1, dayCache?.days ?? 1)) - 1
        return kind
    }
    func pointerKind(mapPoint m: SIMD2<Float>) -> String {
        guard let g = game else { return "normal" }
        let c = cell(at: m)
        if let p = scene.placed.last(where: { g.isVisitable($0) && (underCursor($0, m) || onFootprint($0, c)) }) {
            return g.monster(for: p) != nil ? "attack" : "activate"
        }
        if g.heroes.contains(where: { $0.z == g.level && $0.x == c.0 && $0.y == c.1 }) { return "normal" }
        return g.passability.isFree(c.0, c.1) ? "move" : "blocked"
    }

    /// The right-click box: what it says and where its top-left corner is on the canvas.
    var popup: (title: String, lines: [String], x: Int, y: Int)?
    var popupSize = (w: 0, h: 0)
    /// Is a canvas point on the open box?
    func onPopup(_ x: Float, _ y: Float) -> Bool {
        guard let p = popup else { return false }
        return x >= Float(p.x) && x < Float(p.x + popupSize.w) && y >= Float(p.y) && y < Float(p.y + popupSize.h)
    }

    /// A right click on the map: describe the hero or the object there (topmost drawn wins)
    /// in a box near the canvas point; nothing there clears it.
    func inspect(mapPoint m: SIMD2<Float>, canvas: (Float, Float)) {
        popup = nil
        creatureDialog = nil
        guard let g = game, let ui = ui else { return }
        let c = cell(at: m)
        var text: (title: String, body: [String])?
        if let i = g.heroes.firstIndex(where: { $0.z == g.level && Int($0.position.x.rounded()) == c.0 && Int($0.position.y.rounded()) == c.1 }) {
            armyPopup = ArmyPopup(hero: i); return   // an own army: its right-click window
        }
        else if let p = scene.placed.last(where: { underCursor($0, m) || onFootprint($0, c) }) {
            if let i = g.monster(for: p), let def = g.tables?.creature(g.monsters[i].creature) {   // a wandering stack gets the creature dialog
                creatureDialog = (def, g.monsters[i].count, g.monsters[i].extra.compactMap { e in g.tables?.creature(e.creature).map { ($0, e.count) } })
                return
            }
            text = g.describe(p)
        }
        else { text = g.describe(cellX: c.0, cellY: c.1) }
        guard let t = text else { return }
        var lines: [String] = []
        for para in t.body { lines += AdventureUI.wrap(para, font: ui.numberFont, width: 220); lines.append("") }
        if lines.last == "" { lines.removeLast() }
        let w = max(ui.dateFont.measure(t.title), lines.map { ui.numberFont.measure($0) }.max() ?? 0)
        let h = ui.dateFont.lineHeight + 4 + lines.count * ui.numberFont.lineHeight
        // near the cursor, kept inside the map viewport
        var x = Int(canvas.0) + 16, y = Int(canvas.1) + 16
        if x + w + 40 > AdventureUI.mapViewportWidth { x = Int(canvas.0) - w - 40 }
        if y + h + 30 > AdventureUI.height { y = Int(canvas.1) - h - 30 }
        popup = (t.title, lines, max(0, x), max(0, y))
    }

    /// The quads of the right-click box.
    func popupQuads() -> [Quad] {
        guard let p = popup, let ui = ui else { return [] }
        let w = max(ui.dateFont.measure(p.title), p.lines.map { ui.numberFont.measure($0) }.max() ?? 0)
        let h = ui.dateFont.lineHeight + 4 + p.lines.count * ui.numberFont.lineHeight
        guard let box = ui.popupBitmap(clientW: w, clientH: h) else { return [] }
        popupSize = (box.bitmap.width, box.bitmap.height)
        var out = [Quad(texture: uiTexture("popup|\(w)x\(h)", { box.bitmap }), x: p.x, y: p.y, w: box.bitmap.width, h: box.bitmap.height)]
        let cx = p.x + box.clientX, cy = p.y + box.clientY
        let tw = ui.dateFont.measure(p.title)
        out.append(Quad(texture: uiTexture("date|\(p.title)", { ui.dateFont.render(p.title, colour: (40, 24, 8)) }), x: cx + (w - tw) / 2, y: cy, w: tw, h: ui.dateFont.size))
        for (i, line) in p.lines.enumerated() where !line.isEmpty {
            out.append(Quad(texture: uiTexture("num|\(line)", { ui.numberFont.render(line, colour: (40, 24, 8)) }), x: cx, y: cy + ui.dateFont.lineHeight + 4 + i * ui.numberFont.lineHeight, w: ui.numberFont.measure(line), h: ui.numberFont.size))
        }
        return out
    }

    /// A click on the map at a map-canvas point: visit the object there, or walk to the cell.
    func click(mapPoint m: SIMD2<Float>) {
        guard let g = game else { return }
        // a sanctuary holding one of the player's armies: leave it?
        if let p = scene.placed.last(where: { ($0.type == "sanctuary" || $0.type == "sea_sanctuary") && g.sanctuaryGuests["\(g.level)|\($0.cellX)|\($0.cellY)"] != nil && (self.underCursor($0, m) || self.onFootprint($0, cell(at: m))) }) {
            g.askLeaveSanctuary("\(g.level)|\(p.cellX)|\(p.cellY)"); return
        }
        guard let hero = g.heroes.first, hero.z == g.level else { return }   // viewing the other level: nothing to do there
        var (x, y) = cell(at: m)
        func underCursor(_ p: MapScene.Placed) -> Bool { self.underCursor(p, m) }
        func onFootprint(_ p: MapScene.Placed) -> Bool { self.onFootprint(p, (x, y)) }
        // a visitable object under the cursor or on the clicked cell (topmost drawn wins): walk next to it and use it
        if let p = scene.placed.last(where: { g.isVisitable($0) && (underCursor($0) || onFootprint($0)) }) {
            g.click(hero: hero, pickup: p)
            return
        }
        if hero.boat != nil || g.boat(at: x, y) != nil { g.click(hero: hero, x: x, y: y); return }   // sailing, or a ship to board
        if !g.passability.isFree(x, y) {
            // Clicked on something you cannot stand on. If an object's picture is under the cursor
            // (a bridge deck is drawn well above its cells), go to the nearest free cell of its
            // footprint; otherwise to the nearest free cell around the click.
            var best: (Int, Int)?
            var bestD = Float.infinity
            for p in scene.placed where underCursor(p) {
                for i in 0..<p.sprite.footprint.w {
                    for j in 0..<p.sprite.footprint.h where g.passability.isFree(p.cellX + i, p.cellY + j) {
                        let (cx, cy) = screen(Float(p.cellX + i), Float(p.cellY + j))
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

    /// The game's own path arrows: adv_object.internal.<green|red>_arrow.<straight|left|right>.<dir> / .dest
    func arrowSprite(_ name: String, prefix: String = "adv_object.internal") -> Sprite? {
        let key = "\(prefix).\(name)"
        if let s = actorSprites[key] { return s }
        guard let r = resolver, let e = r.entry("\(prefix).\(name).h4d"), let s = try? Sprite(data: r.archive.payload(e)) else { return nil }
        actorSprites[key] = s
        return s
    }

    /// Screen centre of a (fractional) cell.
    func screen(_ x: Float, _ y: Float) -> (Float, Float) {
        ((y - x) * 32 + Float(scene.map.size * 32 + 32), (x + y) * 16 + 32)
    }

    /// The quads of one hero at time t: its current sequence frame (and shadow) at its map position.
    func heroQuads(_ h: Hero, at t: Double) -> [Quad] {
        guard let r = resolver else { print("hero: no resolver"); return [] }
        let state = h.isWalking ? "walk" : "wait"
        // at sea the army is drawn as its ship (adv_actor.ships.<alignment>)
        let actorName = h.boat.map { "ships.\(["life", "order", "death", "chaos", "nature", "might"].contains($0) ? $0 : "generic")" } ?? h.actor
        guard let entry = r.sequence(actor: actorName, state: state, facing: h.facing) else { print("hero: no sequence for \(h.actor) \(state) \(h.facing)"); return [] }
        if actorSprites[entry] == nil {
            do { actorSprites[entry] = try Sprite(data: r.archive.payload(entry)) } catch { print("hero: \(entry): \(error)") }
        }
        guard let s = actorSprites[entry] else { return [] }
        let tl = s.timeline
        var frame = s.frames.first, shadow = frame.flatMap { s.shadow(for: $0) }
        if !tl.isEmpty {
            // walking: one full cycle per cell so the gait matches the ground; otherwise by the file's speed
            let index: Int
            if h.isWalking { index = Int(h.distance * Float(tl.count)) % tl.count }
            else { index = Int(t / (tl[0].frame.speed > 0 ? Double(tl[0].frame.speed) / 60.0 : 0.125)) % tl.count }
            let e = tl[index]
            frame = e.frame; shadow = e.shadow
        }
        let (px, py) = h.position
        let (sx, sy0) = screen(px, py)
        let sy = sy0 - (game.map { h.elevation(in: $0.passability) } ?? 0)   // raised on bridges
        let ox = Int(sx) + Int(s.origin.x), oy = Int(sy) - 16 + Int(s.origin.y)   // origin is from the cell's top vertex
        var out: [Quad] = []
        // the selected army's ring (adv_object.internal.selected.army, 8 turning frames) under its feet
        if h === game?.heroes.first, let ring = arrowSprite("selected.army"), !ring.frames.isEmpty {
            let f = ring.frames[Int(t / 0.1) % ring.frames.count]
            let rx = Int(sx) + Int(ring.origin.x), ry = Int(sy) - 16 + Int(ring.origin.y)
            out.append(Quad(texture: texture(for: f, of: "selected.army"), x: rx + f.box.left, y: ry + f.box.top, w: f.bitmap.width, h: f.bitmap.height))
        }
        if let sh = shadow { out.append(Quad(texture: texture(for: sh, of: entry), x: ox + sh.box.left, y: oy + sh.box.top, w: sh.bitmap.width, h: sh.bitmap.height)) }
        if let f = frame { out.append(Quad(texture: texture(for: f, of: entry), x: ox + f.box.left, y: oy + f.box.top, w: f.bitmap.width, h: f.bitmap.height)) }
        if ProcessInfo.processInfo.environment["H4DEBUG"] != nil {
            print("hero: \(entry) at cell (\(px),\(py)) screen (\(sx),\(sy)) origin \(s.origin) frame \(frame?.name ?? "-") box \(frame.map { "\($0.box)" } ?? "-") -> \(out.map { "(\($0.x),\($0.y) \($0.w)x\($0.h))" })")
        }
        return out
    }

    /// A cell's draw depth, raised past every large object whose footprint it stands in front of.
    /// An object sorts by its footprint's bottom row, but a cell beside one of its front walls
    /// (beyond it in x or in y, e.g. a town's gate) is nearer the viewer than the whole object.
    func inFront(_ x: Int, _ y: Int, _ depth: Float) -> Float {
        var d = depth
        for p in scene.placed where p.sprite.footprint.w * p.sprite.footprint.h > 1 && Float(p.depth) >= d {
            let x0 = p.cellX, y0 = p.cellY, x1 = p.cellX + p.sprite.footprint.w, y1 = p.cellY + p.sprite.footprint.h
            guard x >= x0 - 1, y >= y0 - 1, x <= x1 + 1, y <= y1 + 1 else { continue }
            let beyondX = x >= x1 && y >= y0, beyondY = y >= y1 && x >= x0
            if beyondX || beyondY { d = Float(p.depth) + 1 }
        }
        return d
    }

    func quads(at t: Double) -> [Quad] {
        var out = terrain
        let minX = pan.x - 512, minY = pan.y - 512, maxX = pan.x + viewSize.x / zoom + 512, maxY = pan.y + viewSize.y / zoom + 512
        // heroes are sorted in among the objects by the same depth rule (cell row, then column)
        var pending: [(depth: Float, quads: [Quad])] = []
        if let g = game {
            // empty ships on the water
            for b in g.boats where b.z == g.level {
                let ship = Hero(actor: "", x: b.x, y: b.y, movement: 0)
                ship.boat = b.alignment; ship.facing = "sw"
                pending.append((inFront(b.x, b.y, Float((b.x + b.y) * 1000 + (b.y - b.x) + 500)), heroQuads(ship, at: t)))
            }
            for h in (g.heroes + g.enemyHeroes) where h.z == g.level {
                for a in (h.owner == g.map.humanColour && settings.showMovementPath ? g.arrows(for: h) : []) {
                    // arrows sort with the objects (a tree in front hides them) and ride up onto bridges
                    guard let s = arrowSprite(a.name), let f = s.frames.first else { continue }
                    let raise = g.passability.elevation(a.x, a.y)
                    let (sx, sy) = screen(Float(a.x), Float(a.y))
                    let ox = Int(sx) + Int(s.origin.x), oy = Int(sy - raise) - 16 + Int(s.origin.y)
                    var q: [Quad] = []
                    if let sh = s.shadow(for: f) { q.append(Quad(texture: texture(for: sh, of: a.name), x: ox + sh.box.left, y: oy + sh.box.top, w: sh.bitmap.width, h: sh.bitmap.height)) }
                    q.append(Quad(texture: texture(for: f, of: a.name), x: ox + f.box.left, y: oy + f.box.top, w: f.bitmap.width, h: f.bitmap.height))
                    pending.append((inFront(a.x, a.y, Float((a.x + a.y) * 1000 + (a.y - a.x) + 499) + (raise > 0 ? 2500 : 0)), q))
                }
                let (px, py) = h.position
                // on a bridge the hero is drawn after the bridge pieces around it
                let raised: Float = h.elevation(in: g.passability) > 0 ? 2500 : 0
                pending.append((inFront(Int(px.rounded()), Int(py.rounded()), (px + py) * 1000 + (py - px) + 500 + raised), heroQuads(h, at: t)))
            }
            pending.sort { $0.depth < $1.depth }
        }
        for p in scene.placed {
            while let first = pending.first, first.depth <= Float(p.depth) { out += first.quads; pending.removeFirst() }
            if Float(p.anchorX) < minX || Float(p.anchorX) > maxX || Float(p.anchorY) < minY || Float(p.anchorY) > maxY { continue }
            let (f, sh) = frame(of: p, at: t)
            var ox = p.anchorX + Int(p.sprite.origin.x), oy = p.anchorY + Int(p.sprite.origin.y)
            // a wandering stack walking up to a hero: drawn where it has got to
            if let g = game, let cp = g.chargePosition, g.monster(for: p) == cp.monster {
                let (sx, sy) = screen(cp.x, cp.y)
                ox = Int(sx) + Int(p.sprite.origin.x); oy = Int(sy) - 16 + Int(p.sprite.origin.y)
            }
            if let base = p.sprite.baseFrame, f.name != base.name {   // animated towns: frames are deltas over base_frame
                if let s = sh { out.append(Quad(texture: texture(for: s, of: p.name), x: ox + s.box.left, y: oy + s.box.top, w: s.bitmap.width, h: s.bitmap.height)) }
                out.append(Quad(texture: texture(for: base, of: p.name), x: ox + base.box.left, y: oy + base.box.top, w: base.bitmap.width, h: base.bitmap.height))
                out.append(Quad(texture: texture(for: f, of: p.name), x: ox + f.box.left, y: oy + f.box.top, w: f.bitmap.width, h: f.bitmap.height))
            } else {
                if let s = sh { out.append(Quad(texture: texture(for: s, of: p.name), x: ox + s.box.left, y: oy + s.box.top, w: s.bitmap.width, h: s.bitmap.height)) }
                out.append(Quad(texture: texture(for: f, of: p.name), x: ox + f.box.left, y: oy + f.box.top, w: f.bitmap.width, h: f.bitmap.height))
            }
        }
        for p in pending { out += p.quads }
        if let g = game, let ui = ui, let fs = ui.flag(AdventureUI.playerColourNames[0]), !fs.frames.isEmpty {   // the owner's waving flag over towns and mines
            let f = fs.frames[Int(t / 0.12) % fs.frames.count]
            let tex = texture(for: f, of: "flag|red")
            for m in g.mines where m.owned {
                let (sx, sy) = screen(Float(m.x), Float(m.y))
                out.append(Quad(texture: tex, x: Int(sx) - 2, y: Int(sy) - 70, w: f.bitmap.width, h: f.bitmap.height))
            }
            for tn in g.towns where tn.owned {   // on the highest point of the town picture
                if let p = scene.placed.first(where: { $0.category == "castle" && $0.cellX == tn.x && $0.cellY == tn.y }) {
                    out.append(Quad(texture: tex, x: p.x + p.image.bitmap.width / 2 - 4, y: p.y - 4, w: f.bitmap.width, h: f.bitmap.height))
                }
            }
        }
        if let g = game, showBlocked {   // on top of everything so buildings do not hide their own cells
            let n = g.map.size
            for x in 0..<n { for y in 0..<n where g.map.cells[g.level][x * n + y] != nil && !g.passability.isFree(x, y) {
                let (sx, sy) = screen(Float(x), Float(y))
                if sx >= minX, sx <= maxX, sy >= minY, sy <= maxY { out.append(Quad(texture: redDot, x: Int(sx) - 3, y: Int(sy) - 3, w: 6, h: 6)) }
            } }
        }
        return out
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = SIMD2(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastFrame)
        frameTimes.append(dt)
        lastFrame = now
        if let g = game {
            g.update(dt: Float(min(dt, 0.1)))
            for line in g.log { print(line); toasts.append((line, now.addingTimeInterval(5))) }
            for name in g.sounds { sound?.play(name) }
            g.sounds.removeAll()
            updateMusic()
            if lastAutosaveDay != g.day, mapPath != nil { lastAutosaveDay = g.day; autosave() }   // each new day autosaves
            // the hero's ride: sound.hero horse.walk loops while a hero walks on the map
            if !inCombat, townOpen == nil, g.heroes.contains(where: { $0.isWalking }) { sound?.startLoop("hero horse.walk", key: "horse") }
            else { sound?.stopLoop("horse") }
            updateAmbient(now)
            g.log.removeAll()
            collectFloaters(now: now)
            toasts.removeAll { $0.until < now }
            if let h = g.heroes.first {
                onTitle?("Heroes IV — \(scene.map.name) — movement \(Int(h.movement.rounded()))/\(Int(h.maxMovement))")
            }
        }
        if frameTimes.count >= 300 {
            let avg = frameTimes.reduce(0, +) / Double(frameTimes.count)
            print(String(format: "%.1f fps (avg frame %.2f ms)", 1 / avg, avg * 1000))
            frameTimes.removeAll()
        }
        encode(rpd: rpd, present: drawable, time: now.timeIntervalSince(start))
    }

    /// Keep the map view on the map: the playable diamond of cells (y - x within n/2, x + y
    /// within n/2 of n) is, on the canvas, the rectangle of cell centres x 16n+32...48n+32,
    /// y 8n+32...24n+32; the view stays half a tile inside it so nothing beyond the edge shows.
    func clampPan() {
        guard ui != nil else { return }
        let n = Float(scene.map.size)
        let x0 = 16 * n + 64, x1 = 48 * n, y0 = 8 * n + 48, y1 = 24 * n + 16
        let vw = Float(AdventureUI.mapViewportWidth) * uiScale / zoom, vh = viewSize.y / zoom
        pan.x = vw >= x1 - x0 ? (x0 + x1 - vw) / 2 : min(max(pan.x, x0), x1 - vw)
        pan.y = vh >= y1 - y0 ? (y0 + y1 - vh) / 2 : min(max(pan.y, y0), y1 - vh)
    }

    func encode(rpd: MTLRenderPassDescriptor, present: MTLDrawable?, time: Double) {
        if !inCombat, townOpen == nil { clampPan() }
        if let g = game, let t = g.enteredTown { townOpen = t; g.enteredTown = nil }
        if let g = game, let cs = combat, let pb = g.pendingBattle, cs.battle == nil {
            let cell = g.map.cells[g.level][pb.hero.x * g.map.size + pb.hero.y]
            cs.start(game: g, hero: pb.hero, monsterAt: pb.monster, pb.placed, terrain: cell?.type ?? 1, variant: cell?.variant ?? 0)
            g.pendingBattle = nil
        }
        if let g = game, let cs = combat, let ps = g.pendingSiege, cs.battle == nil {
            let tw = g.towns[ps.town]
            cs.startSiege(game: g, hero: ps.hero, town: ps.town, terrain: tw.terrain)
            g.pendingSiege = nil
        }
        if let g = game, let cs = combat, let pb = g.pendingHeroBattle, cs.battle == nil {
            let cell = g.map.cells[g.level][pb.enemy.x * g.map.size + pb.enemy.y]
            cs.start(game: g, hero: pb.hero, enemy: pb.enemy, terrain: cell?.type ?? 1, variant: cell?.variant ?? 0)
            g.pendingHeroBattle = nil
        }
        let now = Date()
        combat?.update(now: now)
        let inTown = townOpen != nil && town != nil
        let mapList = inTown || inCombat ? [] : quads(at: time)
        let uiList = inCombat ? combatQuads(now: now) : inTown ? townQuads() : uiQuads()
        // where this frame's buttons are (any quad drawn with a layers.button.* picture), for the click sound
        buttonRects = uiList.filter { buttonTextures.contains(ObjectIdentifier($0.texture)) }.map { ($0.x, $0.y, $0.w, $0.h) }
        // the adventure panel's own buttons are painted into its frame; their hotspots mark them
        if !inCombat, !inTown, let ui = ui {
            for n in ["Game_menu_button", "Marketplace_button", "move_army_button", "overview_button", "spell_button", "surface_button",
                      "System_menu_button", "underground_button", "end_turn"] {
                if let h = ui.hotspot(n) { buttonRects.append((h.x, h.y, h.width, h.height)) }
            }
        }
        let list = mapList + uiList
        var verts: [Vertex] = []
        verts.reserveCapacity(list.count * 6)
        for q in list {
            let x0 = Float(q.x), y0 = Float(q.y), x1 = Float(q.x + q.w), y1 = Float(q.y + q.h)
            verts += [Vertex(x: x0, y: y0, u: 0, v: 0), Vertex(x: x1, y: y0, u: 1, v: 0), Vertex(x: x0, y: y1, u: 0, v: 1),
                      Vertex(x: x1, y: y0, u: 1, v: 0), Vertex(x: x1, y: y1, u: 1, v: 1), Vertex(x: x0, y: y1, u: 0, v: 1)]
        }
        let bytes = verts.count * MemoryLayout<Vertex>.stride
        if vertexBuffer.length < bytes { vertexBuffer = device.makeBuffer(length: bytes * 2, options: .storageModeShared)! }
        verts.withUnsafeBytes { vertexBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }

        let cmd = queue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        // pass 1: the map, clipped to the viewport left of the panel
        var cam = Camera(vw: viewSize.x, vh: viewSize.y, px: pan.x, py: pan.y, zoom: zoom, pad: 0)
        enc.setVertexBytes(&cam, length: MemoryLayout<Camera>.stride, index: 1)
        let viewportW = ui == nil ? Int(viewSize.x) : min(Int(viewSize.x), Int(Float(AdventureUI.mapViewportWidth) * uiScale))
        enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: max(1, viewportW), height: Int(viewSize.y)))
        let minX = pan.x, minY = pan.y, maxX = pan.x + Float(viewportW) / zoom, maxY = pan.y + viewSize.y / zoom
        for (i, q) in mapList.enumerated() {
            if Float(q.x + q.w) < minX || Float(q.x) > maxX || Float(q.y + q.h) < minY || Float(q.y) > maxY { continue }
            enc.setFragmentTexture(q.texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: i * 6, vertexCount: 6)
        }
        // pass 2: the chrome on the 1024x768 canvas
        if !uiList.isEmpty {
            enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(viewSize.x), height: Int(viewSize.y)))
            var uiCam = Camera(vw: viewSize.x, vh: viewSize.y, px: 0, py: 0, zoom: uiScale, pad: 0)
            enc.setVertexBytes(&uiCam, length: MemoryLayout<Camera>.stride, index: 1)
            for (i, q) in uiList.enumerated() {
                enc.setFragmentTexture(q.texture, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: (mapList.count + i) * 6, vertexCount: 6)
            }
        }
        enc.endEncoding()
        if let p = present { cmd.present(p) }
        cmd.commit()
        if present == nil { cmd.waitUntilCompleted() }
    }
}
