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
    /// The player's army visiting the town (0x8abe60): the one that walked in, else the first army
    /// standing on a cell in front of the gate (the entering neighbours in the exe's order), not at sea.
    public func visitingArmy(town i: Int) -> Hero? {
        if let v = townVisitor, v.town == i, heroes.contains(where: { $0 === v.hero }) { return v.hero }
        let z = towns[i].z
        for c in townEntryNeighbours(i) {
            if let h = heroes.first(where: { $0.z == z && $0.boat == nil && $0.x == c.0 && $0.y == c.1 }) { return h }
        }
        return nil
    }

    /// The cells a step from which enters the town (0x4f9be0): for each of its trigger cells
    /// (0x44cdd0; model cells, the first coordinate outer) its 8 neighbours in the exe's direction
    /// order whose step back toward it crosses an entry edge (0x4d7300) -- the cells in front of
    /// the gate. A model without entry edges falls back to the remake's gate cells.
    public func townEntryNeighbours(_ i: Int) -> [(Int, Int)] {
        guard let p = townPlaced(i) else { return [] }
        let back = level; level = towns[i].z; defer { level = back }
        let pass = passability
        var out: [(Int, Int)] = []
        for dx in 0..<p.sprite.footprint.w { for dy in 0..<p.sprite.footprint.h {
            let t = (p.cellX + dx, p.cellY + dy)
            guard pass.isTrigger(t.0, t.1) else { continue }
            for d in GameState.directions {
                let n = (t.0 + d.0, t.1 + d.1)
                guard n.0 >= 0, n.1 >= 0, n.0 < map.size, n.1 < map.size, pass.enters(from: n.0, n.1, to: t.0, t.1) else { continue }
                if !out.contains(where: { $0 == n }) { out.append(n) }
            }
        } }
        return out.isEmpty ? gateCells(p) : out
    }

    /// Where an army leaving the town stands (0x4f9ea0, filter 0x4fa120): the first cell in front
    /// of the gate that is free land with no trigger, army or ship on it; failing that the nearest
    /// such cell by route from the town (0x4fa3e0, the planner's settle order [I: cheapest route,
    /// then the lower cell index]). Nil when there is none.
    public func townExitCell(_ i: Int) -> (Int, Int)? {
        guard townPlaced(i) != nil else { return nil }
        let z = towns[i].z
        let back = level; level = z; defer { level = back }
        let pass = passability
        func free(_ c: (Int, Int)) -> Bool {
            pass.isFree(c.0, c.1) && !pass.isWater(c.0, c.1) && !pass.isTrigger(c.0, c.1)
                && !heroes.contains { $0.z == z && standingCell($0) == c }
                && !enemyHeroes.contains { $0.z == z && $0.x == c.0 && $0.y == c.1 }
                && !boats.contains { $0.z == z && $0.x == c.0 && $0.y == c.1 }
        }
        let front = townEntryNeighbours(i)
        if let c = front.first(where: free) { return c }
        let r = pass.search(fromAll: front)
        var best: (cost: Int32, cell: Int)? = nil
        for (k, g) in r.cost.enumerated() where g < .max {
            let c = (k / pass.size, k % pass.size)
            guard free(c), best.map({ g < $0.cost }) ?? true else { continue }
            best = (g, k)
        }
        return best.map { ($0.cell / pass.size, $0.cell % pass.size) }
    }

    /// Does the town screen offer the empty visiting row (0x8b5eb0)? No army visits, the player has
    /// fewer than 8 armies (0x7e1a70) and an army could stand outside (0x4f9ea0 / 0x4fa3e0).
    public func townOffersVisitingRow(_ i: Int) -> Bool {
        visitingArmy(town: i) == nil && heroes.count < GameState.maxArmies && townExitCell(i) != nil
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
        GameState.layout(h.members.map { .hero($0) } + h.army.map { .stack($0) }, keys: h.rowKeys)
    }

    public func setGarrison(_ i: Int, _ row: [ArmySlot?]) {
        towns[i].garrisonHeroes = row.compactMap { $0?.hero }
        towns[i].garrison = row.compactMap { $0?.stack }
        towns[i].rowKeys = GameState.keys(of: row)
    }
    /// Put a row back into the army: its first hero leads it (taking over the army's place on the
    /// map); creatures without a hero stay a heroless army (army_split_spec.md §6); an army left
    /// with nothing leaves the map (0x4bb0f0). Returns the army object now holding the row.
    @discardableResult
    public func setArmy(_ h: Hero, _ row: [ArmySlot?]) -> Hero? {
        let hs = row.compactMap { $0?.hero }, stacks = row.compactMap { $0?.stack }
        if hs.isEmpty && stacks.isEmpty {
            heroes.removeAll { $0 === h }
            if let v = townVisitor, v.hero === h { townVisitor = nil }
            return nil
        }
        let lead: Hero = hs.first ?? (h.heroless ? h : heroless(like: h))
        if lead !== h {
            lead.x = h.x; lead.y = h.y; lead.z = h.z; lead.facing = h.facing; lead.owner = h.owner
            lead.path = []; lead.plan = []; lead.target = nil; lead.listRank = h.listRank
            if lead.heroless || h.heroless { lead.movement = h.movement }
            if let k = heroes.firstIndex(where: { $0 === h }) { heroes[k] = lead } else { heroes.insert(lead, at: 0) }
            if let v = townVisitor, v.hero === h { townVisitor = (v.town, lead) }
            h.companions = []; h.army = []; h.rowKeys = []
        }
        lead.companions = lead.heroless ? [] : Array(hs.dropFirst())
        lead.army = stacks
        lead.rowKeys = GameState.keys(of: row)
        refreshHeroless(lead)
        lead.maxMovement = armyMovement(lead); lead.movement = min(lead.movement, lead.maxMovement)
        return lead
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

    /// Apply the town screen's rows: the garrison, and the visiting army (creatures left without a
    /// hero stay outside as a heroless army).
    @discardableResult
    public func applyTownRows(_ i: Int, _ rows: [[ArmySlot?]], visitor: Hero?) -> Bool {
        if let v = visitor {
            setGarrison(i, rows[0]); setArmy(v, rows[1])
        } else {
            setGarrison(i, rows[0])
        }
        return true
    }
    /// The town screen closes (or switches town) with the visiting row offered and holding
    /// something (0x8b6010 / 0x8affc0 -> 0x4bada0): it becomes the player's army on the exit cell
    /// (searched again), with or without a hero, and is selected; the town remembers it as its
    /// visitor (town+0x124). With nowhere to stand (never at the exe's opening check) the troops
    /// go back into the garrison [remake]. Returns the new army.
    @discardableResult
    public func leaveTown(_ i: Int, spare row: [ArmySlot?]) -> Hero? {
        let spare = row.compactMap { $0 }
        guard !spare.isEmpty else { return nil }
        let hs = spare.compactMap { $0.hero }
        guard heroes.count < GameState.maxArmies, let cell = townExitCell(i) else {
            towns[i].garrisonHeroes += hs; towns[i].garrison += spare.compactMap { $0.stack }
            return nil
        }
        let lead: Hero = hs.first ?? {
            let h = Hero(actor: "", x: 0, y: 0, movement: 0); h.heroless = true; h.name = ""
            h.alignment = towns[i].alignment; return h
        }()
        lead.x = cell.0; lead.y = cell.1; lead.z = towns[i].z; lead.owner = map.humanColour
        if lead.heroless { lead.home = cell }
        lead.companions = lead.heroless ? [] : Array(hs.dropFirst())
        lead.army = spare.compactMap { $0.stack }; lead.rowKeys = GameState.keys(of: row)
        lead.path = []; lead.plan = []; lead.target = nil; lead.listRank = nextListRank()
        refreshHeroless(lead)
        // garrison stacks have the day's full movement (new-day refresh / a recruit's, 0x63e2e0);
        // a hero keeps what it has left; the army goes at its slowest member's pace
        lead.maxMovement = armyMovement(lead)
        lead.movement = lead.heroless ? lead.maxMovement : min(lead.movement, lead.maxMovement)
        heroes.append(lead)
        select(lead)   // 0x4b5eb0
        townVisitor = (i, lead)
        updateVision()
        return lead
    }

    /// Recruits go into the garrison (0x894470): onto a stack of theirs or a free slot.
    public func addToGarrison(_ i: Int, _ creature: String, _ count: Int) -> Bool {
        if let k = towns[i].garrison.firstIndex(where: { $0.creature == creature }) { towns[i].garrison[k].count += count; return true }
        guard garrisonCount(i) < GameState.rowSlots else { return false }
        towns[i].garrison.append(Hero.Stack(creature: creature, count: count))
        return true
    }
}
