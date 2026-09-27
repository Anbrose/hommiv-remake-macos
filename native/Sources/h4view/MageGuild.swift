import Foundation
import H4Engine

/// The mage guild book (t_mage_guild_window 0x75f7c0, town_screens_spec §4.1): the full-screen frame
/// dialog.mage_guild.<alignment>_1024 (Top, Left, Bottom, Right), the book dialog.mage_guild.book at the
/// frame's Book_Pages; an index page per spread (levels 1-2, levels 3-5) with each spell in the place
/// table 0x98b480 gives it by (level, own / neighbour school, count) -- the school frame, the icon, the
/// plaque and the name -- and the level titles; a detail page per spell with its picture, text, cost,
/// flavour and the town's heroes who know it.
extension Renderer {
    /// Places per (level, school rank r, running count k) (table 0x98b480; 0 = no place).
    static let guildPlaces: [Int] = [1, 2, 3, 4, 5, 0, 6, 7, 0, 1, 2, 3, 4, 5, 0, 6, 7, 0, 1, 2, 0, 3, 4, 0, 5, 6, 0,
                                     1, 2, 0, 3, 0, 0, 4, 0, 0, 1, 0, 0, 2, 0, 0, 3, 0, 0]
    var guildBook: LayerFile? { dFile("dialog.mage_guild.book") }
    /// The frame (screen 1024 wide: `_1024`) and the book origin B = its Book_Pages top-left.
    func guildOrigin() -> (frame: LayerFile?, bx: Int, by: Int) {
        guard let g = game, let i = townOpen else { return (nil, 0, 0) }
        let f = dFile("dialog.mage_guild.\(g.towns[i].alignment)_1024")
        let fw = f?.layers.map { $0.x + $0.width }.max() ?? AdventureUI.width, fh = f?.layers.map { $0.y + $0.height }.max() ?? AdventureUI.height
        let ox = (AdventureUI.width - fw) / 2, oy = (AdventureUI.height - fh) / 2
        guard let bp = dLayer(f, "Book_Pages") else { return (f, (AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2) }
        return (f, ox + bp.x, oy + bp.y)
    }
    /// The guild's spells in their places: (spell, level, page, frame hotspot), in the order of the sorted list.
    func guildCells() -> [(spell: Int, level: Int, page: Int, frame: UILayer)] {
        guard let g = game, let i = townOpen, let d = guildBook else { return [] }
        let t = g.towns[i]
        let neighbour = g.buildingKeyword(t.alignment, 25)?.split(separator: " ").first.map(String.init) ?? ""
        var spells: [Int] = []
        for lv in 1...5 where g.isBuiltPublic(t, 19 + lv) && lv <= t.guildSpells.count { spells += t.guildSpells[lv - 1] }
        spells.sort { (RuleTables.spells[$0].level, RuleTables.spells[$0].name) < (RuleTables.spells[$1].level, RuleTables.spells[$1].name) }
        var counts: [Int: Int] = [:]
        var out: [(Int, Int, Int, UILayer)] = []
        for s in spells {
            let def = RuleTables.spells[s], L = max(1, min(5, def.level))
            let r = def.school == t.alignment ? 0 : def.school == neighbour ? 1 : 2
            let key = L * 3 + r, k = counts[key, default: 0]
            counts[key] = k + 1
            guard k < 3 else { continue }
            let n = Renderer.guildPlaces[3 * (3 * (L - 1) + r) + k]
            guard n > 0, let f = dLayer(d, "level_\(L)_frame_\(n)") else { continue }
            out.append((s, L, L > 2 ? 1 : 0, f))
        }
        return out
    }
    /// The heroes in the town (the garrison, then the visiting army) who know a spell.
    func guildHeroes(_ spell: Int) -> [Hero] {
        guard let g = game, let i = townOpen else { return [] }
        var hs = g.towns[i].garrisonHeroes
        if let v = g.visitingArmy(town: i) { hs += [v] + v.companions }
        return hs.filter { $0.spells.contains(spell) }
    }
    /// A hero row's text (0x8652a0: the spell's Mage Guild / Spell Book hero text for that hero).
    func guildHeroText(_ h: Hero, _ sp: Int) -> String {
        guard let g = game else { return h.name }
        let s = RuleTables.spells[sp]
        guard var t = g.tables?.spellGuildText[s.keyword] ?? g.tables?.spellBookText[s.keyword] else { return h.name }
        let power = bookPower(sp, caster: Caster(hero: h, spellPoints: g.spellPoints(h)))
        let creatures: String = { guard let c = g.tables?.creature(s.creature) else { return "\(power)" }; return "\(power) \(power == 1 ? c.name : c.plural)" }()
        for k in ["%capitalize_spell_name", "%Capitalize_spell_name", "%Spell_Name", "%Spell_name", "%spell_name"] { t = t.replacingOccurrences(of: k, with: s.name) }
        for k in ["%Hero_name", "%hero_name", "%Hero_Name"] { t = t.replacingOccurrences(of: k, with: h.name) }
        t = t.replacingOccurrences(of: "%power", with: "\(power)").replacingOccurrences(of: "%creatures", with: creatures)
        t = t.replacingOccurrences(of: "%lives", with: power == 1 ? "1 life" : "\(max(1, power)) lives")
        return t
    }

    func mageGuildQuads() -> [Quad] {
        guard let ui = ui, let g = game, let i = townOpen, let d = guildBook, let dlg = townDialog else { return [] }
        let t = g.towns[i]
        let (f, bx, by) = guildOrigin()
        let halo = Renderer.halo200
        var out: [Quad] = []
        for n in ["Top", "Left", "Bottom", "Right"] { out += dImage(f, "guildframe.\(t.alignment)", n, (AdventureUI.width - 1024) / 2, (AdventureUI.height - 768) / 2) }
        out += dImageAt(dLayer(d, "Book_Pages"), "guild", x: bx, y: by)
        let frames = dFile("icons.spellbook_frames")
        let cells = guildCells()
        switch dlg {
        case .mageGuild(let page):
            // the level titles (the L1 / L2 plaques serve L3 / L4); the i-th of a page shows while i < the highest level present
            let highest = cells.map { $0.level }.max() ?? 0
            let levels = page == 0 ? [1, 2] : [3, 4, 5]
            for (pos, L) in levels.enumerated() where pos < highest {
                out += dImage(d, "guild", "Level_\([1, 2, 1, 2, 5][L - 1])_Spells_Background", bx, by)
                guard let r = dRect(d, "level_\(L)_spells") else { continue }
                out += dText(text("level_x_spells.mage_guild", "Level %level Spells").replacingOccurrences(of: "%level", with: "\(L)"), r.offset(bx, by),
                             font: ui.font(r.h), centre: true, vcentre: true, halo: halo, 0, 0)
            }
            for c in cells where c.page == page {
                let fx = bx + c.frame.x, fy = by + c.frame.y
                let s = RuleTables.spells[c.spell]
                out += dImageAt(dLayer(frames, s.school.capitalized), "sbframes", x: fx, y: fy)
                out += dImageAt(spellIcon(id: c.spell), "spellicon", x: fx + 7, y: fy + 6)
                out += dImageAt(dLayer(d, "Spell_Background"), "guild", x: fx - 32, y: fy + 49)
                out += dText(s.name, DRect(fx - 17, fy + 67, 101, 42), font: ui.font(14), centre: true, vcentre: true, halo: halo, 0, 0)
            }
            if page == 1 { out += townButton("mage_guild.last_spell", x: bx + 7, y: by + 29) }
            if page == 0, cells.contains(where: { $0.page == 1 }) { out += townButton("mage_guild.next_spell", x: bx + 756, y: by + 24) }
        case .guildSpell(let sp, let heroTop):
            let s = RuleTables.spells[sp]
            out += dImage(d, "guild", "Spell_Name_Background", bx, by)
            out += dImage(d, "guild", "Hero_List_Background", bx, by)
            if let sf = dLayer(d, "spell_frame") {
                out += dImageOffset(dLayer(frames, s.school.capitalized), "sbframes", x: bx + sf.x, y: by + sf.y)
                out += dImageAt(spellIcon(id: sp), "spellicon", x: bx + sf.x + 7, y: by + sf.y + 6)
            }
            if let sil = dLayer(d, "icon_silhouette") { out += dImageAlpha(spellIcon180(s), "spell180", x: bx + sil.x, y: by + sil.y, alpha: 4) }   // 0x59ee20(..., 1, 4): at 4/15
            out += dText(s.name, dRect(d, "Spell_Name")?.offset(bx, by), font: ui.font(23), centre: true, vcentre: true, halo: halo, 0, 0)
            if let r = dRect(d, "description_text")?.offset(bx, by) {
                let pf = ui.font(20)
                let help = (g.tables?.spellHelp[s.keyword] ?? "") + "\n\n" + text("cost.mage_guild", "Cost") + ": \(s.cost)"
                let h = min(dLines(help, width: r.w, font: pf).count * pf.lineHeight, 284)
                out += dText(help, DRect(r.x, r.y, r.w, h), font: pf, centre: false, halo: halo, 0, 0, clip: true)
                if let fl = g.tables?.spellFlavor[s.keyword], !fl.isEmpty, let sfnt = scriptFont(18) {
                    let fy = r.y + h + 20, fh = dLines(fl, width: r.w, font: sfnt).count * sfnt.lineHeight
                    if fy + fh <= by + 455 { out += dText(fl, DRect(r.x, fy, r.w, fh), font: sfnt, centre: false, halo: halo, 0, 0) }
                }
            }
            out += dText(text("hero_list.mage_guild", "Hero List"), dRect(d, "Hero_List")?.offset(bx, by), font: ui.font(25), centre: true, vcentre: true, halo: halo, 0, 0)
            let heroes = guildHeroes(sp)
            for k in 0..<5 {
                guard let slot = dLayer(d, "hero_frame_\(k + 1)") else { continue }
                let sx = bx + slot.x, sy = by + slot.y
                let r = DRect(sx + 83, sy + 4, 204, 67)
                if heroes.isEmpty {
                    if k == 0 { out += dText(text("no_knowledge.mage_guild", "No heroes in town know %spell_name").replacingOccurrences(of: "%spell_name", with: s.name), r, font: ui.font(16), centre: false, halo: halo, 0, 0) }
                    continue
                }
                guard heroTop + k < heroes.count else { continue }
                let h = heroes[heroTop + k]
                out += dImageAt(ui.portrait(keyword: h.keyword, alignment: h.alignment), "portrait", x: sx + 13, y: sy + 12)
                out += dImageAt(dLayer(frames, "Hero_Frame"), "sbframes", x: sx, y: sy)
                out += dText(guildHeroText(h, sp), r, font: ui.font(16), centre: false, halo: halo, 0, 0)
            }
            let k = cells.firstIndex { $0.spell == sp } ?? 0
            if k > 0 { out += townButton("mage_guild.last_spell", x: bx + 30, y: by + 490) }
            if k + 1 < cells.count { out += townButton("mage_guild.next_spell", x: bx + 348, y: by + 490) }
            if heroTop > 0 { out += townButton("spellbook.last_hero", x: bx + 425, y: by + 52) }
            if heroTop + 5 < heroes.count { out += townButton("spellbook.next_hero", x: bx + 426, y: by + 508) }
            out += townButton("spellbook.index", x: bx + 523, y: by + 525)
        default: break
        }
        out += townButton("mage_guild.close", x: bx + 16, y: by + 530)
        return out
    }

    func mageGuildClick(x: Float, y: Float) {
        guard let dlg = townDialog else { return }
        let (_, bx, by) = guildOrigin()
        func hit(_ file: String, _ px: Int, _ py: Int) -> Bool { townButtonHit(file, x: bx + px, y: by + py, x, y) }
        if hit("mage_guild.close", 16, 530) { townDialog = nil; return }
        let cells = guildCells()
        switch dlg {
        case .mageGuild(let page):
            if page == 1, hit("mage_guild.last_spell", 7, 29) { townDialog = .mageGuild(page: 0); return }
            if page == 0, cells.contains(where: { $0.page == 1 }), hit("mage_guild.next_spell", 756, 24) { townDialog = .mageGuild(page: 1); return }
            for c in cells where c.page == page {
                let fx = bx + c.frame.x + 7, fy = by + c.frame.y + 6
                if x >= Float(fx) && x < Float(fx + 62) && y >= Float(fy) && y < Float(fy + 44) { townDialog = .guildSpell(spell: c.spell, heroTop: 0); return }
            }
        case .guildSpell(let sp, let heroTop):
            let k = cells.firstIndex { $0.spell == sp } ?? 0
            if hit("spellbook.index", 523, 525) { townDialog = .mageGuild(page: RuleTables.spells[sp].level > 2 ? 1 : 0); return }
            if k > 0, hit("mage_guild.last_spell", 30, 490) { townDialog = .guildSpell(spell: cells[k - 1].spell, heroTop: 0); return }
            if k + 1 < cells.count, hit("mage_guild.next_spell", 348, 490) { townDialog = .guildSpell(spell: cells[k + 1].spell, heroTop: 0); return }
            let n = guildHeroes(sp).count
            if heroTop > 0, hit("spellbook.last_hero", 425, 52) { townDialog = .guildSpell(spell: sp, heroTop: heroTop - 1); return }
            if heroTop + 5 < n, hit("spellbook.next_hero", 426, 508) { townDialog = .guildSpell(spell: sp, heroTop: heroTop + 1); return }
        default: break
        }
    }
}
