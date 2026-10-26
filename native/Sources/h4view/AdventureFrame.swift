import Foundation
import AppKit
import H4Engine

/// The adventure frame (t_adventure_frame, adventure_frame_spec.md) as heroes4.exe's builder 0x4acbb0
/// makes it at 1024x768: the eight frame pieces in their order, the minimap with its black-and-white
/// view rectangle, the kingdom's resources (icon, then the amount in font 14 or 16, black with the
/// light halo, centred and top-aligned), the day scroll, the hero list (pitch 77), the selected
/// army's rings (style 3: a column-major zig-zag ending in the full-height Right piece) and the town
/// list (pitch 72: the town picture, the micro-map, the small_list Frame over them).
extension Renderer {
    /// 0x5400d0: rows are made while the next one fits, at a pitch of Army_Frame's height - 4.
    static func heroListRows(listHeight: Int, frameHeight: Int) -> Int {
        let pitch = max(1, frameHeight - 4)
        var n = 0
        while (n + 1) * pitch <= listHeight { n += 1 }
        return n
    }
    /// 0x5420f7: the move bar shows movement points (100 a cell) out of a fixed 1500.
    static func moveBarFill(movement: Float, height: Int) -> Int {
        let points = Int((movement * 100).rounded())
        return min(height, height * max(0, points) / 1500)
    }
    /// 0x542250: the right bar is the army's strength (0x6411d0) on a log scale from 100 to 18000.
    static func strengthBarFill(value: Int, height: Int) -> Int {
        guard value > 0 else { return 0 }
        let num = Int((log(Double(value)) - log(100.0)) * 1000)
        let den = Int((log(18000.0) - log(100.0)) * 1000)
        return min(height, height * num / den)
    }

    /// The frame pieces, in creation order (IGNORE and DONTUSE are never drawn by the exe).
    static let framePieces = ["Top", "Top_Border", "Left", "Left_Border", "Right", "Right_Border", "Bottom", "Bottom_Border"]
    /// t_material_display: resources in table order with the font the field's height picks.
    static let materialFields: [(name: String, font: Int)] = [("Gold", 16), ("Wood", 14), ("Ore", 14), ("Crystal", 16), ("Sulfur", 14), ("Mercury", 16), ("Gems", 14)]
    /// The selected army's ring slots (style 3, table 0x984b50 + 3*56: (row, col) into
    /// top_left..bottom_right): each piece and its ring box (piece top-left minus its offset).
    /// 0x6439c0 lays the pieces out from the `army` hotspot (736,575): a top piece moves the pen
    /// down by its height (72), any other right by the previous slot's width and up by 72, so the
    /// pieces' pixels touch: Top_Left 736 (70 wide), Top 806 (59), Top 865 (59), Right 924.
    static let armyRingPieces: [(piece: String, x: Int, y: Int)] = [
        ("Top_Left", 736, 574), ("Bottom_Left", 736, 638), ("Top", 795, 574), ("Bottom", 795, 638),
        ("Top", 854, 574), ("Bottom_Right", 853, 638), ("Right", 912, 574)]

    /// A frame layer by name, whatever its case ("LEft").
    func frameLayer(_ ui: AdventureUI, _ name: String) -> UILayer? {
        ui.frame[name] ?? ui.frame.layers.first { $0.name.lowercased() == name.lowercased() }
    }

    /// 0x401660: the amount with thousands separators if it fits (or is under 1000), else 12.3k / 123k, then M, G.
    static func materialText(_ v: Int, font: H4Font, width: Int) -> String {
        let sign = v < 0 ? "-" : "", a = abs(v)
        let full = sign + grouped(a)
        if a < 1000 || font.measure(full) <= width { return full }
        for (div, suffix) in [(1_000, "k"), (1_000_000, "M"), (1_000_000_000, "G")] {
            let q = Double(a) / Double(div)
            let one = sign + String(format: "%.1f", (q * 10).rounded(.down) / 10) + suffix
            if q < 100, font.measure(one) <= width { return one }
            let whole = sign + String(Int(q)) + suffix
            if font.measure(whole) <= width || suffix == "G" { return whole }
        }
        return full
    }

    /// A copy of part of a bitmap.
    static func crop(_ b: Bitmap, x: Int, y: Int, w: Int, h: Int) -> Bitmap {
        var o = Bitmap(width: w, height: h)
        for yy in 0..<h where y + yy >= 0 && y + yy < b.height {
            for xx in 0..<w where x + xx >= 0 && x + xx < b.width {
                for k in 0..<4 { o.pixels[(yy * w + xx) * 4 + k] = b.pixels[((y + yy) * b.width + x + xx) * 4 + k] }
            }
        }
        return o
    }

