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
    func castlePanels(_ d: LayerFile, count: Int) -> [UILayer] {
        var out: [UILayer] = []
        for k in 0..<min(5, count) {
            let name = k < 3 ? "Monster_\(k + 1)" : "Monster_\(k + 1)_of_5"
            if let l = d[name] { out.append(l) }
        }
        return out
    }

    func castleQuads() -> [Quad] {
        guard let g = game, let ui = ui, let i = townOpen, let d = ui.dialog("Castle_Screen"), let tables = g.tables else { return [] }
        let (ox, oy) = castleOrigin
        let panelLayers: Set<String> = ["Abilities_Frame", "Ability_1", "Ability_2", "Ability_3", "Ability_4", "Animation", "Blank_Background", "Creature_Background",
                                        "Damage", "Hit_Points", "Melee_Attack", "Melee_Defense", "Movement", "Ranged_Attack", "Ranged_Defense", "Shots", "Speed"]
        var out = dialogImages(d, key: "castle", at: ox, oy, skip: panelLayers.union(["close_button", "purchase_all_button"]).union(d.layers.map(\.name).filter { $0.hasPrefix("Monster_") || $0.hasPrefix("Resource_") && $0 != "Resource_layer" }))
        let creatures = castleCreatures()
        let panels = castlePanels(d, count: creatures.count)
        let base = d["Monster_1"].map { ($0.x, $0.y) } ?? (6, 4)
        // the empty places (up to five)
        let allPlaces = ["Monster_1", "Monster_2", "Monster_3", "Monster_4_of_5", "Monster_5_of_5"].compactMap { d[$0] }
        for p in allPlaces.dropFirst(panels.count) {
            if let bl = d["Blank_Background"] { out.append(Quad(texture: uiTexture("dlg|castle|blank", { bl.bitmap }), x: ox + p.x + bl.x - base.0, y: oy + p.y + bl.y - base.1, w: bl.width, h: bl.height)) }
        }
        let skills = iconSheet("skills.creature.52")
        for (k, c) in creatures.enumerated() where k < panels.count {
            guard let def = tables.creature(c) else { continue }
            let px = ox + panels[k].x - base.0, py = oy + panels[k].y - base.1
            for n in ["Creature_Background", "Abilities_Frame", "Damage", "Hit_Points", "Melee_Attack", "Melee_Defense", "Movement", "Ranged_Attack", "Ranged_Defense", "Shots", "Speed"] {
                guard let l = d[n] else { continue }
                out.append(Quad(texture: uiTexture("dlg|castle|\(n)", { l.bitmap }), x: px + l.x, y: py + l.y, w: l.width, h: l.height))
            }
            if let a = d["Animation"], let icon = ui.creatureIcon(c, size: 82) {
                out.append(Quad(texture: uiTexture("cicon82|\(c)", { icon.bitmap }), x: px + a.x + (a.width - icon.width) / 2, y: py + a.y + (a.height - icon.height) / 2, w: icon.width, h: icon.height))
            }
            let n = g.towns[i].available[c] ?? 0
            func at(_ name: String) -> UILayer? { d[name] ?? d.layers.first { $0.name.lowercased() == name.lowercased() } }
            func shifted(_ l: UILayer?) -> UILayer? { l.map { UILayer(name: $0.name, kind: 1, x: $0.x + px - ox, y: $0.y + py - oy, width: $0.width, height: $0.height, bitmap: Bitmap(width: 1, height: 1)) } }
            out += centred("\(n) \(n == 1 ? def.name : def.plural)", in: shifted(at("Creature_Name")), at: ox, oy, font: ui.numberFont)
            out += centred((g.tables?.strings["weekly_growth.castle_window"] ?? "Growth:  %number").replacingOccurrences(of: "%number", with: "\(def.growth)"), in: shifted(at("Creature_Growth")), at: ox, oy, font: ui.numberFont)
            let ranged = def.shots > 0
            let values: [(String, String)] = [("Damage_Text", "\(def.damageLow)-\(def.damageHigh)"), ("Hit_Points_Text", "\(def.hitPoints)"), ("melee_attack_Text", "\(def.attack)"),
                                              ("Melee_Defense_Text", "\(def.defense)"), ("ranged_attack_Text", ranged ? "\(def.attack)" : "N/A"), ("Ranged_Defense_Text", "\(def.defense)"),
                                              ("Shots_Text", ranged ? "\(def.shots)" : "N/A"), ("Speed_Text", "\(def.speed)"), ("Movement_Text", "\(def.move)")]
            for (slot, v) in values { out += centred(v, in: shifted(at(slot)), at: ox, oy, font: ui.numberFont) }
            if let r = d["Resource_1"], let icon = materialIcon("Gold", size: 32) {
                out.append(Quad(texture: uiTexture("mat32|\(icon.name)", { icon.bitmap }), x: px + r.x + (r.width - icon.width) / 2, y: py + r.y + (r.height - icon.height) / 2, w: icon.width, h: icon.height))
                out += centred("\(def.gold)", in: shifted(at("Resource_1_Text")), at: ox, oy, font: ui.numberFont)
            }
            for (a, ab) in (RuleTables.creatureAbilities[c.lowercased()] ?? []).prefix(4).enumerated() {
                if let l = skills[ab.lowercased()], let slot = d["Ability_\(a + 1)"] {
                    out.append(Quad(texture: uiTexture("skill|\(ab)", { l.bitmap }), x: px + slot.x + (slot.width - l.width) / 2, y: py + slot.y + (slot.height - l.height) / 2, w: l.width, h: l.height))
                }
            }
        }
        for (r, key) in [("Gold", "text_gold"), ("Wood", "text_wood"), ("Ore", "text_ore"), ("Crystal", "text_crystal"), ("Sulfur", "text_sulfur"), ("Mercury", "text_mercury"), ("Gems", "text_gems")] {
            out += centred("\(g.resources[r] ?? 0)", in: d[key], at: ox, oy, font: ui.numberFont)
        }
        for (slot, name) in [("purchase_all_button", "max"), ("close_button", "close")] {
            guard let l = d[slot], let b = ui.button(name) ?? ui.button(name == "max" ? "buy" : name) else { continue }
            out.append(Quad(texture: uiTexture("button|\(b.name)|\(name)", { b.bitmap }), x: ox + l.x + (l.width - b.width) / 2, y: oy + l.y + (l.height - b.height) / 2, w: b.width, h: b.height))
        }
        return out
    }

    func castleClick(x: Float, y: Float) {
        guard let g = game, let i = townOpen, let d = ui?.dialog("Castle_Screen"), let tables = g.tables else { townDialog = nil; return }
        let (ox, oy) = castleOrigin
        if inside(d["close_button"], at: ox, oy, x, y) { townDialog = nil; return }
        let creatures = castleCreatures()
        if inside(d["purchase_all_button"], at: ox, oy, x, y) {
            // Buy All (0x5c6d00): what can be afforded of every dwelling, with room in the garrison;
            // the list is shown to confirm ("Do you want to recruit these creatures?")
            var gold = g.resources["Gold", default: 0], room = GameState.rowSlots - g.garrisonCount(i)
            var plan: [(String, Int)] = []
            var short = "", total = 0
            for c in creatures {
                guard let def = tables.creature(c), let have = g.towns[i].available[c], have > 0 else { continue }
                let n = min(have, def.gold > 0 ? gold / def.gold : have)
                if n <= 0 { short = "not_enough_resources"; continue }
                if !g.towns[i].garrison.contains(where: { $0.creature == c }) && !plan.contains(where: { $0.0 == c }) {
                    if room <= 0 { short = "not_enough_slots"; continue }
                    room -= 1
                }
                plan.append((c, n)); gold -= n * def.gold; total += n * def.gold
            }
            let strings = g.tables?.strings ?? [:]
            if plan.isEmpty {
                let key = short.isEmpty ? "not_enough_creatures" : short
                prompt = (strings["\(key).castle_window"] ?? "You cannot recruit any creatures.", false, nil)
                return
            }
            let lines = plan.map { c, n in "\(n) \(n == 1 ? tables.creature(c)?.name ?? c : tables.creature(c)?.plural ?? c)" }
            let text = (strings["recruit_creatures.castle_window"] ?? "Do you want to recruit these creatures?") + "\n\n" + lines.joined(separator: ", ") + "\n\n\(total) gold"
            prompt = (text, true, { [weak self] in
                guard let self = self, let g = self.game else { return }
                for (c, n) in plan {
                    guard let def = tables.creature(c), g.addToGarrison(i, c, n) else { continue }
                    g.towns[i].available[c, default: 0] -= n; g.resources["Gold", default: 0] -= n * def.gold
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
            let most = min(g.towns[i].available[c] ?? 0, def.gold > 0 ? g.resources["Gold", default: 0] / def.gold : 99)
            townDialog = .recruit(creature: c, count: most)
            return
        }
    }
}
