import Foundation

/// The other players' heroes and battles between heroes (heroes4.exe 0x80eb70 / 0x7fd530 /
/// 0x7fe8a0): the moving army attacks from the bottom left; the winner's living heroes share the
/// loser's casualties' experience (creatures' Experience x killed, (level + 1) x 100 per hero,
/// divided by the difficulty for a human winner), weighted by level + 2; all the loser's
/// artifacts go to the winner; the loser's heroes are taken prisoner.
extension GameState {
    public func enemyAt(_ x: Int, _ y: Int) -> Hero? { enemyHeroes.first { $0.z == level && $0.x == x && $0.y == y } }

    /// The battlefield of a fight in which an army is aboard a ship (0x62bf60 -> 0x62af00, each
    /// side's ship from its creature array, vtable+0x18 = army +0xc8, -1 on land): one ship -- an
    /// army on the shore against one aboard, or a ship against a stack -- fights on that ship's
    /// deck, battlefield_preset_map.<alignment>.single (0x62a050); two ships lie side by side, the
    /// attacker's <alignment>.lower and the defender's <alignment>.upper (0x629c70 / 0x629e60).
    /// Both armies then stand in formation 5 (0x62d987). nil: no ship, the land field of the
    /// terrain. The exe's names run Life, Order, Death, Chaos, Nature, Might (0x628300); a ship of
    /// no alignment has no preset there (an empty handle), the remake takes the neutral deck.
    public static func shipField(attacker: String?, defender: String?) -> [String]? {
        func name(_ a: String) -> String {
            ["life": "Life", "order": "Order", "death": "Death", "chaos": "Chaos", "nature": "Nature", "might": "Might"][a.lowercased()] ?? "neutral"
        }
        switch (attacker, defender) {
        case (nil, nil): return nil
        case let (a?, d?): return ["\(name(a)).lower", "\(name(d)).upper"]
        case let (a?, nil): return ["\(name(a)).single"]
        case let (nil, d?): return ["\(name(d)).single"]
        }
    }

    /// An enemy army on the map: its cell blocks the way.
    public func place(enemy h: Hero) {
        enemyHeroes.append(h)
        if h.z < passabilities.count { passabilities[h.z].block(h.x, h.y) }
    }
    func removeEnemy(_ h: Hero) {
        enemyHeroes.removeAll { $0 === h }
        if h.z < passabilities.count { passabilities[h.z].free(h.x, h.y) }
    }

    /// Walk up to an enemy army and attack it: the first click plans, a click on the army the
    /// route leads to goes -- next to it too (0x4f5c80: its route is the one step onto it).
    func attack(_ e: Hero, with hero: Hero) {
        if GameState.adjacent((hero.x, hero.y), (e.x, e.y)) {
            if hero.attackTarget === e, hero.plan.isEmpty {   // an empty walk list: face it, then the attack (0x544ce0, 0x522560)
                hero.attackTarget = nil; face(hero, toward: (e.x, e.y)); armyReached(hero, enemy: e); pendingHeroBattle = (hero, e); moveEnded(hero)
            }
            else { hero.plan = []; hero.attackTarget = e; hero.target = nil; hero.tradeTarget = nil }
            return
        }
        let cells = (-1...1).flatMap { dx in (-1...1).map { dy in (e.x + dx, e.y + dy) } }.filter { $0 != (e.x, e.y) && isVacant($0, for: hero) }
        var best: [(x: Int, y: Int)]? = nil, bestN = Int.max
        for c in cells { if let p = passability.path(from: (hero.x, hero.y), to: c, afloat: hero.boat != nil), p.count < bestN { best = p; bestN = p.count } }
        guard let route = best else { return }
        if hero.attackTarget === e, !hero.plan.isEmpty { hero.path = hero.plan; hero.plan = []; hero.progress = 0; return }
        hero.plan = route; hero.attackTarget = e; hero.target = nil
    }

