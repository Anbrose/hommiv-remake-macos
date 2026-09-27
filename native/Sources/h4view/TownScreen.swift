import Foundation
import Metal
import H4Engine

/// The town screen on the 1024x768 canvas (t_town_window 0x8ac0c0, town_screens_spec §1): the town
/// view (layers.town.<alignment>.<terrain>, a 1280x825 picture scaled by 0.8 and bottom-aligned on
/// town_image.y1 = 568, so its top 92 px are cut off) with the built buildings of
/// layers.town.<alignment>.layout in the fixed order of table 0x996488, and the bottom bar of
/// layers.town.1024 with the town name, the dwellings, the treasury, the town list and the army rows.
final class TownScreen {
    let archive: H4Archive
    let frame: LayerFile
    var views: [String: LayerFile] = [:]     // "life.grass"
    var layouts: [String: LayerFile] = [:]   // "life"
    var lifted: [String: Bitmap] = [:]       // the hover pictures ("adjusted" 0x180 copies)
    var showBuildList = false
    var buildRows: [(rect: (Int, Int, Int, Int), building: RuleTables.BuildingDef)] = []

    /// The 1280x825 view is scaled to the canvas width (0.8): 1024x660, its bottom at 568.
    static let viewW = 1024, viewH = 660, sourceW = 1280, sourceH = 825
    static let viewDY = 568 - 660
    static let terrainNames: [UInt8: String] = [0: "grass", 1: "grass", 2: "rough", 3: "swamp", 4: "volcanic", 5: "snow", 6: "sand", 7: "dirt", 8: "subterranean"]

    init(archive: H4Archive) throws {
        self.archive = archive
        frame = try LayerFile(data: archive.payload("layers.town.1024.h4d"))
    }

    func view(_ alignment: String, _ terrain: UInt8) -> LayerFile? {
        let key = "\(alignment).\(TownScreen.terrainNames[terrain] ?? "grass")"
        if views[key] == nil, let d = try? archive.payload("layers.town.\(key).h4d") ?? archive.payload("layers.town.\(alignment).grass.h4d") { views[key] = try? LayerFile(data: d) }
        return views[key]
    }
    /// A building's animation (animation.town.<alignment>.<building>.h4d): a "base" image the
    /// size of the building's layer and frames placed on it; nil when the building has none.
    var animations: [String: Sprite?] = [:]
    func animation(_ alignment: String, _ building: String) -> Sprite? {
        let key = "\(alignment).\(building.lowercased())"
        if animations[key] == nil {
            animations[key] = .some((try? archive.payload("animation.town.\(key).h4d")).flatMap { try? Sprite(data: $0) })
        }
        return animations[key] ?? nil
    }
    func layout(_ alignment: String) -> LayerFile? {
        if layouts[alignment] == nil, let d = try? archive.payload("layers.town.\(alignment).layout.h4d") { layouts[alignment] = try? LayerFile(data: d) }
        return layouts[alignment]
    }

    /// Source (1280x825) rectangle -> canvas rectangle: scaled by 0.8, moved up by 92.
    static func place(_ l: UILayer) -> (x: Int, y: Int, w: Int, h: Int) {
        let sx = Float(viewW) / Float(sourceW), sy = Float(viewH) / Float(sourceH)
        return (Int(Float(l.x) * sx), Int(Float(l.y) * sy) + viewDY, max(1, Int(Float(l.width) * sx)), max(1, Int(Float(l.height) * sy)))
    }

    func hotspot(_ name: String) -> UILayer? { frame[name] ?? frame.layers.first { $0.name.lowercased() == name.lowercased() } }
    func hit(_ l: UILayer?, _ x: Float, _ y: Float) -> Bool {
        guard let l = l else { return false }
        return x >= Float(l.x) && x < Float(l.x + l.width) && y >= Float(l.y) && y < Float(l.y + l.height)
    }

