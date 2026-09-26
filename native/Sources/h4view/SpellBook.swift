import Foundation
import H4Engine

/// The spell book (t_spellbook_window 0x868980, layers.dialog.spell_book; spell_effects_spec §5):
/// 13 exclusive tabs -- Damage, Curse, Blessings, Summoning along the top (flag columns), Combat and
/// Adventure along the bottom, All, Items and the five schools down the right -- each shown only
/// when it has spells; the tab's banner (icons.spells.type) on the left page; twelve spells a
/// spread, level then name, each in its school's frame (icons.spellbook_frames) with its name,
/// "Cost N" at the caster's real cost (unaffordable: disabled, the cost in the other colour) and an
/// Information button opening the two-spell detail view (180 px icon, help and flavour, cast).
struct SpellBookState {
    var spells: [Int]            // the book's spells
    var castable: Set<Int>
    var points: Int
    var tab: String              // Damage, Curse, Blessings, Summoning, Combat, Adventure, All, Items, Life ...
    var page = 0
    var costs: [Int: Int] = [:]
    var items: Set<Int> = []     // spells the worn items give
    var detail: Int? = nil       // the detail view: the first of the two spells shown
    init(spells: [Int], castable: Set<Int>, points: Int, combat: Bool, costs: [Int: Int] = [:], items: Set<Int> = []) {
        self.spells = spells; self.castable = castable; self.points = points; self.costs = costs; self.items = items
        tab = combat ? "Combat" : "Adventure"
    }
}