    /// Experience shared by an army's living heroes: by level + 2 each, or equally (0x641310).
    public func share(_ n: Int, among hs: [Hero], equally: Bool = false) {
        var remaining = n
        var w = hs.reduce(0) { $0 + (equally ? 1 : $1.level + 2) }
        for h in hs {
            let wi = equally ? 1 : h.level + 2
            guard w > 0 else { break }
            let part = Int((Double(wi) * Double(remaining) / Double(w)).rounded())
            remaining -= part; w -= wi
            giveExperience(part, toOnly: h)
        }
    }

    /// A battle between heroes is over: `won` for the player's army. `army` / `enemyArmy` are the
    /// survivors, `value` the experience of the loser's casualties.
    public func finishHeroBattle(hero: Hero, enemy: Hero, won: Bool, army: [Hero.Stack], enemyArmy: [Hero.Stack], value: Int) {
        clearBattleEffects(hero)
        let mine = hero.members, theirs = enemy.members
        if won { recordBattleWin(colour: map.humanColour, winnerValue: armyValue(hero), loserValue: armyValue(enemy)) }
        else { recordBattleWin(colour: enemy.owner, winnerValue: armyValue(enemy), loserValue: armyValue(hero)) }
        if won {
            hero.army = army
            share(value + theirs.reduce(0) { $0 + ($1.level + 1) * 100 }, among: mine)
            // the booty: every artifact of the beaten army to the first hero (0x7fb560)
            giveLoot(theirs.flatMap { $0.equipped.compactMap { $0 } + $0.backpack }, to: hero)
            for h in theirs { h.equipped = Array(repeating: nil, count: h.equipped.count); h.backpack = [] }
            removeEnemy(enemy)
            log.append("\(enemy.name)'s army is destroyed; \(theirs.map { $0.name }.joined(separator: ", ")) taken prisoner")
        } else {
            enemy.army = enemyArmy
            share(value + mine.reduce(0) { $0 + ($1.level + 1) * 100 }, among: theirs)
            giveLoot(mine.flatMap { $0.equipped.compactMap { $0 } + $0.backpack }, to: enemy)
            for h in mine { h.equipped = Array(repeating: nil, count: h.equipped.count); h.backpack = [] }
            heroes.removeAll { $0 === hero }
            log.append("\(hero.name)'s army is destroyed")
        }
        refreshMovement(hero)
        pendingHeroBattle = nil
        checkScenario()
    }

    /// A siege is over (0x8965e0): won, the town is the player's (a hero is needed, and there is
    /// one), its garrison gone; lost, the defenders keep their survivors and the army is beaten.
    public func finishSiege(hero: Hero, town i: Int, won: Bool, army: [Hero.Stack], garrison: [Hero.Stack], value: Int) {
        clearBattleEffects(hero)
        let defenders = armyValue(towns[i].garrison) + towns[i].garrisonHeroes.reduce(0) { $0 + 100 * ($1.level + 1) }
        if won { recordBattleWin(colour: map.humanColour, winnerValue: armyValue(hero), loserValue: defenders) }
        else if let o = townOwner(towns[i]) { recordBattleWin(colour: o, winnerValue: defenders, loserValue: armyValue(hero)) }
        if won {
            hero.army = army
            share(value, among: hero.members)
            towns[i].garrison = []
            let previous = towns[i].owner
            towns[i].owned = true; towns[i].owner = map.humanColour
            caravansAtCapture(town: i, newOwner: map.humanColour)
            log.append(text("town_captured_town.misc", "You have captured %town_name.").replacingOccurrences(of: "%town_name", with: towns[i].name))
            runTownEvent(i, slot: 1, previousOwner: previous, hero: hero)
        } else {
            towns[i].garrison = garrison
            runTownEvent(i, slot: 2, hero: hero)   // "attack repelled"
            heroes.removeAll { $0 === hero }
            log.append("\(hero.name)'s army is destroyed at \(towns[i].name)")
        }
        refreshMovement(hero)
        pendingSiege = nil
        checkScenario()
    }
}