    /// The building drawing order per alignment (table 0x996488: later entries over earlier ones).
    static let drawOrder: [String: [Int]] = [
        "life": [0, 1, 2, 11, 3, 4, 5, 7, 8, 14, 15, 16, 17, 18, 19, 10, 28, 29, 27, 20, 21, 22, 23, 24, 25, 26, 12, 13, 6, 9],
        "order": [3, 4, 5, 0, 1, 2, 11, 8, 7, 18, 19, 16, 17, 14, 15, 31, 10, 20, 21, 22, 23, 24, 25, 26, 9, 30, 12, 13, 6],
        "death": [0, 1, 2, 3, 4, 5, 7, 8, 11, 14, 15, 16, 17, 18, 19, 10, 20, 21, 22, 23, 24, 25, 26, 12, 13, 32, 33, 9, 6],
        "chaos": [11, 0, 1, 2, 3, 4, 5, 14, 15, 16, 17, 18, 19, 7, 8, 13, 35, 10, 26, 20, 21, 22, 23, 24, 25, 34, 12, 9, 6, 36],
        "nature": [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 38, 17, 16, 19, 18, 15, 14, 20, 21, 22, 23, 24, 25, 26, 39, 12, 13, 9, 37],
        "might": [11, 0, 1, 2, 3, 4, 5, 6, 7, 8, 18, 19, 16, 17, 14, 15, 40, 35, 42, 12, 13, 10, 41, 9],
    ]
    /// A built building hides the one it replaces (0xa85d08, applied transitively by 0x8a31f0).
    static let supersedes: [Int: Int] = [1: 0, 2: 1, 4: 3, 5: 4, 21: 20, 22: 21, 23: 22, 24: 23]

    /// The hover picture (0x422b80(layout, 0x180)): every colour's HSV value lifted,
    /// V' = 255 - (255 - V) x 256 / 384, hue and saturation kept (black -> 85 grey). No rim.
    static func lift(_ b: Bitmap) -> Bitmap {
        var o = b
        for i in stride(from: 0, to: o.pixels.count, by: 4) where o.pixels[i + 3] > 0 {
            let r = Int(b.pixels[i]), g = Int(b.pixels[i + 1]), bl = Int(b.pixels[i + 2])
            let v = max(r, g, bl), v2 = 255 - (255 - v) * 256 / 384
            if v == 0 { o.pixels[i] = 85; o.pixels[i + 1] = 85; o.pixels[i + 2] = 85; continue }
            o.pixels[i] = UInt8(min(255, (r * v2 + v / 2) / v)); o.pixels[i + 1] = UInt8(min(255, (g * v2 + v / 2) / v)); o.pixels[i + 2] = UInt8(min(255, (bl * v2 + v / 2) / v))
        }
        return o
    }
}

extension Renderer {
    static let townMaterials = ["Gold", "Wood", "Ore", "Crystal", "Sulfur", "Mercury", "Gems"]
    /// The town list's first row (the scrollbar's position).
    private static var townListTopStore: [ObjectIdentifier: Int] = [:]
    var townListTop: Int {
        get { Renderer.townListTopStore[ObjectIdentifier(self)] ?? 0 }
        set { Renderer.townListTopStore[ObjectIdentifier(self)] = newValue }
    }
    /// The split toggle (t_toggle_button +0x6b0): the next move splits the stack.
    private static var townSplitStore: [ObjectIdentifier: Bool] = [:]
    var townSplitOn: Bool {
        get { Renderer.townSplitStore[ObjectIdentifier(self)] ?? false }
        set { Renderer.townSplitStore[ObjectIdentifier(self)] = newValue }
    }

    // MARK: the view

