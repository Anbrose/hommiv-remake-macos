import Foundation
import H4Engine

/// The tavern (layers.dialog.hire_hero): the eleven base classes on their wheel, each offered one
/// showing its candidate's portrait; the chosen one large on the right with its name, class, the
/// class skills, the price and the biography; male / female switch the pool, the scrollbar
/// browses it; Buy hires, the check closes.
extension Renderer {
    var hireOrigin: (Int, Int) { ((AdventureUI.width - 707) / 2, (AdventureUI.height - 600) / 2) }

    /// The dialog (t_hire_hero_dialog 0x743f40, town_screens_spec §4.2), in its children's order: the big
    /// portrait at selected_portrait's top-left, the scrollbar, the gender checkboxes and labels, the name,
    /// class and title, the class skills, the biography, the price, Buy and Close, the class highlight, the
    /// class portraits, then Foreground, selected_ring and Skill_Frame over them. Black text with the
    /// (200,200,200) halo, the title without.
    func hireQuads() -> [Quad] {
        guard let o = hire, let g = game, let t = g.tables, let ui = ui, let d = ui.dialog("hire_hero") else { return [] }
        let (ox, oy) = hireOrigin
        let halo = Renderer.halo200
        let c = o.selected, key = RuleTables.heroClasses[c].keyword
        var out = dImage(d, "hire", "Background", ox, oy)
        let list = o.candidates[c] ?? [], k = o.index[c] ?? 0
        let hd = k < list.count ? t.heroes[list[k]] : nil
        if let hd = hd, let slot = d["selected_portrait"] {
            out += dImageAt(ui.portrait(keyword: hd.keyword, alignment: RuleTables.heroClasses[c].alignment, size: 82), "p82", x: ox + slot.x, y: oy + slot.y)
        }
        if let kit = kit, let sb = d["scrollbar"] { out += quads(kit.vScrollbar(ox + sb.x, oy + sb.y, sb.height, first: k, visible: 1, total: max(1, list.count))) }
        let f18 = ui.font(18)
        for (box, lab, on, word) in [("male_checkbox", "male_text", o.female[c] != true, "tavern_male.text"), ("female_checkbox", "female_text", o.female[c] == true, "tavern_female.text")] {
            if let b = d[box] { out += townButton("checkbox", x: ox + b.x, y: oy + b.y, pressed: on) }
            out += dText(text(word, word.contains("female") ? "Female" : "Male"), rect(d[lab], ox, oy), font: f18, centre: false, halo: halo, 0, 0)
        }
        if let hd = hd { out += dText(hd.name, rect(d["hero_name"], ox, oy), font: ui.font(25), centre: true, halo: halo, 0, 0) }
        out += dText(text(key, key.replacingOccurrences(of: "_", with: " ").capitalized), rect(d["hero_class"], ox, oy), font: f18, centre: true, halo: halo, 0, 0)
        out += dText(text("tavern.misc", "Tavern"), rect(d["Title"], ox, oy), font: ui.font(23), centre: true, 0, 0)
        for (n, s) in RuleTables.heroClasses[c].skills.prefix(3).enumerated() {
            guard let slot = d["Skill_\(n + 1)"] else { continue }
            for l in skillIcon(s, level: 1) { out.append(Quad(texture: uiTexture("skillicon|\(l.name)|\(s)", { l.bitmap }), x: ox + slot.x + l.x, y: oy + slot.y + l.y, w: l.width, h: l.height)) }
        }
        if let hd = hd { out += dText(hd.biography, rect(d["biography"], ox, oy), font: ui.font(20), centre: false, halo: halo, 0, 0, clip: true) }
        out += dImage(d, "hire", "Gold", ox, oy)
        out += dText("\(o.prices[c])", rect(d["gold_number"], ox, oy), font: ui.font(21), centre: true, halo: halo, 0, 0)
        out += townButton("buy", x: ox + 447, y: oy + 344, disabled: g.resources["Gold", default: 0] < o.prices[c])
        out += townButton("close", x: ox + 616, y: oy + 541)
        // the chosen class's highlight (a magic class the round one), both moved to its portrait + (-14,-15)
        if let slot = d["\(key)_portrait"] {
            let magic = [1, 3, 5, 7, 9].contains(c)
            out += dImageAt(d[magic ? "Magic_Highlight" : "Might_Highlight"], "hire", x: ox + slot.x - 14, y: oy + slot.y - 15)
        }
        for cl in 0...10 {
            let ck = RuleTables.heroClasses[cl].keyword
            guard let slot = d["\(ck)_portrait"], let l = o.candidates[cl], let n = o.index[cl], n < l.count else { continue }
            out += dImageAt(ui.portrait(keyword: t.heroes[l[n]].keyword, alignment: RuleTables.heroClasses[cl].alignment), "p52", x: ox + slot.x, y: oy + slot.y)
        }
        for n in ["Foreground", "selected_ring", "Skill_Frame"] { out += dImage(d, "hire", n, ox, oy) }
        return out
    }

    func hireClick(x: Float, y: Float) {
        guard var o = hire, let g = game, let d = ui?.dialog("hire_hero") else { hire = nil; return }
        let (ox, oy) = hireOrigin
        for c in 0...10 where o.candidates[c] != nil && inside(d["\(RuleTables.heroClasses[c].keyword)_portrait"], at: ox, oy, x, y) { o.selected = c; hire = o; return }
        if inside(d["male_checkbox"], at: ox, oy, x, y) || inside(d["male_text"], at: ox, oy, x, y) { g.switchGender(&o, female: false) }
        if inside(d["female_checkbox"], at: ox, oy, x, y) || inside(d["female_text"], at: ox, oy, x, y) { g.switchGender(&o, female: true) }
        if let sb = d["scrollbar"], inside(sb, at: ox, oy, x, y), let list = o.candidates[o.selected], !list.isEmpty {
            let up = (kit?.vScrollbarHit(ox + sb.x, oy + sb.y, sb.height, x, y) ?? 1) < 0
            o.index[o.selected] = ((o.index[o.selected] ?? 0) + (up ? list.count - 1 : 1)) % list.count
        }
        if townButtonHit("buy", x: ox + 447, y: oy + 344, x, y), g.resources["Gold", default: 0] >= o.prices[o.selected] {
            let visitor = o.town == nil ? g.heroes.first : nil
            if let h = g.hire(o, with: visitor) { g.log.append("\(h.name) joins you"); sound?.play("dialogue.tavern") }
            hire = nil; return
        }
        if townButtonHit("close", x: ox + 616, y: oy + 541, x, y) { hire = nil; return }
        hire = o
    }
}
