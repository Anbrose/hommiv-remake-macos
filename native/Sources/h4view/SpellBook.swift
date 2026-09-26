import Foundation
import H4Engine

/// The spell book (layers.dialog.spell_book): an open book, school tabs down the right (Life,
/// Death, Order, Chaos, Nature, Items, All), Combat / Adventure along the bottom, twelve spells a
/// spread (two per row, three rows a page: spell_1_row_1 / spell_2_row_1 and row_2 ... row_6),
/// each icon with its name and cost under it; the spell points in Points_Frame, Done to close.
/// In battle a spell picked is then aimed with the cast_spell pointer.
struct SpellBookState {
    var spells: [Int]            // the book's spells
    var castable: Set<Int>
    var points: Int
    var school: String? = nil    // nil: All
    var combat: Bool
    var page = 0
}

extension Renderer {
    static let bookSchools = ["life", "death", "order", "chaos", "nature"]
    var bookOrigin: (Int, Int) { ((AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2) }

    func bookSpells(_ sb: SpellBookState) -> [Int] {
        sb.spells.filter { sp in
            let s = RuleTables.spells[sp]
            return (sb.school == nil || s.school == sb.school) && (sb.combat ? s.has("Cmb") : s.has("Adv"))
        }.sorted { a, b in
            let x = RuleTables.spells[a], y = RuleTables.spells[b]
            return x.level != y.level ? x.level < y.level : x.name < y.name
        }
    }
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

    func spellBookQuads() -> [Quad] {
        guard let sb = spellBook, let ui = ui, let d = ui.dialog("spell_book") else { return [] }
        let (ox, oy) = bookOrigin
        var out: [Quad] = []
        func img(_ n: String) {
            guard let l = d[n] else { return }
            out.append(Quad(texture: uiTexture("dlg|book|\(n)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height))
        }
        for n in ["Background", "Left", "Right", "Top", "Bottom"] { img(n) }
        // the tabs: the chosen one pressed
        let tabs: [(String, String?)] = [("Life", "life"), ("Death", "death"), ("Order", "order"), ("Chaos", "chaos"), ("Nature", "nature"), ("All", nil)]
        for (t, school) in tabs {
            let on = sb.school == school
            img(d["\(t)_\(on ? "Pressed" : "Released")"] != nil ? "\(t)_\(on ? "Pressed" : "Released")" : "\(t)_\(on ? "Pressed" : "released")")
        }
        img("Items_Released")
        img(sb.combat ? "Combat_Pressed" : "Combat_released"); img(sb.combat ? "Adventure_Released" : "Adventure_Pressed")
        img("Done_Released"); img("Points_Frame")
        let list = bookSpells(sb)
        if sb.page > 0 { img("Back_Released") }
        if (sb.page + 1) * 12 < list.count { img("Forward_Released") }
        if let pf = d["points"] { out += centred("\(sb.points)", in: pf, at: ox, oy, font: ui.numberFont, colour: (255, 236, 160)) }
        let slots = bookSlots(d, ox, oy)
        for (k, sp) in list.dropFirst(sb.page * 12).prefix(12).enumerated() where k < slots.count {
            let s = RuleTables.spells[sp]
            let (x, y) = slots[k]
            if let icon = spellIcon(s.name) ?? spellIcon(s.keyword) {
                out.append(Quad(texture: uiTexture("spellicon|\(icon.name)", { icon.bitmap }), x: x + (52 - icon.width) / 2, y: y + (52 - icon.height) / 2, w: icon.width, h: icon.height))
                if !sb.castable.contains(sp) { out.append(Quad(texture: shade, x: x, y: y, w: 52, h: 52)) }
            }
            let colour: (UInt8, UInt8, UInt8) = sb.castable.contains(sp) ? (40, 24, 8) : (120, 100, 80)
            let box = UILayer(name: "", kind: 1, x: x - ox - 50, y: y - oy + 54, width: 152, height: 16, bitmap: Bitmap(width: 1, height: 1))
            out += centred(s.name, in: box, at: ox, oy, font: ui.numberFont, colour: colour)
            let cbox = UILayer(name: "", kind: 1, x: x - ox - 50, y: y - oy + 70, width: 152, height: 16, bitmap: Bitmap(width: 1, height: 1))
            out += centred("\(s.cost)", in: cbox, at: ox, oy, font: ui.numberFont, colour: colour)
        }
        return out
    }

    func spellBookClick(x: Float, y: Float) {
        guard var sb = spellBook, let ui = ui, let d = ui.dialog("spell_book") else { spellBook = nil; return }
        let (ox, oy) = bookOrigin
        func hit(_ names: String...) -> Bool { names.contains { inside(d[$0], at: ox, oy, x, y) } }
        if hit("Done_Released") || x < Float(ox) || x >= Float(ox + 800) || y < Float(oy) || y >= Float(oy + 600) { spellBook = nil; sound?.play("miscellaneous.button"); return }
        let tabs: [(String, String?)] = [("Life", "life"), ("Death", "death"), ("Order", "order"), ("Chaos", "chaos"), ("Nature", "nature"), ("All", nil)]
        for (t, school) in tabs where hit("\(t)_Released", "\(t)_released", "\(t)_Pressed") { sb.school = school; sb.page = 0; spellBook = sb; return }
        if hit("Combat_released", "Combat_Pressed") { sb.combat = true; sb.page = 0 }
        if hit("Adventure_Released", "Adventure_Pressed") { sb.combat = false; sb.page = 0 }
        let list = bookSpells(sb)
        if hit("Back_Released"), sb.page > 0 { sb.page -= 1 }
        if hit("Forward_Released"), (sb.page + 1) * 12 < list.count { sb.page += 1 }
        for (k, (sx, sy)) in bookSlots(d, ox, oy).enumerated() where x >= Float(sx) && x < Float(sx + 52) && y >= Float(sy) && y < Float(sy + 52) {
            let i = sb.page * 12 + k
            guard i < list.count, sb.castable.contains(list[i]) else { break }
            spellBook = nil
            castPicked(list[i])
            return
        }
        spellBook = sb
    }
    func spellBookTip(x: Float, y: Float) -> String? {
        guard let sb = spellBook, let d = ui?.dialog("spell_book") else { return nil }
        let (ox, oy) = bookOrigin
        let list = bookSpells(sb)
        for (k, (sx, sy)) in bookSlots(d, ox, oy).enumerated() where x >= Float(sx) && x < Float(sx + 52) && y >= Float(sy) && y < Float(sy + 52) {
            let i = sb.page * 12 + k
            guard i < list.count else { return nil }
            let s = RuleTables.spells[list[i]]
            return "\(s.name) (\(s.school.capitalized) \(s.level), \(s.cost)): " + (game?.tables?.spellHelp[s.keyword] ?? "")
        }
        return nil
    }

    // MARK: casting in battle

    /// The combat panel's cast button: the book of the unit whose turn it is.
    func openCombatBook() {
        guard let cs = combat, let b = cs.battle, let u = b.current, let c = u.caster else { return }
        spellBook = SpellBookState(spells: c.spells, castable: Set(b.castable(u)), points: c.spellPoints, combat: true)
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
