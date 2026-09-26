import Foundation

/// A place in an army row: a hero (it takes a slot) or a creature stack.
public enum ArmySlot {
    case hero(Hero), stack(Hero.Stack)
    public var hero: Hero? { if case .hero(let h) = self { return h }; return nil }
    public var stack: Hero.Stack? { if case .stack(let s) = self { return s }; return nil }
}

/// The town screen's two rows (town_spec §4): the garrison (creatures and heroes stationed in the
/// town) above, the visiting army -- exactly the player's army on the gate cell, or a spare empty
/// one that becomes an army at the gate when the screen closes -- below; seven slots each.
extension GameState {
    public static let rowSlots = 7

    public func townPlaced(_ i: Int) -> MapScene.Placed? {
        guard i < towns.count, towns[i].z < scenes.count else { return nil }
        return scenes[towns[i].z].placed.first { $0.category == "castle" && $0.cellX == towns[i].x && $0.cellY == towns[i].y }
    }
    /// The player's army on the town's gate cell (not at sea) (0x8abe60).
    public func visitingArmy(town i: Int) -> Hero? {
        if let v = townVisitor, v.town == i, heroes.contains(where: { $0 === v.hero }) { return v.hero }
        guard let p = townPlaced(i) else { return nil }
        let back = level; level = towns[i].z; defer { level = back }
        let gates = gateCells(p)
        return heroes.first { h in h.z == towns[i].z && h.boat == nil && gates.contains { g in g == (h.x, h.y) } }
    }
    public func garrisonSlots(_ i: Int) -> [ArmySlot] {
        towns[i].garrisonHeroes.map { .hero($0) } + towns[i].garrison.map { .stack($0) }
    }
    public func armySlots(_ h: Hero) -> [ArmySlot] { ([h] + h.companions).map { .hero($0) } + h.army.map { .stack($0) } }

    public func setGarrison(_ i: Int, _ slots: [ArmySlot]) {
        towns[i].garrisonHeroes = slots.compactMap { $0.hero }
        towns[i].garrison = slots.compactMap { $0.stack }
    }
    /// Put a row back into the army: its first hero leads it (taking over the army's place on the
    /// map), an army left with nothing leaves the map. False when creatures would be left without
    /// a hero (armies here are led by one).
    @discardableResult
    public func setArmy(_ h: Hero, _ slots: [ArmySlot]) -> Bool {
        let hs = slots.compactMap { $0.hero }, stacks = slots.compactMap { $0.stack }
        guard let lead = hs.first else {
            if !stacks.isEmpty { return false }
            heroes.removeAll { $0 === h }
            return true
        }
        if lead !== h {
            lead.x = h.x; lead.y = h.y; lead.z = h.z; lead.facing = h.facing; lead.owner = h.owner
            lead.path = []; lead.plan = []; lead.target = nil
            if let k = heroes.firstIndex(where: { $0 === h }) { heroes[k] = lead } else { heroes.insert(lead, at: 0) }
            h.companions = []; h.army = []
        }
        lead.companions = Array(hs.dropFirst())
        lead.army = stacks
        lead.maxMovement = armyMovement(lead); lead.movement = min(lead.movement, lead.maxMovement)
        return true
    }

