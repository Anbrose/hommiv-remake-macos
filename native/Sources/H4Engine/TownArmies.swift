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
    /// A row as its seven places: the items put back where the row's keys say they stood, the
    /// rest into the first free places.
    static func layout(_ items: [ArmySlot], keys: [String?]) -> [ArmySlot?] {
        var row = [ArmySlot?](repeating: nil, count: rowSlots)
        let itemKeys = GameState.keys(of: items.map { Optional($0) })
        var used = Set<Int>()
        for (k, key) in keys.prefix(rowSlots).enumerated() {
            guard let key = key, let j = itemKeys.indices.first(where: { !used.contains($0) && itemKeys[$0] == key }) else { continue }
            row[k] = items[j]; used.insert(j)
        }
        for j in items.indices where !used.contains(j) {
            if let k = row.firstIndex(where: { $0 == nil }) { row[k] = items[j] }
        }
        return row
    }
    /// Each place's key: a hero by identity, a stack by creature and which of that creature it is.
    static func keys(of row: [ArmySlot?]) -> [String?] {
        var seen: [String: Int] = [:]
        return row.map { s -> String? in
            switch s {
            case .hero(let h)?: return "h:\(ObjectIdentifier(h).hashValue)"
            case .stack(let st)?: let n = seen[st.creature, default: 0]; seen[st.creature] = n + 1; return "c:\(st.creature)#\(n)"
            case nil: return nil
            }
        }
    }
    public func garrisonSlots(_ i: Int) -> [ArmySlot?] {
        GameState.layout(towns[i].garrisonHeroes.map { .hero($0) } + towns[i].garrison.map { .stack($0) }, keys: towns[i].rowKeys)
    }
    public func garrisonCount(_ i: Int) -> Int { towns[i].garrisonHeroes.count + towns[i].garrison.count }
    public func armySlots(_ h: Hero) -> [ArmySlot?] {
        GameState.layout(([h] + h.companions).map { .hero($0) } + h.army.map { .stack($0) }, keys: h.rowKeys)
    }

    public func setGarrison(_ i: Int, _ row: [ArmySlot?]) {
        towns[i].garrisonHeroes = row.compactMap { $0?.hero }
        towns[i].garrison = row.compactMap { $0?.stack }
        towns[i].rowKeys = GameState.keys(of: row)
    }
    /// Put a row back into the army: its first hero leads it (taking over the army's place on the
    /// map), an army left with nothing leaves the map. False when creatures would be left without
    /// a hero (armies here are led by one).
    @discardableResult
    public func setArmy(_ h: Hero, _ row: [ArmySlot?]) -> Bool {
        let hs = row.compactMap { $0?.hero }, stacks = row.compactMap { $0?.stack }
        guard let lead = hs.first else {
            if !stacks.isEmpty { return false }
            heroes.removeAll { $0 === h }
            return true
        }
        if lead !== h {
            lead.x = h.x; lead.y = h.y; lead.z = h.z; lead.facing = h.facing; lead.owner = h.owner
            lead.path = []; lead.plan = []; lead.target = nil
            if let k = heroes.firstIndex(where: { $0 === h }) { heroes[k] = lead } else { heroes.insert(lead, at: 0) }
            if let v = townVisitor, v.hero === h { townVisitor = (v.town, lead) }
            h.companions = []; h.army = []; h.rowKeys = []
        }
        lead.companions = Array(hs.dropFirst())
        lead.army = stacks
        lead.rowKeys = GameState.keys(of: row)
        lead.maxMovement = armyMovement(lead); lead.movement = min(lead.movement, lead.maxMovement)
        return true
    }

    /// A drop of place `from` on place `to` (0x646d40): an empty place takes it (or `split` of it),
    /// the same creature merges, anything else swaps; heroes never merge.
    public static func move(_ rows: inout [[ArmySlot?]], from: (row: Int, k: Int), to: (row: Int, k: Int), split: Int? = nil) -> Bool {
        guard from != to, let src = rows[from.row][from.k] else { return false }
        let dst = rows[to.row][to.k]
        if let a = src.stack, dst == nil || dst?.stack?.creature == a.creature {
            let n = min(a.count, split ?? a.count)
            guard n > 0 else { return false }
            let have = dst?.stack?.count ?? 0
            rows[to.row][to.k] = .stack(Hero.Stack(creature: a.creature, count: have + n))
            rows[from.row][from.k] = n >= a.count ? nil : .stack(Hero.Stack(creature: a.creature, count: a.count - n))
            return true
        }
        rows[to.row][to.k] = src
        rows[from.row][from.k] = dst
        return true
    }
    /// Everything of one row into the other (Move Up / Move Down, 0x647280): same creatures merge,
    /// the rest fill free places.
    public static func moveAll(_ rows: inout [[ArmySlot?]], from: Int, to: Int) {
        for k in rows[from].indices {
            guard let s = rows[from][k] else { continue }
            if let a = s.stack, let j = rows[to].firstIndex(where: { $0?.stack?.creature == a.creature }) {
                rows[to][j] = .stack(Hero.Stack(creature: a.creature, count: rows[to][j]!.stack!.count + a.count)); rows[from][k] = nil
            } else if let j = rows[to].firstIndex(where: { $0 == nil }) {
                rows[to][j] = s; rows[from][k] = nil
            }
        }
    }

    /// Apply the town screen's rows: the garrison, and the visiting army.
    /// False (and nothing changed) when the army would be left with creatures but no hero.
    public func applyTownRows(_ i: Int, _ rows: [[ArmySlot?]], visitor: Hero?) -> Bool {
        if let v = visitor {
            let rest = rows[1].compactMap { $0 }
            if !rest.isEmpty && !rest.contains(where: { $0.hero != nil }) { return false }
            setGarrison(i, rows[0]); setArmy(v, rows[1])
        } else {
            setGarrison(i, rows[0])
        }
        return true
    }
    /// The town screen closes with a spare row holding something (0x8b0e50 -> 0x4bada0): it becomes
    /// an army at the gate (or the nearest free cell); creatures without a hero go back in.
    public func leaveTown(_ i: Int, spare row: [ArmySlot?]) {
        let spare = row.compactMap { $0 }
        guard !spare.isEmpty else { return }
        let hs = spare.compactMap { $0.hero }
        guard let lead = hs.first, let p = townPlaced(i) else {
            towns[i].garrison += spare.compactMap { $0.stack }
            return
        }
        let back = level; level = towns[i].z; defer { level = back }
        let gates = gateCells(p)
        guard let cell = gates.first(where: { isVacant($0, for: lead) && enemyAt($0.0, $0.1) == nil }) ?? freeCell(near: gates[0].0, gates[0].1) else {
            towns[i].garrisonHeroes += hs; towns[i].garrison += spare.compactMap { $0.stack }; return
        }
        lead.x = cell.0; lead.y = cell.1; lead.z = towns[i].z; lead.owner = map.humanColour
        lead.companions = Array(hs.dropFirst()); lead.army = spare.compactMap { $0.stack }; lead.rowKeys = GameState.keys(of: row)
        lead.path = []; lead.plan = []; lead.target = nil
        lead.maxMovement = armyMovement(lead)
        heroes.insert(lead, at: 0)
    }

    /// Recruits go into the garrison (0x894470): onto a stack of theirs or a free slot.
    public func addToGarrison(_ i: Int, _ creature: String, _ count: Int) -> Bool {
        if let k = towns[i].garrison.firstIndex(where: { $0.creature == creature }) { towns[i].garrison[k].count += count; return true }
        guard garrisonCount(i) < GameState.rowSlots else { return false }
        towns[i].garrison.append(Hero.Stack(creature: creature, count: count))
        return true
    }
}
