import Foundation
import H4Engine

/// The tavern (layers.dialog.hire_hero): the eleven base classes on their wheel, each offered one
/// showing its candidate's portrait; the chosen one large on the right with its name, class, the
/// class skills, the price and the biography; male / female switch the pool, the scrollbar
/// browses it; Buy hires, the check closes.
extension Renderer {
    var hireOrigin: (Int, Int) { ((AdventureUI.width - 707) / 2, (AdventureUI.height - 600) / 2) }

    func hireQuads() -> [Quad] {
        guard let o = hire, let g = game, let t = g.tables, let ui = ui, let d = ui.dialog("hire_hero") else { return [] }
        let (ox, oy) = hireOrigin
        var out = dialogImages(d, key: "hire", at: ox, oy, skip: ["Foreground", "Might_Highlight", "Magic_Highlight", "Skill_Frame", "Gold", "selected_ring"])
        out += centred(text("tavern.misc", "Tavern"), in: d["Title"], at: ox, oy, font: ui.dateFont)
        func img(_ n: String, at x: Int? = nil, _ y: Int? = nil) {
            guard let l = d[n] else { return }
            out.append(Quad(texture: uiTexture("dlg|hire|\(n)", { l.bitmap }), x: x ?? ox + l.x, y: y ?? oy + l.y, w: l.width, h: l.height))
        }
        for c in 0...10 {
            let key = RuleTables.heroClasses[c].keyword
            guard let slot = d["\(key)_portrait"], let list = o.candidates[c], let k = o.index[c], k < list.count else { continue }
            let hd = t.heroes[list[k]]
            if let p = ui.portrait(keyword: hd.keyword, alignment: RuleTables.heroClasses[c].alignment) {
                out.append(Quad(texture: uiTexture("portrait|\(hd.keyword)", { p.bitmap }), x: ox + slot.x + (slot.width - p.width) / 2, y: oy + slot.y + (slot.height - p.height) / 2, w: p.width, h: p.height))
            }
        }
        img("Foreground")
        // the chosen class: its highlight (might classes the square one, magic the round one)
        let c = o.selected, key = RuleTables.heroClasses[c].keyword
        if let slot = d["\(key)_portrait"] {
            let magic = [1, 3, 5, 7, 9].contains(c)
            if let hl = d[magic ? "Magic_Highlight" : "Might_Highlight"] { img(hl.name, at: ox + slot.x + (magic ? -13 : -14), oy + slot.y + (magic ? -13 : -15)) }
        }
        img("selected_ring"); img("Skill_Frame"); img("Gold")
        if let list = o.candidates[c], let k = o.index[c], k < list.count {
            let hd = t.heroes[list[k]]
            if let slot = d["selected_portrait"], let p = ui.portrait(keyword: hd.keyword, alignment: RuleTables.heroClasses[c].alignment, size: 82) {
                out.append(Quad(texture: uiTexture("portrait82|\(hd.keyword)", { p.bitmap }), x: ox + slot.x + (slot.width - p.width) / 2, y: oy + slot.y + (slot.height - p.height) / 2, w: p.width, h: p.height))
            }
            out += centred(hd.name, in: d["hero_name"], at: ox, oy, font: ui.dateFont)
            out += centred(text(key, key.capitalized), in: d["hero_class"], at: ox, oy, font: ui.numberFont)
            out += paragraph(hd.biography, in: d["biography"], at: ox, oy, font: ui.numberFont)
        }
        for (k, s) in RuleTables.heroClasses[c].skills.prefix(3).enumerated() {
            guard let slot = d["Skill_\(k + 1)"] else { continue }
            for l in skillIcon(s, level: 1) { out.append(Quad(texture: uiTexture("skillicon|\(l.name)|\(s)", { l.bitmap }), x: ox + slot.x + l.x, y: oy + slot.y + l.y, w: l.width, h: l.height)) }
        }
        out += centred("\(o.prices[c])", in: d["gold_number"], at: ox, oy, font: ui.numberFont)
        for (box, lab, on, word) in [("male_checkbox", "male_text", o.female[c] != true, "tavern_male.text"), ("female_checkbox", "female_text", o.female[c] == true, "tavern_female.text")] {
            if let b = d[box], let bt = ui.button("checkbox", state: on ? "Pressed" : "Released") {
                out.append(Quad(texture: uiTexture("button|checkbox|\(on)", { bt.bitmap }), x: ox + b.x + (b.width - bt.width) / 2, y: oy + b.y + (b.height - bt.height) / 2, w: bt.width, h: bt.height))
            }
            out += paragraph(text(word, word.contains("female") ? "Female" : "Male"), in: d[lab], at: ox, oy, font: ui.numberFont)
        }
        let afford = g.resources["Gold", default: 0] >= o.prices[c]
        for (slot, name, state) in [("buy_button", "buy", afford ? "Released" : "Disabled"), ("ok_button", "ok", "Released")] {
            guard let l = d[slot], let b = ui.button(name, state: state) ?? ui.button(name) else { continue }
            out.append(Quad(texture: uiTexture("button|\(name)|\(b.name)", { b.bitmap }), x: ox + l.x + (l.width - b.width) / 2, y: oy + l.y + (l.height - b.height) / 2, w: b.width, h: b.height))
        }
        return out
    }

    func hireClick(x: Float, y: Float) {
        guard var o = hire, let g = game, let d = ui?.dialog("hire_hero") else { hire = nil; return }
        let (ox, oy) = hireOrigin
        for c in 0...10 where o.candidates[c] != nil && inside(d["\(RuleTables.heroClasses[c].keyword)_portrait"], at: ox, oy, x, y) { o.selected = c; hire = o; return }
        if inside(d["male_checkbox"], at: ox, oy, x, y) || inside(d["male_text"], at: ox, oy, x, y) { g.switchGender(&o, female: false) }
        if inside(d["female_checkbox"], at: ox, oy, x, y) || inside(d["female_text"], at: ox, oy, x, y) { g.switchGender(&o, female: true) }
        if let sb = d["scrollbar"], inside(sb, at: ox, oy, x, y), let list = o.candidates[o.selected], !list.isEmpty {
            let up = y < Float(oy + sb.y + sb.height / 2)
            o.index[o.selected] = ((o.index[o.selected] ?? 0) + (up ? list.count - 1 : 1)) % list.count
        }
        if inside(d["buy_button"], at: ox, oy, x, y), g.resources["Gold", default: 0] >= o.prices[o.selected] {
            let visitor = o.town == nil ? g.heroes.first : nil
            if let h = g.hire(o, with: visitor) { g.log.append("\(h.name) joins you"); sound?.play("dialogue.tavern") }
            hire = nil; return
        }
        if inside(d["ok_button"], at: ox, oy, x, y) || x < Float(ox) || x > Float(ox + 707) || y < Float(oy) || y > Float(oy + 600) { hire = nil; return }
        hire = o
    }
}
