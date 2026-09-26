import Foundation

/// The other players' heroes and battles between heroes (heroes4.exe 0x80eb70 / 0x7fd530 /
/// 0x7fe8a0): the moving army attacks from the bottom left; the winner's living heroes share the
/// loser's casualties' experience (creatures' Experience x killed, (level + 1) x 100 per hero,
/// divided by the difficulty for a human winner), weighted by level + 2; all the loser's
/// artifacts go to the winner; the loser's heroes are taken prisoner.
extension GameState {
    public func enemyAt(_ x: Int, _ y: Int) -> Hero? { enemyHeroes.first { $0.z == level && $0.x == x && $0.y == y } }

    /// An enemy army on the map: its cell blocks the way.
    public func place(enemy h: Hero) {
        enemyHeroes.append(h)
        if h.z < passabilities.count { passabilities[h.z].block(h.x, h.y) }
    }
    func removeEnemy(_ h: Hero) {
        enemyHeroes.removeAll { $0 === h }
        if h.z < passabilities.count { passabilities[h.z].free(h.x, h.y) }
    }

    /// Walk up to an enemy army and attack it.
    func attack(_ e: Hero, with hero: Hero) {
        if GameState.adjacent((hero.x, hero.y), (e.x, e.y)) { pendingHeroBattle = (hero, e); return }
        let cells = (-1...1).flatMap { dx in (-1...1).map { dy in (e.x + dx, e.y + dy) } }.filter { $0 != (e.x, e.y) && isVacant($0, for: hero) }
        var best: [(x: Int, y: Int)]? = nil, bestN = Int.max
        for c in cells { if let p = passability.path(from: (hero.x, hero.y), to: c), p.count < bestN { best = p; bestN = p.count } }
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
        let mine = [hero] + hero.companions, theirs = [enemy] + enemy.companions
        if won {
            hero.army = army
            share(value + theirs.reduce(0) { $0 + ($1.level + 1) * 100 }, among: mine)
            // the booty: every artifact of the beaten army, into the first hero's backpack
            for h in theirs { hero.backpack += h.equipped.compactMap { $0 } + h.backpack }
            removeEnemy(enemy)
            log.append("\(enemy.name)'s army is destroyed; \(theirs.map { $0.name }.joined(separator: ", ")) taken prisoner")
        } else {
            enemy.army = enemyArmy
            share(value + mine.reduce(0) { $0 + ($1.level + 1) * 100 }, among: theirs)
            for h in mine { enemy.backpack += h.equipped.compactMap { $0 } + h.backpack }
            heroes.removeAll { $0 === hero }
            log.append("\(hero.name)'s army is destroyed")
        }
        refreshMovement(hero)
        pendingHeroBattle = nil
        checkScenario(newDay: false)
    }

    /// A siege is over (0x8965e0): won, the town is the player's (a hero is needed, and there is
    /// one), its garrison gone; lost, the defenders keep their survivors and the army is beaten.
    public func finishSiege(hero: Hero, town i: Int, won: Bool, army: [Hero.Stack], garrison: [Hero.Stack], value: Int) {
        clearBattleEffects(hero)
        if won {
            hero.army = army
            share(value, among: [hero] + hero.companions)
            towns[i].garrison = []
            let previous = towns[i].owner
            towns[i].owned = true; towns[i].owner = map.humanColour
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
        checkScenario(newDay: false)
    }
}