    /// A drop of slot `from` on slot `to` (0x646d40): the same creature merges (or takes `split`
    /// of them), an empty place takes it, anything else swaps; heroes never merge. Rows hold 7.
    public static func move(_ rows: inout [[ArmySlot]], from: (row: Int, k: Int), to: (row: Int, k: Int), split: Int? = nil) -> Bool {
        guard from.k < rows[from.row].count, from != to else { return false }
        let src = rows[from.row][from.k]
        if to.k < rows[to.row].count, let a = src.stack, let b = rows[to.row][to.k].stack, a.creature == b.creature {
            let n = min(a.count, split ?? a.count)
            rows[to.row][to.k] = .stack(Hero.Stack(creature: b.creature, count: b.count + n))
            if n >= a.count { rows[from.row].remove(at: from.k) } else { rows[from.row][from.k] = .stack(Hero.Stack(creature: a.creature, count: a.count - n)) }
            return true
        }
        if to.k >= rows[to.row].count {   // an empty place
            if let n = split, let a = src.stack, n < a.count {
                guard rows[to.row].count < rowSlots, n > 0 else { return false }
                rows[from.row][from.k] = .stack(Hero.Stack(creature: a.creature, count: a.count - n))
                rows[to.row].append(.stack(Hero.Stack(creature: a.creature, count: n)))
                return true
            }
            if from.row != to.row && rows[to.row].count >= rowSlots { return false }
            rows[from.row].remove(at: from.k)
            rows[to.row].append(src)
            return true
        }
        // swap
        let other = rows[to.row][to.k]
        rows[to.row][to.k] = src
        rows[from.row][from.k] = other
        return true
    }
    /// Everything of one row into the other (Move Up / Move Down, 0x647280): same creatures merge,
    /// the rest fill free slots.
    public static func moveAll(_ rows: inout [[ArmySlot]], from: Int, to: Int) {
        var keep: [ArmySlot] = []
        for s in rows[from] {
            if let a = s.stack, let k = rows[to].firstIndex(where: { $0.stack?.creature == a.creature }) {
                rows[to][k] = .stack(Hero.Stack(creature: a.creature, count: rows[to][k].stack!.count + a.count))
            } else if rows[to].count < rowSlots { rows[to].append(s) } else { keep.append(s) }
        }
        rows[from] = keep
    }

    /// Apply the town screen's rows: the garrison, and the visiting army (or the spare one).
    /// False (and nothing changed) when the army would be left with creatures but no hero.
    public func applyTownRows(_ i: Int, _ rows: [[ArmySlot]], visitor: Hero?) -> Bool {
        if let v = visitor {
            if rows[1].compactMap({ $0.hero }).isEmpty && !rows[1].isEmpty { return false }
            setGarrison(i, rows[0]); setArmy(v, rows[1])
        } else {
            setGarrison(i, rows[0])
        }
        return true
    }
    /// The town screen closes with a spare row holding something (0x8b0e50 -> 0x4bada0): it becomes
    /// an army at the gate (or the nearest free cell); creatures without a hero go back in.
    public func leaveTown(_ i: Int, spare: [ArmySlot]) {
        guard !spare.isEmpty else { return }
        let hs = spare.compactMap { $0.hero }
        guard let lead = hs.first, let p = townPlaced(i) else {
            towns[i].garrison += spare.compactMap { $0.stack }
            return
        }
        let back = level; level = towns[i].z; defer { level = back }
        let gates = gateCells(p)
        guard let cell = gates.first(where: { isVacant($0, for: lead) && enemyAt($0.0, $0.1) == nil }) ?? freeCell(near: gates[0].0, gates[0].1) else {
            setGarrison(i, garrisonSlots(i) + spare); return
        }
        lead.x = cell.0; lead.y = cell.1; lead.z = towns[i].z; lead.owner = map.humanColour
        lead.companions = Array(hs.dropFirst()); lead.army = spare.compactMap { $0.stack }
        lead.path = []; lead.plan = []; lead.target = nil
        lead.maxMovement = armyMovement(lead)
        heroes.insert(lead, at: 0)
    }

    /// Recruits go into the garrison (0x894470): onto a stack of theirs or a free slot.
    public func addToGarrison(_ i: Int, _ creature: String, _ count: Int) -> Bool {
        if let k = towns[i].garrison.firstIndex(where: { $0.creature == creature }) { towns[i].garrison[k].count += count; return true }
        guard garrisonSlots(i).count < GameState.rowSlots else { return false }
        towns[i].garrison.append(Hero.Stack(creature: creature, count: count))
        return true
    }
}
