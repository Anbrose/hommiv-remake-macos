import Foundation
import H4Engine

/// t_army_info_window (heroes4.exe 0x53a1c0; re/town_popup_spec.md §3): one window for the right
/// click of every creature array -- armies, town garrisons, garrisons, wandering stacks -- the
/// content gated by the information level L (GameState.infoLevel, 0x4faf40: 4 own or allied,
/// else the Scouting of a hero in range, -1 none): layers.dialog.army_right_click's Background,
/// the stat icons, morale/luck (icons.morale.34), the skill or ability icons at Skill_k's corner
/// under Skills_Frame, the texts (numbers from L 3), OK (button.ok at Close_Button's corner),
/// Army or Town only for L 4, and the ring row of style 0 (Left, Middle ×5, Right from (13,51))
/// with the array's seven places and their counts in number_text (exact from L 1, else words).
extension Renderer {
    enum ArmyMember { case hero(Hero), stack(CreatureDef, Int) }
    static let armyInfoOrigin = ((AdventureUI.width - 464) / 2, (AdventureUI.height - 494) / 2)
    /// The ring row's portrait places (52x52 top-lefts) relative to the window.
    static let armyInfoPortraits: [(Int, Int)] = (0..<7).map { ($0 == 6 ? 386 : 28 + 60 * $0, 65) }

    /// A text window: font, left or centred, top-aligned, black, with or without the halo.
    func infoText(_ s: String, _ l: UILayer?, size: Int, centre: Bool, halo: Bool, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let ui = ui, let l = l, !s.isEmpty else { return [] }
        let f = ui.font(size)
        var out: [Quad] = []
        for (k, line) in s.components(separatedBy: "\n").enumerated() where !line.isEmpty {
            let w = f.measure(line)
            let x = centre ? l.x + (l.width - w) / 2 : l.x
            out.append(Quad(texture: uiTexture((halo ? "atext|" : "ntext|") + "\(size)|\(line)", { halo ? f.render(line, colour: (0, 0, 0), halo: Renderer.armyHalo) : f.render(line, colour: (0, 0, 0)) }),
                            x: ox + x, y: oy + l.y + k * f.lineHeight, w: w, h: f.size))
        }
        return out
    }

