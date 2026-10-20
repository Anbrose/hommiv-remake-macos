import Foundation

/// Armies meeting (heroes4.exe 0x522560, esi the army reached, edi the one arriving): a ship that
/// sails into an empty ship takes it (0x524610: the reached army, empty and aboard, gets the
/// arriving army's owner), and the two then meet as any armies of one owner do. A computer's two
/// armies trade at once (0x486f80): the stronger becomes the main army and gathers, swap by swap,
/// the most valuable seven places it can hold; the other keeps the rest, and leaves the map when
/// left empty (an empty one aboard leaves its ship).
extension GameState {
    /// Is the colour played by the computer (player +0x88)?
    func isComputer(_ owner: Int) -> Bool { owner != map.humanColour }

    /// Two armies of one owner (or team) met: the computer's trade at once when both are the
    /// computer's (0x522a48 -> 0x486f80), the army screen otherwise (0x522b4f).
    func armiesMet(arriving m: Hero, reached r: Hero) {
        if isComputer(r.owner), r.owner == m.owner { aiTrade(reached: r, arriving: m) } else { pendingTrade = (m, r) }
    }

    /// The computer's trade on contact (0x486f80 with 0x484bb0 / 0x484da0 / 0x4857f0): the main
    /// army is the reached one when worth strictly more (0x6421d0), else the arriving one. Two
    /// map armies with at most two heroes between them pool their places (the same creatures
    /// merged) sorted by worth (stack vt+0x10), the weakest seven into the main row from its
    /// first place, the stronger rest into the other's; otherwise the rows stay as they are.
    /// Then, while one exists, the swap of a main place with an other place that raises the main
    /// row's worth most is made -- never one leaving it heroless or giving it a third hero, and a
    /// heroless main row always takes a hero. The rows are kept only when the main row ends
    /// worth more than it was (> 0.0, [0x970e6c]). Returns whether they were.
    @discardableResult
    func aiTrade(reached r: Hero, arriving m: Hero) -> Bool {
        let rr = armySlots(r), mr = armySlots(m)
        let rMain = aiArmyValue(rr) > aiArmyValue(mr)
        let (main, other) = rMain ? (r, m) : (m, r)
        guard let rows = GameState.aiTradeRows(main: rMain ? rr : mr, other: rMain ? mr : rr,
                                               value: { [unowned self] in aiArmyValue($0) }, worth: { [unowned self] in aiPlaceWorth($0) }) else { return false }
        setArmies([(main, rows.main), (other, rows.other)])
        return true
    }

    /// A place's worth to the trade's sort (0x485c70, the place's vt+0x10): a stack's creatures
    /// count x experience, a hero's value.
    func aiPlaceWorth(_ s: ArmySlot) -> Float {
        switch s {
        case .stack(let st): return Float(st.count) * Float(tables?.creature(st.creature)?.experience ?? 0)
        case .hero(let h): return heroValue(h)
        }
    }