    /// The shown buildings in drawing order: built, not superseded, with a layout layer (0x8af5f0).
    func townShownBuildings(_ t: GameState.Town) -> [(id: Int, layer: UILayer)] {
        guard let g = game, let ts = town, let lay = ts.layout(t.alignment) else { return [] }
        let order = TownScreen.drawOrder[t.alignment] ?? []
        let built = Set(order.filter { b in g.buildingKeyword(t.alignment, b).map { t.buildings.contains($0) } ?? false })
        var hidden = Set<Int>()
        for b in built { var x = b; while let lower = TownScreen.supersedes[x] { hidden.insert(lower); x = lower } }
        return order.compactMap { b -> (Int, UILayer)? in
            guard built.contains(b), !hidden.contains(b), let k = g.buildingKeyword(t.alignment, b) else { return nil }
            guard let l = lay.layers.first(where: { $0.name.lowercased() == k }), l.width > 0 else { return nil }
            return (b, l)
        }
    }
    /// The building button under a canvas point: the front-most (last drawn) whose picture is opaque there.
    func townBuildingAt(_ x: Float, _ y: Float) -> UILayer? {
        guard let g = game, let i = townOpen, i < g.towns.count, y < 546 else { return nil }
        for (_, l) in townShownBuildings(g.towns[i]).reversed() {
            let r = TownScreen.place(l)
            guard x >= Float(r.x), x < Float(r.x + r.w), y >= Float(r.y), y < Float(r.y + r.h) else { continue }
            let px = min(l.width - 1, Int((x - Float(r.x)) * Float(l.width) / Float(r.w))), py = min(l.height - 1, Int((y - Float(r.y)) * Float(l.height) / Float(r.h)))
            if l.bitmap.pixels[(py * l.bitmap.width + px) * 4 + 3] > 15 { return l }
        }
        return nil
    }

    func townViewQuads(_ t: GameState.Town) -> [Quad] {
        guard let ts = town, let v = ts.view(t.alignment, t.terrain) else { return [] }
        var out: [Quad] = []
        func put(_ l: UILayer, _ key: String, _ bitmap: @autoclosure () -> Bitmap) {
            let r = TownScreen.place(l)
            out.append(Quad(texture: uiTexture(key, { bitmap() }), x: r.x, y: r.y, w: r.w, h: r.h))
        }
        if let bg = v["background"] ?? v.layers.first { put(bg, "town|\(t.alignment)|\(t.terrain)|bg", bg.bitmap) }
        let shown = townShownBuildings(t)
        // every shadow first (they are sent to the back of the view), then the buildings
        if let lay = ts.layout(t.alignment) {
            for (_, b) in shown {
                if let sh = lay.layers.first(where: { $0.name.lowercased() == b.name.lowercased() + " shadow" }), sh.width > 0 { put(sh, "town|\(t.alignment)|\(sh.name)", sh.bitmap) }
            }
        }
        for (_, b) in shown {
            if townHover == b.name {
                let key = "\(t.alignment)|\(b.name)"
                if ts.lifted[key] == nil { ts.lifted[key] = TownScreen.lift(b.bitmap) }
                put(b, "townlit|\(key)", ts.lifted[key]!)
            } else {
                put(b, "town|\(t.alignment)|\(b.name)", b.bitmap)
            }
            // its animation: the frames over the building, looping (frame time = speed / 60 s)
            if let anim = ts.animation(t.alignment, b.name) {
                let frames = anim.images.filter { $0.name.hasPrefix("frame") }
                if !frames.isEmpty {
                    let period = frames[0].speed > 0 ? Double(frames[0].speed) / 60.0 : 0.125
                    let f = frames[Int(Date().timeIntervalSince1970 / period) % frames.count]
                    // frame boxes are measured from the 1x1 "animation_position" marker
                    let anchor = anim.images.first { $0.name == "animation_position" }?.box ?? (left: 0, top: 0, right: 0, bottom: 0)
                    if f.bitmap.width > 1 {
                        let l = UILayer(name: f.name, kind: 4, x: b.x + f.box.left - anchor.left, y: b.y + f.box.top - anchor.top, width: f.bitmap.width, height: f.bitmap.height, bitmap: f.bitmap)
                        let fr = TownScreen.place(l)
                        out.append(Quad(texture: texture(for: f, of: "townanim.\(t.alignment).\(b.name)"), x: fr.x, y: fr.y, w: fr.w, h: fr.h))
                    }
                }
            }
        }
        // the view file's other layers (foregrounds), in file order, over the buildings
        for f in v.layers where f.name.lowercased() != "background" && f.width > 0 { put(f, "town|\(t.alignment)|\(t.terrain)|\(f.name)", f.bitmap) }
        return out
    }