    func adventureFrameQuads(_ ui: AdventureUI, _ g: GameState) -> [Quad] {
        var out: [Quad] = []
        for name in Renderer.framePieces {
            guard let l = frameLayer(ui, name) else { continue }
            out.append(Quad(texture: uiTexture("frame|\(l.name)", { l.bitmap }), x: l.x, y: l.y, w: l.width, h: l.height))
        }
        // the minimap and its view rectangle: black 1-px frame outside, white 1-px frame on it (0x7a0470)
        if let mm = ui.hotspot("mini_map") {
            let enemies: Int = g.enemyHeroes.reduce(0) { $0 + $1.x * 13 + $1.y * 3 }
            let own: Int = g.heroes.reduce(0) { $0 + $1.x * 7 + $1.y }
            let places: Int = g.towns.filter { $0.owned }.count * 31 + g.mines.filter { $0.owned }.count * 17
            let stamp = g.level * 7_000_001 + g.day * 1000 + enemies + own + places
            if minimapTexture == nil || minimapStamp != stamp { minimapTexture = makeTexture(AdventureUI.minimap(game: g, size: mm.width)); minimapStamp = stamp }
            out.append(Quad(texture: minimapTexture!, x: mm.x, y: mm.y, w: mm.width, h: mm.height))
            // the map window over the playable rectangle [0, 32n] x [0, 16n] of the exe's map pixels
            let n = Float(scene.map.size), w = mapWindow
            let mapW = n * 32, mapH = n * 16
            let v0 = pan + w.min / zoom - scene.exeOrigin, v1 = pan + w.max / zoom - scene.exeOrigin
            let vx0 = v0.x / mapW, vy0 = v0.y / mapH, vx1 = v1.x / mapW, vy1 = v1.y / mapH
            let rx0 = mm.x + Int(max(0, min(1, vx0)) * Float(mm.width)), rx1 = mm.x + Int(max(0, min(1, vx1)) * Float(mm.width))
            let ry0 = mm.y + Int(max(0, min(1, vy0)) * Float(mm.height)), ry1 = mm.y + Int(max(0, min(1, vy1)) * Float(mm.height))
            if rx1 > rx0, ry1 > ry0 {
                for (tex, x0, y0, x1, y1) in [(black, rx0 - 1, ry0 - 1, rx1 + 1, ry1 + 1), (white, rx0, ry0, rx1, ry1)] {
                    out.append(Quad(texture: tex, x: x0, y: y0, w: x1 - x0, h: 1)); out.append(Quad(texture: tex, x: x0, y: y1 - 1, w: x1 - x0, h: 1))
                    out.append(Quad(texture: tex, x: x0, y: y0, w: 1, h: y1 - y0)); out.append(Quad(texture: tex, x: x1 - 1, y: y0, w: 1, h: y1 - y0))
                }
            }
        }
        // the kingdom's resources: icon, then the amount
        for (name, size) in Renderer.materialFields {
            if let icon = frameLayer(ui, name) { out.append(Quad(texture: uiTexture("frame|\(icon.name)", { icon.bitmap }), x: icon.x, y: icon.y, w: icon.width, h: icon.height)) }
            guard let field = frameLayer(ui, "\(name)_Number") else { continue }
            let f = ui.font(size)
            let text = Renderer.materialText(g.resources[name] ?? 0, font: f, width: field.width)
            let w = f.measure(text)
            out.append(Quad(texture: uiTexture("mat\(size)|\(text)", { f.render(text, colour: (0, 0, 0), halo: Renderer.armyHalo) }), x: field.x + (field.width - w) / 2, y: field.y, w: w, h: f.size))
        }
        // the day scroll: Background, the date (14, black with the halo, centred, top), the roll end last
        if let slot = ui.hotspot("day_scroll") {
            if let bg = ui.dayScroll["Background"] { out.append(Quad(texture: uiTexture("scroll|bg", { bg.bitmap }), x: slot.x + bg.x, y: slot.y + bg.y, w: bg.width, h: bg.height)) }
            if let field = ui.dayScroll["text"] {
                let f = ui.font(14)
                let text = (g.tables?.strings["date.adventure_frame"] ?? "Day %day of Week %week\nMonth %month")
                    .replacingOccurrences(of: "%day", with: "\(g.dayOfWeek)").replacingOccurrences(of: "%week", with: "\(g.week)").replacingOccurrences(of: "%month", with: "\(g.month)")
                for (i, line) in text.components(separatedBy: "\n").enumerated() where !line.isEmpty {
                    let w = f.measure(line)
                    out.append(Quad(texture: uiTexture("atext|14|\(line)", { f.render(line, colour: (0, 0, 0), halo: Renderer.armyHalo) }), x: slot.x + field.x + (field.width - w) / 2, y: slot.y + field.y + i * f.lineHeight, w: w, h: f.size))
                }
            }
            if let rt = ui.dayScroll["Right"] { out.append(Quad(texture: uiTexture("scroll|right", { rt.bitmap }), x: slot.x + rt.x, y: slot.y + rt.y, w: rt.width, h: rt.height)) }
        }
        // the hero list (0x5400d0, adventure_hero_list_spec.md): 3 rows at (747, 344 + 77k), each
        // [Empty_Background when no portrait] portrait, move bar, strength bar, Army_Frame or the highlight
        _ = ui.heroRing()
        if let rings = ui.armyRings, let list = ui.hotspot("Hero_List") {
            // (the list keeps its order; the selected army is heroes[0]; an army without a hero shows its strongest creature)
            let armies = g.armyList
            let rows = Renderer.heroListRows(listHeight: list.height, frameHeight: rings["Army_Frame"]?.height ?? 81)
            let selected = g.heroes.first.flatMap { s in armies.firstIndex { $0 === s } }
            func draw(_ l: UILayer?, _ rx: Int, _ ry: Int) {
                guard let l = l else { return }
                out.append(Quad(texture: uiTexture("armyring|\(l.name)", { l.bitmap }), x: rx + l.x, y: ry + l.y, w: l.width, h: l.height))
            }
            /// A bar emptying from the top: its bottom `filled` rows stay in place.
            func bar(_ b: UILayer?, _ filled: Int, _ rx: Int, _ ry: Int) {
                guard let b = b else { return }
                let f = min(filled, b.height)
                guard f > 0 else { return }
                let tex = uiTexture("ring|\(b.name)|\(f)", { Renderer.crop(b.bitmap, x: 0, y: b.height - f, w: b.width, h: f) })
                out.append(Quad(texture: tex, x: rx + b.x, y: ry + b.y + b.height - f, w: b.width, h: f))
            }
            for k in 0..<rows {
                let rx = list.x, ry = list.y + (rings["Army_Frame"].map { $0.height - 4 } ?? 77) * k
                if k < armies.count {
                    let h = armies[k]
                    if let p = rings["portrait"], let pic = armyPortrait(h) {
                        out.append(Quad(texture: uiTexture("icon|\(pic.name)", { pic.bitmap }), x: rx + p.x, y: ry + p.y, w: pic.width, h: pic.height))
                    } else { draw(rings["Empty_Background"], rx, ry) }
                    if let b = rings["Move_Bar"] { bar(b, Renderer.moveBarFill(movement: h.movement, height: b.height), rx, ry) }
                    if let b = rings["Mana_Bar"] { bar(b, Renderer.strengthBarFill(value: g.armyValue(h), height: b.height), rx, ry) }
                } else {
                    draw(rings["Empty_Background"], rx, ry)
                }
                draw(k == selected ? rings["Army_Frame_Highlight"] ?? rings["Army_Frame"] : rings["Army_Frame"], rx, ry)
            }
        }
        // the selected army's rings (the first hero's army)
        if let h = g.heroes.first {
            // each place where the army keeps it (t_creature_array slots); a lifted stack leaves its place
            let row = g.armySlots(h), lifting = panelDrag?.at != nil ? panelDrag : nil
            let items: [(icon: UILayer?, count: String?, hero: Bool)] = row.enumerated().map { k, slot in
                guard let s = slot else { return (nil, nil, false) }
                if let l = lifting, l.k == k, !(l.split && (s.stack?.count ?? 0) > 1) { return (nil, nil, false) }
                let (icon, count) = slotIcon(s, ui: ui)
                return (icon, count, s.hero != nil)
            }
            out += ringRowQuads(Renderer.armyRingPieces.map { ($0.piece, $0.x, $0.y) }, items: items, selected: nil)
            if let l = lifting, let at = l.at, let s = row[safe: l.k] ?? nil {
                // the drop target's drag_border (slot vfuncs 0x643460 / 0x6433f0), then the carried picture
                if let t = panelRing(at: at.0, at.1), t != l.k, let b = ui.creatureRing("drag_border") {
                    let o = Renderer.armyRingPieces[t]
                    out.append(Quad(texture: uiTexture("cring|\(b.name)", { b.bitmap }), x: o.x + b.x, y: o.y + b.y, w: b.width, h: b.height))
                }
                let (icon, count) = slotIcon(s, ui: ui)
                if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: Int(at.0) - icon.width / 2, y: Int(at.1) - icon.height / 2, w: icon.width, h: icon.height)) }
                ringLabel(&out, ui: ui, cx: Int(at.0), cy: Int(at.1), count: l.split ? nil : count, hero: s.hero != nil)
            }
        }
        // the town list (0x8a3970): rows at (837, 354 + 72k); an empty row keeps its Frame
        if let list = ui.hotspot("Town_list"), let sl = ui.smallList() {
            let owned = g.towns.filter { $0.owned }
            for i in 0..<3 {
                let rx = list.x, ry = list.y + 72 * i
                defer { if let f = sl["Frame"] { out.append(Quad(texture: uiTexture("smalllist|Frame", { f.bitmap }), x: rx + f.x, y: ry + f.y, w: f.width, h: f.height)) } }
                guard i < owned.count else { continue }
                let t = owned[i]
                if let town = sl["town"], let pic = ui.townPicture(t.alignment) {   // the picture button, 68x48 of the 73-px card
                    let tw = town.width, th = town.height
                    let terrain = TownScreen.terrainNames[t.terrain] ?? "grass"
                    if let bg = pic.layers.first(where: { $0.name.lowercased() == terrain }) ?? pic["grass"] {
                        out.append(Quad(texture: uiTexture("tpic|\(t.alignment)|\(bg.name)", { Renderer.crop(bg.bitmap, x: 0, y: 0, w: min(tw - bg.x, bg.width), h: min(th - bg.y, bg.height)) }), x: rx + town.x + bg.x, y: ry + town.y + bg.y, w: min(tw - bg.x, bg.width), h: min(th - bg.y, bg.height)))
                    }
                    let walls = t.buildings.contains("castle") ? "Castle" : t.buildings.contains("citadel") ? "Citadel" : t.buildings.contains("fort") ? "Fort" : "VillageHall"
                    if let w = pic[walls] { out.append(Quad(texture: uiTexture("tpic|\(t.alignment)|\(walls)", { w.bitmap }), x: rx + town.x + w.x, y: ry + town.y + w.y, w: w.width, h: w.height)) }
                    // bars: creatures waiting to be recruited, mage guild level, buildings built
                    let waiting = t.available.values.reduce(0, +)
                    let guild = (1...5).filter { t.buildings.contains("mage guild \($0)") }.count
                    let built = g.tables.map { tb in Float(t.buildings.count) / Float(max(1, tb.buildings(for: t.alignment).count)) } ?? 0
                    for (slot, frac, rgb) in [("creatures", min(1, Float(waiting) / 60), (40, 200, 40)), ("magic", Float(guild) / 5, (40, 80, 220)), ("misc", built, (220, 40, 40))] as [(String, Float, (UInt8, UInt8, UInt8))] {
                        guard let hs = pic[slot] else { continue }
                        let bw = min(hs.width, tw - hs.x)
                        out.append(Quad(texture: solid(20, 20, 20), x: rx + town.x + hs.x, y: ry + town.y + hs.y, w: bw, h: hs.height))
                        let w = Int(Float(bw) * max(0, min(1, frac)))
                        if w > 0 { out.append(Quad(texture: solid(rgb.0, rgb.1, rgb.2), x: rx + town.x + hs.x, y: ry + town.y + hs.y, w: w, h: hs.height)) }
                    }
                }
                // the micro-map: the map around the town
                if let m = sl["map"], let hs = ui.hotspot("mini_map") {
                    let tex = uiTexture("townmap|\(t.x),\(t.y)|\(minimapStamp)", {
                        let full = AdventureUI.minimap(game: g, size: hs.width)
                        let n = Float(g.map.size)
                        let px = Int((Float(t.y - t.x) + n / 2) / n * Float(hs.width)), py = Int((Float(t.x + t.y + 6) - n / 2) / n * Float(hs.width))
                        return Renderer.crop(full, x: px - m.width / 2, y: py - m.height / 2, w: m.width, h: m.height)
                    })
                    out.append(Quad(texture: tex, x: rx + m.x, y: ry + m.y, w: m.width, h: m.height))
                }
            }
        }
        return out
    }
}