    /// The trade's rows (see aiTrade): nil when the main row would not gain.
    static func aiTradeRows(main: [ArmySlot?], other: [ArmySlot?], value: ([ArmySlot?]) -> Float, worth: (ArmySlot) -> Float) -> (main: [ArmySlot?], other: [ArmySlot?])? {
        let n = rowSlots
        func pad(_ r: [ArmySlot?]) -> [ArmySlot?] { Array((r + [ArmySlot?](repeating: nil, count: n)).prefix(n)) }
        var a = pad(main), b = pad(other)
        let start = value(a)
        func heroes(_ r: [ArmySlot?]) -> Int { r.filter { $0?.hero != nil }.count }
        // 0x484da0: two map armies with at most two heroes between them pool their places (0x4852b0)
        if heroes(a) + heroes(b) <= 2 {
            var pool: [ArmySlot] = []
            for s in (a + b).compactMap({ $0 }) {
                if case .stack(let st) = s, let k = pool.firstIndex(where: { $0.stack?.creature == st.creature }), let have = pool[k].stack {
                    pool[k] = .stack(Hero.Stack(creature: st.creature, count: have.count + st.count))
                } else { pool.append(s) }
            }
            let sorted = pool.enumerated().sorted { (worth($0.element), -$0.offset) > (worth($1.element), -$1.offset) }.map(\.element)
            a = [ArmySlot?](repeating: nil, count: n); b = a
            // from the weakest: the main row's places 0..6, then the other's
            for (k, s) in sorted.reversed().enumerated() { if k < n { a[k] = s } else { b[k - n] = s } }
        }
        // 0x4857f0, again while it finds one
        while true {
            let base = value(a), h0 = heroes(a)
            var best: (i: Int, j: Int, gain: Float)? = nil
            for i in 0..<n { for j in 0..<n {
                if a[i] == nil && b[j] == nil { continue }
                swap(&a[i], &b[j])
                let h1 = heroes(a)
                if !((h0 < h1 && h1 > 2) || (h1 == 0 && h0 != 0)) {
                    let g = value(a) - base
                    if g > 0 { if best == nil || g > best!.gain { best = (i, j, g) } }
                    else if h0 == 0 && h1 == 1 { best = (i, j, .greatestFiniteMagnitude) }
                }
                swap(&a[i], &b[j])
            } }
            guard let p = best else { break }
            swap(&a[p.i], &b[p.j])
        }
        return value(a) - start > 0 ? (a, b) : nil
    }

    /// A ship reaching an empty ship (0x522583 -> 0x524610): the empty ship, an army with no
    /// creatures aboard, becomes the arriving army's owner's; then the two meet (armiesMet).
    func takeOverEmptyShip(_ hero: Hero, _ b: Int) {
        let s = boats.remove(at: b)
        let e = heroless(like: hero)
        e.x = s.x; e.y = s.y; e.z = s.z; e.boat = s.alignment; e.owner = hero.owner
        e.facing = Hero.facing(dx: hero.x - s.x, dy: hero.y - s.y)
        e.listRank = nextListRank()
        e.maxMovement = armyMovement(e); e.movement = e.maxMovement
        face(hero, toward: (s.x, s.y))
        // the player's armies stand on open cells, the other players' block theirs
        if heroes.contains(where: { $0 === hero }) { heroes.append(e); if s.z < passabilities.count { passabilities[s.z].free(s.x, s.y) } } else { enemyHeroes.append(e) }
        armiesMet(arriving: hero, reached: e)
        // the computer's trade left it empty: it stays an empty ship, now the owner's
        if pendingTrade?.other !== e, e.army.isEmpty, e.companions.isEmpty, heroes.contains(where: { $0 === e }) || enemyHeroes.contains(where: { $0 === e }) {
            setArmy(e, [])
        }
    }

    /// At sea, a click on an empty ship: sail beside it, then take it (two clicks, as any route).
    func sailToEmptyShip(_ hero: Hero, _ b: Int) {
        let c = (boats[b].x, boats[b].y)
        if GameState.adjacent(standingCell(hero), c) {
            if hero.boardTarget.map({ $0 == c }) == true, hero.plan.isEmpty { hero.boardTarget = nil; takeOverEmptyShip(hero, b) }
            else { hero.plan = []; hero.boardTarget = c; hero.target = nil; hero.planGoal = c }
            return
        }
        if hero.boardTarget.map({ $0 == c }) == true, !hero.plan.isEmpty { hero.path = hero.plan; hero.plan = []; hero.progress = 0; return }
        var best: [(x: Int, y: Int)]? = nil
        for d in GameState.directions {
            let n = (c.0 + d.0, c.1 + d.1)
            guard passability.isFreeWater(n.0, n.1), isVacant(n, for: hero) || n == standingCell(hero) else { continue }
            if let r = passability.path(from: standingCell(hero), to: n, afloat: true), best == nil || r.count < best!.count { best = r }
        }
        guard let r = best else { return }
        hero.plan = r; hero.boardTarget = c; hero.target = nil; hero.planGoal = c
    }
}
