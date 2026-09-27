import Foundation
import H4Engine

/// The fort / citadel / castle's creature screen (t_castle_window 0x5c1a90, layers.dialog.Castle_Screen):
/// one panel per built dwelling (ids 12..19 in order; 3 across, then 2 centred below) with the
/// creature, how many wait and the weekly growth, its stats, cost and abilities; a panel opens
/// the recruit dialog for that creature (into the garrison); Buy All buys what can be afforded.
extension Renderer {
    var castleOrigin: (Int, Int) { ((AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2) }

    /// The built dwellings' creatures, in id order.
    func castleCreatures() -> [String] {
        guard let g = game, let i = townOpen else { return [] }
        let t = g.towns[i]
        return (12...19).compactMap { b -> String? in
            guard g.isBuiltPublic(t, b) else { return nil }
            return g.buildingDef(t, b)?.creature
        }
    }
    /// The places of the panels (0x5c1e56): Monster_1..3, then Monster_4/5_of_5 (of_6 with the portal).
    static let castlePlaces = ["Monster_1", "Monster_2", "Monster_3", "Monster_4_of_5", "Monster_5_of_5"]
    func castlePanels(_ d: LayerFile, count: Int) -> [UILayer] {
        Renderer.castlePlaces.prefix(min(5, count)).compactMap { d[$0] }
    }
    /// A panel's rect: its layout box moved by the place's offset d = Monster_k - Monster_1.
    func castleRect(_ d: LayerFile, _ name: String, _ dx: Int, _ dy: Int) -> DRect? { dRect(d, name).map { $0.offset(dx, dy) } }

    func castleQuads() -> [Quad] {
        guard let g = game, let ui = ui, let i = townOpen, let d = ui.dialog("Castle_Screen"), let tables = g.tables else { return [] }
        let (ox, oy) = castleOrigin
        var out = dImage(d, "castle", "Background", ox, oy)
        let creatures = castleCreatures()
        let base = d["Monster_1"].map { ($0.x, $0.y) } ?? (6, 4)
        let skills = iconSheet("skills.creature.52")
        let f12 = ui.font(12), f14 = ui.font(14)
        func t(_ s: String, _ r: DRect?, _ f: H4Font, v: Bool = false) { out += dText(s, r?.offset(ox, oy), font: f, centre: true, vcentre: v, 0, 0) }
        for (k, c) in creatures.enumerated() where k < 5 {
            guard let def = tables.creature(c), let place = d[Renderer.castlePlaces[k]] else { continue }
            let dx = place.x - base.0, dy = place.y - base.1
            out += dImage(d, "castle", "Creature_Background", ox, oy, dx: dx, dy: dy)
            // 0x5c3120 / 0x5c5c00: name, growth, the model, the stats, the costs, the abilities under their frame
            let n = g.towns[i].available[c] ?? 0
            t("\(n) \(n == 1 ? def.name : def.plural)", castleRect(d, "Creature_Name", dx, dy), f14, v: true)
            t(text("weekly_growth.castle_window", "Growth:  %number").replacingOccurrences(of: "%number", with: "\(townGrowth(i, c))"), castleRect(d, "Creature_Growth", dx, dy), f12, v: true)
            if let a = d["Animation"] { out += creatureModelQuads(c, box: UILayer(name: "", kind: 1, x: a.x + dx, y: a.y + dy, width: a.width, height: a.height, bitmap: Bitmap(width: 1, height: 1)), ox, oy) }
            let ab = Set(RuleTables.creatureAbilities[c.lowercased()] ?? [])
            let ranged = def.shots > 0
            let melee = ranged && !ab.contains("normal_melee") ? (def.attack + 1) / 2 : def.attack
            let defence = ab.contains("insubstantial") ? def.defense * 2 : def.defense
            let shots = ab.contains("unlimited_shots") ? "Inf" : ranged ? "\(def.shots)" : text("not_applicable.dialog", "N/A")
            let stats: [(String, String, String)] = [("Damage", "Damage_Text", "\(def.damageLow)-\(def.damageHigh)"), ("Melee_Attack", "melee_attack_Text", "\(melee)"),
                                                     ("Melee_Defense", "Melee_Defense_Text", "\(defence)"), ("Hit_Points", "Hit_Points_Text", "\(def.hitPoints)"),
                                                     ("Ranged_Attack", "ranged_attack_Text", "\(def.attack)"), ("Ranged_Defense", "Ranged_Defense_Text", "\(ab.contains("skeletal") ? defence * 2 : defence)"),
                                                     ("Shots", "Shots_Text", shots), ("Speed", "Speed_Text", "\(def.speed)"), ("Movement", "Movement_Text", "\(def.move)")]
            for (icon, slot, v) in stats {
                out += dImage(d, "castle", icon, ox, oy, dx: dx, dy: dy)
                t(v, castleRect(d, slot, dx, dy), f12)
            }
            for (j, (m, v)) in creatureCost(def).filter({ $0.1 != 0 }).prefix(3).enumerated() {
                if let r = castleRect(d, "Resource_\(j + 1)", dx, dy) { out += dImageOffset(materialIcon(m, size: 32), "mat32", x: ox + r.x, y: oy + r.y) }
                t("\(v)", castleRect(d, "Resource_\(j + 1)_Text", dx, dy), f12)
            }
            for (a, name) in (RuleTables.creatureAbilities[c.lowercased()] ?? []).prefix(4).enumerated() {
                guard let l = skills[name.lowercased()], let r = castleRect(d, "Ability_\(a + 1)", dx, dy) else { continue }
                out += dImageAt(l, "cskill", x: ox + r.x, y: oy + r.y)
            }
            out += dImage(d, "castle", "Abilities_Frame", ox, oy, dx: dx, dy: dy)
        }
        // the empty places after the panels
        for k in min(5, creatures.count)..<5 {
            guard let place = d[Renderer.castlePlaces[k]] else { continue }
            out += dImage(d, "castle", "Blank_Background", ox, oy, dx: place.x - base.0, dy: place.y - base.1)
        }
        out += dImage(d, "castle", "Resource_layer", ox, oy)
        for m in Renderer.townMaterials {
            guard let r = dRect(d, "text_\(m.lowercased())") else { continue }
            let f = ui.font(r.h)
            out += dText(Renderer.materialText(g.resources[m] ?? 0, font: f, width: r.w), r.offset(ox, oy), font: f, centre: true, 0, 0)
        }
        out += townButton("max", x: ox + 602, y: oy + 546)
        out += townButton("ok", x: ox + 712, y: oy + 546)
        return out
    }

    func castleClick(x: Float, y: Float) {
        guard let g = game, let i = townOpen, let d = ui?.dialog("Castle_Screen"), let tables = g.tables else { townDialog = nil; return }
        let (ox, oy) = castleOrigin
        if townButtonHit("ok", x: ox + 712, y: oy + 546, x, y) { townDialog = nil; return }
        let creatures = castleCreatures()
        if townButtonHit("max", x: ox + 602, y: oy + 546, x, y) {
            // Buy All (0x5c6d00): what can be afforded of every dwelling, with room in the garrison;
            // the list is shown to confirm ("Do you want to recruit these creatures?")
            var purse = g.resources, room = GameState.rowSlots - g.garrisonCount(i)
            var plan: [(String, Int)] = []
            var short = ""
            var total: [String: Int] = [:]
            for c in creatures {
                guard let def = tables.creature(c), let have = g.towns[i].available[c], have > 0 else { continue }
                var n = have
                for (m, v) in creatureCost(def) where v > 0 { n = min(n, (purse[m] ?? 0) / v) }
                if n <= 0 { short = "not_enough_resources"; continue }
                if !g.towns[i].garrison.contains(where: { $0.creature == c }) && !plan.contains(where: { $0.0 == c }) {
                    if room <= 0 { short = "not_enough_slots"; continue }
                    room -= 1
                }
                plan.append((c, n))
                for (m, v) in creatureCost(def) { purse[m, default: 0] -= v * n; total[m, default: 0] += v * n }
            }
            let strings = g.tables?.strings ?? [:]
            if plan.isEmpty {
                let key = short.isEmpty ? "not_enough_creatures" : short
                prompt = (strings["\(key).castle_window"] ?? "You cannot recruit any creatures.", false, nil)
                return
            }
            let lines = plan.map { c, n in "\(n) \(n == 1 ? tables.creature(c)?.name ?? c : tables.creature(c)?.plural ?? c)" }
            let price = Renderer.townMaterials.compactMap { m in total[m].flatMap { $0 > 0 ? "\($0) \(m.lowercased())" : nil } }.joined(separator: ", ")
            let text = (strings["recruit_creatures.castle_window"] ?? "Do you want to recruit these creatures?") + "\n\n" + lines.joined(separator: ", ") + "\n\n" + price
            prompt = (text, true, { [weak self] in
                guard let self = self, let g = self.game else { return }
                for (c, n) in plan {
                    guard let def = tables.creature(c), g.addToGarrison(i, c, n) else { continue }
                    g.towns[i].available[c, default: 0] -= n
                    for (m, v) in self.creatureCost(def) { g.resources[m, default: 0] -= v * n }
                }
                self.sound?.play("dialogue.recruit")
            })
            return
        }
        for (k, p) in castlePanels(d, count: creatures.count).enumerated() where inside(p, at: ox, oy, x, y) {
            let c = creatures[k]
            guard let def = tables.creature(c) else { return }
            // no room: a stack of theirs or a free slot is needed (0x8b1160)
            if !g.towns[i].garrison.contains(where: { $0.creature == c }) && g.garrisonCount(i) >= GameState.rowSlots {
                prompt = ((g.tables?.strings["no_room.town"] ?? "There is no room in your garrison to hire %creatures.").replacingOccurrences(of: "%creatures", with: def.plural), false, nil)
                return
            }
            townDialog = .recruit(creature: c, count: recruitMost(c), fromCastle: true)
            return
        }
    }
}
