import Foundation

/// Creature dwellings on the adventure map (t_adv_dwelling, re/map_dwelling_spec.md).
///
/// - Population is kept in fourteenths of a creature (dwelling +0xac): a new dwelling holds one
///   week's growth (growth x 14, 0x43c8c2); an owned one gains `growth` fourteenths a day (half a
///   week's growth a week, 0x43cdb0); the dialog offers population / 14.
/// - An unowned dwelling of level 2..4 is guarded by its own creature: round(budget / experience)
///   with budget 166 / 750 / 2000 by level (table 0xa4cc24, 0x43c862); the guards grow while it is
///   unowned, by min(count / 10, growth) a week in 256ths (t_creature 0x63e2e0), instead of the
///   population.
/// - A visit (0x43cf10): an ally's dwelling refuses ("refused_ally"); another player's or a
///   neutral one with guards asks "guarded" and fights them; else 0x43d8e0: flag it (a hero is
///   needed: "no_heroes"), then "empty" under one creature, "no_room.dwelling" without room for
///   the creature, else the recruit dialog (t_recruit_dialog 0x7f5b00, the town's one) with the
///   population and the gold price less the best creature discount of the army's heroes (artifact
///   effect 6, 0x641cc0 / 0x7266d0), rounded.
extension GameState {
    /// The guards' worth by creature level (0xa4cc24).
    public static let dwellingGuardBudget = [0, 0, 166, 750, 2000]

    /// How many of its creature guard a fresh unowned dwelling ((budget + xp / 2) / xp, 0x43c892).
    public static func dwellingGuards(_ c: CreatureDef) -> Int {
        let budget = dwellingGuardBudget[max(0, min(4, c.level))]
        guard budget > 0, c.experience > 0 else { return 0 }
        return (budget + c.experience / 2) / c.experience
    }

    /// The best creature-cost discount (percent) of an army's heroes' worn artifacts (effect 6).
    public func recruitDiscount(_ heroes: [Hero]) -> Int {
        heroes.flatMap { $0.artifactEffects }.filter { $0.type == 6 }.map(\.amount).max().map { max(0, $0) } ?? 0
    }
    /// The price of one creature in every material (table order, gold first), the gold less the
    /// discount: (gold x (100 - pct) + 50) / 100 (0x43df37, 0x8b530d).
    public func recruitCost(_ c: CreatureDef, discount: Int) -> [(String, Int)] { GameState.recruitCost(c, discount: discount) }
    public static func recruitCost(_ c: CreatureDef, discount: Int) -> [(String, Int)] {
        var cost = c.cost.isEmpty ? ["Gold": c.gold] : c.cost
        cost["Gold"] = max(0, ((cost["Gold"] ?? 0) * (100 - discount) + 50) / 100)
        return GameState.recruitMaterials.compactMap { m in cost[m].flatMap { $0 != 0 || m == "Gold" ? (m, $0) : nil } }
    }
    public static let recruitMaterials = ["Gold", "Wood", "Ore", "Crystal", "Sulfur", "Mercury", "Gems"]
    /// The dialog's maximum and starting count (0x7fa822): what waits, and what every priced
    /// material pays for.
    public func recruitMost(available: Int, cost: [(String, Int)]) -> Int {
        var n = available
        for (m, v) in cost where v > 0 { n = min(n, (resources[m] ?? 0) / v) }
        return max(0, n)
    }
    /// Can the hero's army take this creature (a stack of it, or a free slot of the seven)?
    public func canAccept(_ creature: String, _ hero: Hero) -> Bool {
        hero.army.contains { $0.creature == creature } || 1 + hero.companions.count + hero.army.count < Hero.armySlots
    }

    /// What the recruit dialog of a dwelling offers: the creature, how many wait, the price.
    public func dwellingOffer(_ i: Int, for hero: Hero) -> (creature: CreatureDef, available: Int, cost: [(String, Int)])? {
        guard dwellings.indices.contains(i), let c = tables?.creature(dwellings[i].creature) else { return nil }
        return (c, dwellings[i].available, recruitCost(c, discount: recruitDiscount(hero.members)))
    }

    /// Buy creatures of a dwelling into the hero's army (the dialog's Buy, 0x43e03a).
    @discardableResult
    public func recruit(fromDwelling i: Int, count: Int, to hero: Hero) -> Bool {
        guard count > 0, let o = dwellingOffer(i, for: hero), count <= recruitMost(available: o.available, cost: o.cost),
              canAccept(o.creature.keyword, hero), add(o.creature.keyword, count, to: hero) else { return false }
        dwellings[i].available -= count
        for (m, v) in o.cost { resources[m, default: 0] -= v * count }
        log.append("recruited \(count) \(count == 1 ? o.creature.name : o.creature.plural)")
        return true
    }

    /// A dwelling's own table text ("Guarded", "Empty", ...) with its placeholders.
    func dwellingText(_ p: MapScene.Placed, _ i: Int, _ key: String, _ extra: [String: String] = [:]) -> String? {
        guard let c = tables?.creature(dwellings[i].creature) else { return nil }
        var subs = ["%creature_name": c.plural, "%Creature_name": c.plural.prefix(1).uppercased() + c.plural.dropFirst(), "%object_name": dwellingName(p)]
        for (k, v) in extra { subs[k] = v }
        return objectText(p, key, subs)
    }

    /// The dwelling's own name (a random one by what it became: its sprite names the table row).
    func dwellingName(_ p: MapScene.Placed) -> String {
        var short = p.name.replacingOccurrences(of: "adv_object.creature generators.", with: "").replacingOccurrences(of: ".h4d", with: "").lowercased()
        if short.hasSuffix(" r") { short.removeLast(2) }
        if let (major, minor) = tables?.objectNames[short], let n = tables?.objectText(major, minor, "name") { return n }
        return tables?.objectText(p.type, p.subtype, "name") ?? short
    }

