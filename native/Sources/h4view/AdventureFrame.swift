import Foundation
import H4Engine

/// The adventure frame (t_adventure_frame, adventure_frame_spec.md) as heroes4.exe's builder 0x4acbb0
/// makes it at 1024x768: the eight frame pieces in their order, the minimap with its black-and-white
/// view rectangle, the kingdom's resources (icon, then the amount in font 14 or 16, black with the
/// light halo, centred and top-aligned), the day scroll, the hero list (pitch 77), the selected
/// army's rings (style 3: a column-major zig-zag ending in the full-height Right piece) and the town
/// list (pitch 72: the town picture, the micro-map, the small_list Frame over them).
extension Renderer {
    /// The frame pieces, in creation order (IGNORE and DONTUSE are never drawn by the exe).
    static let framePieces = ["Top", "Top_Border", "Left", "Left_Border", "Right", "Right_Border", "Bottom", "Bottom_Border"]
    /// t_material_display: resources in table order with the font the field's height picks.
    static let materialFields: [(name: String, font: Int)] = [("Gold", 16), ("Wood", 14), ("Ore", 14), ("Crystal", 16), ("Sulfur", 14), ("Mercury", 16), ("Gems", 14)]
    /// The selected army's ring slots (style 3): each piece and its window origin (piece top-left minus its box).
    static let armyRingPieces: [(piece: String, x: Int, y: Int)] = [
        ("Top_Left", 736, 574), ("Bottom_Left", 736, 638), ("Top", 795, 574), ("Bottom", 795, 638),
        ("Top", 854, 574), ("Bottom_Right", 853, 638), ("Right", 923, 574)]

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
            let n = Float(scene.map.size)
            let mapW = n * 32, mapH = n * 16
            let originX: Float = n * 16 + 32, originY: Float = n * 8 + 32
            let vx0 = (pan.x - originX) / mapW, vy0 = (pan.y - originY) / mapH
            let vx1 = vx0 + Float(AdventureUI.mapViewportWidth) * uiScale / zoom / mapW, vy1 = vy0 + viewSize.y / zoom / mapH
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
        // the hero list: rows at (747, 344 + 77k), the portrait, the move bar filling from the bottom, the mana bar, the frame
        _ = ui.heroRing()
        if let rings = ui.armyRings, let list = ui.hotspot("Hero_List") {
            for (k, h) in g.heroes.prefix(AdventureUI.heroSlots.count).enumerated() {
                let rx = list.x, ry = list.y + 77 * k
                if let p = rings["portrait"], let pic = ui.portrait(keyword: h.keyword, alignment: h.alignment) {
                    out.append(Quad(texture: uiTexture("portrait|\(h.alignment)|\(h.keyword)", { pic.bitmap }), x: rx + p.x, y: ry + p.y, w: pic.width, h: pic.height))
                }
                if let bar = rings["Move_Bar"], h.maxMovement > 0 {
                    let filled = Int(Float(bar.height) * max(0, min(1, h.movement / h.maxMovement)))
                    if filled > 0 {
                        let tex = uiTexture("ring|move|\(filled)", { Renderer.crop(bar.bitmap, x: 0, y: bar.height - filled, w: bar.width, h: filled) })
                        out.append(Quad(texture: tex, x: rx + bar.x, y: ry + bar.y + bar.height - filled, w: bar.width, h: filled))
                    }
                }
                if let bar = rings["Mana_Bar"] {
                    let top = max(1, g.maxSpellPoints(h))
                    let filled = Int(Float(bar.height) * max(0, min(1, Float(g.spellPoints(h)) / Float(top))))
                    if filled > 0 { out.append(Quad(texture: solid(40, 80, 232), x: rx + bar.x + 3, y: ry + bar.y + bar.height - filled, w: bar.width - 6, h: filled)) }
                }
                if let f = rings[k == 0 ? "Army_Frame_Highlight" : "Army_Frame"] ?? rings["Army_Frame"] {
                    out.append(Quad(texture: uiTexture("armyring|\(f.name)", { f.bitmap }), x: rx + f.x, y: ry + f.y, w: f.width, h: f.height))
                }
            }
        }
        // the selected army's rings (the first hero's army)
        if let h = g.heroes.first {
            let heroes = [h] + h.companions
            var items: [(UILayer?, String?)] = heroes.map { (ui.portrait(keyword: $0.keyword, alignment: $0.alignment), String?.none) }
            items += h.army.map { (ui.creatureIcon($0.creature), String($0.count)) }
            for (k, s) in Renderer.armyRingPieces.enumerated() {
                let cx = s.x + 41, cy = s.y + 41
                if k < items.count, let icon = items[k].0 {
                    out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height))
                }
                if let p = ui.creatureRing(s.piece) {
                    out.append(Quad(texture: uiTexture("cring|\(p.name)", { p.bitmap }), x: s.x + p.x, y: s.y + p.y, w: p.width, h: p.height))
                }
                if k < items.count { ringLabel(&out, ui: ui, cx: cx, cy: cy, count: items[k].1, hero: k < heroes.count) }
            }
        }
        // the town list: rows at (837, 354 + 72k)
        if let list = ui.hotspot("Town_list"), let sl = ui.smallList() {
            for (i, t) in g.towns.filter({ $0.owned }).prefix(3).enumerated() {
                let rx = list.x, ry = list.y + 72 * i
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
                if let f = sl["Frame"] { out.append(Quad(texture: uiTexture("smalllist|Frame", { f.bitmap }), x: rx + f.x, y: ry + f.y, w: f.width, h: f.height)) }
            }
        }
        return out
    }
}
