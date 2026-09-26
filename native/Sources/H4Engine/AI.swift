import Foundation

/// The computer players. Each takes its turn when the human ends his: its towns build and hire,
/// its heroes go for what is worth most for the way (resources, mines and generators, dwellings,
/// monsters it can beat, towns, the player's armies when it is the stronger). Its fights with
/// monsters and garrisons are resolved at once; an attack on the player's army opens the battle.
extension GameState {
    static let startingResources: [String: Int] = ["Gold": 15000, "Wood": 15, "Ore": 15, "Mercury": 7, "Sulfur": 7, "Crystal": 7, "Gems": 7]

    /// The computer players: the scenario's other colours that own a town or a hero.
    public var aiPlayers: [Int] {
        Set(towns.compactMap { $0.owner }).union(enemyHeroes.map { $0.owner }).filter { $0 != map.humanColour }.sorted()
    }

    /// Run with a computer player's treasury and ownership.
    func acting<T>(as colour: Int, _ body: () -> T) -> T {
        let saved = resources, savedQuick = quickCombatOnly
        resources = aiResources[colour] ?? GameState.startingResources
        acting = colour; quickCombatOnly = true
        let r = body()
        aiResources[colour] = resources
        resources = saved; acting = nil; quickCombatOnly = savedQuick
        return r
    }

    /// An army's strength for comparing armies (the quick-combat threat of each stack).
    public func strength(_ h: Hero) -> Float {
        combatants(of: h).reduce(0) { $0 + QuickCombat.threat($1) + Float($1.hitPoints * $1.count) }
    }
    func strength(monster m: Monster) -> Float {
        guard let t = tables else { return 0 }
        var out: Float = 0
        for (c, n) in [(m.creature, m.count)] + m.extra.map({ ($0.creature, $0.count) }) {
            if let d = t.creature(c) { let s = Combatant(creature: d, count: n); out += QuickCombat.threat(s) + Float(s.hitPoints * n) }
        }
        return out
    }

    /// One computer player's day.
    func aiTurn(_ colour: Int) {
        acting(as: colour) {
            // income: its towns' halls, its mines
            for t in towns where t.owner == colour { resources["Gold", default: 0] += hallIncome(t) }
            for m in mines where m.owner == colour { resources[m.resource, default: 0] += m.amount }
            // towns: build what it can, hire what it can afford into the garrison
            for i in towns.indices where towns[i].owner == colour {
                if let t = tables {
                    let options = t.buildings(for: towns[i].alignment).filter { canBuild($0, in: towns[i]) }
                    // dwellings first, the higher the better, then the rest by cost
                    if let b = options.max(by: { a, b in (a.creature != nil ? 10000 : 0) + a.cost["Gold", default: 0] < (b.creature != nil ? 10000 : 0) + b.cost["Gold", default: 0] }) {
                        build(b, in: i)
                    }
                    for (c, n) in towns[i].available.sorted(by: { (t.creature($0.key)?.level ?? 0) > (t.creature($1.key)?.level ?? 0) }) where n > 0 {
                        guard let d = t.creature(c), d.gold > 0 else { continue }
                        let k = min(n, resources["Gold", default: 0] / d.gold)
                        guard k > 0 else { continue }
                        if let g = towns[i].garrison.firstIndex(where: { $0.creature == c }) { towns[i].garrison[g].count += k }
                        else if towns[i].garrison.count < 7 { towns[i].garrison.append(Hero.Stack(creature: c, count: k)) } else { continue }
                        towns[i].available[c, default: 0] -= k
                        resources["Gold", default: 0] -= k * d.gold
                    }
                }
            }
            // a player with towns and no hero hires one at its first town (2500 gold)
            if !enemyHeroes.contains(where: { $0.owner == colour }), resources["Gold", default: 0] >= 2500,
               let t = towns.first(where: { $0.owner == colour }), let p = scenes[t.z].placed.first(where: { $0.category == "castle" && $0.cellX == t.x && $0.cellY == t.y }) {
                let back = level; level = t.z
                if let cell = gateCells(p).first(where: { passability.isFree($0.0, $0.1) && enemyAt($0.0, $0.1) == nil }) {
                    var mh = MapHero(); mh.level = 1
                    let e = Hero.fromMap(mh, alignment: t.alignment, x: cell.0, y: cell.1, tables: tables, random: &random)
                    e.owner = colour; e.z = t.z; e.home = cell
                    resources["Gold", default: 0] -= 2500
                    place(enemy: e)
                }
                level = back
            }
            // heroes
            for h in enemyHeroes where h.owner == colour {
                h.maxMovement = armyMovement(h); h.movement = h.maxMovement
                aiMove(h)
            }
        }
    }