    // MARK: the bottom bar

    /// A button file (layers.button.<file>, or layers.<file>), found whatever the case of its name.
    func townButtonFile(_ file: String) -> LayerFile? { kit?.file("button.\(file)") ?? kit?.file(file) }
    /// A t_button (0x5a0010) of a button file with its window at (x, y): Highlighted under the pointer.
    func townButton(_ file: String, x: Int, y: Int, disabled: Bool = false, pressed: Bool = false) -> [Quad] {
        let f = townButtonFile(file)
        let (w, h) = townButtonSize(file)
        let over = pointerCanvas.0 >= Float(x) && pointerCanvas.0 < Float(x + w) && pointerCanvas.1 >= Float(y) && pointerCanvas.1 < Float(y + h)
        let names = disabled ? ["Disabled"] : pressed ? ["Pressed", "Released"] : over ? ["Highlighted", "Released"] : ["Released"]
        guard let l = names.lazy.compactMap({ MenuKit.find(f, $0) }).first else { return [] }
        return dImageOffset(l, "tbtn.\(file)", x: x, y: y)
    }
    func townButtonSize(_ file: String) -> (Int, Int) {
        guard let l = MenuKit.find(townButtonFile(file), "Released") else { return (0, 0) }
        return (l.x + l.width, l.y + l.height)
    }
    func townButtonHit(_ file: String, x: Int, y: Int, _ px: Float, _ py: Float) -> Bool {
        let (w, h) = townButtonSize(file)
        return px >= Float(x) && px < Float(x + w) && py >= Float(y) && py < Float(y + h)
    }
    static let townOK = (938, 716), townMoveUp = (395, 649), townMoveDown = (397, 594)
    var townSplitAt: (file: String, x: Int, y: Int) { townTwoRows ? ("split", 912, 617) : ("split_single", 924, 624) }

    /// The governor (0x416260): the town's hero with the best Nobility; none without Nobility.
    func townGovernor(_ i: Int) -> Hero? {
        guard let g = game else { return nil }
        var heroes = g.towns[i].garrisonHeroes
        if let v = g.visitingArmy(town: i) { heroes += [v] + v.companions }
        return heroes.filter { $0.skill("nobility") > 0 }.max { $0.skill("nobility") < $1.skill("nobility") }
    }
    /// The dwelling strip (0x8b7620): the built dwellings 12..19 in id order take the slots 1, 2, ...
    func townDwellings(_ i: Int) -> [(slot: Int, creature: String)] {
        guard let g = game else { return [] }
        let t = g.towns[i]
        var out: [(Int, String)] = []
        for b in 12...19 where g.isBuiltPublic(t, b) {
            if let c = g.buildingDef(t, b)?.creature, out.count < 6 { out.append((out.count, c)) }
        }
        return out
    }
    /// Weekly growth with the town's bonuses (0x898310 / 700): +50% breeding pit, +100% the grail of a might town.
    func townGrowth(_ i: Int, _ creature: String) -> Int {
        guard let g = game, let c = g.tables?.creature(creature) else { return 0 }
        let t = g.towns[i]
        var bonus = 0
        if g.isBuiltPublic(t, 40) { bonus += 50 }
        if t.alignment == "might", g.isBuiltPublic(t, 11) { bonus += 100 }
        return max(1, (c.growth * 700 * (100 + bonus) / 100 + 350) / 700)
    }
    /// The player's towns (the town list's contents).
    var townListTowns: [Int] { game.map { g in g.towns.indices.filter { g.towns[$0].owned } } ?? [] }

