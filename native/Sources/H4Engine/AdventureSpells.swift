import Foundation

/// Spells cast on the adventure map (the Adventure-flag spells of table.Spells).
extension GameState {
    /// Adventure spells the hero knows and can cast now (school skill, spell points).
    public func adventureSpells(_ h: Hero) -> [Int] {
        let items = h.artifactSpells
        return h.spells.union(items.withSkill).union(items.free).filter { sp in
            sp < RuleTables.spells.count && RuleTables.spells[sp].has("Adv") && (h.canLearn(sp) || items.free.contains(sp)) && h.spellCost(sp) <= spellPoints(h)
        }.sorted()
    }
    public func castAdventureSpell(_ spell: Int, by h: Hero) {
        guard adventureSpells(h).contains(spell) else { return }
        let s = RuleTables.spells[spell]
        h.spellPoints = spellPoints(h) - h.spellCost(spell)
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
        case 158: if !summonBoat(h) { h.spellPoints = spellPoints(h) + h.spellCost(spell) }   // no ship: nothing spent
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

/// Mage guilds (heroes4.exe 0x89b010): each town draws its spells when the game starts from its
/// own school and the two next to it on the wheel life-order-death-chaos-nature -- per guild level
/// 1...5 its own 3/3/2/2/1 and each neighbour's 2/2/2/1/1 -- a High Priority spell first, then the
/// spells other towns use least, at random. A hero in the town learns every spell of the guild
/// levels built that the school skill allows (0x72db40), free.
extension GameState {
    public func setupGuilds() {
        let wheel = ["life", "order", "death", "chaos", "nature"]
        var used = [Int](repeating: 0, count: RuleTables.spells.count)
        for i in towns.indices {
            guard let own = wheel.firstIndex(of: towns[i].alignment) else { continue }   // might: no guild
            var levels = [[Int]](repeating: [], count: 5)
            for lv in 1...5 {
                for (school, rel) in [(own, 0), ((own + 1) % 5, 1), ((own + 4) % 5, 1)] {
                    var quota = rel == 0 ? [3, 3, 2, 2, 1][lv - 1] : [2, 2, 2, 1, 1][lv - 1]
                    let cands = RuleTables.spells.indices.filter { RuleTables.spells[$0].school == wheel[school] && RuleTables.spells[$0].level == lv && RuleTables.spells[$0].has("Teach") }
                    var chosen: [Int] = []
                    let hi = cands.filter { RuleTables.spells[$0].has("HiPri") }
                    if quota > 0, !hi.isEmpty { let s = hi[rng(hi.count)]; chosen.append(s); used[s] += 1; quota -= 1 }
                    while quota > 0 {
                        let left = cands.filter { !chosen.contains($0) }
                        guard let least = left.map({ used[$0] }).min() else { break }
                        let pool = left.filter { used[$0] == least }
                        let s = pool[rng(pool.count)]; chosen.append(s); used[s] += 1; quota -= 1
                    }
                    levels[lv - 1] += chosen
                }
            }
            towns[i].guildSpells = levels
        }
    }
    /// The spells of the guild levels the town has built.
    public func guildSpells(_ t: Town) -> [Int] {
        (1...5).filter { t.buildings.contains("mage guild \($0)") }.flatMap { t.guildSpells.count >= $0 ? t.guildSpells[$0 - 1] : [] }
    }
    /// A hero in a town learns what its guild teaches him.
    @discardableResult
    public func learnFromGuild(_ h: Hero, town i: Int) -> [Int] {
        var learned: [Int] = []
        for hh in [h] + h.companions {
            for s in guildSpells(towns[i]) where !hh.spells.contains(s) && hh.canLearn(s) { hh.spells.insert(s); learned.append(s) }
        }
        if !learned.isEmpty { log.append("learned " + Set(learned).map { RuleTables.spells[$0].name }.sorted().joined(separator: ", ")) }
        return learned
    }
}

extension GameState {
    /// Drink a potion from the backpack on the map: its spell on the hero, free; the potion is gone.
    @discardableResult
    public func drink(_ h: Hero, backpackIndex k: Int) -> Bool {
        guard h.backpack.indices.contains(k), let e = RuleTables.effects(ofArtifact: h.backpack[k]).first(where: { $0.type == 0x2e }),
              e.spell >= 0, e.spell < RuleTables.spells.count, RuleTables.spells[e.spell].has("Adv") else { return false }
        let name = artifactName(h.backpack[k])
        h.backpack.remove(at: k)
        let saved = h.spellPoints
        h.spellPoints = spellPoints(h) + h.spellCost(e.spell)   // the potion pays for itself
        h.spells.insert(e.spell)
        castAdventureSpell(e.spell, by: h)
        if e.spell != 76 { h.spellPoints = saved }
        log.append("\(h.name) drinks \(name)")
        return true
    }
}