    /// A computer hero's moves for the day: the best target by value per day of travel, walked
    /// to with the day's movement, used when reached; again while it has movement and targets.
    func aiMove(_ h: Hero) {
        let back = level
        level = h.z
        defer { level = back }
        var steps = 0
        while h.movement >= 1, steps < 6, pendingHeroBattle == nil {
            steps += 1
            guard let goal = aiTarget(h) else { return }
            // walk: the cells before the goal (the goal itself is the object, the army or the town gate)
            passability.free(h.x, h.y)
            var moved = false
            for c in goal.path {
                let cost = passability.stepCost(from: h.x, h.y, to: c.x, c.y)
                if h.movement + 0.001 < cost { break }
                if !isVacant((c.x, c.y), for: h) || enemyAt(c.x, c.y) != nil { break }
                h.movement -= cost; h.x = c.x; h.y = c.y; moved = true
            }
            passability.block(h.x, h.y)
            if (h.x, h.y) == (goal.stand.0, goal.stand.1) || GameState.adjacent((h.x, h.y), goal.at) {
                goal.use()
            } else if !moved { return }
        }
    }

    /// What the computer hero goes for: (path to where it stands, the target cell, what it does there).
    func aiTarget(_ h: Hero) -> (path: [(x: Int, y: Int)], stand: (Int, Int), at: (Int, Int), use: () -> Void)? {
        let ours = strength(h)
        var best: (score: Float, path: [(x: Int, y: Int)], stand: (Int, Int), at: (Int, Int), use: () -> Void)? = nil
        func consider(_ value: Float, at cell: (Int, Int), stand: [(Int, Int)], use: @escaping () -> Void) {
            guard value > 0 else { return }
            let d = abs(cell.0 - h.x) + abs(cell.1 - h.y)
            guard d < 40 else { return }
            // a rough first cut before the path search
            if let b = best, value / Float(1 + d / 20) <= b.score { return }
            for s in stand where (s.0 == h.x && s.1 == h.y) || isVacant(s, for: h) {
                let path: [(x: Int, y: Int)]
                if s.0 == h.x && s.1 == h.y { path = [] }
                else {
                    passability.free(h.x, h.y)
                    let p = passability.path(from: (h.x, h.y), to: s)
                    passability.block(h.x, h.y)
                    guard let pp = p else { continue }
                    path = pp
                }
                let days = 1 + Int(Float(path.count) / max(1, h.maxMovement))
                let score = value / Float(days)
                if score > (best?.score ?? 0) { best = (score, path, s, cell, use) }
                break
            }
        }
        func around(_ p: MapScene.Placed) -> [(Int, Int)] {
            var out: [(Int, Int)] = []
            for dx in -1...p.sprite.footprint.w { for dy in -1...p.sprite.footprint.h where dx == -1 || dy == -1 || dx == p.sprite.footprint.w || dy == p.sprite.footprint.h {
                let c = (p.cellX + dx, p.cellY + dy)
                if canUse(from: c, p) { out.append(c) }
            } }
            return out
        }
        for p in scene.placed {
            let cells = around(p)
            guard !cells.isEmpty else { continue }
            if let i = monster(for: p) {
                let them = strength(monster: monsters[i])
                if ours > them * 1.5 { consider(Float(monsters[i].count * (tables?.creature(monsters[i].creature)?.experience ?? 10)) + 200, at: (p.cellX, p.cellY), stand: cells) { [weak self] in self?.aiUse(h, p) } }
            } else if let i = town(for: p), towns[i].owner == h.owner, !towns[i].garrison.isEmpty {
                // its own town's garrison: taken along
                let g = Float(towns[i].garrison.reduce(0) { $0 + (tables?.creature($1.creature)?.gold ?? 0) * $1.count })
                consider(g, at: (p.cellX, p.cellY), stand: [gateCells(p)[0]]) { [weak self] in
                    guard let self = self else { return }
                    for st in self.towns[i].garrison {
                        if let k = h.army.firstIndex(where: { $0.creature == st.creature }) { h.army[k].count += st.count }
                        else if h.army.count + 1 + h.companions.count < Hero.armySlots { h.army.append(st) } else { continue }
                        self.towns[i].garrison.removeAll { $0.creature == st.creature }
                    }
                    self.refreshMovement(h)
                }
            } else if let i = town(for: p), towns[i].owner != h.owner {
                let gate = gateCells(p)
                let g = Float(towns[i].garrison.reduce(0) { $0 + (tables?.creature($1.creature)?.gold ?? 0) * $1.count })
                if ours > g * 1.2 { consider(6000, at: (p.cellX, p.cellY), stand: [gate[0]]) { [weak self] in self?.aiUse(h, p) } }
            } else if let i = mine(for: p), mines[i].owner != h.owner {
                consider(mines[i].resource == "Gold" ? 1500 : 800, at: (p.cellX, p.cellY), stand: cells) { [weak self] in self?.aiUse(h, p) }
            } else if hasVisit(p) || isPickup(p) {
                let st = objectStates[objectKey(p)]
                var v: Float = 0
                switch p.type {
                case "material_pile", "random_material_pile": v = Float((st?.amount ?? 0) * GameState.materialValue[st?.material ?? 0])
                case "campfire", "flotsam": v = Float((st?.gold ?? 0) + (st?.amount ?? 0) * 125)
                case "treasure", "artifact", "random_artifact", "corpse", "shipwreck_survivor": v = Float(max(st?.gold ?? 0, 1200))
                case "windmill", "weekly_material_generator", "random_weekly_material_generator": v = st?.owner == h.owner ? 0 : 900
                case "academy", "arena", "training_grounds", "mercenary_camp", "sacred_grove", "sphinx": v = h.visitedObjects.contains(objectKey(p)) ? 0 : 700
                case "magic_gem": v = 800
                case "creature_bank": if let s = st, s.guardCounts.contains(where: { $0 > 0 }) { v = ours > Float(s.worth) * 2 ? Float(s.worth) : 0 }
                default: v = 0
                }
                consider(v, at: (p.cellX, p.cellY), stand: cells) { [weak self] in self?.aiUse(h, p) }
            } else if let i = dwelling(for: p), dwellings[i].available > 0 {
                consider(Float(dwellings[i].available * (tables?.creature(dwellings[i].creature)?.gold ?? 0)) / 2, at: (p.cellX, p.cellY), stand: cells) { [weak self] in self?.aiUse(h, p) }
            }
        }
        // the player's armies it is stronger than
        for ph in heroes where ph.z == h.z {
            let theirs = strength(ph)
            guard ours > theirs * 1.3 else { continue }
            let stand = (-1...1).flatMap { dx in (-1...1).map { (ph.x + dx, ph.y + $0) } }.filter { $0 != (ph.x, ph.y) }
            consider(4000 + theirs / 10, at: (ph.x, ph.y), stand: stand) { [weak self] in
                self?.pendingHeroBattle = (ph, h); self?.aiAttacking = true
                self?.log.append("\(h.name) attacks \(ph.name)!")
            }
        }
        return best.map { ($0.path, $0.stand, $0.at, $0.use) }
    }