    /// The town list's picture of a town (layers.town.<alignment>.tiny: terrain, walls, three bars), 89x48.
    func townListPicture(_ t: GameState.Town, x: Int, y: Int) -> [Quad] {
        guard let g = game, let f = kit?.file("town.\(t.alignment).tiny") else { return [] }
        var out: [Quad] = []
        let terrain = TownScreen.terrainNames[t.terrain] ?? "grass"
        if let bg = dLayer(f, terrain) ?? dLayer(f, "grass") { out += dImageOffset(bg, "tlist.\(t.alignment)", x: x, y: y) }
        let walls = t.buildings.contains("castle") ? "Castle" : t.buildings.contains("citadel") ? "Citadel" : t.buildings.contains("fort") ? "Fort" : "Village"
        out += dImageOffset(dLayer(f, walls), "tlist.\(t.alignment)", x: x, y: y)
        let waiting = t.available.values.reduce(0, +)
        let guild = (1...5).filter { t.buildings.contains("mage guild \($0)") }.count
        let built = g.tables.map { tb in Float(t.buildings.count) / Float(max(1, tb.buildings(for: t.alignment).count)) } ?? 0
        for (slot, frac, rgb) in [("creatures", min(1, Float(waiting) / 60), (40, 200, 40)), ("magic", Float(guild) / 5, (40, 80, 220)), ("misc", built, (220, 40, 40))] as [(String, Float, (UInt8, UInt8, UInt8))] {
            guard let hs = dLayer(f, slot) else { continue }
            out.append(Quad(texture: solid(20, 20, 20), x: x + hs.x, y: y + hs.y, w: hs.width, h: hs.height))
            let w = Int(Float(hs.width) * max(0, min(1, frac)))
            if w > 0 { out.append(Quad(texture: solid(rgb.0, rgb.1, rgb.2), x: x + hs.x, y: y + hs.y, w: w, h: hs.height)) }
        }
        return out
    }

