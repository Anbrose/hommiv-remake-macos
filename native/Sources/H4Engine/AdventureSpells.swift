import Foundation

/// Spells cast on the adventure map (the Adventure-flag spells of table.Spells).
extension GameState {
    /// Adventure spells the hero knows and can cast now (school skill, spell points).
    public func adventureSpells(_ h: Hero) -> [Int] {
        h.spells.filter { sp in
            sp < RuleTables.spells.count && RuleTables.spells[sp].has("Adv") && h.canLearn(sp) && RuleTables.spells[sp].cost <= spellPoints(h)
        }.sorted()
    }
    public func castAdventureSpell(_ spell: Int, by h: Hero) {
        guard adventureSpells(h).contains(spell) else { return }
        let s = RuleTables.spells[spell]
        h.spellPoints = spellPoints(h) - s.cost
        sounds.append("spell.\(s.keyword)")
        switch spell {
        case 181:   // Town Gate: to the nearest own town
            if let t = retreatTown(for: h), let p = scenes[towns[t].z].placed.first(where: { $0.category == "castle" && $0.cellX == towns[t].x && $0.cellY == towns[t].y }) {
                level = towns[t].z
                let gate = gateCells(p).first { passability.isFree($0.0, $0.1) } ?? gateCells(p)[0]
                h.x = gate.0; h.y = gate.1; h.z = level; h.path = []; h.plan = []; h.target = nil
                jumped = true
            }
        case 108: h.timedEffects["spell.pathfinding"] = 1           // no terrain penalty today
        case 132: h.movement += h.maxMovement * 0.3                  // Endurance ("by 30") [G: read as 30%]
        case 70: h.armyLuck["spell.luck"] = 10                       // maximum luck until the next battle
        case 103: h.armyMorale["spell.morale"] = 10
        case 76: h.spellPoints = spellPoints(h) + 25
        case 57: h.fountainEffects.insert("vigor")
        case 153: h.fountainEffects.insert("strength")
        case 146: h.fountainEffects.insert("speed")
        default:
            log.append("\(s.name) has no effect here yet")
        }
        floaters.append((s.name, h.x, h.y))
    }
}