    /// A hero walks into a dwelling (0x43cf10).
    func visitDwelling(hero: Hero, _ i: Int, _ p: MapScene.Placed) {
        hero.target = nil
        let me = actingColour
        dwellings[i].visited.insert(me)   // the visitor's bit in +0xb0
        if isHumanActing { sounds.append("dialogue.recruit") }   // dialogue sound 0x12 at every visit
        if let o = dwellings[i].owner, o != me, let team = map.teams[me], map.teams[o] == team {
            if isHumanActing, let t = objectText(p, "refused_ally", ["%name": dwellingName(p)]) { scripts.messages.append(t) }
            return
        }
        if dwellings[i].owner != me, dwellings[i].guards > 0, let c = tables?.creature(dwellings[i].creature) {
            let n = dwellings[i].guards
            let words = "\(n) \(n == 1 ? c.name : c.plural)"
            let text = dwellingText(p, i, "guarded", ["%creatures": words, "%Creatures": words]) ?? "Fight them?"
            let fight: () -> Void = { [weak self] in
                guard let self = self else { return }
                var m = Monster(x: p.cellX, y: p.cellY, name: p.name, creature: c.keyword, count: n)
                m.z = self.level; m.bank = GameState.dwellingPrefix + "\(i)"
                self.monsters.append(m)
                self.fight(hero: hero, monsterAt: self.monsters.count - 1, p)
            }
            if isHumanActing { sounds.append("dialogue.recruit"); question = (text, fight) } else { fight() }
            return
        }
        dwellingRecruitFlow(hero: hero, i, p)
    }

    /// The flag and the offer (0x43d8e0), also after the guards are beaten.
    func dwellingRecruitFlow(hero: Hero, _ i: Int, _ p: MapScene.Placed) {
        guard let c = tables?.creature(dwellings[i].creature) else { return }
        let me = actingColour
        if dwellings[i].owner != me {
            dwellings[i].owner = me; dwellings[i].owned = isHumanActing
            if isHumanActing { sounds.append("miscellaneous.flag_mine") }
        }
        if dwellings[i].available < 1 {
            if isHumanActing, let t = dwellingText(p, i, "empty") { scripts.messages.append(t) }
            return
        }
        if !isHumanActing {   // the computer buys what it can afford (0x4879e0, simplified)
            let n = recruitMost(available: dwellings[i].available, cost: recruitCost(c, discount: recruitDiscount(hero.members)))
            if n > 0, canAccept(c.keyword, hero) { recruit(fromDwelling: i, count: n, to: hero) }
            return
        }
        guard canAccept(c.keyword, hero) else {
            scripts.messages.append((tables?.strings["no_room.dwelling"] ?? "Unfortunately, you have no room in your army to add %creature_name.")
                .replacingOccurrences(of: "%creature_name", with: c.plural))
            return
        }
        dwellingOpen = (i, hero)
    }

    /// An owned dwelling's day: `growth` fourteenths more (0x43cdb0).
    public static func populationDay(_ available: Int, _ fourteenths: Int, growth: Int) -> (Int, Int) {
        let f = fourteenths + growth
        return (available + f / 14, f % 14)
    }
    /// Unowned guards' day: min(count x 256 / 10, growth x 256) / 7 more 256ths (t_creature 0x63e328).
    public static func guardsDay(_ count: Int, _ fraction: Int, growth: Int) -> (Int, Int) {
        let f = fraction + min(count * 256 / 10, growth * 256) / 7
        return (count + (f >> 8), f & 0xff)
    }

    static let dwellingPrefix = "dwelling|"
    /// The dwelling whose guards a battle's monster is.
    func guardedDwelling(_ monster: Monster) -> Int? {
        guard let key = monster.bank, key.hasPrefix(GameState.dwellingPrefix) else { return nil }
        return Int(key.dropFirst(GameState.dwellingPrefix.count))
    }

    /// Owned dwellings grow; an unowned one's guards grow instead (0x43cdb0 daily).
    func dwellingsNewDay() {
        for i in dwellings.indices {
            guard let c = tables?.creature(dwellings[i].creature) else { continue }
            if dwellings[i].owner != nil {
                (dwellings[i].available, dwellings[i].fourteenths) = GameState.populationDay(dwellings[i].available, dwellings[i].fourteenths, growth: c.growth)
            } else if dwellings[i].guards > 0 {
                (dwellings[i].guards, dwellings[i].guardFraction) = GameState.guardsDay(dwellings[i].guards, dwellings[i].guardFraction, growth: c.growth)
            }
        }
    }
}

extension GameState {
    /// The right-click text of a dwelling (0x43e0e0): "help" until the player has visited it, then
    /// "help_ally" (an ally's), "help_empty" (under one creature), "help_guarded" (someone else's
    /// with guards) or "help_visited".
    func dwellingHelpKey(_ i: Int) -> String {
        let me = map.humanColour, d = dwellings[i]
        guard d.visited.contains(me) else { return "help" }
        if let o = d.owner, o != me, let team = map.teams[me], map.teams[o] == team { return "help_ally" }
        if d.available < 1 { return "help_empty" }
        if d.owner != me, d.guards > 0 { return "help_guarded" }
        return "help_visited"
    }
}

extension GameState {
    /// Debugging: a hero visits a map dwelling as if walking into it.
    public func debugVisitDwelling(hero: Hero, _ p: MapScene.Placed) -> Bool {
        guard let i = dwelling(for: p) else { return false }
        visitDwelling(hero: hero, i, p); return true
    }
}
