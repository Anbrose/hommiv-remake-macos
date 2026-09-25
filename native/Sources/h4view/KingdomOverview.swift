import Foundation
import H4Engine

/// The kingdom overview (panel button "overview"): layers.dialog.Kingdom_Overview.Layout is the
/// frame with the resources owned and earned per day along the bottom and the list buttons; the
/// list shown fills its "Views" area -- Town_List (a row of 152 px per town: card, income, the
/// garrison and the creatures for hire) or Hero_List (a row of 91 px per hero: portrait, name,
/// primary skills; the chosen hero's numbers and skill grid at the right).
struct KingdomOverview {
    enum Mode { case towns, heroes }
    var mode: Mode = .towns
    var scroll = 0
    var selectedHero = 0
}

extension Renderer {
    var overviewOrigin: (Int, Int) { ((AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2) }
    func overviewLayout(_ name: String) -> LayerFile? { ui?.dialog("Kingdom_Overview.\(name)") }
    /// Every hero of the player, companions included.
    var kingdomHeroes: [Hero] { game?.heroes.flatMap { [$0] + $0.companions } ?? [] }

    func overviewQuads() -> [Quad] {
        guard let ko = overview, let g = game, let ui = ui, let d = overviewLayout("Layout") else { return [] }
        let (ox, oy) = overviewOrigin
        var out = dialogImages(d, key: "ko", at: ox, oy, skip: Set(d.layers.map { $0.name }).subtracting(["Background"]))
        out += dialogImages(d, key: "ko", at: ox, oy, skip: ["Background", "Town_List_Disabled", "Hero_List_Disabled", "Army_List_Disabled", "Army_List_Released", "Town_List_Released", "Hero_List_Released"])
        // the list buttons: the shown list's pressed
        for (name, mode) in [("Town_List", KingdomOverview.Mode.towns), ("Hero_List", .heroes)] {
            if let l = d["\(name)_\(ko.mode == mode ? "Pressed" : "Released")"] { out.append(Quad(texture: uiTexture("dlg|ko|\(l.name)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height)) }
        }
        if let l = d["Army_List_Disabled"] { out.append(Quad(texture: uiTexture("dlg|ko|\(l.name)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height)) }
        let strings = g.tables?.strings ?? [:]
        out += centred(strings["kingdom_overview_title.misc"] ?? "Kingdom Overview", in: d["Title"], at: ox, oy, font: ui.dateFont)
        let income = g.income
        for r in ["Gold", "Wood", "Ore", "Crystal", "Gems", "Mercury", "Sulfur"] {
            let earned = d["\(r)_earned"] ?? d["\(r)_Earned"]
            out += centred("\(g.resources[r] ?? 0)", in: d["\(r)_Owned"], at: ox, oy, font: ui.numberFont)
            out += centred("+\(income[r] ?? 0)", in: earned, at: ox, oy, font: ui.numberFont)
        }
        if let s = d["Close_Button"], let b = ui.button("close") ?? ui.button("ok") {
            out.append(Quad(texture: uiTexture("button|\(b.name)|close", { b.bitmap }), x: ox + s.x + (s.width - b.width) / 2, y: oy + s.y + (s.height - b.height) / 2, w: b.width, h: b.height))
        }
        guard let views = d["Views"] else { return out }
        let vx = ox + views.x, vy = oy + views.y
        switch ko.mode {
        case .heroes: out += overviewHeroes(ko, vx, vy)
        case .towns: out += overviewTowns(ko, vx, vy)
        }
        return out
    }

    private func overviewHeroes(_ ko: KingdomOverview, _ vx: Int, _ vy: Int) -> [Quad] {
        guard let g = game, let ui = ui, let d = overviewLayout("Hero_List") else { return [] }
        var out: [Quad] = []
        let heroes = kingdomHeroes
        for (row, h) in heroes.dropFirst(ko.scroll).prefix(5).enumerated() {
            guard let r = d["Hero_\(row + 1)"] else { continue }
            let rx = vx + r.x, ry = vy + r.y
            for n in [ko.scroll + row == ko.selectedHero ? "Portrait_Pressed" : "Portrait_Released", "Name_Scroll", "Mini_Skill_Frame"] {
                if let l = d[n] { out.append(Quad(texture: uiTexture("dlg|kohero|\(n)", { l.bitmap }), x: rx + l.x, y: ry + l.y, w: l.width, h: l.height)) }
            }
            if let slot = d["Hero_Portrait"], let p = ui.portrait(keyword: h.keyword, alignment: h.alignment) {
                out.append(Quad(texture: uiTexture("portrait|\(h.alignment)|\(h.keyword)", { p.bitmap }), x: rx + slot.x + (slot.width - p.width) / 2, y: ry + slot.y + (slot.height - p.height) / 2, w: p.width, h: p.height))
            }
            out += centred(h.name, in: d["Hero_Text"], at: rx, ry, font: ui.numberFont)
            for (k, p) in (0..<9).filter({ h.skill(id: $0) > 0 }).prefix(5).enumerated() {
                guard let slot = d["Primary_\(k + 1)"] else { continue }
                for l in skillIcon(p, level: h.skill(id: p)) {
                    out.append(Quad(texture: uiTexture("skillicon|\(l.name)|\(p)", { l.bitmap }), x: rx + slot.x + l.x, y: ry + slot.y + l.y, w: l.width, h: l.height))
                }
            }
        }
        // the chosen hero at the right
        guard heroes.indices.contains(ko.selectedHero) else { return out }
        let h = heroes[ko.selectedHero]
        for n in ["Background", "Melee", "Hit_Points", "Spell_Points", "Experience", "Speed", "Move", "Skill_Frame"] {
            if let l = d[n] { out.append(Quad(texture: uiTexture("dlg|kohero|\(n)", { l.bitmap }), x: vx + l.x, y: vy + l.y, w: l.width, h: l.height)) }
        }
        let s = g.heroStats(h)
        let owner = g.heroes.first { $0 === h || $0.companions.contains { $0 === h } }
        for (slot, v) in [("Damage_text", s.damage), ("Health_Text", "\(s.hitPoints)"), ("Spell_Points_Text", "\(s.spellPoints)"), ("Experience_Text", "\(h.experience)"),
                          ("Speed_Text", "\(s.speed)"), ("Movement_Text", "\(Int(owner?.movement ?? 0))"), ("Luck_Text", "0"), ("Morale_Text", "0")] {
            out += centred(v, in: d[slot], at: vx, vy, font: ui.numberFont)
        }
        let rows = [d["skill_1"]] + (2...5).map { d["skill_row_\($0)"] }
        for (r, ids) in skillRows(h).prefix(5).enumerated() {
            guard let row = rows[r], let first = d["skill_1"], let second = d["skill_2"] else { continue }
            for (k, id) in ids.prefix(4).enumerated() {
                let x = vx + first.x + k * (second.x - first.x), y = vy + row.y
                for l in skillIcon(id, level: h.skill(id: id)) { out.append(Quad(texture: uiTexture("skillicon|\(l.name)|\(id)", { l.bitmap }), x: x + l.x, y: y + l.y, w: l.width, h: l.height)) }
            }
        }
        return out
    }

    private func overviewTowns(_ ko: KingdomOverview, _ vx: Int, _ vy: Int) -> [Quad] {
        guard let g = game, let ui = ui, let d = overviewLayout("Town_List") else { return [] }
        var out: [Quad] = []
        for (row, t) in g.towns.filter({ $0.owned }).dropFirst(ko.scroll).prefix(3).enumerated() {
            let rx = vx, ry = vy + row * 152
            for n in ["Garrison_Scroll", "Hire_Scroll", "Gold", "Gold_Scroll", "Ring_Background"] {
                if let l = d[n] { out.append(Quad(texture: uiTexture("dlg|kotown|\(n)", { l.bitmap }), x: rx + l.x, y: ry + l.y, w: l.width, h: l.height)) }
            }
            if let list = d["Town_list"], let card = ui.tinyCard(t.alignment) {
                let terrain = TownScreen.terrainNames[t.terrain] ?? "grass"
                if let bg = card.layers.first(where: { $0.name.lowercased() == terrain }) ?? card["grass"] {
                    out.append(Quad(texture: uiTexture("tiny|\(t.alignment)|\(bg.name)", { bg.bitmap }), x: rx + list.x + bg.x, y: ry + list.y + bg.y, w: bg.width, h: bg.height))
                }
                let walls = t.buildings.contains("castle") ? "Castle" : t.buildings.contains("citadel") ? "Citadel" : t.buildings.contains("fort") ? "Fort" : "Village"
                if let w = card[walls] { out.append(Quad(texture: uiTexture("tiny|\(t.alignment)|\(walls)", { w.bitmap }), x: rx + list.x + w.x, y: ry + list.y + w.y, w: w.width, h: w.height)) }
            }
            if t.builtToday, let l = d["Built"] { out.append(Quad(texture: uiTexture("dlg|kotown|Built", { l.bitmap }), x: rx + l.x, y: ry + l.y, w: l.width, h: l.height)) }
            out += centred(t.name, in: UILayer(name: "", kind: 1, x: 0, y: 62, width: 116, height: 16, bitmap: Bitmap(width: 1, height: 1)), at: rx, ry, font: ui.numberFont)
            out += centred("\(g.hallIncome(t))", in: d["Gold_Text"], at: rx, ry, font: ui.numberFont)
            out += centred("Garrison", in: d["Garrison_Text"], at: rx, ry, font: ui.numberFont)
            out += centred("For Hire", in: d["Hire_Text"], at: rx, ry, font: ui.numberFont)
            // the creatures waiting to be hired, in the lower ring row
            if let rings = d["Hire_Rings"] {
                for (k, (c, n)) in t.available.filter({ $0.value > 0 }).sorted(by: { $0.key < $1.key }).prefix(7).enumerated() {
                    guard let icon = ui.creatureIcon(c) else { continue }
                    let cx = rx + rings.x + rings.width * (2 * k + 1) / 14, cy = ry + rings.y + rings.height / 2 - 6
                    out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height))
                    out += centred("\(n)", in: UILayer(name: "", kind: 1, x: cx - rx - 25, y: cy - ry + 24, width: 50, height: 14, bitmap: Bitmap(width: 1, height: 1)), at: rx, ry, font: ui.ringFont)
                }
            }
        }
        return out
    }

    /// A click with the overview open: the list buttons, a hero row, Close, or outside.
    func overviewClick(x: Float, y: Float) {
        guard var ko = overview, let d = overviewLayout("Layout") else { overview = nil; return }
        let (ox, oy) = overviewOrigin
        if inside(d["Town_List_Released"], at: ox, oy, x, y) { ko.mode = .towns; ko.scroll = 0 }
        else if inside(d["Hero_List_Released"], at: ox, oy, x, y) { ko.mode = .heroes; ko.scroll = 0 }
        else if inside(d["Close_Button"], at: ox, oy, x, y) || x < Float(ox) || x >= Float(ox + 800) || y < Float(oy) || y >= Float(oy + 600) { overview = nil; sound?.play("miscellaneous.button"); return }
        else if ko.mode == .heroes, let views = d["Views"], let hl = overviewLayout("Hero_List") {
            for row in 0..<5 {
                guard let r = hl["Hero_\(row + 1)"] else { continue }
                if inside(r, at: ox + views.x, oy + views.y, x, y), ko.scroll + row < kingdomHeroes.count { ko.selectedHero = ko.scroll + row }
            }
        } else if inside(d["Scrollbar"], at: ox, oy, x, y), let bar = d["Scrollbar"] {
            let n = ko.mode == .heroes ? kingdomHeroes.count : (game?.towns.filter { $0.owned }.count ?? 0)
            let page = ko.mode == .heroes ? 5 : 3
            ko.scroll = max(0, min(max(0, n - page), ko.scroll + (y < Float(oy + bar.y + bar.height / 2) ? -1 : 1)))
        }
        overview = ko
    }
}
