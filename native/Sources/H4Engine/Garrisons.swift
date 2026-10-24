import Foundation

/// Garrisons (t_adv_garrison, objects_spec "garrison"): a wall with a gate held by troops. The
/// gate stops an army (0x442a90, path types 0, 2, 4, 5) while the garrison has troops and is
/// neither the army's owner's nor an ally's (the same team; a garrison or army with no owner is
/// nobody's ally): routes end on it and the walk stops before it (the walk list checks type 4,
/// 0x544252), the garrison then used from the cell before (0x4423f0): the troops fought, a win
/// takes it (0x442710: the owner becomes the attacker's; it stays outside). An empty foreign
/// one is taken when visited (0x442860); an own or allied one only opens. Stepping onto the
/// gate triggers nothing (vtable+0x9c = 0x40c030). The computer plans with type 7, which no
/// garrison stops, so its route may lead through a gate its walk then stops before.
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
        if garrisonStops(st, for: map.humanColour) { for c in st.gate { passability.setStop(c / n, c % n, true) } }
    }
    /// The garrison's owner and the army's are one side (0x4423f0 / 0x442a90: the same owner, or
    /// both owned and of one team).
    func garrisonFriendly(_ st: ObjectState, to colour: Int?) -> Bool {
        st.garrisonOwner == colour || (st.garrisonOwner != nil && colour != nil && team(of: st.garrisonOwner!) == team(of: colour!))
    }
    /// The gate stops an army of this colour (0x442a90): troops in it (0x63fcb0) and not its side's.
    public func garrisonStops(_ st: ObjectState, for colour: Int?) -> Bool {
        st.isGarrison && st.troopCounts.contains { $0 > 0 } && !garrisonFriendly(st, to: colour)
    }
    /// Held against the player.
    public func garrisonHostile(_ st: ObjectState) -> Bool { garrisonStops(st, for: map.humanColour) }
    /// Shut or open every garrison's gate for an army of this colour (nil: the computer's planner,
    /// type 7, which no gate stops); the player's view is the standing one.
    func applyGarrisonGates(for colour: Int?, planner: Bool = false) {
        for (k, st) in objectStates where st.isGarrison {
            let c = k.split(separator: "|").compactMap { Int($0) }
            guard c.count == 3, c[0] < passabilities.count else { continue }
            let stop = !planner && garrisonStops(st, for: colour)
            for g in st.gate { passabilities[c[0]].setStop(g / map.size, g % map.size, stop) }
        }
    }
    /// The garrison whose gate the cell is, on level z (its object key).
    func garrisonGate(at c: (x: Int, y: Int), z: Int) -> String? {
        let k = c.x * map.size + c.y
        return objectStates.first { key, st in st.isGarrison && key.hasPrefix("\(z)|") && st.gate.contains(k) }?.key
    }
    /// A computer army may step onto the cell: free, or a gate (the player's view of it aside;
    /// whether it stops the army is the walk's own test) with no army on it.
    func aiVacant(_ c: (x: Int, y: Int), for h: Hero) -> Bool {
        if h.boat == nil, garrisonGate(at: c, z: h.z) != nil { return !heroes.contains { $0 !== h && $0.z == h.z && standingCell($0) == (c.x, c.y) } }
        return isVacant((c.x, c.y), for: h)
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
        } else if !garrisonFriendly(st, to: hero.owner) {
            takeGarrison(key, by: hero.owner)   // (0x442860: an own or allied one only opens)
        }
    }
    /// The army's owner holds it now (0x442710 / 0x442860): the troops gone, the gate as the
    /// player sees it.
    func takeGarrison(_ key: String, by colour: Int? = nil) {
        guard var st = objectStates[key] else { return }
        st.garrisonOwner = colour ?? map.humanColour
        st.troopCounts = st.troopCounts.map { _ in 0 }
        objectStates[key] = st
        let c = key.split(separator: "|").compactMap { Int($0) }
        if c.count == 3, c[0] < passabilities.count { for g in st.gate { passabilities[c[0]].setStop(g / map.size, g % map.size, garrisonHostile(st)) } }
        visionChanged = true
    }

    /// A computer army's walk stopped before a garrison's gate (the walk list's type-4 stop): the
    /// garrison is used from there (0x4423f0) -- its troops fought, resolved at once as the
    /// computer's other fights are (AI.swift); a win takes it, a loss leaves the survivors in it.
    func aiAttackGarrison(_ h: Hero, _ key: String) {
        guard let st = objectStates[key], garrisonStops(st, for: h.owner) else { return }
        let t = tables
        let defenders = zip(st.troopCreatures, st.troopCounts).filter { $0.1 > 0 }.compactMap { c, n in t?.creature(c).map { Combatant(creature: $0, count: n) } }
        let r = QuickCombat.fight(attackers: combatants(of: h), defenders: defenders, seed: day * 31 + key.split(separator: "|").compactMap { Int($0) }.reduce(0, +))
        func keyword(_ name: String) -> String { t?.creatures.first { $0.name == name }?.keyword ?? name }
        h.army = r.attackers.filter { $0.alive && !$0.isHero }.map { Hero.Stack(creature: keyword($0.name), count: $0.count) }
        if r.attackerWon { takeGarrison(key, by: h.owner); return }
        var held = st
        let left = Dictionary(r.defenders.filter { $0.alive }.map { (keyword($0.name), $0.count) }, uniquingKeysWith: +)
        held.troopCounts = held.troopCreatures.map { left[$0] ?? 0 }
        objectStates[key] = held
        if heroes.contains(where: { $0 === h }) { heroes.removeAll { $0 === h } } else { removeEnemy(h) }
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
            for g in st.gate { passabilities[c[0]].setStop(g / map.size, g % map.size, garrisonHostile(st)) }
        }
    }
}
