import Foundation
import H4Engine

/// The kingdom overview (t_kingdom_overview_window, menus_spec D2): layers.dialog.Kingdom_Overview.Layout
/// with the title (PA.20 black), the materials owned and earned ("N/day", PA.16 black, centred), the
/// three list tabs (Army / Town / Hero list, the shown one pressed), Close (button.ok at Close_Button's
/// top-left), the scrollbar at (7,49) and the list in "Views": Army_List (5 rows of 91: the leader in
/// Army_Leader, a mini-map with its marker, the army's ring row), Town_List (3 rows of 152: the town
/// card, gold income, Garrison / Creatures for Hire scrolls and their ring rows) or Hero_List (5 rows:
/// portrait toggle, name, primary skills; the chosen hero's numbers, luck and morale icons, skills,
/// Bio and SpellBook at the right).
struct KingdomOverview {
    enum Mode { case armies, towns, heroes }
    var mode: Mode = .towns
    var scroll = 0
    var selectedHero = 0
    /// The snapshot hook's names ("armies", "heroes", else towns).
    init(mode: Mode = .towns) { self.mode = mode }
    init(snapshot m: String) { mode = m == "heroes" ? .heroes : m == "armies" ? .armies : .towns }
}

extension Renderer {
    var overviewOrigin: (Int, Int) { ((AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2) }
    func overviewLayout(_ name: String) -> LayerFile? { kit?.file("dialog.Kingdom_Overview.\(name)") }
    /// Every hero of the player, companions included.
    var kingdomHeroes: [Hero] { game?.heroes.flatMap { [$0] + $0.companions } ?? [] }
    static let overviewTabs: [(String, KingdomOverview.Mode)] = [("Army_List", .armies), ("Town_List", .towns), ("Hero_List", .heroes)]
    static let overviewMaterials = ["Gold", "Wood", "Ore", "Crystal", "Gems", "Mercury", "Sulfur"]

    func overviewQuads() -> [Quad] {
        guard let ko = overview, let g = game, let kit = kit, let d = overviewLayout("Layout") else { return [] }
        let (ox, oy) = overviewOrigin
        func l(_ n: String) -> UILayer? { MenuKit.find(d, n) }
        let tag = "Kingdom_Overview.Layout"
        var out = kit.image(l("Background"), tag, ox, oy)
        if let t = l("Title") { out += kit.text(kit.t("kingdom_overview_title.misc", "Kingdom Overview"), UIRect(t, ox, oy), MenuKit.Style(t.height, halo: nil, just: 1), clip: false) }
        let income = g.income
        for r in Renderer.overviewMaterials {
            out += kit.image(l(r), tag, ox, oy)
            if let o = l("\(r)_Owned") { out += kit.text(Renderer.grouped(g.resources[r] ?? 0), UIRect(o, ox, oy), MenuKit.Style(o.height, halo: nil, just: 1), clip: false) }
            if let e = l("\(r)_Earned") { out += kit.text("\(income[r] ?? 0)/\(kit.t("day.text", "day"))", UIRect(e, ox, oy), MenuKit.Style(e.height, halo: nil, just: 1), clip: false) }
        }
        for (name, mode) in Renderer.overviewTabs {
            let hot = l("\(name)_Released").map { UIRect($0, ox, oy).contains(pointerCanvas.0, pointerCanvas.1) } ?? false
            out += kit.layoutButton("dialog.Kingdom_Overview.Layout", name, ko.mode == mode ? .pressed : hot ? .highlighted : .released, ox, oy)
        }
        if let c = l("Close_Button") { out += kit.button("ok", .released, ox + c.x, oy + c.y) }
        let (count, page) = overviewCount(ko.mode)
        if let s = l("Scrollbar") { out += kit.vScrollbar(ox + s.x, oy + s.y, s.height, first: ko.scroll, visible: page, total: count) }
        var q = quads(out)
        guard let views = l("Views") else { return q }
        let vx = ox + views.x, vy = oy + views.y
        switch ko.mode {
        case .heroes: q += overviewHeroes(ko, vx, vy)
        case .towns: q += overviewTowns(ko, vx, vy)
        case .armies: q += overviewArmies(ko, vx, vy)
        }
        return q
    }
    func overviewCount(_ m: KingdomOverview.Mode) -> (Int, Int) {
        switch m {
        case .heroes: return (kingdomHeroes.count, 5)
        case .armies: return (game?.heroes.count ?? 0, 5)
        case .towns: return (game?.towns.filter { $0.owned }.count ?? 0, 3)
        }
    }

    /// A ring row (t_creature_array_window 0x6439c0) with its top-left at (x, y): the Left, Middle x5,
    /// Right pieces edge to edge, a portrait or creature icon in each hole with its count.
    func overviewRingRow(_ items: [(UILayer?, String?, Bool)], x: Int, y: Int) -> [Quad] {
        guard let ui = ui else { return [] }
        var out: [Quad] = []
        var cursor = x
        for k in 0..<7 {
            let name = k == 0 ? "Left" : k == 6 ? "Right" : "Middle"
            guard let p = ui.creatureRing(name) else { continue }
            let fx = cursor - p.x, fy = y - p.y
            let cx = fx + 41, cy = fy + 41
            if k < items.count, let icon = items[k].0 { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height)) }
            out.append(Quad(texture: uiTexture("cring|\(p.name)", { p.bitmap }), x: fx + p.x, y: fy + p.y, w: p.width, h: p.height))
            if k < items.count { ringLabel(&out, ui: ui, cx: cx, cy: cy, count: items[k].1, hero: items[k].2) }
            cursor += p.width
        }
        return out
    }
    func armyItems(_ leader: Hero) -> [(UILayer?, String?, Bool)] {
        guard let ui = ui else { return [] }
        let heroes = [leader] + leader.companions
        return heroes.map { (ui.portrait(keyword: $0.keyword, alignment: $0.alignment), nil, true) } + leader.army.map { (ui.creatureIcon($0.creature), String($0.count), false) }
    }

    private func overviewArmies(_ ko: KingdomOverview, _ vx: Int, _ vy: Int) -> [Quad] {
        guard let g = game, let ui = ui, let kit = kit, let d = overviewLayout("Army_List") else { return [] }
        func l(_ n: String) -> UILayer? { MenuKit.find(d, n) }
        let tag = "Kingdom_Overview.Army_List"
        var out: [Quad] = []
        let full = AdventureUI.minimap(game: g, size: 256)
        for (row, h) in g.heroes.enumerated().dropFirst(ko.scroll).prefix(5) {
            guard let r = l("Army_\(row - ko.scroll + 1)") else { continue }
            let rx = vx + r.x, ry = vy + r.y
            if let p = l("portrait"), let pic = ui.portrait(keyword: h.keyword, alignment: h.alignment) {
                out.append(Quad(texture: uiTexture("icon|\(pic.name)", { pic.bitmap }), x: rx + p.x, y: ry + p.y, w: pic.width, h: pic.height))
            }
            out += quads(kit.image(l("Army_Leader"), tag, rx, ry))
            out += quads(kit.image(l("Frame"), tag, rx, ry))
            // the mini-map around the army, its place marked
            if let m = l("map") {
                let n = Float(g.map.size)
                let px = Int((Float(h.y - h.x) + n / 2) / n * 256), py = Int((Float(h.x + h.y) - n / 2) / n * 256)
                let key = "komap|\(h.x),\(h.y),\(g.level)|\(g.day)"
                out.append(Quad(texture: uiTexture(key, {
                    var b = Bitmap(width: m.width, height: m.height)
                    for y in 0..<m.height { for x in 0..<m.width {
                        let sx = px - m.width / 2 + x, sy = py - m.height / 2 + y
                        guard sx >= 0, sx < full.width, sy >= 0, sy < full.height else { continue }
                        for c in 0..<4 { b.pixels[(y * m.width + x) * 4 + c] = full.pixels[(sy * full.width + sx) * 4 + c] }
                    } }
                    return b
                }), x: rx + m.x, y: ry + m.y, w: m.width, h: m.height))
                if let mk = l("marker") { out.append(Quad(texture: redDot, x: rx + m.x + m.width / 2 - mk.width / 2, y: ry + m.y + m.height / 2 - mk.height / 2, w: mk.width, h: mk.height)) }
            }
            if let gr = l("Garrison_Rings") { out += overviewRingRow(armyItems(h), x: rx + gr.x + 10, y: ry + gr.y + 3) }
        }
        return out
    }

    private func overviewHeroes(_ ko: KingdomOverview, _ vx: Int, _ vy: Int) -> [Quad] {
        guard let g = game, let ui = ui, let kit = kit, let d = overviewLayout("Hero_List") else { return [] }
        func l(_ n: String) -> UILayer? { MenuKit.find(d, n) }
        let tag = "Kingdom_Overview.Hero_List"
        var out: [Quad] = []
        let heroes = kingdomHeroes
        for (row, h) in heroes.enumerated().dropFirst(ko.scroll).prefix(5) {
            guard let r = l("Hero_\(row - ko.scroll + 1)") else { continue }
            let rx = vx + r.x, ry = vy + r.y
            out += quads(kit.image(l(row == ko.selectedHero ? "Portrait_Pressed" : "Portrait_Released"), tag, rx, ry))
            if let slot = l("Hero_Portrait"), let p = ui.portrait(keyword: h.keyword, alignment: h.alignment) {
                out.append(Quad(texture: uiTexture("portrait|\(h.alignment)|\(h.keyword)", { p.bitmap }), x: rx + slot.x, y: ry + slot.y, w: p.width, h: p.height))
            }
            out += quads(kit.image(l("Name_Scroll"), tag, rx, ry) + kit.image(l("Mini_Skill_Frame"), tag, rx, ry))
            if let t = l("Hero_Text") { out += quads(kit.text(h.name, UIRect(t, rx, ry), MenuKit.Style(18, halo: nil, just: 1), clip: false)) }
            for (k, p) in (0..<9).filter({ h.skill(id: $0) > 0 }).prefix(5).enumerated() {
                guard let slot = l("Primary_\(k + 1)") else { continue }
                for s in skillIcon(p, level: h.skill(id: p)) {
                    out.append(Quad(texture: uiTexture("skillicon|\(s.name)|\(p)", { s.bitmap }), x: rx + slot.x + s.x, y: ry + slot.y + s.y, w: s.width, h: s.height))
                }
            }
        }
        // the chosen hero at the right
        guard heroes.indices.contains(ko.selectedHero) else { return out }
        let h = heroes[ko.selectedHero]
        var items: [UIItem] = []
        for n in ["Background", "Skill_Frame", "Melee", "Hit_Points", "Spell_Points", "Experience", "Speed", "Move"] { items += kit.image(l(n), tag, vx, vy) }
        items += kit.layoutButton("dialog.Kingdom_Overview.Hero_List", "Bio", .released, vx, vy)
        items += kit.layoutButton("dialog.Kingdom_Overview.Hero_List", "SpellBook", .released, vx, vy)
        let s = g.heroStats(h)
        let owner = g.heroes.first { $0 === h || $0.companions.contains { $0 === h } }
        let army = owner.map { [$0] + $0.companions } ?? [h]
        let moraleArmy: [(alignment: String, undead: Bool)] = army.map { ($0.alignment, false) } + (owner?.army ?? []).compactMap { st in g.tables?.creature(st.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
        let bonus = ArmyBonuses(heroes: army)
        let morale = min(10, max(-10, Battle.armyMorale(own: h.alignment, army: moraleArmy) + bonus.morale)), luck = min(10, max(-10, bonus.luck))
        for (slot, v) in [("Damage_text", s.damage), ("Health_Text", "\(s.hitPoints)"), ("Spell_Points_Text", "\(g.spellPoints(h))"), ("Experience_Text", Renderer.grouped(h.experience)),
                          ("Speed_Text", "\(s.speed)"), ("Movement_Text", "\(Int(owner?.movement ?? 0))"), ("Luck_Text", luck > 0 ? "+\(luck)" : "\(luck)"), ("Morale_Text", morale > 0 ? "+\(morale)" : "\(morale)")] {
            if let t = l(slot) { items += kit.text(v, UIRect(t, vx, vy), MenuKit.Style(t.height, halo: nil, just: 1), clip: false) }
        }
        out += quads(items)
        let icons = iconSheet("morale.34")
        for (slot, v, word) in [("Morale", morale, "morale"), ("Luck", luck, "luck")] {
            guard let t = l(slot), let ic = icons["\(v) \(word)"] else { continue }
            out.append(Quad(texture: uiTexture("moraleicon|\(ic.name)", { ic.bitmap }), x: vx + t.x + (t.width - ic.width) / 2, y: vy + t.y + (t.height - ic.height) / 2, w: ic.width, h: ic.height))
        }
        let rows = [l("skill_1")] + (2...5).map { l("skill_row_\($0)") }
        for (r, ids) in skillRows(h).prefix(5).enumerated() {
            guard let row = rows[r], let first = l("skill_1"), let second = l("skill_2") else { continue }
            for (k, id) in ids.prefix(4).enumerated() {
                let x = vx + first.x + k * (second.x - first.x), y = vy + row.y
                for s in skillIcon(id, level: h.skill(id: id)) { out.append(Quad(texture: uiTexture("skillicon|\(s.name)|\(id)", { s.bitmap }), x: x + s.x, y: y + s.y, w: s.width, h: s.height)) }
            }
        }
        return out
    }

    private func overviewTowns(_ ko: KingdomOverview, _ vx: Int, _ vy: Int) -> [Quad] {
        guard let g = game, let ui = ui, let kit = kit, let d = overviewLayout("Town_List") else { return [] }
        func l(_ n: String) -> UILayer? { MenuKit.find(d, n) }
        let tag = "Kingdom_Overview.Town_List"
        var out: [Quad] = []
        for (row, t) in g.towns.filter({ $0.owned }).dropFirst(ko.scroll).prefix(3).enumerated() {
            let rx = vx, ry = vy + row * 152
            if let list = l("Town_list"), let card = ui.tinyCard(t.alignment) {
                let terrain = TownScreen.terrainNames[t.terrain] ?? "grass"
                if let bg = card.layers.first(where: { $0.name.lowercased() == terrain }) ?? card["grass"] {
                    out.append(Quad(texture: uiTexture("tiny|\(t.alignment)|\(bg.name)", { bg.bitmap }), x: rx + list.x + bg.x, y: ry + list.y + bg.y, w: bg.width, h: bg.height))
                }
                let walls = t.buildings.contains("castle") ? "Castle" : t.buildings.contains("citadel") ? "Citadel" : t.buildings.contains("fort") ? "Fort" : "Village"
                if let w = card[walls] { out.append(Quad(texture: uiTexture("tiny|\(t.alignment)|\(walls)", { w.bitmap }), x: rx + list.x + w.x, y: ry + list.y + w.y, w: w.width, h: w.height)) }
            }
            var items: [UIItem] = []
            if t.builtToday { items += kit.image(l("Built"), tag, rx, ry) }
            for n in ["Gold", "Gold_Scroll", "Garrison_Scroll", "Hire_Scroll", "Ring_Background"] { items += kit.image(l(n), tag, rx, ry) }
            if let s = l("Gold_Text") { items += kit.text("\(g.hallIncome(t))", UIRect(s, rx, ry), MenuKit.Style(18, halo: nil, just: 1), clip: false) }
            if let s = l("Garrison_Text") { items += kit.text(kit.t("kingdom_overview_garrison.misc", "Garrison"), UIRect(s, rx, ry), MenuKit.Style(s.height / 2, halo: nil, just: 1, vcentre: true), clip: false) }
            if let s = l("Hire_Text") { items += kit.text(kit.t("kingdom_overview_hire.misc", "Creatures for Hire"), UIRect(s, rx, ry), MenuKit.Style(s.height / 2, halo: nil, just: 1, vcentre: true), clip: false) }
            out += quads(items)
            let garrison: [(UILayer?, String?, Bool)] = t.garrisonHeroes.map { (ui.portrait(keyword: $0.keyword, alignment: $0.alignment), nil, true) } + t.garrison.map { (ui.creatureIcon($0.creature), String($0.count), false) }
            if let gr = l("Garrison_Rings") { out += overviewRingRow(garrison, x: rx + gr.x + 14, y: ry + gr.y) }
            let hire: [(UILayer?, String?, Bool)] = t.available.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { (ui.creatureIcon($0.key), String($0.value), false) }
            if let hr = l("Hire_Rings") { out += overviewRingRow(hire, x: rx + hr.x + 14, y: ry + hr.y) }
        }
        return out
    }

    /// A click with the overview open: the list tabs, a hero row, the scrollbar, Close, or outside.
    func overviewClick(x: Float, y: Float) {
        guard var ko = overview, let kit = kit, let d = overviewLayout("Layout") else { overview = nil; return }
        let (ox, oy) = overviewOrigin
        func l(_ n: String) -> UILayer? { MenuKit.find(d, n) }
        for (name, mode) in Renderer.overviewTabs where inside(l("\(name)_Released"), at: ox, oy, x, y) {
            ko.mode = mode; ko.scroll = 0; overview = ko; sound?.play("miscellaneous.button"); return
        }
        if let c = l("Close_Button"), UIRect(ox + c.x, oy + c.y, 76, 44).contains(x, y) { overview = nil; sound?.play("miscellaneous.button"); return }
        if x < Float(ox) || x >= Float(ox + 800) || y < Float(oy) || y >= Float(oy + 600) { overview = nil; return }
        if let s = l("Scrollbar"), let dir = kit.vScrollbarHit(ox + s.x, oy + s.y, s.height, x, y) {
            let (n, page) = overviewCount(ko.mode)
            ko.scroll = max(0, min(max(0, n - page), ko.scroll + dir))
        } else if ko.mode == .heroes, let views = l("Views"), let hl = overviewLayout("Hero_List") {
            for row in 0..<5 {
                guard let r = MenuKit.find(hl, "Hero_\(row + 1)") else { continue }
                if inside(r, at: ox + views.x, oy + views.y, x, y), ko.scroll + row < kingdomHeroes.count { ko.selectedHero = ko.scroll + row }
            }
        }
        overview = ko
    }
}