    func townScreenQuads() -> [Quad] {
        guard let ts = town, let g = game, let i = townOpen, i < g.towns.count, let ui = ui else { return [] }
        let t = g.towns[i], fr = ts.frame
        var out = townViewQuads(t)
        out += layoutImage(fr, "Background", 0, 0)
        out += layoutImage(fr, "Border", 0, 0)
        out += townButton("ok", x: Renderer.townOK.0, y: Renderer.townOK.1)
        // the town menu button (0x5a2250: its layout layers at their own boxes)
        let menuBox = ts.hotspot("Menu_Button_Released")
        let overMenu = menuBox.map { ts.hit($0, pointerCanvas.0, pointerCanvas.1) } ?? false
        out += layoutImage(fr, menu != nil ? "Menu_Button_Pressed" : overMenu ? "Menu_Button_Highlighted" : "Menu_Button_Released", 0, 0)
        if townTwoRows {
            out += townButton("move_up", x: Renderer.townMoveUp.0, y: Renderer.townMoveUp.1)
            out += townButton("move_garrison_down", x: Renderer.townMoveDown.0, y: Renderer.townMoveDown.1)
        }
        if let lord = townGovernor(i), let slot = ts.hotspot("Lord_Portrait") {
            out += dImageAt(ui.portrait(keyword: lord.keyword, alignment: lord.alignment), "lord", x: slot.x, y: slot.y)
            out += layoutImage(fr, "Lord_border", 0, 0)
        }
        // the dwellings: portraits, then the rings over them, then the insets with the counts
        let dwellings = townDwellings(i)
        for d in dwellings {
            guard let slot = ts.hotspot("dwelling_\(d.slot + 1)") else { continue }
            out += dImageAt(ui.creatureIcon(d.creature), "dwelling", x: slot.x, y: slot.y)
        }
        out += layoutImage(fr, "Creature_Portrait_Rings", 0, 0)
        let f11 = ui.font(11)
        for d in dwellings {
            guard let slot = ts.hotspot("dwelling_\(d.slot + 1)"), let inset = ui.creatureRing("inset") else { continue }
            let ix = slot.x + 1, iy = slot.y + 45
            out += dImageAt(inset, "cring", x: ix, y: iy)
            let n = Renderer.materialText(t.available[d.creature] ?? 0, font: f11, width: 29)
            out += dText(n, DRect(ix + 11, iy + 7, 29, 11), font: f11, centre: true, halo: Renderer.halo200, 0, 0)
        }
        // the treasury: each icon, then its number (font 12, centred, top, halo, fitted)
        let f12 = ui.font(12)
        for m in Renderer.townMaterials {
            out += layoutImage(fr, m, 0, 0)
            guard let r = ts.hotspot("\(m)_Number") else { continue }
            out += dText(Renderer.materialText(g.resources[m] ?? 0, font: f12, width: r.width), DRect(r), font: f12, centre: true, halo: Renderer.halo200, 0, 0)
        }
        // the town name: Prose_Antique 23, black, no halo, centred, top
        out += dText(t.name, ts.hotspot("Town_Name").map(DRect.init), font: ui.font(23), centre: true, 0, 0)
        // the town list: its scrollbar and three rows of layers.town.list
        let towns = townListTowns
        if let kit = kit { out += quads(kit.vScrollbar(24, 576, 182, first: townListTop, visible: 3, total: towns.count)) }
        if let tl = kit?.file("town.list") {
            for k in 0..<3 {
                let n = townListTop + k
                guard n < towns.count else { break }
                let tw = g.towns[towns[n]]
                let rx = 82, ry = 573 + 62 * k
                if let p = dLayer(tl, "town") { out += townListPicture(tw, x: rx + p.x, y: ry + p.y) }
                if let m = dLayer(tl, "map") {
                    let hs = ui.hotspot("mini_map")?.width ?? 200
                    let tex = uiTexture("townmap|\(tw.x),\(tw.y)|\(minimapStamp)|\(m.width)", {
                        let full = AdventureUI.minimap(game: g, size: hs)
                        let sz = Float(g.map.size)
                        let px = Int((Float(tw.y - tw.x) + sz / 2) / sz * Float(hs)), py = Int((Float(tw.x + tw.y + 6) - sz / 2) / sz * Float(hs))
                        return Renderer.crop(full, x: px - m.width / 2, y: py - m.height / 2, w: m.width, h: m.height)
                    })
                    out.append(Quad(texture: tex, x: rx + m.x, y: ry + m.y, w: m.width, h: m.height))
                }
                out += dImage(tl, "town.list", "Frame", rx, ry)
                if towns[n] == i { out += dImage(tl, "town.list", "Highlighted", rx, ry) }
                if tw.builtToday { out += dImage(tl, "town.list", "Built", rx, ry) }
            }
        }
        // the army rows: Single_Border and the single split toggle without a visiting row
        if !townTwoRows { out += layoutImage(fr, "Single_Border", 0, 0) }
        let sp = townSplitAt
        out += townButton(sp.file, x: sp.x, y: sp.y, pressed: townSplitOn)
        out += townRowQuads()
        out += townDialogQuads()
        out += shopQuads()
        out += hireQuads()
        out += marketQuads()
        out += menuQuads()
        if prompt != nil { out += messageBoxQuads() }
        out += townBalloonQuads()
        return out
    }

    // MARK: clicks

