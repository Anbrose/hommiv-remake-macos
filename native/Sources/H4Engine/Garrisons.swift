import Foundation

/// Garrisons (t_adv_garrison, objects_spec "garrison"): a wall with a gate held by troops. While a
/// colour other than the player's holds it with troops, its gate is shut to the player's armies
/// (route planning goes round it); visiting it means fighting the troops, and winning takes it
/// (the gate opens). An empty one is taken by walking up to it.
extension GameState {
    static let garrisonPrefix = "garrison|"

    /// Roll the troops (a count of 0: the creature's level budget, as for placed armies) and note
    /// the gate: the passable cells inside the footprint.
    func setupGarrison(_ p: MapScene.Placed, _ st: inout ObjectState) {
        let rec = record(for: p)
        st.isGarrison = true
        st.garrisonOwner = rec?.owner
        var rng = GameRandom(seed: p.cellX * 4481 + p.cellY * 7907)
        for case let (id, n)? in rec?.army ?? [] where id < RuleTables.creatureIds.count {
            guard let c = tables?.creature(RuleTables.creatureIds[id]) else { continue }
            var count = n
            if count <= 0 {
                let base = Double(GameState.monsterBudget[min(4, max(1, c.level))])
                count = max(1, (rng.next() % (Int(base * 0.4) + 1) + Int(base * 0.8)) / max(1, c.experience))
            }
            if let k = st.troopCreatures.firstIndex(of: c.keyword) { st.troopCounts[k] += count }
            else { st.troopCreatures.append(c.keyword); st.troopCounts.append(count) }
        }
        let n = map.size
        for dx in 0..<p.sprite.footprint.w { for dy in 0..<p.sprite.footprint.h where passability.isFree(p.cellX + dx, p.cellY + dy) {
            st.gate.append((p.cellX + dx) * n + p.cellY + dy)
        } }
        if garrisonHostile(st) { for c in st.gate { passability.block(c / n, c % n) } }
    }
    /// Held against the player: another colour (or nobody) with troops in it.
    public func garrisonHostile(_ st: ObjectState) -> Bool {
        st.isGarrison && st.garrisonOwner != map.humanColour && st.troopCounts.contains { $0 > 0 }
    }
    /// The troops as "25 pikemen, 10 archers".
    public func garrisonTroops(_ st: ObjectState) -> String {
        zip(st.troopCreatures, st.troopCounts).filter { $0.1 > 0 }.map { c, k in
            let d = tables?.creature(c); return "\(k) \(k == 1 ? d?.name ?? c : d?.plural ?? c)" }.joined(separator: ", ")
    }

    func visitGarrison(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        let key = objectKey(p)
        if garrisonHostile(st) {
            let stacks = zip(st.troopCreatures, st.troopCounts).filter { $0.1 > 0 }
            guard let lead = stacks.first else { return }
            var m = Monster(x: p.cellX, y: p.cellY, name: p.name, creature: lead.0, count: lead.1, extra: stacks.dropFirst().map { ($0.0, $0.1) })
            m.z = level; m.bank = GameState.garrisonPrefix + key
            monsters.append(m)
            fight(hero: hero, monsterAt: monsters.count - 1, p)
        } else if st.garrisonOwner != map.humanColour {
            takeGarrison(key)
        }
    }
    /// The player holds it now: the troops gone, the gate open.
    func takeGarrison(_ key: String) {
        guard var st = objectStates[key] else { return }
        st.garrisonOwner = map.humanColour
        st.troopCounts = st.troopCounts.map { _ in 0 }
        objectStates[key] = st
        let c = key.split(separator: "|").compactMap { Int($0) }
        if c.count == 3, c[0] < passabilities.count { for g in st.gate { passabilities[c[0]].free(g / map.size, g % map.size) } }
        sounds.append("miscellaneous.flag_mine")
        visionChanged = true
    }
    /// A lost attack: what is left of the lead stack stays (the others as they were).
    func garrisonHeld(_ key: String, leadLeft: Int) {
        guard var st = objectStates[key], let k = st.troopCounts.firstIndex(where: { $0 > 0 }) else { return }
        st.troopCounts[k] = max(1, leadLeft)
        objectStates[key] = st
    }
}

extension GameState {
    /// After loading: each garrison's gate shut or open as its holder and troops say.
    func reapplyGarrisons() {
        for (k, st) in objectStates where st.isGarrison {
            let c = k.split(separator: "|").compactMap { Int($0) }
            guard c.count == 3, c[0] < passabilities.count else { continue }
            for g in st.gate { if garrisonHostile(st) { passabilities[c[0]].block(g / map.size, g % map.size) } else { passabilities[c[0]].free(g / map.size, g % map.size) } }
        }
    }
}