    /// `slots`: the array's seven places (nil = empty); `selected`: the place shown below;
    /// `army`: the army whose movement is shown; `button`: Army_Released / Town_Released (level 4).
    func armyInfoQuads(slots members: [ArmyMember?], level L: Int, title: String, selected: Int?, army owner: Hero?, moraleAlignment: String?, button: String?) -> [Quad] {
        guard let ui = ui, let g = game, let d = ui.dialog("army_right_click") else { return [] }
        let (ox, oy) = Renderer.armyInfoOrigin
        var out = layoutImage(d, "Background", ox, oy)
        for n in ["Damage", "Melee_Attack", "Melee_Defense", "Hit_Points"] { out += layoutImage(d, n, ox, oy) }
        let sel = selected.flatMap { members.indices.contains($0) ? members[$0] : nil }
        // morale and luck (values only from L 3)
        var morale = 0, luck = 0
        // (the army's leader's alignment; a heroless array: the shown member's own [I])
        let shownAlignment: String? = { switch sel { case .hero(let h)?: return h.alignment; case .stack(let c, _)?: return c.alignment; case nil: return nil } }()
        if L >= 3, let own = moraleAlignment ?? shownAlignment {
            var heroes: [Hero] = [], army: [(alignment: String, undead: Bool)] = []
            for m in members {
                switch m {
                case .hero(let h)?: heroes.append(h); army.append((h.alignment, false))
                case .stack(let c, _)?: army.append((c.alignment, Combatant(creature: c, count: 1).has("undead")))
                case nil: break
                }
            }
            morale = max(-10, min(10, Battle.armyMorale(own: own, army: army)))
            luck = max(-10, min(10, ArmyBonuses(heroes: heroes).luck))
        }
        let icons = iconSheet("morale.34")
        func mood(_ slot: String, _ v: Int, _ word: String) {
            guard let l = d[slot], let ic = icons["\(v) \(word)"] else { return }
            out.append(Quad(texture: uiTexture("moraleicon|\(ic.name)", { ic.bitmap }), x: ox + l.x, y: oy + l.y + ((l.height - ic.height) >> 1), w: ic.width, h: ic.height))
        }
        mood("Morale", morale, "morale")
        for n in ["Speed", "Movement", "Ranged_Attack", "Ranged_Defense", "Shots", "Spell_Points"] { out += layoutImage(d, n, ox, oy) }
        mood("Luck", luck, "luck")
        out += layoutImage(d, "Experience", ox, oy)
        // skills (a hero, L ≥ 3) or abilities (a creature, always), then the frame over them
        var skillIcons: [[UILayer]] = []
        switch sel {
        case .hero(let h)? where L >= 3: skillIcons = (0..<9).filter { h.skill(id: $0) > 0 }.prefix(5).map { skillIcon($0, level: h.skill(id: $0)) }
        case .stack(let c, _)?:
            let sheet = iconSheet("skills.creature.52")
            skillIcons = armyInfoAbilities(c.keyword).compactMap { sheet[$0.lowercased()].map { [$0] } }
        default: break
        }
        for (k, ls) in skillIcons.enumerated() {
            guard let slot = d["Skill_\(k + 1)"] else { continue }
            for l in ls { out.append(Quad(texture: uiTexture("skillicon|\(l.name)|\(k)|\(l.width)", { l.bitmap }), x: ox + slot.x + l.x, y: oy + slot.y + l.y, w: l.width, h: l.height)) }
        }
        out += layoutImage(d, "Skills_Frame", ox, oy)
        // texts
        func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        out += infoText(title, d["Title"], size: 27, centre: true, halo: true, ox, oy)
        switch sel {
        case .hero(let h)?:
            out += infoText(classLine(h), d["Level"], size: 16, centre: false, halo: true, ox, oy)
            out += infoText(cap(h.alignment), d["Alignment"], size: 16, centre: false, halo: true, ox, oy)
            if L >= 3 {
                let s = g.heroStats(h)
                var v: [(String, String, Int)] = [("Damage_Text", s.damage, 14), ("Melee_Attack_Text", "\(s.attack)", 16), ("Melee_Defense_Text", "\(s.defense)", 16),
                    ("Hit_Points_Text", "\(s.hitPoints)", 16), ("Speed_Text", "\(s.speed)", 16), ("Shots_Text", s.shots > 0 ? " \(s.shots) " : "N/A", 16),
                    ("Ranged_Attack_Text", s.shots > 0 ? "\(s.ranged)" : "N/A", 16), ("Ranged_Defense_Text", "\(s.defense)", 16), ("Spell_Points_Text", "\(g.spellPoints(h))", 16),
                    ("Experience_Text", Renderer.grouped(h.experience), 14), ("Morale_Text", morale > 0 ? "+\(morale)" : "\(morale)", 16), ("Luck_Text", luck > 0 ? "+\(luck)" : "\(luck)", 16)]
                if let o = owner { v.append(("Movement_Text", "\(Int(o.movement))\n(\(Int(o.maxMovement)))", 16)) }
                for (slot, t, size) in v { out += infoText(t, d[slot], size: size, centre: true, halo: false, ox, oy) }
            }
        case .stack(let c, let n)?:
            out += infoText(cap(L < 1 || n != 1 ? c.plural : c.name), d["Level"], size: 16, centre: false, halo: true, ox, oy)
            out += infoText(cap(c.alignment), d["Alignment"], size: 16, centre: false, halo: true, ox, oy)
            if L >= 3 {
                let v: [(String, String, Int)] = [("Damage_Text", "\(c.damageLow)-\(c.damageHigh)", 14), ("Melee_Attack_Text", "\(c.attack)", 16), ("Melee_Defense_Text", "\(c.defense)", 16),
                    ("Hit_Points_Text", "\(c.hitPoints)", 16), ("Speed_Text", "\(c.speed)", 16), ("Movement_Text", "\(c.move)\n(\(c.move))", 16),
                    ("Shots_Text", c.shots > 0 ? " \(c.shots) " : "N/A", 16), ("Ranged_Attack_Text", c.shots > 0 ? "\(c.attack)" : "N/A", 16),
                    ("Ranged_Defense_Text", "\(c.defense)", 16), ("Spell_Points_Text", "\(c.spellPoints)", 16),
                    ("Morale_Text", morale > 0 ? "+\(morale)" : "\(morale)", 16), ("Luck_Text", luck > 0 ? "+\(luck)" : "\(luck)", 16)]
                for (slot, t, size) in v { out += infoText(t, d[slot], size: size, centre: true, halo: false, ox, oy) }
            }
        case nil: break
        }
        // buttons
        out += buttonAt("ok", "Released", d["Close_Button"], ox, oy)
        if let b = button { out += layoutImage(d, b, ox, oy).button() }
        // the ring row: portrait, piece (or its highlight) over it, the count
        let strings = g.tables?.strings ?? [:]
        var cursor = 13
        for k in 0..<7 {
            let name = k == 0 ? "Left" : k == 6 ? "Right" : "Middle"
            guard let p = ui.creatureRing(name) else { continue }
            let wx = ox + cursor - p.x, wy = oy + 51 - p.y   // the piece's window origin
            let (px, py) = Renderer.armyInfoPortraits[k]
            var count = ""
            if k < members.count, let m = members[k] {
                switch m {
                case .hero(let h):
                    if let pic = ui.portrait(keyword: h.keyword, alignment: h.alignment) { out.append(Quad(texture: uiTexture("icon|\(pic.name)", { pic.bitmap }), x: ox + px, y: oy + py, w: pic.width, h: pic.height)) }
                case .stack(let c, let n):
                    if let pic = ui.creatureIcon(c.keyword) { out.append(Quad(texture: uiTexture("icon|\(pic.name)", { pic.bitmap }), x: ox + px, y: oy + py, w: pic.width, h: pic.height)) }
                    count = L >= 1 ? "\(n) " : Renderer.armySizeWord(n, strings)
                }
            }
            let piece = (k == selected ? ui.creatureRing(name + "_Highlight") : nil) ?? p
            out.append(Quad(texture: uiTexture("cring|\(piece.name)", { piece.bitmap }), x: wx + piece.x, y: wy + piece.y, w: piece.width, h: piece.height))
            if !count.isEmpty, let nt = ui.creatureRing("number_text") {
                let box = UILayer(name: "", kind: 1, x: wx - ox + nt.x, y: wy - oy + nt.y, width: nt.width, height: nt.height, bitmap: Bitmap(width: 1, height: 1))
                out += infoText(count, box, size: L >= 1 ? 25 : 12, centre: true, halo: true, ox, oy)
            }
            cursor += p.width
        }
        return out
    }

    /// Which ring slot a point is on (the portrait places).
    func armyInfoSlot(x: Float, y: Float) -> Int? {
        let (ox, oy) = Renderer.armyInfoOrigin
        return Renderer.armyInfoPortraits.firstIndex { x >= Float(ox + $0.0) && x < Float(ox + $0.0 + 52) && y >= Float(oy + $0.1) && y < Float(oy + $0.1 + 52) }
    }
}