    /// A click on the town screen (canvas coordinates).
    func townScreenClick(x: Float, y: Float) {
        guard let ts = town, let g = game, let i = townOpen, i < g.towns.count else { return }
        if prompt != nil { _ = messageBoxClick(x: x, y: y); return }
        if townDialog != nil { _ = townDialogClick(x: x, y: y); return }
        if townButtonHit("ok", x: Renderer.townOK.0, y: Renderer.townOK.1, x, y) { closeTown(); return }
        if ts.hit(ts.hotspot("Menu_Button_Released"), x, y) { openTownMenu(); return }
        let sp = townSplitAt
        if townButtonHit(sp.file, x: sp.x, y: sp.y, x, y) { townSplitOn.toggle(); return }
        if townRowsClick(x: x, y: y) { return }
        // the town list: the scrollbar pages by 2 rows (188 / 70), a row switches town
        let towns = townListTowns
        if let kit = kit, let d = kit.vScrollbarHit(24, 576, 182, x, y) {
            townListTop = max(0, min(max(0, towns.count - 3), townListTop + 2 * d)); return
        }
        for k in 0..<3 where x >= 82 && x < 232 && y >= Float(573 + 62 * k) && y < Float(633 + 62 * k) {
            let n = townListTop + k
            if n < towns.count, towns[n] != i { closeTown(); townOpen = towns[n] }
            return
        }
        for d in townDwellings(i) where ts.hit(ts.hotspot("dwelling_\(d.slot + 1)"), x, y) { openRecruit(d.creature); return }
        if let top = townBuildingAt(x, y) { townBuildingClicked(top.name.lowercased()) }
    }
    /// The recruit dialog for a creature (0x8b50d0), starting at the most that can be bought.
    func openRecruit(_ c: String) {
        townDialog = .recruit(creature: c, count: recruitMost(c))
    }
    /// A building of the view was clicked: its window (0x8b4a80 and the handlers of town_spec).
    func townBuildingClicked(_ name: String) {
        guard let g = game, let i = townOpen, let tables = g.tables else { return }
        let t = g.towns[i]
        if name.hasPrefix("mage guild") { openMageGuild(); return }
        if ["fort", "citadel", "castle"].contains(name) { openCastle(); return }
        if ["village hall", "town hall", "city hall"].contains(name) { townDialog = .buildList; return }
        if name == "blacksmith" { openTownBlacksmith(); return }
        if name.contains("tavern") { openTavern(); return }
        if let b = tables.buildings(for: t.alignment).first(where: { $0.keyword == name }), let c = b.creature { openRecruit(c); return }
        townDialog = .buildList
    }
    func openCastle() {
        guard let g = game else { return }
        if castleCreatures().isEmpty { prompt = (g.tables?.strings["town.castle_no_dwellings"] ?? "You must build a creature dwelling before you can recruit creatures.", false, nil) }
        else { townDialog = .castle }
    }
    func openMageGuild() {
        guard let g = game, let i = townOpen else { return }
        if !g.isBuiltPublic(g.towns[i], 20) { prompt = (text("no_mage_guild.misc", "There is no mage guild in this town."), false, nil); return }
        townDialog = .mageGuild(page: 0)
    }
    func openTavern() {
        guard let g = game, let i = townOpen else { return }
        if let r = g.tavernRefusal(town: i) { prompt = (r, false, nil) } else { hire = g.hireOffer(town: i) }
    }
    func openTownBlacksmith() {
        guard let g = game, let i = townOpen, let hero = g.visitingArmy(town: i) ?? g.towns[i].garrisonHeroes.first else { return }
        let o = ShopOffer(key: "town|\(i)", title: text("blacksmith", "Blacksmith"), panel: g.towns[i].alignment.capitalized, items: [], potions: [], hero: hero)
        shop = ShopState(offer: o, panel: ui?.dialog("Blacksmith.\(o.panel)")); sound?.play("dialogue.marketplace")
    }
    /// The town menu (0x8b2b60): a scroll menu at the menu button's top-left with the town's actions.
    /// (Prison, transformer, seminary, university, shipyard, caravan and governor entries have no window
    /// in this build and are left out.) The menu is moved up so that it fits on the screen [G].
    func openTownMenu() {
        guard let g = game, let i = townOpen, let ts = town else { return }
        let t = g.towns[i]
        var items: [(String, () -> Void)] = []
        items.append((text("town_purchase_building.misc", "Purchase Building"), { [weak self] in self?.townDialog = .buildList }))
        items.append((text("town_hire_creature.misc", "Recruit Creatures"), { [weak self] in self?.openCastle() }))
        if g.isBuiltPublic(t, 9) { items.append((text("town_hire_hero.misc", "Hire Heroes"), { [weak self] in self?.openTavern() })) }
        if g.isBuiltPublic(t, 20) { items.append((text("town_mage_guild.misc", "Learn Spells"), { [weak self] in self?.openMageGuild() })) }
        if g.isBuiltPublic(t, 10) {
            let name = g.buildingDef(t, 10)?.name ?? "Blacksmith"
            items.append((text("town_use_blacksmith.misc", "Purchase Equipment").replacingOccurrences(of: "%blacksmith", with: name), { [weak self] in self?.openTownBlacksmith() }))
        }
        if t.owned { items.append((text("marketplace", "Marketplace"), { [weak self] in self?.market = MarketState(k: 3) })) }
        let b = ts.hotspot("Menu_Button_Released")
        var y = b?.y ?? 699
        if let kit = kit {
            let rows = kit.scrollMenuRows(items.map { $0.0 }, x: b?.x ?? 393, y: 0)
            let h = (rows.last.map { $0.rect.y + $0.rect.h } ?? 102) + 43
            y = min(y, AdventureUI.height - h)
        }
        menu = PopupMenu(items: items, x: b?.x ?? 393, y: y)
    }
    /// The town screen's hot keys: M opens the marketplace (marketplace.hot_keys).
    func townKey(_ chars: String) -> Bool {
        guard townOpen != nil, townDialog == nil, menu == nil, market == nil, hire == nil, shop == nil, prompt == nil else { return false }
        if chars.lowercased() == text("marketplace.hot_keys", "M").lowercased() { market = MarketState(k: 3); return true }
        return false
    }