/// A stack lifted out of the adventure panel's rings (t_drag_creature, 0x6434d0): its place, the
/// pointer once it moved, and whether it is a split drag (Shift: the source keeps its creatures).
var panelDrag: (k: Int, at: (Float, Float)?, split: Bool)?

/// The adventure panel's rings act as the exe's t_creature_array_window built with drag enabled
/// (0x4ae5bb: style 3, +0xc4 = +0xcc = 1): a drop moves, merges or swaps inside the army
/// (0x646d40), Shift splits through the split dialog (0x6467f0), a double click opens the army
/// screen on the slot (0x4af170).
extension Renderer {
    /// The panel slot under a canvas point: the slot window has its piece's rectangle (0x597e50
    /// with the image's rect); the later slot lies on top.
    func panelRing(at x: Float, _ y: Float) -> Int? {
        guard let ui = ui else { return nil }
        for (k, s) in Renderer.armyRingPieces.enumerated().reversed() {
            guard let p = ui.creatureRing(s.piece) else { continue }
            let px = Float(s.x + p.x), py = Float(s.y + p.y)
            if x >= px, x < px + Float(p.width), y >= py, y < py + Float(p.height) { return k }
        }
        return nil
    }
    /// The adventure screen with nothing open over it: its panel takes the mouse.
    var panelIdle: Bool {
        guard let g = game, ui != nil, !inCombat, !computerTurnBusy, endGame == nil, townOpen == nil, armySession == nil, caravanUI == nil,
              splitDialog == nil, puzzle == nil, !thievesGuildOpen, shop == nil, sanctuary == nil, hire == nil, mapRecruit == nil, optionsOpen == nil,
              spellBook == nil, menu == nil, !Renderer.scenarioInfoOpen, saveDialog == nil, prompt == nil, g.scripts.messages.isEmpty, g.choice == nil,
              g.heroPick == nil, g.skillDialog == nil, g.teleportChoice == nil, g.levelUp == nil, market == nil, overview == nil, armyPopup == nil,
              popup == nil, adventureDialog == nil, creatureDialog == nil else { return false }
        return true
    }
    /// A press on an occupied ring of the selected army: the stack may be dragged.
    func panelPress(x: Float, y: Float, shift: Bool) {
        panelDrag = nil
        guard panelIdle, let g = game, let h = g.heroes.first, let k = panelRing(at: x, y), (g.armySlots(h)[safe: k] ?? nil) != nil else { return }
        panelDrag = (k, nil, shift)
    }
    /// The pointer moved with a stack held.
    func panelDragged(x: Float, y: Float, shift: Bool) -> Bool {
        guard var d = panelDrag else { return false }
        if d.at == nil { d.split = d.split || shift; NSCursor.hide() }
        d.at = (x, y); panelDrag = d
        return true
    }
    /// The button came up: a drop when the stack was carried. True when it was a drag.
    func panelRelease(x: Float, y: Float, shift: Bool) -> Bool {
        guard let d = panelDrag else { return false }
        panelDrag = nil
        guard d.at != nil else { return false }
        NSCursor.unhide()
        if let to = panelRing(at: x, y) { panelDrop(from: d.k, to: to, split: d.split || shift) }
        return true
    }
    /// 0x646d40 inside one army: a split drop onto an empty place or the same creature opens the
    /// split dialog; otherwise an empty place takes the stack, the same creature merges, anything
    /// else (a hero included) swaps. One army: no movement cost, nothing can leave it.
    func panelDrop(from: Int, to: Int, split: Bool) {
        guard from != to, let g = game, let h = g.heroes.first else { return }
        let row = g.armySlots(h)
        guard let src = row[safe: from] ?? nil, to < row.count else { return }
        let dst = row[to]
        if split, let a = src.stack, dst == nil || dst?.stack?.creature == a.creature, a.count > 1 || dst != nil {
            let have = dst?.stack?.count ?? 0
            let o = Renderer.armyRingPieces[to]
            openSplit(creature: a.creature, source: a.count, destination: have, at: (o.x + 41, o.y + 41)) { [weak self] n in
                let delta = n - have
                if delta > 0 { self?.panelMove(from, to, count: delta) } else if delta < 0 { self?.panelMove(to, from, count: -delta) }
            }
            return
        }
        panelMove(from, to, count: nil)
    }
    func panelMove(_ from: Int, _ to: Int, count: Int?) {
        guard let g = game, let h = g.heroes.first else { return }
        let x = g.singleRow(h)
        guard x.move(from: (0, from), to: (0, to), split: count) == nil else { return }
        g.setArmy(h, x.rows[0])
    }
}