extension Renderer {
    static let bookTabs = ["Damage", "Curse", "Blessings", "Summoning", "Combat", "Adventure", "All", "Items", "Life", "Death", "Order", "Chaos", "Nature"]
    var bookOrigin: (Int, Int) { ((AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2) }

    func bookSpells(_ sb: SpellBookState, tab: String? = nil) -> [Int] {
        let t = tab ?? sb.tab
        return sb.spells.filter { sp in
            let s = RuleTables.spells[sp]
            switch t {
            case "Damage": return s.has("Dmg")
            case "Curse": return s.has("Curse")
            case "Blessings": return s.has("Bless")
            case "Summoning": return s.has("Summ")
            case "Combat": return s.has("Cmb")
            case "Adventure": return s.has("Adv")
            case "Items": return sb.items.contains(sp)
            case "All": return true
            default: return s.school == t.lowercased()
            }
        }.sorted { a, b in
            let x = RuleTables.spells[a], y = RuleTables.spells[b]
            return x.level != y.level ? x.level < y.level : x.name < y.name
        }
    }
    /// A tab's layer, whatever the case of its state suffix.
    func bookLayer(_ d: LayerFile, _ name: String) -> UILayer? { d[name] ?? d.layers.first { $0.name.lowercased() == name.lowercased() } }
    /// The twelve icon places of a spread (canvas coordinates of each 52x52 icon).
    func bookSlots(_ d: LayerFile, _ ox: Int, _ oy: Int) -> [(Int, Int)] {
        guard let a = d["spell_1_row_1"], let b2 = d["spell_2_row_1"] else { return [] }
        let dx = b2.x - a.x
        let lefts = [a.y, d["row_2"]?.y ?? a.y + 130, d["row_3"]?.y ?? a.y + 262]
        let right = d["row_4"]?.x ?? 407
        var out: [(Int, Int)] = []
        for (px, rows) in [(a.x, lefts), (right, [d["row_4"]?.y ?? 142, d["row_5"]?.y ?? 272, d["row_6"]?.y ?? 404])] {
            for y in rows { out.append((ox + px, oy + y)); out.append((ox + px + dx, oy + y)) }
        }
        return out
    }
    func bookCost(_ sb: SpellBookState, _ sp: Int) -> Int { sb.costs[sp] ?? RuleTables.spells[sp].cost }
    func spellIcon180(_ s: SpellDef) -> UILayer? {
        iconSheet("spells.\(s.school).180")[s.name.lowercased()] ?? iconSheet("spells.\(s.school).180")[s.keyword.lowercased()]
    }

    func spellBookQuads() -> [Quad] {
        guard let sb = spellBook, let ui = ui, let d = ui.dialog("spell_book") else { return [] }
        let (ox, oy) = bookOrigin
        var out: [Quad] = []
        func place(_ l: UILayer, dx: Int = 0, dy: Int = 0, key: String) {
            out.append(Quad(texture: uiTexture("dlg|book|\(key)", { l.bitmap }), x: ox + l.x + dx, y: oy + l.y + dy, w: l.width, h: l.height))
        }
        func img(_ n: String) { if let l = bookLayer(d, n) { place(l, key: l.name) } }
        for n in ["Background", "Left", "Right", "Top", "Bottom"] { img(n) }
        // the tabs that have spells; the chosen one pressed
        for t in Renderer.bookTabs where !bookSpells(sb, tab: t).isEmpty {
            img("\(t)_\(sb.tab == t ? "Pressed" : "Released")")
        }
        img("Done_Released"); img("Points_Frame")
        let ink: (UInt8, UInt8, UInt8) = (12, 8, 4), faint: (UInt8, UInt8, UInt8) = (150, 60, 40)
        if let pf = d["points"] { out += centred("\(sb.points)", in: pf, at: ox, oy, font: ui.font(16), colour: (255, 236, 160)) }
        let list = bookSpells(sb)
        if let first = sb.detail {
            // the detail view: two spells, one a page
            for (k, sp) in list.dropFirst(first).prefix(2).enumerated() {
                let s = RuleTables.spells[sp], dx = k == 0 ? 0 : 335
                let affordable = bookCost(sb, sp) <= sb.points && sb.castable.contains(sp)
                out += centred(s.name, in: d[k == 0 ? "spell_name" : "spell_name_2"], at: ox, oy, font: ui.font(24), colour: ink)
                if let box = d["icon_silhouette"], let ic = spellIcon180(s) {
                    out.append(Quad(texture: uiTexture("spell180|\(ic.name)", { ic.bitmap }), x: ox + box.x + dx + (box.width - ic.width) / 2, y: oy + box.y + (box.height - ic.height) / 2 - 56, w: ic.width, h: ic.height))
                }
                let body = (game?.tables?.spellHelp[s.keyword] ?? "") + ((game?.tables?.spellFlavor[s.keyword]).map { "\n\n" + $0 } ?? "")
                if let box = d["description_text"] {
                    let b = UILayer(name: "", kind: 1, x: box.x + dx, y: box.y + 170, width: box.width, height: box.height - 170, bitmap: Bitmap(width: 1, height: 1))
                    out += paragraph(body, in: b, at: ox, oy, font: ui.font(14), colour: ink)
                    out += centred("\(text("cost.mage_guild", "Cost")) \(bookCost(sb, sp))", in: UILayer(name: "", kind: 1, x: box.x + dx, y: box.y + 142, width: box.width, height: 20, bitmap: Bitmap(width: 1, height: 1)), at: ox, oy, font: ui.font(16), colour: affordable ? ink : faint)
                }
                if affordable, let c = d["cast_spell_detail"], let b = ui.button("combat.cast_spell") ?? ui.button("spellbook.cast_spell") {
                    out.append(Quad(texture: uiTexture("button|cast", { b.bitmap }), x: ox + c.x + dx + (c.width - b.width) / 2, y: oy + c.y + (c.height - b.height) / 2, w: b.width, h: b.height))
                }
            }
            if first > 0 { img("Back_Released") }
            if first + 2 < list.count { img("Forward_Released") }
            if let ib = d["index_button"], let b = ui.button("spellbook.index") {
                out.append(Quad(texture: uiTexture("button|index", { b.bitmap }), x: ox + ib.x + (ib.width - b.width) / 2, y: oy + ib.y + (ib.height - b.height) / 2, w: b.width, h: b.height))
            }
            return out
        }
        // the tab's banner and name on the left page
        if let banner = iconSheet("spells.type")[sb.tab.lowercased()], let hb = d["header_icon"] {
            out.append(Quad(texture: uiTexture("booktype|\(sb.tab)", { banner.bitmap }), x: ox + hb.x + (hb.width - banner.width) / 2, y: oy + hb.y + (hb.height - banner.height) / 2, w: banner.width, h: banner.height))
        }
        if sb.page > 0 { img("Back_Released") }
        if (sb.page + 1) * 12 < list.count { img("Forward_Released") }
        let frames = iconSheet("spellbook_frames")
        let cellIcon = frames["spell_icon"]
        let slots = bookSlots(d, ox, oy)
        for (k, sp) in list.dropFirst(sb.page * 12).prefix(12).enumerated() where k < slots.count {
            let s = RuleTables.spells[sp]
            let (x, y) = slots[k]
            let affordable = bookCost(sb, sp) <= sb.points && sb.castable.contains(sp)
            // the frame (the school's, or Generic for an item's spell), the icon in its spell_icon box
            let fx = x - (cellIcon?.x ?? 7), fy = y - (cellIcon?.y ?? 6)
            if let fr = frames[sb.items.contains(sp) && !sb.spells.isEmpty && sb.tab == "Items" ? "generic" : s.school] ?? frames["generic"] {
                out.append(Quad(texture: uiTexture("bookframe|\(fr.name)", { fr.bitmap }), x: fx, y: fy, w: fr.width, h: fr.height))
            }
            if let icon = spellIcon(s.name) ?? spellIcon(s.keyword) {
                out.append(Quad(texture: uiTexture("spellicon|\(icon.name)", { icon.bitmap }), x: x + (52 - icon.width) / 2, y: y + (46 - icon.height) / 2, w: icon.width, h: icon.height))
            }
            if let cb = bookLayer(d, "Cost_Background") { place(cb, dx: x - ox - 74, dy: y - oy - 142, key: "costbg") }
            if let c = d["cost"] {
                let box = UILayer(name: "", kind: 1, x: c.x + x - ox - 74, y: c.y + y - oy - 142, width: c.width, height: c.height, bitmap: Bitmap(width: 1, height: 1))
                out += centred("\(text("cost.mage_guild", "Cost")) \(bookCost(sb, sp))", in: box, at: ox, oy, font: ui.font(14), colour: affordable ? ink : faint)
            }
            if let inf = bookLayer(d, "Information_Released") { place(inf, dx: x - ox - 74, dy: y - oy - 142, key: "info") }
            if let n = d["name"] {
                let box = UILayer(name: "", kind: 1, x: n.x + x - ox - 74, y: n.y + y - oy - 142 - 6, width: n.width, height: n.height, bitmap: Bitmap(width: 1, height: 1))
                out += paragraph(s.name, in: box, at: ox, oy, font: ui.font(16), colour: affordable ? ink : faint)
            }
        }
        // the page number
        if list.count > 12 {
            let t = "\(sb.page + 1) / \((list.count + 11) / 12)"
            out += centred(t, in: UILayer(name: "", kind: 1, x: 340, y: 505, width: 120, height: 20, bitmap: Bitmap(width: 1, height: 1)), at: ox, oy, font: ui.font(16), colour: ink)
        }
        return out
    }

    func spellBookClick(x: Float, y: Float) {
        guard var sb = spellBook, let ui = ui, let d = ui.dialog("spell_book") else { spellBook = nil; return }
        let (ox, oy) = bookOrigin
        func hit(_ names: String...) -> Bool { names.contains { inside(bookLayer(d, $0), at: ox, oy, x, y) } }
        if hit("Done_Released") || x < Float(ox) || x >= Float(ox + 800) || y < Float(oy) || y >= Float(oy + 600) { spellBook = nil; sound?.play("miscellaneous.button"); return }
        for t in Renderer.bookTabs where !bookSpells(sb, tab: t).isEmpty && hit("\(t)_Released", "\(t)_Pressed") {
            sb.tab = t; sb.page = 0; sb.detail = nil; spellBook = sb; return
        }
        let list = bookSpells(sb)
        if let first = sb.detail {
            if hit("Back_Released"), first > 0 { sb.detail = max(0, first - 2) }
            if hit("Forward_Released"), first + 2 < list.count { sb.detail = first + 2 }
            if hit("index_button") { sb.page = first / 12; sb.detail = nil }
            for k in 0..<2 {
                guard let c = d["cast_spell_detail"], first + k < list.count else { continue }
                let r = UILayer(name: "", kind: 1, x: c.x + (k == 0 ? 0 : 335), y: c.y, width: c.width, height: c.height, bitmap: c.bitmap)
                let sp = list[first + k]
                if inside(r, at: ox, oy, x, y), sb.castable.contains(sp), bookCost(sb, sp) <= sb.points { spellBook = nil; castPicked(sp); return }
            }
            spellBook = sb
            return
        }
        if hit("Back_Released"), sb.page > 0 { sb.page -= 1 }
        if hit("Forward_Released"), (sb.page + 1) * 12 < list.count { sb.page += 1 }
        for (k, (sx, sy)) in bookSlots(d, ox, oy).enumerated() {
            let i = sb.page * 12 + k
            guard i < list.count else { break }
            // the Information button: the detail view from this spell
            if let inf = bookLayer(d, "Information_Released"), inside(UILayer(name: "", kind: 1, x: inf.x + sx - ox - 74, y: inf.y + sy - oy - 142, width: inf.width, height: inf.height, bitmap: inf.bitmap), at: ox, oy, x, y) {
                sb.detail = i - i % 2; spellBook = sb; return
            }
            if x >= Float(sx) && x < Float(sx + 52) && y >= Float(sy) && y < Float(sy + 52) {
                guard sb.castable.contains(list[i]), bookCost(sb, list[i]) <= sb.points else { break }
                spellBook = nil
                castPicked(list[i])
                return
            }
        }
        spellBook = sb
    }
    func spellBookTip(x: Float, y: Float) -> String? {
        guard let sb = spellBook, sb.detail == nil, let d = ui?.dialog("spell_book") else { return nil }
        let (ox, oy) = bookOrigin
        let list = bookSpells(sb)
        for (k, (sx, sy)) in bookSlots(d, ox, oy).enumerated() where x >= Float(sx) && x < Float(sx + 52) && y >= Float(sy) && y < Float(sy + 52) {
            let i = sb.page * 12 + k
            guard i < list.count else { return nil }
            let s = RuleTables.spells[list[i]]
            return "\(s.name): " + (game?.tables?.spellHelp[s.keyword] ?? "")
        }
        return nil
    }

    // MARK: casting in battle

    /// The combat panel's cast button: the book of the unit whose turn it is.
    func openCombatBook() {
        guard let cs = combat, let b = cs.battle, let u = b.current, let c = u.caster else { return }
        let all = Set(c.spells).union(c.free)
        spellBook = SpellBookState(spells: Array(all), castable: Set(b.castable(u)), points: c.spellPoints, combat: true,
                                   costs: Dictionary(all.map { ($0, c.cost($0)) }, uniquingKeysWith: { a, _ in a }), items: c.free)
    }
    /// A spell picked from the book: cast now if it needs no target, else aim it.
    func castPicked(_ spell: Int) {
        guard let cs = combat, let b = cs.battle else {
            castAdventure(spell); return
        }
        if Battle.untargeted(spell) { b.cast(spell, on: nil, tables: game?.tables); cs.pump() }
        else { casting = spell }
    }
    /// Adventure-map casting (heroes' map spells).
    func castAdventure(_ spell: Int) {
        guard let g = game, let h = g.heroes.first else { return }
        g.castAdventureSpell(spell, by: h)
    }
}