    /// Snapshot hooks (H4TOWNDLG, comma separated): "rich" builds every building (not the shipyard) and fills
    /// the treasury and dwellings first; then "buildlist", "detail", "castle", "recruitcastle", "guild0",
    /// "guild1", "guildspell" or "menu" opens that window; "novisit" sends the heroes away (the single row).
    func townSnapshot(_ s: String) {
        guard let g = game, let i = townOpen else { return }
        let parts = s.split(separator: ",").map(String.init)
        if parts.contains("rich") {
            for m in Renderer.townMaterials { g.resources[m] = m == "Gold" ? 50000 : 50 }
            for (b, k) in RuleTables.buildingIds[g.towns[i].alignment] ?? [:] where b != 6 && ![15, 17, 19].contains(b) { g.towns[i].buildings.insert(k) }
            for b in 12...19 { if let c = g.buildingDef(g.towns[i], b)?.creature { g.towns[i].available[c] = 7 + b } }
        }
        for p in parts {
            switch p {
            case "buildlist": townDialog = .buildList
            case "detail": if let t = buildTiles().first(where: { $0.state == 6 }) ?? buildTiles().first { townDialog = .buildDetail(t.def) }
            case "castle": townDialog = .castle
            case "recruitcastle": if let c = castleCreatures().last { townDialog = .recruit(creature: c, count: recruitMost(c), fromCastle: true) }
            case "guild0": townDialog = .mageGuild(page: 0)
            case "guild1": townDialog = .mageGuild(page: 1)
            case "guildspell": if let c = guildCells().first { townDialog = .guildSpell(spell: c.spell, heroTop: 0) }
            case "menu": openTownMenu(); menu?.opened = .distantPast
            case "novisit": g.townVisitor = nil; for h in g.heroes { h.x = 0; h.y = 0 }
            default: break
            }
        }
    }
}