    /// A computer hero uses an object: at once, with no questions (yes to buying, the gold from
    /// chests, the first choice), its fights quickly resolved.
    func aiUse(_ h: Hero, _ p: MapScene.Placed) {
        let msgs = scripts.messages.count, fl = floaters.count, snd = sounds.count, lg = log.count
        if let i = town(for: p), !towns[i].garrison.isEmpty, towns[i].owner != h.owner {
            // a garrisoned town: the siege resolved at once
            let t = tables
            let defenders = towns[i].garrison.compactMap { s in t?.creature(s.creature).map { Combatant(creature: $0, count: s.count) } }
            let r = QuickCombat.fight(attackers: combatants(of: h), defenders: defenders, seed: day * 31 + i)
            h.army = r.attackers.filter { $0.alive && !$0.isHero }.map { s in Hero.Stack(creature: t?.creatures.first { $0.name == s.name }?.keyword ?? s.name, count: s.count) }
            towns[i].garrison = r.defenders.filter { $0.alive }.map { s in Hero.Stack(creature: t?.creatures.first { $0.name == s.name }?.keyword ?? s.name, count: s.count) }
            if r.attackerWon {
                let lost = towns[i].owned
                towns[i].owner = h.owner; towns[i].owned = false; towns[i].garrison = []
                if lost { log.append(text("town_lost_town.misc", "The enemy has taken the town of %town_name.").replacingOccurrences(of: "%town_name", with: towns[i].name)) }
            } else { removeEnemy(h) }
            return
        }
        interact(hero: h, p)
        if let q = question { question = nil; q.yes() }
        if let c = choice { choice = nil; c.pick(0) }
        if let offer = chestOffer, offer.hero === h { chestOffer = nil; resources["Gold", default: 0] += offer.gold }
        if enteredTown != nil { enteredTown = nil }
        // nothing of it for the player's screen
        if scripts.messages.count > msgs { scripts.messages.removeSubrange(msgs...) }
        if floaters.count > fl { floaters.removeSubrange(fl...) }
        if sounds.count > snd { sounds.removeSubrange(snd...) }
        if log.count > lg { log.removeSubrange(lg...) }
    }
}
